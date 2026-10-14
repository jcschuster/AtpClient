defmodule AtpClient.Interpretation.Formula do
  @moduledoc false

  # The concrete syntax tree of `Tptp.Node` read into the few shapes an
  # interpretation is written in. Anything else is `{:other, kind}`, which no
  # reader accepts as a table entry.

  alias Tptp.Node

  @type term_ ::
          {:var, binary()}
          | {:obj, binary()}
          | {:app, binary(), [term_()]}
          | {:distinct, [term_()]}
          | {:bool, boolean()}
          | {:eq, term_(), term_()}
          | {:neq, term_(), term_()}
          | {:not, term_()}
          | {:and, [term_()]}
          | {:or, [term_()]}
          | {:iff | :implies | :other_binary, term_(), term_()}
          | {:forall | :exists, [{binary(), binary() | nil}], term_()}
          | {:other, atom()}

  @parens [:fof_unitary_formula, :tff_unitary_formula, :thf_unitary_formula]
  @ands [:fof_and_formula, :tff_and_formula]
  @ors [:fof_or_formula, :tff_or_formula, :cnf_disjunction]
  @eqs [:fof_defined_infix_formula, :tff_defined_infix]
  @neqs [:fof_infix_unary, :tff_infix_unary]
  @binaries [:fof_binary_nonassoc, :tff_binary_nonassoc]
  @quantified [:fof_quantified_formula, :tff_quantified_formula]
  @applications [:fof_plain_term, :tff_plain_atomic, :fof_defined_plain_term, :tff_defined_plain]
  @arguments [:fof_arguments, :tff_arguments]
  @symbols [:constant, :type_constant, :functor, :defined_type, :atomic_word, :lower_word]

  @spec read(Node.t()) :: term_()
  def read(%Node{kind: kind, children: [child]}) when kind in @parens, do: read(child)

  def read(%Node{kind: kind, children: children}) when kind in @ands,
    do: {:and, flat(children, :and)}

  def read(%Node{kind: kind, children: children}) when kind in @ors,
    do: {:or, flat(children, :or)}

  def read(%Node{kind: kind, children: [left, right]}) when kind in @eqs,
    do: {:eq, read(left), read(right)}

  def read(%Node{kind: kind, children: [left, right]}) when kind in @neqs,
    do: {:neq, read(left), read(right)}

  def read(%Node{kind: kind, children: [left, op, right]}) when kind in @binaries do
    op = if op.kind in [:iff, :implies], do: op.kind, else: :other_binary
    {op, read(left), read(right)}
  end

  def read(%Node{kind: kind, children: [quantifier, variables, body]}) when kind in @quantified do
    {if(quantifier.kind == :exists, do: :exists, else: :forall), variables(variables), read(body)}
  end

  def read(%Node{kind: :fof_unary_formula, children: [child]}), do: {:not, read(child)}
  def read(%Node{kind: :cnf_literal, children: [child]}), do: {:not, read(child)}

  def read(%Node{kind: :tff_prefix_unary, children: [%Node{kind: :tilde}, child]}),
    do: {:not, read(child)}

  def read(%Node{kind: kind, children: [functor | rest]}) when kind in @applications do
    arguments =
      case rest do
        [] ->
          []

        [%Node{kind: arguments, children: children}] when arguments in @arguments ->
          Enum.map(children, &read/1)

        [argument] ->
          [read(argument)]
      end

    case Node.value(functor) do
      "$distinct" -> {:distinct, arguments}
      name -> {:app, name, arguments}
    end
  end

  def read(%Node{kind: :variable, text: text}), do: {:var, text}
  def read(%Node{kind: :distinct_object} = node), do: {:obj, unquote_object(node.text)}
  def read(%Node{kind: :defined_constant, text: "$true"}), do: {:bool, true}
  def read(%Node{kind: :defined_constant, text: "$false"}), do: {:bool, false}

  def read(%Node{kind: kind, children: []} = node) when kind in @symbols,
    do: {:app, Node.value(node), []}

  def read(%Node{kind: :defined_constant} = node), do: {:app, Node.value(node), []}
  def read(%Node{kind: kind}), do: {:other, kind}

  defp flat(children, op) do
    Enum.flat_map(children, fn child ->
      case read(child) do
        {^op, inner} -> inner
        other -> [other]
      end
    end)
  end

  defp variables(%Node{kind: :variable, text: name}), do: [{name, nil}]

  defp variables(%Node{kind: :tff_typed_variable, children: [variable, type]}),
    do: [{variable.text, Node.value(type)}]

  defp variables(%Node{children: children}), do: Enum.flat_map(children, &variables/1)

  # `"d0"` names the element `d0`. The two escapes a distinct object may hold are
  # `\\` and `\"`.
  defp unquote_object(<<?", rest::binary>>) do
    rest |> binary_part(0, byte_size(rest) - 1) |> String.replace(~r/\\(["\\])/, "\\1")
  end

  @doc false
  @spec conjuncts(term_()) :: [term_()]
  def conjuncts({:and, items}), do: items
  def conjuncts(term), do: [term]

  @doc false
  # The elements a domain formula names, by type: `! [X] : (X = e | …)`,
  # `$distinct(e, …)` and a conjunction of pairwise `e != e'`. `:error` for
  # anything else.
  @spec domain(term_()) :: {:ok, binary(), [binary()]} | :error
  def domain({:forall, [{variable, type}], body}) do
    disjuncts =
      case body do
        {:or, items} -> items
        item -> [item]
      end

    elements =
      Enum.map(disjuncts, fn
        {:eq, {:var, ^variable}, element} -> element(element)
        {:eq, element, {:var, ^variable}} -> element(element)
        _other -> :error
      end)

    if :error in elements, do: :error, else: {:ok, type || "$i", elements}
  end

  def domain({:distinct, items}) do
    elements = Enum.map(items, &element/1)
    if :error in elements, do: :error, else: {:ok, "$i", elements}
  end

  def domain({:and, items}) do
    elements =
      Enum.flat_map(items, fn
        {:neq, left, right} -> [element(left), element(right)]
        _other -> [:error]
      end)

    if :error in elements, do: :error, else: {:ok, "$i", Enum.uniq(elements)}
  end

  def domain({:neq, _left, _right} = item), do: domain({:and, [item]})
  def domain(_term), do: :error

  @doc false
  @spec element(term_()) :: binary() | :error
  def element({:obj, name}), do: name
  def element({:app, name, []}), do: name
  def element(_term), do: :error

  @doc false
  # Table entries from mapping conjuncts. `elements` are the domain's elements,
  # which tell a constant on the left of `=` from an element on the right.
  @spec tables([term_()]) :: {:ok, map()} | {:error, term()}
  def tables(conjuncts) do
    Enum.reduce_while(conjuncts, {:ok, %{constants: %{}, functions: %{}, predicates: %{}}}, fn
      conjunct, {:ok, acc} ->
        case entry(conjunct) do
          {:constant, symbol, value} ->
            {:cont, {:ok, put_in(acc, [:constants, symbol], value)}}

          {:function, key, arguments, value} ->
            {:cont, {:ok, update_in(acc, [:functions], &put_row(&1, key, arguments, value))}}

          {:predicate, key, arguments, value} ->
            {:cont, {:ok, update_in(acc, [:predicates], &put_row(&1, key, arguments, value))}}

          :error ->
            {:halt, {:error, {:unreadable_mapping, conjunct}}}
        end
    end)
  end

  defp put_row(table, key, arguments, value),
    do: Map.update(table, key, %{arguments => value}, &Map.put(&1, arguments, value))

  defp entry({:eq, {:app, symbol, []}, value}), do: with_element(value, &{:constant, symbol, &1})

  defp entry({:eq, {:app, symbol, arguments}, value}) do
    with {:ok, arguments} <- elements(arguments),
         do: with_element(value, &{:function, {symbol, length(arguments)}, arguments, &1})
  end

  defp entry({:app, symbol, arguments}), do: predicate(symbol, arguments, true)
  defp entry({:not, {:app, symbol, arguments}}), do: predicate(symbol, arguments, false)

  defp entry({:iff, {:app, symbol, arguments}, {:bool, value}}),
    do: predicate(symbol, arguments, value)

  defp entry(_term), do: :error

  defp predicate(symbol, arguments, value) do
    with {:ok, arguments} <- elements(arguments),
         do: {:predicate, {symbol, length(arguments)}, arguments, value}
  end

  defp with_element(term, fun) do
    case element(term) do
      :error -> :error
      element -> fun.(element)
    end
  end

  defp elements(terms) do
    elements = Enum.map(terms, &element/1)
    if :error in elements, do: :error, else: {:ok, elements}
  end

  @doc false
  # A universally quantified mapping over the domain, written out: one instance
  # per assignment of elements to its variables.
  @spec expand(term_(), [binary()]) :: [term_()]
  def expand({:forall, variables, body}, elements) do
    variables
    |> Enum.reduce([%{}], fn {variable, _type}, assignments ->
      for assignment <- assignments,
          element <- elements,
          do: Map.put(assignment, variable, element)
    end)
    |> Enum.flat_map(fn assignment -> body |> substitute(assignment) |> conjuncts() end)
  end

  def expand(term, _elements), do: [term]

  defp substitute({:var, name} = variable, assignment) do
    case Map.fetch(assignment, name) do
      {:ok, element} -> {:obj, element}
      :error -> variable
    end
  end

  defp substitute({:app, symbol, arguments}, assignment),
    do: {:app, symbol, Enum.map(arguments, &substitute(&1, assignment))}

  defp substitute({op, items}, assignment) when op in [:and, :or, :distinct],
    do: {op, Enum.map(items, &substitute(&1, assignment))}

  defp substitute({:not, item}, assignment), do: {:not, substitute(item, assignment)}

  defp substitute({op, left, right}, assignment)
       when op in [:eq, :neq, :iff, :implies, :other_binary],
       do: {op, substitute(left, assignment), substitute(right, assignment)}

  defp substitute(term, _assignment), do: term
end
