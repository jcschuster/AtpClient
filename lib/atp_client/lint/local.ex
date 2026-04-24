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

  # =========================================================================
  # Tokenizer
  #
  # Tokens are 3- or 4-tuples `{type, line, column}` or `{type, line, column,
  # value}`. Line and column are 1-based.
  # =========================================================================

  defp tokenize(source), do: tok(source, 1, 1, [])

  defp tok("", _l, _c, acc), do: {:ok, Enum.reverse(acc)}

  # Newlines (CRLF first to avoid double-counting).
  defp tok("\r\n" <> rest, l, _c, acc), do: tok(rest, l + 1, 1, acc)
  defp tok("\n" <> rest, l, _c, acc), do: tok(rest, l + 1, 1, acc)
  defp tok("\r" <> rest, l, _c, acc), do: tok(rest, l + 1, 1, acc)

  # Whitespace.
  defp tok(" " <> rest, l, c, acc), do: tok(rest, l, c + 1, acc)
  defp tok("\t" <> rest, l, c, acc), do: tok(rest, l, c + 1, acc)

  # Line comment: `% ... <newline>`.
  defp tok("%" <> rest, l, c, acc) do
    {rest, c2} = skip_line_comment(rest, c + 1)
    tok(rest, l, c2, acc)
  end

  # Block comment: `/* ... */` (can span lines).
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

  # Punctuation.
  defp tok("(" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:lparen, l, c} | acc])
  defp tok(")" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:rparen, l, c} | acc])
  defp tok("[" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:lbracket, l, c} | acc])
  defp tok("]" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:rbracket, l, c} | acc])
  defp tok("{" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:lbrace, l, c} | acc])
  defp tok("}" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:rbrace, l, c} | acc])
  defp tok("," <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:comma, l, c} | acc])
  defp tok(":" <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:colon, l, c} | acc])
  defp tok("." <> rest, l, c, acc), do: tok(rest, l, c + 1, [{:dot, l, c} | acc])

  # Single-quoted atom: `'foo bar'`.
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

  # Double-quoted distinct symbol: `"foo"`.
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

  # Dollar-word: `$true`, `$i`, `$tType`, ...
  defp tok("$" <> rest, l, c, acc) do
    {tail, rest2, c2} = scan_word_body(rest, c + 1, [])
    tok(rest2, l, c2, [{:lident, l, c, "$" <> tail} | acc])
  end

  # Lowercase-starting identifier.
  defp tok(<<ch, _::binary>> = str, l, c, acc) when ch in ?a..?z do
    {name, rest, c2} = scan_word_body(str, c, [])
    tok(rest, l, c2, [{:lident, l, c, name} | acc])
  end

  # Uppercase / underscore identifier (TPTP variable).
  defp tok(<<ch, _::binary>> = str, l, c, acc) when ch in ?A..?Z or ch == ?_ do
    {name, rest, c2} = scan_word_body(str, c, [])
    tok(rest, l, c2, [{:uident, l, c, name} | acc])
  end

  # Integer — we don't lex decimals/exponents precisely; `.` stops the scan
  # so that `3.` tokenises as `3` followed by `.` (same shape a TPTP parser
  # would see in a malformed trailing number).
  defp tok(<<ch, _::binary>> = str, l, c, acc) when ch in ?0..?9 do
    {num, rest, c2} = scan_number(str, c, [])
    tok(rest, l, c2, [{:number, l, c, num} | acc])
  end

  # Any other character becomes an `:other` token carrying its text.
  # Operators (`&`, `|`, `=>`, ...) fall into this bucket; the structural
  # checker only cares about brackets, commas, and dots, so finer-grained
  # operator lexing would buy us nothing.
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

  # Backslash escape: consume the escape + the next char verbatim.
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

  # =========================================================================
  # Bracket matching
  #
  # Runs independently of the statement-structure check — both walks emit
  # their own diagnostics, and `analyze/1` concatenates and sorts the
  # results. This is fine because the two checks target disjoint issues.
  # =========================================================================

  defp check_brackets(tokens), do: do_check_brackets(tokens, [], [])

  # EOF: every remaining opener is unmatched.
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

        # Treat the closer as if it had matched the most recent opener, so
        # the rest of the file parses against a sensible stack instead of
        # accumulating an avalanche of cascading errors.
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

  # =========================================================================
  # Statement structure
  #
  # Walks the token stream one top-level statement at a time. On any issue
  # it resyncs by skipping past the next top-level dot, so a single broken
  # statement doesn't hide the ones that follow.
  # =========================================================================

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
        # We don't validate include contents; just skip to the next statement.
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

  # Stray dot at top-level is harmless (e.g. empty trailing line after a
  # statement); silently consume it.
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
    {body_diags, rest2} = walk_body(rest, 1, 0, ll, lc, lang, [])

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

  # walk_body: walk tokens inside `lang( ... )`.
  #
  # `depth` starts at 1 (we've already consumed the outer `(`). When we see
  # `:rparen` at depth 1 we've reached the end of the body.
  # `field_idx` counts commas encountered at depth 1 — the role lives in
  # field 2 (after two commas).

  defp walk_body([], _depth, _fi, ll, lc, lang, acc) do
    diag = %Diagnostic{
      line: ll,
      column: lc,
      severity: :error,
      source: "local",
      message: "unterminated `#{lang}` statement (missing `)`)"
    }

    {Enum.reverse([diag | acc]), []}
  end

  defp walk_body([{:rparen, _, _} | rest], 1, _fi, _ll, _lc, _lang, acc) do
    {Enum.reverse(acc), rest}
  end

  defp walk_body([{kind, _, _} | rest], depth, fi, ll, lc, lang, acc)
       when kind in [:lparen, :lbracket, :lbrace] do
    walk_body(rest, depth + 1, fi, ll, lc, lang, acc)
  end

  defp walk_body([{kind, _, _} | rest], depth, fi, ll, lc, lang, acc)
       when kind in [:rparen, :rbracket, :rbrace] do
    # `max(depth - 1, 1)` guards against stray closers inside a body —
    # the bracket checker has already flagged them, and we don't want a
    # stray `]` at depth 1 to prematurely exit the body.
    walk_body(rest, max(depth - 1, 1), fi, ll, lc, lang, acc)
  end

  defp walk_body([{:comma, _cl, _cc} | rest], 1, fi, ll, lc, lang, acc) do
    new_fi = fi + 1

    acc =
      if new_fi == 1 do
        # Just crossed into field 1 — the role. Peek the next lident.
        case peek_role_token(rest) do
          {:lident, rl, rc, role} when role not in @roles ->
            [
              %Diagnostic{
                line: rl,
                column: rc,
                end_line: rl,
                end_column: rc + String.length(role),
                severity: :warning,
                source: "local",
                message:
                  "unknown TPTP role `#{role}`; expected one of: " <>
                    Enum.join(@roles, ", ")
              }
              | acc
            ]

          _ ->
            acc
        end
      else
        acc
      end

    walk_body(rest, 1, new_fi, ll, lc, lang, acc)
  end

  defp walk_body([_ | rest], depth, fi, ll, lc, lang, acc) do
    walk_body(rest, depth, fi, ll, lc, lang, acc)
  end

  defp peek_role_token([{:lident, _, _, _} = t | _]), do: t
  defp peek_role_token(_), do: nil

  # Resync helper: consume tokens until we move past a top-level `.`.
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

  # =========================================================================
  # Symbol extraction
  #
  # Walks the token stream top-level statement by top-level statement, and
  # for each `type`-role statement reconstructs the `name : type_expr`
  # declaration as a `Symbol`.
  # =========================================================================

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

  # `name : type_expr` — name can be a plain lident or a single-quoted atom.
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

  # Reconstruct a human-readable string from a list of tokens. Whitespace
  # handling is best-effort — we drop spaces around punctuation that
  # typically doesn't want them. Good enough for Monaco hover cards.
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

  # Heuristic: collapse whitespace where typical TPTP style does, so
  # `nat > nat` stays readable and `foo(x)` stays compact. The tricky
  # case is `(`: we only want to glue it to the previous token when that
  # token is word-like (identifier, number, closing bracket) — i.e. a
  # function application — not after an operator like `>`.
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
