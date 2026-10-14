defmodule AtpClient.Isabelle.Verdict do
  @moduledoc """
  Reads the `use_theories` payload of an Isabelle server into SZS values.

  Isabelle does not print SZS lines. Its result is a list of messages with
  positions, and the verdict for a lemma is read from the messages at its position.
  `classify/1` treats every message as one bucket; `per_lemma/3` buckets them by
  the line range each lemma covers.

  ## Verdict precedence

  Within a bucket, the signals read from its messages are reconciled in this order,
  each step short-circuiting:

    1. `:counter_satisfiable` — a Nitpick or Quickcheck counterexample disproves the
       goal and dominates any concurrent proof attempt.
    2. `:theorem` from a sledgehammer or metis `found a proof` line.
    3. `:satisfiable` — a Nitpick or Quickcheck model.
    4. A `Failed to finish proof` or `Failed to apply initial proof method` error
       vetoes a `theorem name:` echo from the same bucket: Isabelle prints the goal
       at the `by` position whether or not the method closed it.
    5. `:theorem` from a `theorem name:` completion.
    6. `:timeout`, `:memory_out`, then `:gave_up`.

  A bucket with no signal is `:gave_up`. Messages are read one at a time, never
  across their concatenation: `Nitpick found a model` followed by `Nitpick found no
  counterexample` reads as a model, not as a counterexample.
  """

  alias Tptp.Szs.Ontology

  @typedoc """
  One lemma of a generated theory body.

    * `name` — the lemma's name as written in the body.
    * `range` — the body lines the lemma covers, inclusive, from its `lemma` line to
      the line before the next.
  """
  @type lemma_spec :: %{name: String.t(), range: Range.t()}

  @typedoc """
  The verdict for one lemma, by name. The line number is not carried: it would
  refer to the generated theory, not to the caller's input.
  """
  @type lemma_result :: %{name: String.t() | nil, status: Ontology.t()}

  @doc """
  The verdict over every message of a finished `use_theories` task's `result`.

  Reads messages, not the task's `ok` flag: a theory with `"ok" => false` still
  classifies, with the proof-method veto keeping a goal echo from counting as a
  proof.
  """
  @spec classify(map()) :: Ontology.t()
  def classify(payload) when is_map(payload) do
    payload |> messages() |> bucket()
  end

  @doc """
  One verdict per lemma, in the order of `specs`.

  ## Options

    * `:file` — keep only messages whose `pos.file` ends with this suffix, typically
      `"/<theory_name>.thy"`, so messages from imported theories are left out.
    * `:line_offset` — subtracted from each message's `pos.line` before it is
      compared with a range. A body wrapped in a one-line theory header passes `1`.
  """
  @spec per_lemma(map(), [lemma_spec()], keyword()) :: [lemma_result()]
  def per_lemma(payload, specs, options \\ []) when is_map(payload) and is_list(specs) do
    suffix = Keyword.get(options, :file)
    offset = Keyword.get(options, :line_offset, 0)
    messages = payload |> messages() |> in_file(suffix)

    Enum.map(specs, fn %{name: name, range: range} ->
      bucket = Enum.filter(messages, &in_range?(&1, range, offset))
      %{name: name, status: bucket(bucket)}
    end)
  end

  @doc """
  Every message text in the payload, across all nodes, joined by newlines.
  """
  @spec text(map()) :: binary()
  def text(payload) when is_map(payload), do: payload |> texts() |> Enum.join("\n")

  @doc """
  Every message text in the payload, across all nodes, in order.
  """
  @spec texts(map()) :: [binary()]
  def texts(payload) when is_map(payload) do
    payload |> messages() |> Enum.map(&Map.get(&1, "message", ""))
  end

  @spec bucket([map()]) :: Ontology.t()
  defp bucket(messages) do
    signals = messages |> Enum.map(&signal/1) |> Enum.reject(&is_nil/1)

    cond do
      :counter_satisfiable in signals -> :counter_satisfiable
      :proof_found in signals -> :theorem
      :satisfiable in signals -> :satisfiable
      Enum.any?(messages, &method_failed?/1) -> :gave_up
      :completion in signals -> :theorem
      :timeout in signals -> :timeout
      :memory_out in signals -> :memory_out
      true -> :gave_up
    end
  end

  @spec signal(map()) :: atom() | nil
  defp signal(message) do
    text = Map.get(message, "message", "")

    cond do
      found?(text, "Nitpick found a", "counterexample") -> :counter_satisfiable
      found?(text, "Quickcheck found a", "counterexample") -> :counter_satisfiable
      found?(text, "Nitpick found a", "model") -> :satisfiable
      found?(text, "Quickcheck found a", "model") -> :satisfiable
      String.contains?(text, "found a proof") -> :proof_found
      String.contains?(text, "Found proof") -> :proof_found
      String.contains?(text, "timed out") -> :timeout
      String.contains?(text, "TIMEOUT") -> :timeout
      String.contains?(text, "Out of memory") -> :memory_out
      String.contains?(text, "Nitpick found no") -> :gave_up
      String.contains?(text, "No proof found") -> :gave_up
      String.starts_with?(text, "theorem ") -> :completion
      String.starts_with?(text, "theorem:") -> :completion
      true -> nil
    end
  end

  defp found?(text, tool, what), do: String.contains?(text, tool) and String.contains?(text, what)

  @spec method_failed?(map()) :: boolean()
  defp method_failed?(message) do
    text = Map.get(message, "message", "")

    Map.get(message, "kind") == "error" and
      (String.contains?(text, "Failed to finish proof") or
         String.contains?(text, "Failed to apply initial proof method"))
  end

  @spec in_file([map()], binary() | nil) :: [map()]
  defp in_file(messages, nil), do: messages

  defp in_file(messages, suffix) when is_binary(suffix) do
    Enum.filter(messages, fn message ->
      case get_in(message, ["pos", "file"]) do
        file when is_binary(file) -> String.ends_with?(file, suffix)
        _other -> false
      end
    end)
  end

  @spec in_range?(map(), Range.t(), integer()) :: boolean()
  defp in_range?(message, range, offset) do
    case get_in(message, ["pos", "line"]) do
      line when is_integer(line) -> (line - offset) in range
      _other -> false
    end
  end

  @spec messages(map()) :: [map()]
  defp messages(%{"nodes" => nodes}) when is_list(nodes),
    do: Enum.flat_map(nodes, &Map.get(&1, "messages", []))

  defp messages(_payload), do: []
end
