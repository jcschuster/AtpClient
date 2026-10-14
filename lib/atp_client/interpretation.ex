defmodule AtpClient.Interpretation do
  @moduledoc """
  A model a system printed — a finite model, a Herbrand model, a saturation, a
  Nitpick counterexample — read into one structure, whatever dialect it was
  written in.

  ## Fields

    * `kind` — `:finite` for a finite model read in full, `:herbrand` for a
      saturation or Herbrand model (`formulae` holds it, the tables are empty),
      `:partial` for one read only in part: typed domains, Kripke worlds, a
      Nitpick model.
    * `domains` — the elements of each type, `"$i"` for an untyped domain.
    * `constants` — `%{symbol => element}`.
    * `functions` — `%{{symbol, arity} => %{[element] => element}}`.
    * `predicates` — `%{{symbol, arity} => %{[element] => boolean}}`.
    * `defaults` — `%{{symbol, arity} => element | boolean}`: the value of every
      row the table does not list. Only Nitpick writes one (`_`, its "unspecified",
      or `false` for a set); empty otherwise.
    * `formulae` — for `:herbrand`, the formulae, as a `Tptp.File`.
    * `dialect` — what it was read from: `:standard` (the TPTP `interpretation`
      roles), `:vampire_fmb`, `:fi_roles` (Paradox), `:nitpick`.
    * `source` — the `Tptp.File` it was read from, or the Nitpick message.

  An element is named as the model names it with its quotes removed: Mace4's
  `"d0"` is `d0`, Vampire's `'fmb_$i_1'` is `fmb_$i_1`, Paradox's `"1"` is `1`.
  Every dialect names the same elements the same way, so two readings of one
  model compare equal table by table.

  ## Reading

  `from_file/2` tries the readers in order and takes the first that claims the
  file, by what the file contains and never by which system wrote it:

    1. `AtpClient.Interpretation.Standard` — a statement with an
       `interpretation` role.
    2. `AtpClient.Interpretation.VampireFmb` — statements named
       `finite_domain_<T>`.
    3. `AtpClient.Interpretation.FiRoles` — a `fi_domain` statement.
    4. A saturation (the `:dataform` option within `Saturation`), or
       `interpretation-herbrand` statements: `kind: :herbrand`.

  `AtpClient.Result.interpretation/1` is the usual way in; Nitpick's messages are
  read by `AtpClient.Isabelle.Nitpick`.

  ## Printing

  `to_tptp/1` prints the structure in the standard form, which
  `AtpClient.Interpretation.Standard` reads back into equal tables.
  """

  alias Tptp.Szs.Ontology

  @enforce_keys [:kind, :dialect, :source]
  defstruct [
    :kind,
    :dialect,
    :source,
    formulae: nil,
    domains: %{},
    constants: %{},
    functions: %{},
    predicates: %{},
    defaults: %{}
  ]

  @type element :: binary()
  @type symbol :: binary()

  @type t :: %__MODULE__{
          kind: :finite | :herbrand | :partial,
          domains: %{binary() => [element()]},
          constants: %{symbol() => element()},
          functions: %{{symbol(), non_neg_integer()} => %{[element()] => element()}},
          predicates: %{{symbol(), non_neg_integer()} => %{[element()] => boolean()}},
          defaults: %{{symbol(), non_neg_integer()} => element() | boolean()},
          formulae: Tptp.File.t() | nil,
          dialect: :standard | :vampire_fmb | :fi_roles | :nitpick,
          source: Tptp.File.t() | binary()
        }

  @doc "Whether a reader recognises the file."
  @callback claims?(Tptp.File.t()) :: boolean()

  @doc "Reads a file the reader claims."
  @callback read(Tptp.File.t()) :: {:ok, t()} | {:error, term()}

  @readers [
    AtpClient.Interpretation.Standard,
    AtpClient.Interpretation.VampireFmb,
    AtpClient.Interpretation.FiRoles
  ]

  @doc """
  Reads a parsed model.

  ## Options

    * `:dataform` — the SZS dataform the file was delimited as; a value within
      `Saturation` makes an otherwise unclaimed file a Herbrand model.

  Returns `{:error, {:invalid_interpretation, :unrecognised}}` for a file no
  reader claims, and `{:error, {:invalid_interpretation, reason}}` for one the
  claiming reader cannot read.

      iex> {:ok, file, []} = Tptp.from_string(~s|fof(m, interpretation, ! [X] : (X = "d0" \\| X = "d1") & a = "d0" & p("d1")).|)
      iex> {:ok, model} = AtpClient.Interpretation.from_file(file)
      iex> {model.kind, model.domains, model.constants, model.predicates}
      {:finite, %{"$i" => ["d0", "d1"]}, %{"a" => "d0"}, %{{"p", 1} => %{["d1"] => true}}}
  """
  @spec from_file(Tptp.File.t(), keyword()) ::
          {:ok, t()} | {:error, {:invalid_interpretation, term()}}
  def from_file(%Tptp.File{} = file, opts \\ []) do
    case Enum.find(@readers, & &1.claims?(file)) do
      nil ->
        if saturation?(Keyword.get(opts, :dataform)),
          do: {:ok, herbrand(file, :standard)},
          else: {:error, {:invalid_interpretation, :unrecognised}}

      reader ->
        case reader.read(file) do
          {:ok, interpretation} -> {:ok, interpretation}
          {:error, reason} -> {:error, {:invalid_interpretation, reason}}
        end
    end
  end

  defp saturation?(nil), do: false
  defp saturation?(dataform), do: Ontology.isa?(dataform, :saturation)

  @doc false
  @spec herbrand(Tptp.File.t(), atom()) :: t()
  def herbrand(file, dialect),
    do: %__MODULE__{kind: :herbrand, formulae: file, dialect: dialect, source: file}

  @doc """
  The interpretation in the standard form.

  Untyped (every domain is `"$i"`): one `fof` `interpretation` statement, the
  domain as a disjunction over double-quoted distinct objects, the mappings as a
  conjunction.

  Typed (a domain other than `"$i"`): `tff`, with the elements as constants
  rather than distinct objects — a distinct object is of type `$i`, so a typed
  domain cannot be written with them — declared along with their types, the
  domains as `interpretation-domains` statements (each with a `$distinct` over
  its elements), the mappings as one `interpretation-mappings` statement, and
  every mapped symbol declared with the type its rows show. That is what
  `AtpClient.Interpretation.Standard` reads back, as `:partial`.

  A `:herbrand` interpretation prints its `formulae`. A `:partial` one prints
  what it holds; the defaults Nitpick writes have no standard form and are left
  out.

      iex> model = %AtpClient.Interpretation{kind: :finite, dialect: :standard, source: "",
      ...>   domains: %{"$i" => ["d0", "d1"]}, constants: %{"a" => "d0"},
      ...>   functions: %{{"f", 1} => %{["d0"] => "d1", ["d1"] => "d0"}},
      ...>   predicates: %{{"p", 1} => %{["d0"] => true, ["d1"] => false}}}
      iex> model |> AtpClient.Interpretation.to_tptp() |> IO.iodata_to_binary() |> String.split("\\n")
      ["fof(interpretation, interpretation,",
       ~s|    ( ! [X] : ( X = "d0" \\| X = "d1" )|,
       ~s|    & a = "d0"|,
       ~s|    & f("d0") = "d1"|,
       ~s|    & f("d1") = "d0"|,
       ~s|    & p("d0")|,
       ~s|    & ~ p("d1") )).|,
       ""]

      iex> model = %AtpClient.Interpretation{kind: :partial, dialect: :vampire_fmb, source: "",
      ...>   domains: %{"point" => ["fmb_point_1", "fmb_point_2"]},
      ...>   functions: %{{"f", 1} => %{["fmb_point_1"] => "fmb_point_2", ["fmb_point_2"] => "fmb_point_2"}},
      ...>   predicates: %{{"p", 1} => %{["fmb_point_1"] => true}}}
      iex> model |> AtpClient.Interpretation.to_tptp() |> IO.iodata_to_binary() |> String.split("\\n")
      ["tff(type_point, type, point: $tType).",
       "tff(declare_fmb_point_1, type, fmb_point_1: point).",
       "tff(declare_fmb_point_2, type, fmb_point_2: point).",
       "tff(declare_f, type, f: point > point).",
       "tff(declare_p, type, p: point > $o).",
       "tff(domain_point, interpretation-domains,",
       "    ( ! [X: point] : ( X = fmb_point_1 | X = fmb_point_2 )",
       "    & $distinct(fmb_point_1, fmb_point_2) )).",
       "tff(mappings, interpretation-mappings,",
       "    ( f(fmb_point_1) = fmb_point_2",
       "    & f(fmb_point_2) = fmb_point_2",
       "    & p(fmb_point_1) )).",
       ""]
  """
  @spec to_tptp(t()) :: iodata()
  def to_tptp(%__MODULE__{kind: :herbrand, formulae: %Tptp.File{source: source}}), do: source

  def to_tptp(%__MODULE__{} = interpretation) do
    if Enum.any?(Map.keys(interpretation.domains), &(&1 != "$i")),
      do: typed(interpretation),
      else: untyped(interpretation)
  end

  defp untyped(interpretation) do
    domains =
      for {_type, elements} <- Enum.sort(interpretation.domains),
          do: "! [X] : ( " <> Enum.map_join(elements, " | ", &"X = #{object(&1)}") <> " )"

    case domains ++ mappings(interpretation, &object/1) do
      [] -> "fof(interpretation, interpretation, $true).\n"
      conjuncts -> statement("fof", "interpretation", "interpretation", conjuncts)
    end
  end

  defp typed(interpretation) do
    types =
      for {type, elements} <- interpretation.domains,
          element <- elements,
          into: %{},
          do: {element, type}

    type_of = &Map.get(types, &1, "$i")
    domains = Enum.sort(interpretation.domains)

    type_declarations =
      for {type, _elements} <- domains,
          type != "$i",
          do: "tff(#{name("type_" <> type)}, type, #{symbol(type)}: $tType).\n"

    element_declarations =
      for {type, elements} <- domains,
          element <- elements,
          do:
            "tff(#{name("declare_" <> element)}, type, #{symbol(element)}: #{type_name(type)}).\n"

    constant_declarations =
      for {symbol, element} <- Enum.sort(interpretation.constants),
          do:
            "tff(#{name("declare_" <> symbol)}, type, #{symbol(symbol)}: #{type_name(type_of.(element))}).\n"

    function_declarations =
      for {{symbol, _arity}, rows} <- Enum.sort(interpretation.functions),
          {arguments, value} = rows |> Enum.sort() |> hd(),
          do:
            "tff(#{name("declare_" <> symbol)}, type, #{symbol(symbol)}: " <>
              signature(Enum.map(arguments, type_of), type_of.(value)) <> ").\n"

    predicate_declarations =
      for {{symbol, _arity}, rows} <- Enum.sort(interpretation.predicates),
          {arguments, _value} = rows |> Enum.sort() |> hd(),
          do:
            "tff(#{name("declare_" <> symbol)}, type, #{symbol(symbol)}: " <>
              signature(Enum.map(arguments, type_of), "$o") <> ").\n"

    domain_statements =
      for {type, elements} <- domains do
        disjunction =
          "! [X: #{type_name(type)}] : ( " <>
            Enum.map_join(elements, " | ", &"X = #{symbol(&1)}") <> " )"

        distinct =
          if length(elements) > 1,
            do: ["$distinct(" <> Enum.map_join(elements, ", ", &symbol/1) <> ")"],
            else: []

        statement("tff", name("domain_" <> type), "interpretation-domains", [
          disjunction | distinct
        ])
      end

    mapping_statements =
      case mappings(interpretation, &symbol/1) do
        [] -> []
        conjuncts -> [statement("tff", "mappings", "interpretation-mappings", conjuncts)]
      end

    [
      type_declarations,
      element_declarations,
      constant_declarations,
      function_declarations,
      predicate_declarations,
      domain_statements,
      mapping_statements
    ]
  end

  # The mapping conjuncts, elements rendered by `render`.
  defp mappings(interpretation, render) do
    constants =
      for {symbol, element} <- Enum.sort(interpretation.constants),
          do: "#{symbol(symbol)} = #{render.(element)}"

    functions =
      for {{symbol, _arity}, rows} <- Enum.sort(interpretation.functions),
          {arguments, value} <- Enum.sort(rows),
          do: "#{application(symbol, arguments, render)} = #{render.(value)}"

    predicates =
      for {{symbol, _arity}, rows} <- Enum.sort(interpretation.predicates),
          {arguments, value} <- Enum.sort(rows),
          do: if(value, do: "", else: "~ ") <> application(symbol, arguments, render)

    constants ++ functions ++ predicates
  end

  defp statement(language, name, role, [first | rest]) do
    [
      "#{language}(#{name}, #{role},\n    ( ",
      first,
      Enum.map(rest, &["\n    & ", &1]),
      " )).\n"
    ]
  end

  defp signature([argument], result), do: "#{type_name(argument)} > #{type_name(result)}"

  defp signature(arguments, result),
    do: "(" <> Enum.map_join(arguments, " * ", &type_name/1) <> ") > #{type_name(result)}"

  defp type_name("$" <> _ = defined), do: defined
  defp type_name(type), do: symbol(type)

  defp application(symbol, [], _render), do: symbol(symbol)

  defp application(symbol, arguments, render),
    do: "#{symbol(symbol)}(#{Enum.map_join(arguments, ",", render)})"

  defp object(element), do: ~s("#{String.replace(element, ~r/(["\\])/, "\\\\\\1")}")

  # A statement name: an atomic word.
  defp name(text), do: symbol(text)

  # A lower word is written as it is; anything else single-quoted.
  defp symbol(symbol) do
    if symbol =~ ~r/\A[a-z][A-Za-z0-9_]*\z/,
      do: symbol,
      else: "'" <> String.replace(symbol, ~r/(['\\])/, "\\\\\\1") <> "'"
  end
end

defimpl AtpClient.Input, for: AtpClient.Interpretation do
  def to_iodata(interpretation), do: AtpClient.Interpretation.to_tptp(interpretation)
  def name(_interpretation), do: nil
end
