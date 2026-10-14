defmodule AtpClient.SystemOnTptp.Audit do
  @moduledoc """
  What in a snapshot of systems needs a person's attention: the list
  `mix atp_client.systems.audit` prints and the nightly workflow fails on.

  A finding is one of:

    * `:note` — the system's capabilities come, at least in part, from the
      keyword fallback over `UserNote`, and no override covers it;
    * `:none` — it has no capabilities at all, and no override covers it;
    * `:stale_override` — an override exists, but the rules alone now classify the
      system (its derived capabilities are non-empty and all `:rule`);
    * `:unadvertised_override` — an override names a system the snapshot does not
      list;
    * `{:new_word, field, word}` — a `Status`, `Solved` or `StartSoln` word kept
      in `raw` that the previous snapshot did not have anywhere.

  Each finding names the system and the override that would silence it; adding,
  removing or editing that entry in `priv/system_on_tptp/overrides.json` is the
  only way to silence a line, except a new word, which is new only once.
  """

  alias AtpClient.System

  @type finding ::
          :note
          | :none
          | :stale_override
          | :unadvertised_override
          | {:new_word, :status | :solved | :dataforms, binary()}

  @typedoc "One line of the attention list."
  @type line :: %{system: binary(), finding: finding(), suggestion: binary()}

  @doc """
  The attention list for `systems` under `overrides`, compared with `previous`
  (the systems of the snapshot before, or `nil` for none).
  """
  @spec findings([System.t()], %{binary() => System.override()}, [System.t()] | nil) :: [line()]
  def findings(systems, overrides, previous \\ nil) do
    names = MapSet.new(systems, & &1.name)

    classified =
      Enum.flat_map(systems, fn system ->
        derived = System.derived(system)
        override = Map.get(overrides, system.name)

        cond do
          override && derived != %{} && Enum.all?(derived, &(elem(&1, 1) == :rule)) ->
            [
              line(
                system.name,
                :stale_override,
                "remove the #{inspect(system.name)} entry: the rules give #{caps(derived)}"
              )
            ]

          override ->
            []

          derived == %{} ->
            [line(system.id, :none, suggestion(system.name, []))]

          Enum.any?(derived, &(elem(&1, 1) == :note)) ->
            [line(system.id, :note, suggestion(system.name, Map.keys(derived)))]

          true ->
            []
        end
      end)

    unadvertised =
      for {name, _entry} <- overrides, not MapSet.member?(names, name) do
        line(name, :unadvertised_override, "remove the #{inspect(name)} entry")
      end

    classified ++ Enum.sort_by(unadvertised, & &1.system) ++ new_words(systems, previous)
  end

  defp new_words(_systems, nil), do: []

  defp new_words(systems, previous) do
    seen = words(previous)

    for system <- systems,
        {field, word} <- system |> List.wrap() |> words() |> MapSet.to_list() |> Enum.sort(),
        not MapSet.member?(seen, {field, word}) do
      line(
        system.id,
        {:new_word, field, word},
        "check what #{word} means; it is new to the report and kept as text"
      )
    end
  end

  defp words(systems) do
    for system <- systems,
        pair <-
          Enum.map(system.raw.status, &{:status, &1}) ++
            Enum.map(Map.keys(system.raw.solved), &{:solved, &1}) ++
            Enum.map(Map.keys(system.raw.dataforms), &{:dataforms, &1}),
        into: MapSet.new(),
        do: pair
  end

  defp line(system, finding, suggestion),
    do: %{system: system, finding: finding, suggestion: suggestion}

  defp suggestion(name, capabilities) do
    entry =
      Jason.encode!(%{
        name => %{
          "capabilities" => Enum.map(Enum.sort(capabilities), &Atom.to_string/1),
          "reason" => "…",
          "since" => Date.to_iso8601(Date.utc_today())
        }
      })

    "add to overrides.json: #{entry}"
  end

  defp caps(derived),
    do: derived |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &Atom.to_string/1)

  @doc """
  One line of text per finding.
  """
  @spec format([line()]) :: binary()
  def format(lines) do
    Enum.map_join(lines, "", fn %{system: system, finding: finding, suggestion: suggestion} ->
      "#{system}: #{describe(finding)} — #{suggestion}\n"
    end)
  end

  defp describe(:note), do: "capabilities from the UserNote keyword fallback"
  defp describe(:none), do: "no capabilities"
  defp describe(:stale_override), do: "override may be stale"
  defp describe(:unadvertised_override), do: "override for a system no longer advertised"
  defp describe({:new_word, field, word}), do: "new #{field} word #{inspect(word)}"
end
