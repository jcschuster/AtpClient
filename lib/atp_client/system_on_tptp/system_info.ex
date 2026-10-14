defmodule AtpClient.SystemOnTptp.SystemInfo do
  @moduledoc """
  Reads SystemOnTPTP's SystemInfo report into `AtpClient.System` records, and
  fetches it.

  ## The report

  One record per system, opened by its identifier and `=>`, then one field per
  line as `<Key> == <value>`:

      E---3.5.1            =>
          System           == E
          Version          == 3.5.1
          People           == Stephan Schulz
          URL              == http://www.eprover.org/
          UserNote         == Prover and model finder
          Command          == run_E %s %d THM
          Format           == tptp:raw
          Transform        == none
          SPCs             == TH0_NAR TX0_NAR TF0_NAR FOF CNF
          Solved           == Theorem = SZS status Theorem && Satisfiable = SZS status Satisfiable
          GaveUp           == NO INFORMATION
          StartSoln        == CNFRefutation = SZS output start CNFRefutation
          EndSoln          == CNFRefutation = SZS output end CNFRefutation
          Statistic        == NO INFORMATION
          Status           == READY SoTPTP SSCPA TSTP STAREXEC CASC

  `NO INFORMATION` and an empty value read as absent. `Solved`, `StartSoln`,
  `EndSoln` and `GaveUp` are `&&`-separated `Word = pattern` pairs. A word the SZS ontology
  defines becomes its value in `solved` / `dataforms`; one it does not
  (`PartialSuccess`, `ListOfCNF`) is kept as text in `raw`, so no atom is ever
  created from the report. `Status` words name the interfaces the system is
  offered through and the listings it appears in; `READY` is dropped, and a word
  outside both sets is kept in `raw.status`.

  ## The request

  The report is two POSTs to the configured `:url`: `ListSystems` for the
  identifiers, then `ReportSelectedSystems` naming every one of them. The report
  refuses to run without a problem, so a one-formula problem is sent along.
  """

  alias AtpClient.Config
  alias AtpClient.System
  alias Tptp.Szs.Ontology

  @record ~r/^(\S+)\s+=>\s*$/
  @field ~r/^\s+(\w+)\s+==\s?(.*)$/

  @fields ~w(System Version People URL UserNote Command Format Transform SPCs
             Solved GaveUp StartSoln EndSoln Statistic Status)

  @interfaces %{
    "SoTPTP" => :system_on_tptp,
    "SB4TPTP" => :system_b4_tptp,
    "SoTSTP" => :system_on_tstp,
    "SoTMTP" => :system_on_tmtp,
    "PreTPTP" => :pre_tptp
  }

  @listings %{
    "TSTP" => :tstp,
    "STAREXEC" => :starexec,
    "CASC" => :casc,
    "SSCPA" => :sscpa,
    "ANSWERS" => :answers
  }

  @typedoc """
  Something the parser noticed and read past: a record missing one of the fields
  every record carries, or a line that is neither a record nor a field.
  """
  @type warning ::
          {:missing_fields, id :: binary(), [binary()]}
          | {:unreadable_line, line :: pos_integer(), binary()}

  @doc """
  The interface words of the `Status` field and the atoms they read as.
  """
  @spec interfaces() :: %{binary() => System.interface()}
  def interfaces, do: @interfaces

  @doc """
  The listing words of the `Status` field and the atoms they read as.
  """
  @spec listings() :: %{binary() => System.listing()}
  def listings, do: @listings

  @doc """
  Reads a SystemInfo report.

      iex> text = "E---3.5.1 =>\\n    System == E\\n    Version == 3.5.1\\n    Solved == Theorem = SZS status Theorem && Rated = rated\\n    Status == READY SoTPTP TSTP\\n"
      iex> {:ok, [system], [{:missing_fields, "E---3.5.1", _}]} = AtpClient.SystemOnTptp.SystemInfo.parse(text)
      iex> {system.id, system.solved, system.raw.solved, system.interfaces, system.listings}
      {"E---3.5.1", %{theorem: "SZS status Theorem"}, %{"Rated" => "rated"}, [:system_on_tptp], [:tstp]}
  """
  @spec parse(binary()) :: {:ok, [System.t()], [warning()]}
  def parse(text) when is_binary(text) do
    {records, warnings} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, &line/2)

    records = Enum.reverse(records)

    missing =
      for {id, fields} <- records,
          absent = Enum.reject(@fields, &Map.has_key?(fields, &1)),
          absent != [],
          do: {:missing_fields, id, absent}

    {:ok, Enum.map(records, &system/1), Enum.reverse(warnings) ++ missing}
  end

  defp line({text, number}, {records, warnings}) do
    cond do
      String.trim(text) == "" ->
        {records, warnings}

      match = Regex.run(@record, text) ->
        {[{Enum.at(match, 1), %{}} | records], warnings}

      (match = Regex.run(@field, text)) && records != [] ->
        [{id, fields} | rest] = records
        [_, key, value] = match
        {[{id, Map.put(fields, key, String.trim(value))} | rest], warnings}

      true ->
        {records, [{:unreadable_line, number, text} | warnings]}
    end
  end

  @spec system({binary(), %{binary() => binary()}}) :: System.t()
  defp system({id, fields}) do
    value = fn key -> present(Map.get(fields, key)) end
    {solved, raw_solved} = fields |> Map.get("Solved") |> pairs() |> split_known()
    {dataforms, raw_dataforms} = fields |> Map.get("StartSoln") |> pairs() |> split_known()
    {interfaces, listings, raw_status} = status(Map.get(fields, "Status"))

    %System{
      id: id,
      name: value.("System") || System.name(id),
      version: value.("Version") || System.version(id),
      people: list(value.("People"), ~r/\s*,\s*/),
      url: value.("URL"),
      note: value.("UserNote"),
      interfaces: interfaces,
      listings: listings,
      spcs: if(spcs = value.("SPCs"), do: String.split(spcs)),
      solved: solved,
      dataforms: dataforms,
      command: value.("Command"),
      format: value.("Format"),
      transform: value.("Transform"),
      statistic: value.("Statistic"),
      raw: %{
        status: raw_status,
        solved: raw_solved,
        dataforms: raw_dataforms,
        end_soln: fields |> Map.get("EndSoln") |> pairs() |> Map.new(),
        gave_up: fields |> Map.get("GaveUp") |> pairs() |> Map.new()
      }
    }
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present("NO INFORMATION"), do: nil
  defp present(value), do: value

  defp list(nil, _separator), do: []
  defp list(value, separator), do: String.split(value, separator, trim: true)

  # `Word = pattern && Word = pattern`, in order. A pair without ` = ` is a word with
  # an empty pattern.
  @spec pairs(binary() | nil) :: [{binary(), binary()}]
  defp pairs(value) do
    case present(value) do
      nil ->
        []

      text ->
        text |> String.split(~r/\s*&&\s*/, trim: true) |> Enum.map(&pair/1)
    end
  end

  defp pair(text) do
    case String.split(text, ~r/\s*=\s*/, parts: 2) do
      [word, pattern] -> {String.trim(word), String.trim(pattern)}
      [word] -> {String.trim(word), ""}
    end
  end

  # Ontology words to values, the rest kept as text. The first pattern for a word wins.
  defp split_known(pairs) do
    Enum.reduce(pairs, {%{}, %{}}, fn {word, pattern}, {known, raw} ->
      case Ontology.from_string(word) do
        {:ok, value} -> {Map.put_new(known, value, pattern), raw}
        :error -> {known, Map.put_new(raw, word, pattern)}
      end
    end)
  end

  defp status(value) do
    words = value |> present() |> to_string() |> String.split() |> Enum.reject(&(&1 == "READY"))

    # One record on 2026-10-14 lists SoTPTP twice.
    {for(word <- words, atom = @interfaces[word], uniq: true, do: atom),
     for(word <- words, atom = @listings[word], uniq: true, do: atom),
     Enum.reject(words, &(Map.has_key?(@interfaces, &1) or Map.has_key?(@listings, &1)))}
  end

  @doc """
  Fetches the report for every system the deployment lists as ready.

  ## Options

    * `:url` — the SystemOnTPTP endpoint (default the configured one);
    * `:refresh_timeout_ms` — receive timeout per request (default from config,
      60 s: the report for 174 systems is 135 KB and took 5 s on 2026-10-14).
  """
  @spec fetch(keyword()) :: {:ok, [System.t()], [warning()]} | {:error, term()}
  def fetch(opts \\ []) do
    with {:ok, ids} <- list_systems(opts),
         {:ok, body} <- report(ids, opts) do
      parse(body)
    end
  end

  @doc """
  The identifiers the deployment lists as ready, in the order it lists them.
  """
  @spec list_systems(keyword()) :: {:ok, [binary()]} | {:error, term()}
  def list_systems(opts \\ []) do
    form = [
      {"SubmitButton", "ListSystems"},
      {"ListStatus", "READY"},
      {"QuietFlag", "-q0"},
      {"NoHTML", "1"}
    ]

    with {:ok, body} <- post(form, opts) do
      {:ok,
       body
       |> String.split(~r/\r?\n/, trim: true)
       |> Enum.map(&String.trim/1)
       |> Enum.filter(&String.contains?(&1, "---"))
       |> Enum.uniq()}
    end
  end

  @spec report([binary()], keyword()) :: {:ok, binary()} | {:error, term()}
  defp report([], _opts), do: {:ok, ""}

  defp report(ids, opts) do
    form =
      [
        {"SubmitButton", "ReportSelectedSystems"},
        {"SystemInfo", "SystemInfo"},
        {"ReportFlag", "-q2"},
        {"QuietFlag", "-q01"},
        {"NoHTML", "1"},
        {"ProblemSource", "FORMULAE"},
        {"FORMULAEProblem", "fof(a,axiom,p)."}
      ] ++ Enum.map(ids, &{"System___" <> &1, &1})

    post(form, opts)
  end

  # The form is a list, as in `AtpClient.SystemOnTptp`: the report follows the
  # order of the fields.
  defp post(form, opts) do
    url = Config.fetch!(:sotptp, :url, opts)
    timeout_ms = Config.fetch(:sotptp, :refresh_timeout_ms, 60_000, opts)

    case Req.post(url,
           form: form,
           finch: [name: AtpClient.TptpFinch],
           compressed: false,
           receive_timeout: timeout_ms,
           retry: :transient,
           retry_delay: fn _ -> 500 end
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "API Error: status #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end
end
