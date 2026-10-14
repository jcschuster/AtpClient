defmodule AtpClient.Interpretation.FiRoles do
  @moduledoc """
  Reads the finite models Paradox prints, in its `fi_` roles.

      fof(domain, fi_domain, (![X] : (X = "1" | X = "2")) ).
      fof(f, fi_functors, ( (f("1") = "2") & (f("2") = "2") ) ).
      fof(p, fi_predicates, ( (p("1") <=> $true) & (p("2") <=> $false) ) ).
      fof(q, fi_predicates, ( ![X1,X2] : (q(X1,X2) <=> $true) ) ).

  A row is `p("1") <=> $true`; the compact form `![X1,X2] : (q(X1,X2) <=> $true)`
  states every row at once and is written out over the domain.
  """

  @behaviour AtpClient.Interpretation

  alias AtpClient.Interpretation
  alias AtpClient.Interpretation.Formula
  alias Tptp.Statement.Annotated

  @impl Interpretation
  def claims?(%Tptp.File{statements: statements}),
    do: Enum.any?(statements, &(role(&1) == "fi_domain"))

  @impl Interpretation
  def read(%Tptp.File{} = file) do
    by_role = Enum.group_by(for(%Annotated{} = s <- file.statements, do: s), &role/1)

    domain =
      by_role
      |> Map.get("fi_domain", [])
      |> Enum.map(&(&1.formula |> Formula.read() |> Formula.domain()))

    with [{:ok, type, elements}] <- domain,
         mappings =
           for(
             statement <-
               Map.get(by_role, "fi_functors", []) ++ Map.get(by_role, "fi_predicates", []),
             conjunct <- statement.formula |> Formula.read() |> Formula.conjuncts(),
             instance <- Formula.expand(conjunct, elements),
             do: instance
           ),
         {:ok, tables} <- Formula.tables(mappings) do
      {:ok,
       %Interpretation{
         kind: :finite,
         domains: %{type => elements},
         constants: tables.constants,
         functions: tables.functions,
         predicates: tables.predicates,
         dialect: :fi_roles,
         source: file
       }}
    else
      {:error, _} = error -> error
      _other -> {:error, :unreadable_domain}
    end
  end

  defp role(%Annotated{} = statement), do: Annotated.role_word(statement)
  defp role(_statement), do: nil
end
