defmodule AtpClient.Isabelle.Nitpick do
  @moduledoc """
  Reads a Nitpick counterexample or model, as Isabelle reports it, into an
  `AtpClient.Interpretation` with `dialect: :nitpick` and `kind: :partial`.

  Nitpick prints its header and its model as one `writeln` message:

      Nitpick found a counterexample for card 'a = 2 and card 'b = 1:
        Free variables:
          P = (λx. _)(a1 := False, a2 := True)
          f = (λx. _)(a1 := b1, a2 := b1)
          A = {a2}
          x = a2
        Skolem constant:
          y = a1

  The `card` line gives a domain per type variable, atoms `a1 … an` for `'a`.
  Under `Free variables:`, `Constants:` and `Skolem constants:` (singular or
  plural), an entry `f = (λx. _)(k := v, …)` is a function table, or a predicate
  table when its values are `True`/`False`, with the `_` (Nitpick's
  "unspecified") as its `defaults` entry; `A = {a2, a3}` is a unary predicate,
  true of the atoms listed and `false` by default; a scalar `x = a2` is a
  constant, `b = True` a nullary predicate. `undefined` is left out. Isabelle's
  symbol notation (`\\<lambda>`, `a\\<^sub>1`) and its Unicode rendering are
  both read.

  Only the default output format is read; Nitpick's `format` and `atoms` options
  change the text and are not followed.
  """

  alias AtpClient.Interpretation

  @header ~r/\ANitpick found an? [^\n]*?(?: for (card [^\n]*?))?:[ \t]*$/m
  @section ~r/^  ((?:Free variables?|Constants?|Skolem constants?)):[ \t]*$/
  @subscripts %{
    "₀" => "0",
    "₁" => "1",
    "₂" => "2",
    "₃" => "3",
    "₄" => "4",
    "₅" => "5",
    "₆" => "6",
    "₇" => "7",
    "₈" => "8",
    "₉" => "9"
  }

  @doc """
  The first message in `messages` that starts with `Nitpick found a`, or `nil`.
  """
  @spec message([binary()]) :: binary() | nil
  def message(messages) when is_list(messages),
    do: Enum.find(messages, &String.starts_with?(&1, "Nitpick found a"))

  @doc """
  Reads one Nitpick message.

      iex> message = "Nitpick found a counterexample for card 'a = 2:\\n  Free variables:\\n    P = (\\\\<lambda>x. _)(a\\\\<^sub>1 := False, a\\\\<^sub>2 := True)\\n    x = a\\\\<^sub>1"
      iex> {:ok, model, []} = AtpClient.Isabelle.Nitpick.read(message)
      iex> {model.domains, model.constants, model.predicates, model.defaults}
      {%{"'a" => ["a1", "a2"]}, %{"x" => "a1"}, %{{"P", 1} => %{["a1"] => false, ["a2"] => true}}, %{{"P", 1} => "_"}}
  """
  @spec read(binary()) ::
          {:ok, Interpretation.t(), []} | {:error, {:invalid_interpretation, :unrecognised}}
  def read(message) when is_binary(message) do
    text = normalise(message)

    case Regex.run(@header, text) do
      nil ->
        {:error, {:invalid_interpretation, :unrecognised}}

      header ->
        tables =
          text
          |> entries()
          |> Enum.reduce(
            %{constants: %{}, functions: %{}, predicates: %{}, defaults: %{}},
            &entry/2
          )

        {:ok,
         %Interpretation{
           kind: :partial,
           dialect: :nitpick,
           source: message,
           domains: domains(Enum.at(header, 1)),
           constants: tables.constants,
           functions: tables.functions,
           predicates: tables.predicates,
           defaults: tables.defaults
         }, []}
    end
  end

  # Isabelle symbols and Unicode alike, to `λ` and `a1`.
  defp normalise(text) do
    text
    |> String.replace("\\<lambda>", "λ")
    |> String.replace(~r/\\<\^(?:sub|isub)>/, "")
    |> String.replace(Map.keys(@subscripts), &@subscripts[&1])
  end

  # `card 'a = 4 and card 'b = 4` — a type variable's atoms are its name and an index.
  defp domains(nil), do: %{}

  defp domains(cards) do
    for [_, type, count] <- Regex.scan(~r/card ('?[\w.]+) = (\d+)/, cards),
        into: %{},
        do: {type, atoms(type, String.to_integer(count))}
  end

  defp atoms("'" <> name, size), do: for(index <- 1..size//1, do: "#{name}#{index}")
  defp atoms(_type, _size), do: []

  # `name = value` at four spaces under a section, continuation lines deeper.
  defp entries(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({false, []}, fn line, {inside, entries} ->
      cond do
        Regex.match?(@section, line) ->
          {true, entries}

        not inside ->
          {false, entries}

        String.starts_with?(line, "     ") ->
          {true, continue(entries, line)}

        match = Regex.run(~r/^    (\S+) = (.*)$/, line) ->
          {true, [{Enum.at(match, 1), Enum.at(match, 2)} | entries]}

        true ->
          {false, entries}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp continue([{name, value} | rest], line),
    do: [{name, value <> " " <> String.trim(line)} | rest]

  defp continue([], _line), do: []

  defp entry({name, text}, tables) do
    case parse(String.trim(text)) do
      {{:atom, atom}, ""} ->
        put_in(tables, [:constants, name], atom)

      {{:bool, value}, ""} ->
        put_in(tables, [:predicates, {name, 0}], %{[] => value})

      {{:set, atoms}, ""} ->
        rows = for atom <- atoms, atom != nil, into: %{}, do: {[atom], true}
        row(tables, :predicates, {name, 1}, rows, false)

      {{:fun, default, pairs}, ""} ->
        function(tables, name, default, pairs)

      _other ->
        tables
    end
  end

  defp function(tables, name, default, pairs) do
    rows = flatten(pairs)
    arity = rows |> Enum.map(&length(elem(&1, 0))) |> Enum.max(fn -> 1 end)
    values = Enum.map(rows, &elem(&1, 1))

    if Enum.all?(values, &is_boolean/1) and default in ["_", true, false] do
      row(tables, :predicates, {name, arity}, Map.new(rows), default)
    else
      row(tables, :functions, {name, arity}, Map.new(rows), default)
    end
  end

  defp row(tables, table, key, rows, default) do
    tables |> put_in([table, key], rows) |> put_in([:defaults, key], default)
  end

  # A curried `(λx. _)(a1 := (λx. _)(b1 := True))` is one row per path.
  defp flatten(pairs) do
    Enum.flat_map(pairs, fn
      {key, {:fun, _default, inner}} ->
        for {keys, value} <- flatten(inner), do: {[key | keys], value}

      {key, {:atom, atom}} ->
        [{[key], atom}]

      {key, {:bool, value}} ->
        [{[key], value}]

      {_key, _other} ->
        []
    end)
  end

  # A recursive-descent reading of a value; returns the value and what is left.
  defp parse("{" <> rest) do
    {atoms, rest} = list(String.trim_leading(rest), "}", &atom/1)
    {{:set, atoms}, rest}
  end

  defp parse("(λ" <> rest) do
    case Regex.run(~r/\A\w+\.\s*([^)]+?)\)\s*(.*)\z/s, rest) do
      [_, default, "(" <> rest] ->
        {pairs, rest} = list(String.trim_leading(rest), ")", &assignment/1)
        {{:fun, scalar(default), pairs}, rest}

      [_, default, rest] ->
        {{:fun, scalar(default), []}, rest}

      nil ->
        {{:other, rest}, ""}
    end
  end

  defp parse(text) do
    case Regex.run(~r/\A([^\s,(){}]+)\s*(.*)\z/s, text) do
      [_, "True", rest] -> {{:bool, true}, rest}
      [_, "False", rest] -> {{:bool, false}, rest}
      [_, "undefined", rest] -> {:undefined, rest}
      [_, word, rest] -> {{:atom, word}, rest}
      nil -> {{:other, text}, ""}
    end
  end

  defp scalar("True"), do: true
  defp scalar("False"), do: false
  defp scalar(text), do: String.trim(text)

  defp atom(text) do
    case parse(text) do
      {{:atom, atom}, rest} -> {atom, rest}
      {_other, rest} -> {nil, rest}
    end
  end

  defp assignment(text) do
    case Regex.run(~r/\A([^\s:,]+)\s*:=\s*(.*)\z/s, text) do
      [_, key, rest] ->
        {value, rest} = parse(String.trim_leading(rest))
        {{key, value}, rest}

      nil ->
        {nil, ""}
    end
  end

  # Items separated by commas up to `close`.
  defp list(text, close, item) do
    if String.starts_with?(text, close) do
      {[], text |> String.replace_prefix(close, "") |> String.trim_leading()}
    else
      {value, rest} = item.(text)
      rest = String.trim_leading(rest)

      cond do
        String.starts_with?(rest, ",") ->
          {values, rest} =
            list(rest |> String.replace_prefix(",", "") |> String.trim_leading(), close, item)

          {[value | values], rest}

        String.starts_with?(rest, close) ->
          {[value], rest |> String.replace_prefix(close, "") |> String.trim_leading()}

        true ->
          {[value], ""}
      end
    end
  end
end
