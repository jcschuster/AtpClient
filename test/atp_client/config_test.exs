defmodule AtpClient.ConfigTest do
  use ExUnit.Case, async: false

  alias AtpClient.Config

  # Application env is process-global. Snapshot the backends we touch, mutate
  # freely inside each test, and restore on exit so test order does not
  # matter and other suites are unaffected.
  setup do
    backends = [:sotptp, :starexec, :isabelle, :local_exec]

    snapshot =
      for backend <- backends, into: %{} do
        {backend, Application.get_env(:atp_client, backend, :__unset__)}
      end

    on_exit(fn ->
      for {backend, value} <- snapshot do
        case value do
          :__unset__ -> Application.delete_env(:atp_client, backend)
          v -> Application.put_env(:atp_client, backend, v)
        end
      end
    end)

    :ok
  end

  describe "defaults merge underneath Application env" do
    test "fresh install (no user config) exposes the library defaults" do
      Application.delete_env(:atp_client, :sotptp)

      assert Config.fetch!(:sotptp, :url) ==
               "https://tptp.org/cgi-bin/SystemOnTPTPFormReply"

      assert Config.fetch!(:sotptp, :default_time_limit_sec) == 5
    end

    test "partial user config does not clobber unset defaults (regression for 16B)" do
      # The reviewer's footgun: user touches one key, OTP's put_env replaces
      # the whole keyword list, and `:url` silently disappears.
      Application.put_env(:atp_client, :sotptp, default_time_limit_sec: 10)

      assert Config.fetch!(:sotptp, :url) ==
               "https://tptp.org/cgi-bin/SystemOnTPTPFormReply"

      assert Config.fetch!(:sotptp, :default_time_limit_sec) == 10
    end

    test "user config wins over defaults for keys it does set" do
      Application.put_env(:atp_client, :sotptp,
        url: "https://example.org/api",
        default_time_limit_sec: 30
      )

      assert Config.fetch!(:sotptp, :url) == "https://example.org/api"
      assert Config.fetch!(:sotptp, :default_time_limit_sec) == 30
    end

    test "per-call opts win over both defaults and Application env" do
      Application.put_env(:atp_client, :sotptp, default_time_limit_sec: 30)

      assert Config.fetch!(:sotptp, :default_time_limit_sec,
               default_time_limit_sec: 99
             ) == 99
    end

    test "fetch!/3 still raises for required settings without defaults" do
      Application.delete_env(:atp_client, :starexec)

      assert_raise ArgumentError, ~r/missing required setting `:base_url`/, fn ->
        Config.fetch!(:starexec, :base_url)
      end
    end

    test "defaults are exposed via defaults/0 for tooling" do
      defaults = Config.defaults()

      assert Keyword.has_key?(defaults, :sotptp)
      assert Keyword.has_key?(defaults, :starexec)
      assert Keyword.has_key?(defaults, :isabelle)
      assert Keyword.has_key?(defaults, :local_exec)
    end

    test "isabelle post-processing still defaults :isabelle_dir to :local_dir" do
      Application.put_env(:atp_client, :isabelle,
        password: "x",
        local_dir: "/shared/problems"
      )

      resolved = Config.get(:isabelle)
      assert Keyword.get(resolved, :isabelle_dir) == "/shared/problems"
      # Defaults from @defaults still merged in:
      assert Keyword.get(resolved, :host) == "127.0.0.1"
      assert Keyword.get(resolved, :port) == 9999
    end

    test "isabelle post-processing defaults :local_dir to a tmp subdirectory" do
      Application.put_env(:atp_client, :isabelle, password: "x")

      resolved = Config.get(:isabelle)
      expected = Path.join(System.tmp_dir!(), "atp_client_isabelle")

      assert Keyword.get(resolved, :local_dir) == expected
      # :isabelle_dir then follows :local_dir:
      assert Keyword.get(resolved, :isabelle_dir) == expected
    end

    test "explicit :local_dir wins over the tmp default" do
      Application.put_env(:atp_client, :isabelle,
        password: "x",
        local_dir: "/custom/path"
      )

      resolved = Config.get(:isabelle)
      assert Keyword.get(resolved, :local_dir) == "/custom/path"
    end
  end
end
