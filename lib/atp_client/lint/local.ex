defmodule AtpClient.Lint.Local do
  @moduledoc """
  Pure-Elixir structural checker for TPTP input.

  Runs in microseconds on typical problem sizes, so it can drive the
  editor feedback loop on every keystroke without going through the
  network. Catches the common classes of errors that TPTP4X would
  otherwise flag after a round-trip:

    * unmatched / mismatched brackets (`(`, `[`, `{`);
    * unterminated block comments and quoted atoms;
    * unknown TPTP language prefix (e.g. `fff` instead of `fof`);
    * unknown formula role (e.g. `axim` instead of `axiom`);
    * a statement body that never sees its closing `)` and `.`.
    * juxtaposed identifiers (e.g. `F X` in THF where `F @ X` is required).

  The checker is intentionally forgiving inside formula bodies: it does
  not try to parse the logical content, only the TPTP framing around
  it. That keeps the code small and lets us delegate the authoritative
  syntactic and type analysis to TPTP4X.

  `analyze/1` additionally walks `type`-role statements and returns a
  list of `AtpClient.Lint.Symbol`s — used by the Smart Cell to power
  Monaco hover and completion.
  """

  alias AtpClient.Lint.{Diagnostic, Symbol, Report}

  # Top-level language prefixes recognised at statement position.
  @languages ~w(thf tff fof cnf tpi tcf)

  # Formula roles recognised in the 3rd field of a top-level statement.
  @roles ~w(
    axiom hypothesis definition assumption lemma theorem corollary
    conjecture negated_conjecture plain type fi_domain fi_functors
    fi_predicates interpretation unknown
  )

  @doc """
  Tokenises `source`, checks it for structural issues, and extracts any
  symbol declarations. Always returns a `Report` — a lexer-level
  failure (e.g. unterminated block comment) surfaces as a single
  diagnostic and an empty symbol list.
  """
  @spec analyze(String.t()) :: Report.t()
  def analyze(source) when is_binary(source) do
    case tokenize(source) do
      {:ok, tokens} ->
        diagnostics =
          (check_brackets(tokens) ++ check_statements(tokens))
          |> Enum.sort_by(&{&1.line, &1.column})

        %Report{diagnostics: diagnostics, symbols: extract_symbols(tokens)}

      {:error, diag} ->
        %Report{diagnostics: [diag], symbols: []}
    end
  end

  @doc """
  Convenience wrapper matching the `AtpClient.Lint` backend contract.
  """
  @spec check(String.t(), keyword()) :: {:ok, [Diagnostic.t()]}
  def check(source, _opts \\ []) do
    %Report{diagnostics: diags} = analyze(source)
    {:ok, diags}
  end

  defp tokenize(source), do: tok(source, 1, 1, [])

  defp tok("", _l, _c, acc), do: {:ok, Enum.reverse(acc)}

  defp tok("\r\n" <> rest, l, _c, acc), do: tok(rest, l + 1, 1, acc)
  defp tok("\n" <> rest, l, _c, acc), do: tok(rest, l + 1, 1, acc)
  defp tok("\r" <> rest, l, _c, acc), do: tok(rest, l + 1, 1, acc)

  defp tok(" " <> rest, l, c, acc), do: tok(rest, l, c + 1, acc)
  defp tok("\t" <> rest, l, c, acc), do: tok(rest, l, c + 1, acc)

  defp tok("%" <> rest, l, c, acc) do
    {rest, c2} = skip_line_comment(rest, c + 1)
    tok(rest, l, c2, acc)
  end

  defp tok("/*" <> rest, l, c, acc) do
    case skip_block(rest, l, c + 2) do
      {:ok, rest, l2, c2} ->
        tok(rest, l2, c2, acc)

      :error ->
        {:error,
         %Diagnostic{
           line: l,
           column: c,
           severity: :error,
           source: "local",
           message: "unterminated block comment"
         }}
    end
  end

  defp tok("(" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:lparen, l, c} | acc])
  defp tok(")" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:rparen, l, c} | acc])
  defp tok("[" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:lbracket, l, c} | acc])
  defp tok("]" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:rbracket, l, c} | acc])
  defp tok("{" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:lbrace, l, c} | acc])
  defp tok("}" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:rbrace, l, c} | acc])
  defp tok("," <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:comma, l, c} | acc])
  defp tok(":" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:colon, l, c} | acc])
  defp tok("." <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:dot, l, c} | acc])

  defp tok("'" <> rest, l, c, acc) do
    case scan_quoted(rest, ?', l, c + 1, []) do
      {:ok, str, rest2, l2, c2} ->
        tok(rest2, l2, c2, [{:sqstring, l, c, str} | acc])

      :error ->
        {:error,
         %Diagnostic{
           line: l,
           column: c,
           severity: :error,
           source: "local",
           message: "unterminated single-quoted atom"
         }}
    end
  end

  defp tok("\"" <> rest, l, c, acc) do
    case scan_quoted(rest, ?", l, c + 1, []) do
      {:ok, str, rest2, l2, c2} ->
        tok(rest2, l2, c2, [{:dqstring, l, c, str} | acc])

      :error ->
        {:error,
         %Diagnostic{
           line: l,
           column: c,
           severity: :error,
           source: "local",
           message: "unterminated double-quoted string"
         }}
    end
  end

  defp tok("$" <> rest, l, c, acc) do
    {tail, rest2, c2} = scan_word_body(rest, c + 1, [])
    tok(rest2, l, c2, [{:lident, l, c, "$" <> tail} | acc])
  end

  defp tok(<<ch, _::binary>> = str, l, c, acc) when ch in ?a..?z do
    {name, rest, c2} = scan_word_body(str, c, [])
    tok(rest, l, c2, [{:lident, l, c, name} | acc])
  end

  defp tok(<<ch, _::binary>> = str, l, c, acc) when ch in ?A..?Z or ch == ?_ do
    {name, rest, c2} = scan_word_body(str, c, [])
    tok(rest, l, c2, [{:uident, l, c, name} | acc])
  end

  defp tok(<<ch, _::binary>> = str, l, c, acc) when ch in ?0..?9 do
    {num, rest, c2} = scan_number(str, c, [])
    tok(rest, l, c2, [{:number, l, c, num} | acc])
  end

  defp tok(<<ch::utf8, rest::binary>>, l, c, acc) do
    tok(rest, l, c + 1, [{:other, l, c, <<ch::utf8>>} | acc])
  end

  # --- scanner helpers ----------------------------------------------------

  defp skip_line_comment("\n" <> _ = rest, c), do: {rest, c}
  defp skip_line_comment("\r" <> _ = rest, c), do: {rest, c}
  defp skip_line_comment("", c), do: {"", c}
  defp skip_line_comment(<<_, rest::binary>>, c), do: skip_line_comment(rest, c + 1)

  defp skip_block("", _l, _c), do: :error
  defp skip_block("*/" <> rest, l, c), do: {:ok, rest, l, c + 2}
  defp skip_block("\r\n" <> rest, l, _c), do: skip_block(rest, l + 1, 1)
  defp skip_block("\n" <> rest, l, _c), do: skip_block(rest, l + 1, 1)
  defp skip_block("\r" <> rest, l, _c), do: skip_block(rest, l + 1, 1)
  defp skip_block(<<_::utf8, rest::binary>>, l, c), do: skip_block(rest, l, c + 1)

  defp scan_quoted("", _q, _l, _c, _acc), do: :error

  defp scan_quoted(<<?\\, ch, rest::binary>>, q, l, c, acc) do
    scan_quoted(rest, q, l, c + 2, [<<?\\, ch>> | acc])
  end

  defp scan_quoted(<<q, rest::binary>>, q, l, c, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, l, c + 1}
  end

  defp scan_quoted("\r\n" <> rest, q, l, _c, acc),
    do: scan_quoted(rest, q, l + 1, 1, ["\n" | acc])

  defp scan_quoted("\n" <> rest, q, l, _c, acc),
    do: scan_quoted(rest, q, l + 1, 1, ["\n" | acc])

  defp scan_quoted("\r" <> rest, q, l, _c, acc),
    do: scan_quoted(rest, q, l + 1, 1, ["\r" | acc])

  defp scan_quoted(<<ch::utf8, rest::binary>>, q, l, c, acc) do
    scan_quoted(rest, q, l, c + 1, [<<ch::utf8>> | acc])
  end

  defp scan_word_body(<<ch, rest::binary>>, c, acc)
       when ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9 or ch == ?_ do
    scan_word_body(rest, c + 1, [ch | acc])
  end

  defp scan_word_body(rest, c, acc),
    do: {acc |> Enum.reverse() |> List.to_string(), rest, c}

  defp scan_number(<<ch, rest::binary>>, c, acc) when ch in ?0..?9 do
    scan_number(rest, c + 1, [ch | acc])
  end

  defp scan_number(rest, c, acc),
    do: {acc |> Enum.reverse() |> List.to_string(), rest, c}

  defp check_brackets(tokens), do: do_check_brackets(tokens, [], [])

  defp do_check_brackets([], stack, acc) do
    dangling =
      Enum.map(stack, fn {ch, l, c} ->
        %Diagnostic{
          line: l,
          column: c,
          end_line: l,
          end_column: c + 1,
          severity: :error,
          source: "local",
          message: "unmatched opening `#{ch}`"
        }
      end)

    Enum.reverse(acc, dangling)
  end

  defp do_check_brackets([{kind, l, c} | rest], stack, acc)
       when kind in [:lparen, :lbracket, :lbrace] do
    do_check_brackets(rest, [{open_char(kind), l, c} | stack], acc)
  end

  defp do_check_brackets([{kind, l, c} | rest], stack, acc)
       when kind in [:rparen, :rbracket, :rbrace] do
    expected = open_of(kind)

    case stack do
      [{^expected, _, _} | rest_stack] ->
        do_check_brackets(rest, rest_stack, acc)

      [] ->
        diag = %Diagnostic{
          line: l,
          column: c,
          end_line: l,
          end_column: c + 1,
          severity: :error,
          source: "local",
          message: "unmatched closing `#{close_char(kind)}`"
        }

        do_check_brackets(rest, [], [diag | acc])

      [{other, ol, oc} | rest_stack] ->
        diag = %Diagnostic{
          line: l,
          column: c,
          end_line: l,
          end_column: c + 1,
          severity: :error,
          source: "local",
          message:
            "mismatched `#{close_char(kind)}`; expected closer for `#{other}` " <>
              "opened at line #{ol}, column #{oc}"
        }

        do_check_brackets(rest, rest_stack, [diag | acc])
    end
  end

  defp do_check_brackets([_ | rest], stack, acc),
    do: do_check_brackets(rest, stack, acc)

  defp open_char(:lparen), do: "("
  defp open_char(:lbracket), do: "["
  defp open_char(:lbrace), do: "{"

  defp close_char(:rparen), do: ")"
  defp close_char(:rbracket), do: "]"
  defp close_char(:rbrace), do: "}"

  defp open_of(:rparen), do: "("
  defp open_of(:rbracket), do: "["
  defp open_of(:rbrace), do: "{"

  defp check_statements(tokens), do: walk_top(tokens, [])

  defp walk_top([], acc), do: Enum.reverse(acc)

  defp walk_top(tokens, acc) do
    {diags, rest} = consume_statement(tokens)
    walk_top(rest, Enum.reverse(diags, acc))
  end

  defp consume_statement([{:lident, l, c, name} | rest]) do
    cond do
      name in @languages ->
        consume_lang_stmt(name, l, c, rest)

      name == "include" ->
        {_, rest2} = skip_past_dot(rest, 0)
        {[], rest2}

      true ->
        diag = %Diagnostic{
          line: l,
          column: c,
          end_line: l,
          end_column: c + String.length(name),
          severity: :error,
          source: "local",
          message:
            "unknown TPTP language prefix `#{name}`; expected one of: " <>
              Enum.join(@languages, ", ") <> ", or `include`"
        }

        {_, rest2} = skip_past_dot(rest, 0)
        {[diag], rest2}
    end
  end

  defp consume_statement([{:dot, _l, _c} | rest]), do: {[], rest}

  defp consume_statement([{_type, l, c} = _tok | rest]) do
    diag = %Diagnostic{
      line: l,
      column: c,
      severity: :error,
      source: "local",
      message: "expected a TPTP statement here (e.g. `fof(...)` or `tff(...)`)"
    }

    {_, rest2} = skip_past_dot(rest, 0)
    {[diag], rest2}
  end

  defp consume_statement([{_type, l, c, _} = _tok | rest]) do
    diag = %Diagnostic{
      line: l,
      column: c,
      severity: :error,
      source: "local",
      message: "expected a TPTP statement here (e.g. `fof(...)` or `tff(...)`)"
    }

    {_, rest2} = skip_past_dot(rest, 0)
    {[diag], rest2}
  end

  defp consume_lang_stmt(lang, ll, lc, [{:lparen, _pl, _pc} | rest]) do
    {body_diags, rest2} = walk_body(rest, 1, 0, ll, lc, lang, [], nil)

    case rest2 do
      [{:dot, _, _} | rest3] ->
        {body_diags, rest3}

      [] ->
        diag = %Diagnostic{
          line: ll,
          column: lc,
          end_line: ll,
          end_column: lc + String.length(lang),
          severity: :error,
          source: "local",
          message: "`#{lang}` statement is not terminated with `.`"
        }

        {[diag | body_diags], []}

      [{_, l, c} | _] = rest3 ->
        diag = %Diagnostic{
          line: l,
          column: c,
          severity: :error,
          source: "local",
          message: "expected `.` to terminate `#{lang}` statement"
        }

        {_, rest4} = skip_past_dot(rest3, 0)
        {[diag | body_diags], rest4}

      [{_, l, c, _} | _] = rest3 ->
        diag = %Diagnostic{
          line: l,
          column: c,
          severity: :error,
          source: "local",
          message: "expected `.` to terminate `#{lang}` statement"
        }

        {_, rest4} = skip_past_dot(rest3, 0)
        {[diag | body_diags], rest4}
    end
  end

  defp consume_lang_stmt(lang, ll, lc, rest) do
    {l, c} =
      case rest do
        [{_, l, c} | _] -> {l, c}
        [{_, l, c, _} | _] -> {l, c}
        [] -> {ll, lc + String.length(lang)}
      end

    diag = %Diagnostic{
      line: l,
      column: c,
      severity: :error,
      source: "local",
      message: "expected `(` after `#{lang}`"
    }

    {_, rest2} = skip_past_dot(rest, 0)
    {[diag], rest2}
  end

  defp walk_body([], _depth, _fi, ll, lc, lang, acc, _prev_id) do
    diag = %Diagnostic{
      line: ll,
      column: lc,
      severity: :error,
      source: "local",
      message: "unterminated `#{lang}` statement (missing `)`)"
    }

    {Enum.reverse([diag | acc]), []}
  end

  defp walk_body([{:rparen, _, _} | rest], 1, _fi, _ll, _lc, _lang, acc, _prev_id) do
    {Enum.reverse(acc), rest}
  end

  defp walk_body([{kind, _, _} | rest], depth, fi, ll, lc, lang, acc, _prev_id)
       when kind in [:lparen, :lbracket, :lbrace] do
    walk_body(rest, depth + 1, fi, ll, lc, lang, acc, nil)
  end

  defp walk_body([{kind, _, _} | rest], depth, fi, ll, lc, lang, acc, _prev_id)
       when kind in [:rparen, :rbracket, :rbrace] do
    walk_body(rest, max(depth - 1, 1), fi, ll, lc, lang, acc, nil)
  end

  defp walk_body([{:comma, _cl, _cc} | rest], 1, fi, ll, lc, lang, acc, _prev_id) do
    new_fi = fi + 1

    acc =
      if new_fi == 1 do
        case role_diagnostic(rest) do
          nil -> acc
          diag -> [diag | acc]
        end
      else
        acc
      end

    walk_body(rest, 1, new_fi, ll, lc, lang, acc, nil)
  end

  defp walk_body(
         [{kind, _l, _c, _name} = tok | rest],
         depth,
         fi,
         ll,
         lc,
         lang,
         acc,
         prev_id
       )
       when kind in [:lident, :uident, :number, :sqstring, :dqstring] do
    acc =
      case adjacency_diagnostic(prev_id, tok, fi, lang) do
        nil -> acc
        diag -> [diag | acc]
      end

    walk_body(rest, depth, fi, ll, lc, lang, acc, tok)
  end

  defp walk_body([_ | rest], depth, fi, ll, lc, lang, acc, _prev_id) do
    walk_body(rest, depth, fi, ll, lc, lang, acc, nil)
  end

  defp adjacency_diagnostic(_prev, _tok, fi, _lang) when fi < 2, do: nil
  defp adjacency_diagnostic(nil, _tok, _fi, _lang), do: nil

  defp adjacency_diagnostic(prev, {_kind, l, c, _name} = tok, _fi, lang) do
    prev_text = adjacency_token_text(prev)
    cur_text = adjacency_token_text(tok)

    msg =
      if lang == "thf" do
        "missing `@` between `#{prev_text}` and `#{cur_text}`; " <>
          "THF application requires `@`"
      else
        "unexpected `#{cur_text}` after `#{prev_text}`; " <>
          "expected an operator or punctuation between them"
      end

    %Diagnostic{
      line: l,
      column: c,
      end_line: l,
      end_column: c + token_display_length(tok),
      severity: :error,
      source: "local",
      message: msg
    }
  end

  defp adjacency_token_text({:sqstring, _, _, s}), do: "'" <> s <> "'"
  defp adjacency_token_text({:dqstring, _, _, s}), do: "\"" <> s <> "\""
  defp adjacency_token_text({_, _, _, n}), do: n

  defp token_display_length({:sqstring, _, _, s}), do: String.length(s) + 2
  defp token_display_length({:dqstring, _, _, s}), do: String.length(s) + 2
  defp token_display_length({_, _, _, n}), do: String.length(n)

  defp role_diagnostic([{:lident, _, _, name} | _]) when name in @roles, do: nil

  defp role_diagnostic([{kind, l, c, name} | _]) when kind in [:lident, :uident] do
    %Diagnostic{
      line: l,
      column: c,
      end_line: l,
      end_column: c + String.length(name),
      severity: :warning,
      source: "local",
      message: role_message(name)
    }
  end

  defp role_diagnostic(_), do: nil

  defp role_message(name) do
    stripped = String.trim_leading(name, "_")
    downcased = String.downcase(name)

    cond do
      stripped != name and stripped in @roles ->
        "TPTP roles cannot start with `_`; did you mean `#{stripped}`?"

      downcased != name and downcased in @roles ->
        "TPTP roles are lowercase; did you mean `#{downcased}`?"

      true ->
        "unknown TPTP role `#{name}`; expected one of: " <>
          Enum.join(@roles, ", ")
    end
  end

  defp skip_past_dot([], _depth), do: {:none, []}
  defp skip_past_dot([{:dot, _, _} | rest], 0), do: {:found, rest}

  defp skip_past_dot([{kind, _, _} | rest], depth)
       when kind in [:lparen, :lbracket, :lbrace] do
    skip_past_dot(rest, depth + 1)
  end

  defp skip_past_dot([{kind, _, _} | rest], depth)
       when kind in [:rparen, :rbracket, :rbrace] and depth > 0 do
    skip_past_dot(rest, depth - 1)
  end

  defp skip_past_dot([_ | rest], depth), do: skip_past_dot(rest, depth)

  defp extract_symbols(tokens), do: do_extract(tokens, [])

  defp do_extract([], acc), do: Enum.reverse(acc)

  defp do_extract([{:lident, _, _, lang} | rest], acc) when lang in @languages do
    case collect_body(rest) do
      {:ok, body, rest2} ->
        sym = symbol_from_body(body)
        acc2 = if sym, do: [sym | acc], else: acc
        do_extract(drop_trailing_dot(rest2), acc2)

      :no_body ->
        do_extract(rest, acc)
    end
  end

  defp do_extract([_ | rest], acc), do: do_extract(rest, acc)

  defp collect_body([{:lparen, _, _} | rest]), do: collect_body_inner(rest, 1, [])
  defp collect_body(_), do: :no_body

  defp collect_body_inner([], _depth, acc), do: {:ok, Enum.reverse(acc), []}

  defp collect_body_inner([{:rparen, _, _} | rest], 1, acc),
    do: {:ok, Enum.reverse(acc), rest}

  defp collect_body_inner([{kind, _, _} = t | rest], depth, acc)
       when kind in [:lparen, :lbracket, :lbrace] do
    collect_body_inner(rest, depth + 1, [t | acc])
  end

  defp collect_body_inner([{kind, _, _} = t | rest], depth, acc)
       when kind in [:rparen, :rbracket, :rbrace] do
    collect_body_inner(rest, max(depth - 1, 1), [t | acc])
  end

  defp collect_body_inner([t | rest], depth, acc),
    do: collect_body_inner(rest, depth, [t | acc])

  defp drop_trailing_dot([{:dot, _, _} | rest]), do: rest
  defp drop_trailing_dot(rest), do: rest

  defp symbol_from_body(body) do
    case split_depth0(body, [], [], 0) do
      [_name, [{:lident, _, _, "type"}], formula] ->
        type_decl_from_formula(formula)

      _ ->
        nil
    end
  end

  defp split_depth0([], cur, acc, _depth) do
    Enum.reverse([Enum.reverse(cur) | acc])
  end

  defp split_depth0([{:comma, _, _} | rest], cur, acc, 0) do
    split_depth0(rest, [], [Enum.reverse(cur) | acc], 0)
  end

  defp split_depth0([{kind, _, _} = t | rest], cur, acc, depth)
       when kind in [:lparen, :lbracket, :lbrace] do
    split_depth0(rest, [t | cur], acc, depth + 1)
  end

  defp split_depth0([{kind, _, _} = t | rest], cur, acc, depth)
       when kind in [:rparen, :rbracket, :rbrace] do
    split_depth0(rest, [t | cur], acc, max(depth - 1, 0))
  end

  defp split_depth0([t | rest], cur, acc, depth),
    do: split_depth0(rest, [t | cur], acc, depth)

  defp type_decl_from_formula([{:lident, l, c, name}, {:colon, _, _} | rest]) do
    %Symbol{
      name: name,
      kind: :type_decl,
      type: reconstruct(rest),
      line: l,
      column: c
    }
  end

  defp type_decl_from_formula([{:sqstring, l, c, name}, {:colon, _, _} | rest]) do
    %Symbol{
      name: "'" <> name <> "'",
      kind: :type_decl,
      type: reconstruct(rest),
      line: l,
      column: c
    }
  end

  defp type_decl_from_formula(_), do: nil

  defp reconstruct(tokens) do
    tokens
    |> Enum.map(&token_text/1)
    |> join_smart()
    |> String.trim()
  end

  defp token_text({:lident, _, _, n}), do: n
  defp token_text({:uident, _, _, n}), do: n
  defp token_text({:sqstring, _, _, s}), do: "'" <> s <> "'"
  defp token_text({:dqstring, _, _, s}), do: "\"" <> s <> "\""
  defp token_text({:number, _, _, n}), do: n
  defp token_text({:lparen, _, _}), do: "("
  defp token_text({:rparen, _, _}), do: ")"
  defp token_text({:lbracket, _, _}), do: "["
  defp token_text({:rbracket, _, _}), do: "]"
  defp token_text({:lbrace, _, _}), do: "{"
  defp token_text({:rbrace, _, _}), do: "}"
  defp token_text({:comma, _, _}), do: ","
  defp token_text({:colon, _, _}), do: ":"
  defp token_text({:dot, _, _}), do: "."
  defp token_text({:other, _, _, s}), do: s

  defp join_smart(parts) do
    parts
    |> Enum.reduce([], fn part, acc ->
      case acc do
        [] ->
          [part]

        [prev | _] ->
          if no_space_between?(prev, part) do
            [part | acc]
          else
            [part, " " | acc]
          end
      end
    end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp no_space_between?(prev, next) do
    cond do
      next in [")", "]", "}", ",", "."] -> true
      prev in ["(", "[", "{"] -> true
      next == "(" and word_like?(prev) -> true
      true -> false
    end
  end

  defp word_like?(""), do: false

  defp word_like?(s) do
    last = :binary.last(s)

    last in ?a..?z or last in ?A..?Z or last in ?0..?9 or
      last == ?_ or last == ?) or last == ?] or last == ?} or
      last == ?' or last == ?"
  end
end
