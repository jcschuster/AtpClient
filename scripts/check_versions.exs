# Checks that every place naming AtpClient's version agrees with mix.exs:
#
#   * CITATION.cff `version`, and its `date-released` with the CHANGELOG's date;
#   * .zenodo.json `version`;
#   * the CHANGELOG's latest release section;
#   * every `{:atp_client, "~> …"}` in README.md and examples/*.livemd, which
#     the version must satisfy.
#
# With a tag (`v0.8.0`), the tag must name the version too, and nothing may be
# left under `## [Unreleased]`.
#
#     elixir scripts/check_versions.exs [TAG]
#
# Run by .github/workflows/ci.yml on every push and by release.yml on a tag.

root = Path.expand("..", __DIR__)
read = fn path -> File.read!(Path.join(root, path)) end

capture = fn text, regex, what ->
  case Regex.run(regex, text, capture: :all_but_first) do
    [value] -> value
    [_ | _] = values -> values
    nil -> raise "#{what}: not found"
  end
end

version = capture.(read.("mix.exs"), ~r/^\s*@version "([^"]+)"$/m, "mix.exs @version")
citation = read.("CITATION.cff")
changelog = read.("CHANGELOG.md")

[released, date] =
  capture.(changelog, ~r/^## \[(\d[^\]]*)\] - (\d{4}-\d{2}-\d{2})$/m, "CHANGELOG release")

requirements =
  for path <- ["README.md" | Path.wildcard(Path.join(root, "examples/*.livemd"))],
      path = Path.relative_to(path, root),
      [requirement] <- Regex.scan(~r/\{:atp_client, "([^"]+)"\}/, read.(path), capture: :all_but_first),
      do: {"#{path} requires #{requirement}", Version.match?(version, requirement)}

unreleased =
  case Regex.run(~r/^## \[Unreleased\]\n(.*?)^## \[/ms, changelog, capture: :all_but_first) do
    [entries] -> String.trim(entries)
    nil -> ""
  end

tag_checks =
  case System.argv() do
    [] ->
      []

    [tag] ->
      [
        {"tag #{tag}", String.trim_leading(tag, "v") == version},
        {"nothing under [Unreleased]", unreleased == ""}
      ]
  end

checks =
  [
    {"CITATION.cff version",
     capture.(citation, ~r/^version: "([^"]+)"$/m, "CITATION.cff version") == version},
    {"CITATION.cff date-released #{date}",
     capture.(citation, ~r/^date-released: "([^"]+)"$/m, "CITATION.cff date-released") == date},
    {".zenodo.json version", JSON.decode!(read.(".zenodo.json"))["version"] == version},
    {"CHANGELOG latest release [#{released}]", released == version}
  ] ++ requirements ++ tag_checks

IO.puts("mix.exs @version #{version}")

for {what, ok?} <- checks, do: IO.puts("  #{if ok?, do: "ok      ", else: "MISMATCH"}  #{what}")

if Enum.all?(checks, &elem(&1, 1)), do: :ok, else: System.halt(1)
