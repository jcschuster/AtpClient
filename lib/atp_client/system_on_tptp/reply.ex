defmodule AtpClient.SystemOnTptp.Reply do
  @moduledoc """
  Splits a SystemOnTPTP form reply into one section per system.

  A reply has one of two shapes, chosen by the `X2TPTP` form field:

    * **TSTP** (`X2TPTP=-S`, the default) — one TSTP solution file per system,
      each opening with a rule and a `% File : <id>` header line. A section runs
      from that rule to the next such rule, and its id is the `File` value.
      `Tptp.Tstp.from_string/2` reads it. A system that did not run — SystemOnTPTP
      judged it `Inappropriate` for the problem — has no file and no section.
    * **Raw** — each system's output between `% START OF SYSTEM OUTPUT` and
      `% END OF SYSTEM OUTPUT`, followed by the summary lines
      `% RESULT: <problem> - <id> says <Value>` and `% OUTPUT: …`. A section is
      the delimited output with the summary lines after it, and its id is the
      `<id>` of `% RESULT:`. A system that did not run has the summary lines and
      no output. A `% RESULT:` line inside the delimited output is the system's
      own — GDV prints one for every inference it checks — and is part of the
      output.

  Sections are returned in the order of the reply, which is the order the form
  named the systems in.
  """

  # Horizontal white space is `[ \t]`, never `\s`, which crosses line ends.
  @tstp_start ~r/^%-{4,}[ \t]*\r?\n% File[ \t]*:[ \t]*([^\r\n]*?)[ \t]*\r?$/m
  @start ~r/^% START OF SYSTEM OUTPUT\b/
  @stop ~r/^% END OF SYSTEM OUTPUT\b/
  @result ~r/^% RESULT: .* - (\S+) says /
  @output ~r/^% OUTPUT: /

  @typedoc "A system's identifier and the text of its section."
  @type section :: {binary(), binary()}

  @doc """
  The sections of `body`, in order.

      iex> body = "% START OF SYSTEM OUTPUT\\n% SZS status Theorem\\n% END OF SYSTEM OUTPUT\\n" <>
      ...>   "% RESULT: SOT_x - E---3.5.1 says Theorem - CPU = 0.00\\n" <>
      ...>   "% OUTPUT: SOT_x - E---3.5.1 says Proof - CPU = 0.00\\n" <>
      ...>   "% RESULT: SOT_x - Satallax---3.5 says Inappropriate - CPU = 0\\n" <>
      ...>   "% OUTPUT: SOT_x - Satallax---3.5 says None - CPU = 0\\n"
      iex> for {id, _text} <- AtpClient.SystemOnTptp.Reply.sections(body), do: id
      ["E---3.5.1", "Satallax---3.5"]

      iex> body = "%----\\n% File     : E---3.5.1\\n%----\\n%----\\n% File     : Vampire---5.0.1\\n%----\\n"
      iex> AtpClient.SystemOnTptp.Reply.sections(body)
      [{"E---3.5.1", "%----\\n% File     : E---3.5.1\\n%----\\n"}, {"Vampire---5.0.1", "%----\\n% File     : Vampire---5.0.1\\n%----\\n"}]
  """
  @spec sections(binary()) :: [section()]
  def sections(body) when is_binary(body) do
    case Regex.scan(@tstp_start, body, return: :index) do
      [] -> raw(body)
      starts -> tstp(body, starts)
    end
  end

  @doc """
  Whether `body` is in the TSTP shape.

      iex> AtpClient.SystemOnTptp.Reply.tstp?("%----\\n% File     : E---3.5.1\\n%----\\n")
      true
      iex> AtpClient.SystemOnTptp.Reply.tstp?("% START OF SYSTEM OUTPUT\\n")
      false
  """
  @spec tstp?(binary()) :: boolean()
  def tstp?(body) when is_binary(body), do: Regex.match?(@tstp_start, body)

  @spec tstp(binary(), [[{non_neg_integer(), non_neg_integer()}]]) :: [section()]
  defp tstp(body, starts) do
    offsets = Enum.map(starts, fn [{offset, _length} | _groups] -> offset end)
    ends = tl(offsets) ++ [byte_size(body)]

    starts
    |> Enum.zip(ends)
    |> Enum.map(fn {[{offset, _length}, id], stop} ->
      {binary_part(body, elem(id, 0), elem(id, 1)), binary_part(body, offset, stop - offset)}
    end)
  end

  # A line-by-line pass: `inside` is true between START and END, where a `% RESULT:`
  # line is the system's own; `id` is the identifier of a `% RESULT:` read outside,
  # whose section closes at the `% OUTPUT:` line after it, or before the next
  # section begins.
  @spec raw(binary()) :: [section()]
  defp raw(body) do
    body
    |> String.split(~r/(?<=\n)/)
    |> Enum.reduce(%{lines: [], inside: false, id: nil, sections: []}, &line/2)
    |> close()
    |> Map.fetch!(:sections)
    |> Enum.reverse()
  end

  defp line(text, state) do
    cond do
      state.inside ->
        %{state | lines: [text | state.lines], inside: not Regex.match?(@stop, text)}

      Regex.match?(@start, text) ->
        state |> close() |> Map.merge(%{lines: [text], inside: true})

      match = Regex.run(@result, text) ->
        state = if state.id, do: close(state), else: state
        %{state | lines: [text | state.lines], id: Enum.at(match, 1)}

      state.id && Regex.match?(@output, text) ->
        close(%{state | lines: [text | state.lines]})

      true ->
        %{state | lines: [text | state.lines]}
    end
  end

  defp close(%{id: nil} = state), do: state

  defp close(state) do
    text = state.lines |> Enum.reverse() |> IO.iodata_to_binary()
    %{state | lines: [], inside: false, id: nil, sections: [{state.id, text} | state.sections]}
  end
end
