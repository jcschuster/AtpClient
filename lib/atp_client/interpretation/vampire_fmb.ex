defmodule AtpClient.Interpretation.VampireFmb do
  @moduledoc """
  Reads the finite models Vampire's finite model builder prints.

      tff('declare_$i1',type,'fmb_$i_1':$i).
      tff('finite_domain_$i',axiom, ! [X:$i] : ( X = 'fmb_$i_1' | X = 'fmb_$i_2' ) ).
      tff(a_definition,axiom,a = 'fmb_$i_1').
      tff(function_f,axiom, f('fmb_$i_1') = 'fmb_$i_2' & f('fmb_$i_2') = 'fmb_$i_1' ).
      tff(predicate_p,axiom, p('fmb_$i_1') & ~p('fmb_$i_2') ).

  The domain of type `T` is `finite_domain_<T>`; constants are `<c>_definition`,
  functions `function_<f>`, predicates `predicate_<p>`. The `declare_` typings and
  `distinct_domain_` axioms say nothing the domain does not.
  """

  @behaviour AtpClient.Interpretation

  alias AtpClient.Interpretation
  alias AtpClient.Interpretation.Formula
  alias Tptp.Statement.Annotated

  @impl Interpretation
  def claims?(%Tptp.File{statements: statements}),
    do: Enum.any?(statements, &String.starts_with?(name(&1), "finite_domain_"))

  @impl Interpretation
  def read(%Tptp.File{} = file) do
    statements = for %Annotated{} = statement <- file.statements, do: {name(statement), statement}

    domains =
      for {"finite_domain_" <> _type, statement} <- statements, reduce: {:ok, %{}} do
        {:ok, domains} ->
          case statement.formula |> Formula.read() |> single_domain() do
            {:ok, type, elements} -> {:ok, Map.put(domains, type, elements)}
            :error -> {:error, {:unreadable_domain, name(statement)}}
          end

        error ->
          error
      end

    mappings =
      for {name, statement} <- statements,
          String.ends_with?(name, "_definition") or String.starts_with?(name, "function_") or
            String.starts_with?(name, "predicate_"),
          conjunct <- statement.formula |> Formula.read() |> Formula.conjuncts(),
          do: conjunct

    with {:ok, domains} <- domains,
         {:ok, tables} <- Formula.tables(mappings) do
      typed? = Enum.any?(Map.keys(domains), &(&1 != "$i"))

      {:ok,
       %Interpretation{
         kind: if(typed?, do: :partial, else: :finite),
         domains: domains,
         constants: tables.constants,
         functions: tables.functions,
         predicates: tables.predicates,
         dialect: :vampire_fmb,
         source: file
       }}
    end
  end

  # A one-element domain is `! [X:T] : X = e`, which `Formula.domain/1` reads as well.
  defp single_domain(term), do: Formula.domain(term)

  defp name(%Annotated{name: name}), do: Tptp.Node.value(name) || ""
  defp name(_statement), do: ""
end
