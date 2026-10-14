defmodule AtpClient.Interpretation.Standard do
  @moduledoc """
  Reads the TPTP standard form of an interpretation: statements whose role is
  `interpretation`, optionally with a subrole.

    * `interpretation-domains` — a domain: `! [X] : (X = "d0" | X = "d1")`,
      `$distinct("d0", "d1")`, or pairwise `"d0" != "d1"`.
    * `interpretation-mappings` — a conjunction of `c = "d0"`, `f("d0") = "d1"`,
      `p("d0")`, `~p("d1")`.
    * `interpretation` — one formula holding both, as a conjunction.
    * `interpretation-herbrand` — a Herbrand model: `kind: :herbrand`, the file as
      `formulae`.

  Typed domains (`$tType` declarations, promotion functions) and
  `interpretation-worlds` are recognised and read as far as the forms above go,
  giving `kind: :partial`. A typed domain's elements are constants, as
  `AtpClient.Interpretation.to_tptp/1` writes them; a `$distinct` over elements a
  quantified domain already names is read as their distinctness, not as a
  domain.

  Mace4 writes this form:

      fof(interp_domain, interpretation-domains, ! [X] : ( X = "d0" | X = "d1" )).
      fof(interp_functions, interpretation-mappings, ( a = "d0" & f("d0") = "d1" & f("d1") = "d0" )).
  """

  @behaviour AtpClient.Interpretation

  alias AtpClient.Interpretation
  alias AtpClient.Interpretation.Formula
  alias Tptp.Statement.Annotated

  @impl Interpretation
  def claims?(%Tptp.File{statements: statements}) do
    Enum.any?(statements, &(annotated?(&1) and Annotated.role_word(&1) == "interpretation"))
  end

  @impl Interpretation
  def read(%Tptp.File{} = file) do
    statements =
      for statement <- file.statements,
          annotated?(statement),
          do: {role(statement, file), statement}

    if Enum.any?(statements, &(elem(&1, 0) == "interpretation-herbrand")),
      do: {:ok, Interpretation.herbrand(file, :standard)},
      else: read_tables(statements, file)
  end

  defp read_tables(statements, file) do
    partial? =
      Enum.any?(statements, fn {role, statement} ->
        role == "interpretation-worlds" or (role == "type" and type_declaration?(statement))
      end)

    # Worlds are not read: a Kripke interpretation stays :partial.
    conjuncts =
      for {"interpretation" <> subrole, statement} <- statements,
          subrole != "-worlds",
          conjunct <- statement.formula |> Formula.read() |> Formula.conjuncts(),
          conjunct != {:bool, true},
          do: conjunct

    # Quantified domains first: a `$distinct` or a pairwise `!=` over elements
    # they already name states distinctness, not a domain of its own; over
    # elements they do not, it is the untyped domain.
    {domains, rest} =
      Enum.reduce(conjuncts, {%{}, []}, fn conjunct, {domains, rest} ->
        case {conjunct, Formula.domain(conjunct)} do
          {{:forall, _variables, _body}, {:ok, type, elements}} ->
            {Map.update(domains, type, elements, &Enum.uniq(&1 ++ elements)), rest}

          _otherwise ->
            {domains, [conjunct | rest]}
        end
      end)

    known = domains |> Map.values() |> List.flatten() |> MapSet.new()

    {domains, mappings} =
      Enum.reduce(Enum.reverse(rest), {domains, []}, fn conjunct, {domains, mappings} ->
        case Formula.domain(conjunct) do
          {:ok, _type, elements} -> {untyped(domains, elements, known), mappings}
          :error -> {domains, [conjunct | mappings]}
        end
      end)

    typed? = Enum.any?(Map.keys(domains), &(&1 != "$i"))

    with {:ok, tables} <- mappings |> Enum.reverse() |> Formula.tables() do
      {:ok,
       %Interpretation{
         kind: if(partial? or typed?, do: :partial, else: :finite),
         domains: domains,
         constants: tables.constants,
         functions: tables.functions,
         predicates: tables.predicates,
         dialect: :standard,
         source: file
       }}
    end
  end

  # Distinctness over known elements adds nothing; over unknown ones it is the
  # untyped domain.
  defp untyped(domains, elements, known) do
    if Enum.all?(elements, &MapSet.member?(known, &1)),
      do: domains,
      else: Map.update(domains, "$i", elements, &Enum.uniq(&1 ++ elements))
  end

  defp annotated?(statement), do: match?(%Annotated{}, statement)

  # The role as written, subrole included: `interpretation-domains`.
  defp role(%Annotated{role: role}, %Tptp.File{source: source}),
    do: role |> Tptp.Node.text(source) |> String.replace(~r/\s+/, "")

  defp type_declaration?(%Annotated{formula: formula}) do
    formula |> Tptp.Node.select(:defined_type) |> Enum.any?(&(&1.text == "$tType"))
  end
end
