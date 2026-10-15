defmodule AtpClient.System do
  @moduledoc """
  A system SystemOnTPTP offers: what its SystemInfo record says about it, and what
  it can be used for.

  The record is read by `AtpClient.SystemOnTptp.SystemInfo`; `AtpClient.SystemOnTptp.Systems`
  holds the current set. Every field but `capabilities/1` is the record as written,
  so a rule change never needs the records fetched again.

  ## Fields

    * `id`, `name`, `version` — `"E---3.5.1"`, `"E"`, `"3.5.1"`.
    * `people`, `url`, `note` — `People`, `URL`, `UserNote`.
    * `interfaces` — the SystemOnTPTP interfaces the system is offered through, from
      `Status`: `:system_on_tptp` (problems), `:system_b4_tptp` (problem tools),
      `:system_on_tstp` (solution tools), `:system_on_tmtp`, `:pre_tptp`
      (converters into TPTP).
    * `listings` — the archives the system appears in, from `Status`: `:tstp`,
      `:starexec`, `:casc`, `:sscpa`, `:answers`.
    * `spcs` — the SPCs it accepts, `nil` when the record gives none; read by
      `dialects/1`.
    * `solved` — the SZS values the system reports, each with the text that shows
      it in the output (`:theorem => "SZS status Theorem"`).
    * `dataforms` — the SZS dataforms it outputs, each with the text that opens one
      (`:cnf_refutation => "SZS output start CNFRefutation"`).
    * `command`, `format`, `transform`, `statistic` — as written.
    * `raw` — what has no place above: `Status` words outside both sets,
      `Solved`/`StartSoln` words the ontology does not define, `EndSoln`, `GaveUp`.

  ## Capabilities

  `capabilities/1` says what a system is for, each capability with where it came
  from: `:rule` from the record's machine-readable fields, `:note` from keywords
  in `UserNote` where the rules find nothing, `:override` from
  `priv/system_on_tptp/overrides.json`. See `capabilities/2` for the rules.

  ## Dialects

  `dialects/1` says which TPTP dialects the system takes, read from `spcs`. An
  SPC word is a form and the components a problem must also have — `TH0_NAR` is
  TH0 without arithmetic — and SystemOnTPTP's `RecommendSystems` offers a system
  for a problem when every component of one of its words is in the problem's SPC
  (iProver's `TF0_NDT` for `TF0_THM_NEQ_ARI_NDT`). The form is read as the
  `Tptp.Query.dialect/1` of a problem in it, so the two compare directly:

      dialect = Tptp.Analysis.dialect(Tptp.analyze(problem))
      AtpClient.SystemOnTptp.systems(dialect: dialect)

  By membership, not `Tptp.Query.within?/2`: the records name every form they
  take, and a TF0 file is not a TH0 file to a prover. The other components are
  kept as written, since a problem's dialect does not say whether it has them.
  """

  alias Tptp.Szs.Ontology

  defstruct [
    :id,
    :name,
    :version,
    :url,
    :note,
    :spcs,
    :command,
    :format,
    :transform,
    :statistic,
    people: [],
    interfaces: [],
    listings: [],
    solved: %{},
    dataforms: %{},
    raw: %{status: [], solved: %{}, dataforms: %{}, end_soln: %{}, gave_up: %{}}
  ]

  @typedoc "A SystemOnTPTP interface the system is offered through."
  @type interface ::
          :system_on_tptp | :system_b4_tptp | :system_on_tstp | :system_on_tmtp | :pre_tptp

  @typedoc "An archive the system appears in."
  @type listing :: :tstp | :starexec | :casc | :sscpa | :answers

  @typedoc "What a system can be used for."
  @type capability ::
          :prove
          | :find_model
          | :verify
          | :verify_model
          | :transform
          | :check
          | :inspect
          | :import

  @typedoc "Where a capability came from."
  @type provenance :: :rule | :note | :override

  @typedoc "An entry of the overrides file."
  @type override :: %{capabilities: [capability()], reason: binary(), since: binary()}

  @typedoc """
  A dialect the system accepts, with the other components of the SPC word that
  names it, as written: `{:th0, ["NAR"]}`.
  """
  @type accepted :: {Tptp.Query.dialect(), [binary()]}

  @type t :: %__MODULE__{
          id: binary(),
          name: binary(),
          version: binary() | nil,
          people: [binary()],
          url: binary() | nil,
          note: binary() | nil,
          interfaces: [interface()],
          listings: [listing()],
          spcs: [binary()] | nil,
          solved: %{Ontology.t() => binary()},
          dataforms: %{Ontology.t() => binary()},
          command: binary() | nil,
          format: binary() | nil,
          transform: binary() | nil,
          statistic: binary() | nil,
          raw: %{
            status: [binary()],
            solved: %{binary() => binary()},
            dataforms: %{binary() => binary()},
            end_soln: %{binary() => binary()},
            gave_up: %{binary() => binary()}
          }
        }

  @capabilities [
    :prove,
    :find_model,
    :verify,
    :verify_model,
    :transform,
    :check,
    :inspect,
    :import
  ]

  @verified [:verified_good, :verified_bad, :verify_success, :not_verified, :failed_verified]

  # Substrings of the lower-cased `UserNote`, in the order they are tried.
  @keywords [
    {"prover", :prove},
    {"model finder", :find_model},
    {"verifier", :verify},
    {"checker", :verify},
    {"convert", :transform},
    {"embeds", :transform},
    {"grounds", :transform},
    {"skolemizer", :transform},
    {"transforming", :transform},
    {"checks", :check},
    {"syntax", :check},
    {"viewer", :inspect},
    {"summari", :inspect},
    {"statistics", :inspect},
    {"rates", :inspect}
  ]

  # The form of an SPC word, its first component, as `Tptp.Query` names the
  # dialect of a problem in it.
  @forms %{
    "CNF" => :cnf,
    "FOF" => :fof,
    "TF0" => :tf0,
    "TF1" => :tf1,
    "TX0" => :tx0,
    "TX1" => :tx1,
    "TH0" => :th0,
    "TH1" => :th1,
    "DH0" => :dh0,
    "DH1" => :dh1,
    "NX0" => :nxf,
    "NX1" => :nxf,
    "NH0" => :nhf,
    "NH1" => :nhf
  }

  # The families of the TPTP technical report, which a record may name in place
  # of their forms: SPCForProblem's SPCs are `NTF THF TXF TFF FOF CNF`.
  @families %{
    "THF" => ~w(TH0 TH1),
    "TFF" => ~w(TF0 TF1 TX0 TX1),
    "TXF" => ~w(TX0 TX1),
    "NTF" => ~w(NX0 NX1 NH0 NH1)
  }

  @overrides_path "system_on_tptp/overrides.json"

  @doc "Every capability, in the order `capabilities/2` documents them."
  @spec all_capabilities() :: [capability()]
  def all_capabilities, do: @capabilities

  @doc """
  The name of a system identifier: `"Vampire"` for `"Vampire---5.0.1"`. A bare
  name is returned as it is.

      iex> AtpClient.System.name("Vampire---5.0.1")
      "Vampire"
  """
  @spec name(binary()) :: binary()
  def name(id) when is_binary(id), do: id |> String.split("---", parts: 2) |> hd()

  @doc """
  The version of a system identifier, `nil` for a bare name.

      iex> AtpClient.System.version("Vampire---5.0.1")
      "5.0.1"
  """
  @spec version(binary()) :: binary() | nil
  def version(id) when is_binary(id) do
    case String.split(id, "---", parts: 2) do
      [_name, version] -> version
      [_name] -> nil
    end
  end

  @doc """
  What the system can be used for, each capability with its provenance.

  Derived in three steps:

  1. **Rules** over the machine-readable fields:

     | capability | rule |
     |---|---|
     | `:prove` | `solved` has `:theorem`, `:unsatisfiable` or `:contradictory_axioms` |
     | `:find_model` | `solved` has `:satisfiable` or `:counter_satisfiable`, and a dataform within `Interpretation` (`Saturation` included) |
     | `:verify` | `solved` has `:verified_good`, `:verified_bad`, `:verify_success`, `:not_verified` or `:failed_verified` |
     | `:transform` | offered through `:system_b4_tptp`, and a `ListOfFormulae` dataform or a raw `ListOf…` one |
     | `:check` | offered through `:system_b4_tptp`, and `solved` has `:syntax_error` or `:type_error` |
     | `:import` | offered through `:pre_tptp` |

     The `:verify` rule reads keys, not pattern text: AGMV's key is
     `VerifiedGood`, its pattern `SZS status Verified`, per its record. No rule
     gives `:inspect`: a viewer, a summariser and a converter on SystemOnTSTP
     have the same record (`Success`, no dataform), so the field cannot tell
     them apart and the word has to.

  2. **Keywords** in the lower-cased `note`, only where the rules give nothing:
     `prover` → `:prove`; `model finder` → `:find_model`; `verifier`, `checker` →
     `:verify`; `convert`, `embeds`, `grounds`, `skolemizer`, `transforming` →
     `:transform`; `checks`, `syntax` → `:check`; `viewer`, `summari`,
     `statistics`, `rates` → `:inspect`. One exception: `model verifier` adds
     `:verify_model` whatever the rules gave, since no field tells a model
     verifier from any other.

  3. **Override**: an entry for the system's *name* in `overrides` replaces the
     derived set entirely.

  `%{}` for a system none of the three touches; such a system is still listed and
  runnable.

      iex> system = %AtpClient.System{id: "E---3.5.1", name: "E", note: "Prover and model finder",
      ...>   solved: %{theorem: "SZS status Theorem", satisfiable: "SZS status Satisfiable"},
      ...>   dataforms: %{saturation: "SZS output start Saturation"}}
      iex> AtpClient.System.capabilities(system, %{})
      %{prove: :rule, find_model: :rule}
  """
  @spec capabilities(t(), %{binary() => override()}) :: %{capability() => provenance()}
  def capabilities(%__MODULE__{} = system, overrides \\ overrides()) do
    case Map.fetch(overrides, system.name) do
      {:ok, %{capabilities: capabilities}} -> Map.new(capabilities, &{&1, :override})
      :error -> derived(system)
    end
  end

  @doc """
  The capabilities the rules and keywords give, ignoring any override.
  """
  @spec derived(t()) :: %{capability() => provenance()}
  def derived(%__MODULE__{} = system) do
    rules = Map.new(rules(system), &{&1, :rule})
    note = String.downcase(system.note || "")

    from_note =
      if rules == %{} do
        for {keyword, capability} <- @keywords, String.contains?(note, keyword), into: %{} do
          {capability, :note}
        end
      else
        %{}
      end

    model_verifier =
      if String.contains?(note, "model verifier"), do: %{verify_model: :note}, else: %{}

    rules |> Map.merge(from_note) |> Map.merge(model_verifier)
  end

  @doc """
  The capabilities the rules alone give; never `:inspect`.
  """
  @spec rules(t()) :: [capability()]
  def rules(%__MODULE__{} = system) do
    solved = Map.keys(system.solved)
    dataforms = Map.keys(system.dataforms)
    b4 = :system_b4_tptp in system.interfaces

    fired =
      for {capability, true} <- [
            prove: Enum.any?([:theorem, :unsatisfiable, :contradictory_axioms], &(&1 in solved)),
            find_model:
              Enum.any?([:satisfiable, :counter_satisfiable], &(&1 in solved)) and
                Enum.any?(dataforms, &Ontology.isa?(&1, :interpretation)),
            verify: Enum.any?(@verified, &(&1 in solved)),
            transform:
              b4 and
                (Enum.any?(dataforms, &Ontology.isa?(&1, :list_of_formulae)) or
                   Enum.any?(Map.keys(system.raw.dataforms), &String.starts_with?(&1, "ListOf"))),
            check: b4 and Enum.any?([:syntax_error, :type_error], &(&1 in solved)),
            import: :pre_tptp in system.interfaces
          ],
          do: capability

    fired
  end

  @doc """
  The dialects the system accepts, each with the other components of the SPC
  word that names it: `{:th0, ["NAR"]}` is TH0 without arithmetic, `{:fof, []}`
  all of FOF. In the record's order, once per word. `nil` when the record gives
  no SPCs: nothing is known, which is not nothing accepted.

  The components, after the TPTP technical report: the status `THM`, `CAX`,
  `CSA`, `UNS`, `SAT`, `UNK`, `OPN`; the order `PRP`, `EPR`, `RFO`; equality
  `EQU`, `SEQ`, `PEQ`, `UEQ`, `NUE`, `NEQ`; arithmetic `ARI`, `NAR`; Hornness
  `HRN`, `NHN`; and, newer than its list, datatypes `DAT`, `NDT`.

  A family stands for its forms: `THF` for TH0 and TH1, `TFF` for TF0, TF1, TX0
  and TX1, `TXF` for TX0 and TX1, `NTF` for NX0, NX1, NH0 and NH1. NX0 and NX1
  both read as `:nxf`, NH0 and NH1 as `:nhf`, since `Tptp.Query` does not split
  the non-classical dialects by polymorphism; `spcs` keeps the word. A word of
  any other form is left out and listed by `unread_spcs/1`.

      iex> system = %AtpClient.System{id: "E---3.5.1", spcs: ~w(TH0_NAR TX0_NAR TF0_NAR FOF CNF)}
      iex> AtpClient.System.dialects(system)
      [th0: ["NAR"], tx0: ["NAR"], tf0: ["NAR"], fof: [], cnf: []]

      iex> system = %AtpClient.System{id: "Paradox---4.0", spcs: ~w(FOF_CSA FOF_SAT CNF_SAT)}
      iex> AtpClient.System.dialects(system)
      [fof: ["CSA"], fof: ["SAT"], cnf: ["SAT"]]

      iex> AtpClient.System.dialects(%AtpClient.System{id: "TPTP4X---0.0"})
      nil
  """
  @spec dialects(t()) :: [accepted()] | nil
  def dialects(%__MODULE__{spcs: nil}), do: nil

  def dialects(%__MODULE__{spcs: spcs}) do
    for word <- spcs,
        [form | components] = String.split(word, "_"),
        form <- Map.get(@families, form, [form]),
        dialect = @forms[form],
        uniq: true,
        do: {dialect, components}
  end

  @doc """
  The SPC words whose form `dialects/1` does not read.

      iex> AtpClient.System.unread_spcs(%AtpClient.System{id: "X---1", spcs: ~w(TC0_NAR FOF)})
      ["TC0_NAR"]
  """
  @spec unread_spcs(t()) :: [binary()]
  def unread_spcs(%__MODULE__{spcs: spcs}) do
    for word <- spcs || [],
        [form | _components] = String.split(word, "_"),
        not Map.has_key?(@forms, form) and not Map.has_key?(@families, form),
        do: word
  end

  @doc """
  The overrides file, `priv/system_on_tptp/overrides.json`, keyed by system name.

  Every entry must carry `capabilities`, `reason` and `since`; a malformed file
  raises, since it is maintained by hand alongside this library.
  """
  @spec overrides() :: %{binary() => override()}
  def overrides do
    case :persistent_term.get({__MODULE__, :overrides}, nil) do
      nil ->
        overrides =
          :atp_client
          |> Application.app_dir("priv")
          |> Path.join(@overrides_path)
          |> read_overrides()

        :persistent_term.put({__MODULE__, :overrides}, overrides)
        overrides

      overrides ->
        overrides
    end
  end

  @doc """
  Reads an overrides file at `path`; see `overrides/0`.
  """
  @spec read_overrides(Path.t()) :: %{binary() => override()}
  def read_overrides(path) do
    case File.read(path) do
      {:ok, text} -> text |> Jason.decode!() |> decode_overrides()
      {:error, :enoent} -> %{}
    end
  end

  @doc false
  @spec decode_overrides(map()) :: %{binary() => override()}
  def decode_overrides(map) when is_map(map) do
    Map.new(map, fn
      {name, %{"capabilities" => capabilities, "reason" => reason, "since" => since}}
      when is_list(capabilities) and is_binary(reason) and reason != "" and is_binary(since) ->
        {name,
         %{capabilities: Enum.map(capabilities, &capability!/1), reason: reason, since: since}}

      {name, entry} ->
        raise ArgumentError,
              "override for #{name} needs capabilities, reason and since: #{inspect(entry)}"
    end)
  end

  @doc """
  The capability a word names, for the overrides file and the mix tasks.

      iex> AtpClient.System.capability!("verify_model")
      :verify_model
  """
  @spec capability!(binary()) :: capability()
  def capability!(word) when is_binary(word) do
    Enum.find(@capabilities, &(Atom.to_string(&1) == word)) ||
      raise ArgumentError, "unknown capability #{inspect(word)}"
  end

  @doc """
  The system as plain JSON-encodable data, the shape of `systems.json`.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = system) do
    %{
      "id" => system.id,
      "name" => system.name,
      "version" => system.version,
      "people" => system.people,
      "url" => system.url,
      "note" => system.note,
      "interfaces" => Enum.map(system.interfaces, &Atom.to_string/1),
      "listings" => Enum.map(system.listings, &Atom.to_string/1),
      "spcs" => system.spcs,
      "solved" =>
        Map.new(system.solved, fn {value, pattern} -> {Ontology.name(value), pattern} end),
      "dataforms" =>
        Map.new(system.dataforms, fn {value, pattern} -> {Ontology.name(value), pattern} end),
      "command" => system.command,
      "format" => system.format,
      "transform" => system.transform,
      "statistic" => system.statistic,
      "raw" => %{
        "status" => system.raw.status,
        "solved" => system.raw.solved,
        "dataforms" => system.raw.dataforms,
        "end_soln" => system.raw.end_soln,
        "gave_up" => system.raw.gave_up
      }
    }
  end

  @doc """
  Reads `to_json/1`'s shape back. Interface and listing words outside the known
  sets, and SZS words outside the ontology, go to `raw`; no atom is created.
  """
  @spec from_json(map()) :: t()
  def from_json(%{"id" => id} = map) do
    interfaces = AtpClient.SystemOnTptp.SystemInfo.interfaces() |> Map.values()
    listings = AtpClient.SystemOnTptp.SystemInfo.listings() |> Map.values()
    raw = Map.get(map, "raw", %{})
    {solved, raw_solved} = known(Map.get(map, "solved", %{}))
    {dataforms, raw_dataforms} = known(Map.get(map, "dataforms", %{}))

    %__MODULE__{
      id: id,
      name: Map.get(map, "name") || name(id),
      version: Map.get(map, "version"),
      people: Map.get(map, "people", []),
      url: Map.get(map, "url"),
      note: Map.get(map, "note"),
      interfaces: atoms(Map.get(map, "interfaces", []), interfaces),
      listings: atoms(Map.get(map, "listings", []), listings),
      spcs: Map.get(map, "spcs"),
      solved: solved,
      dataforms: dataforms,
      command: Map.get(map, "command"),
      format: Map.get(map, "format"),
      transform: Map.get(map, "transform"),
      statistic: Map.get(map, "statistic"),
      raw: %{
        status: Map.get(raw, "status", []),
        solved: Map.merge(raw_solved, Map.get(raw, "solved", %{})),
        dataforms: Map.merge(raw_dataforms, Map.get(raw, "dataforms", %{})),
        end_soln: Map.get(raw, "end_soln", %{}),
        gave_up: pairs(Map.get(raw, "gave_up", %{}))
      }
    }
  end

  # Snapshots written before 0.8.0 hold `gave_up` as a list.
  defp pairs(map) when is_map(map), do: map
  defp pairs(_list), do: %{}

  defp atoms(words, known),
    do: for(word <- words, atom <- known, Atom.to_string(atom) == word, do: atom)

  defp known(map) do
    Enum.reduce(map, {%{}, %{}}, fn {word, pattern}, {known, raw} ->
      case Ontology.from_string(word) do
        {:ok, value} -> {Map.put(known, value, pattern), raw}
        :error -> {known, Map.put(raw, word, pattern)}
      end
    end)
  end
end
