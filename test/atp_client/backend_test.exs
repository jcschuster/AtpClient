defmodule AtpClient.BackendTest do
  use ExUnit.Case, async: true

  alias AtpClient.Config.Field

  @backends AtpClient.backends()

  describe "backend registry" do
    test "AtpClient.backends/0 lists the four backends" do
      assert AtpClient.SystemOnTptp in @backends
      assert AtpClient.StarExec in @backends
      assert AtpClient.Isabelle in @backends
      assert AtpClient.LocalExec in @backends
    end

    test "every backend implements the AtpClient.Backend behaviour" do
      for module <- @backends do
        assert function_exported?(module, :config_key, 0),
               "#{inspect(module)}.config_key/0 missing"

        assert function_exported?(module, :label, 0),
               "#{inspect(module)}.label/0 missing"

        assert function_exported?(module, :config_schema, 0),
               "#{inspect(module)}.config_schema/0 missing"

        assert function_exported?(module, :verify, 1),
               "#{inspect(module)}.verify/1 missing"

        assert function_exported?(module, :query, 2),
               "#{inspect(module)}.query/2 missing"
      end
    end

    test "config_key/0 returns the atom the Config module recognizes" do
      assert AtpClient.SystemOnTptp.config_key() == :sotptp
      assert AtpClient.StarExec.config_key() == :starexec
      assert AtpClient.Isabelle.config_key() == :isabelle
      assert AtpClient.LocalExec.config_key() == :local_exec
    end
  end

  describe "config_schema/0" do
    test "every field is a %Field{} with the required fields populated" do
      for module <- @backends, field <- module.config_schema() do
        assert %Field{} = field, "#{inspect(module)} returned a non-Field entry"
        assert is_atom(field.key)
        assert field.type in [:string, :integer, :boolean, :string_list]
        assert is_boolean(field.required?)
        assert field.group in [:connection, :defaults, :advanced]
        assert is_boolean(field.secret?)
      end
    end

    test "secret? is only set on string fields" do
      for module <- @backends,
          field <- module.config_schema(),
          field.secret? do
        assert field.type == :string,
               "#{inspect(module)}.#{field.key} is :secret? but typed #{inspect(field.type)}"
      end
    end

    test "keys are unique within a backend" do
      for module <- @backends do
        keys = Enum.map(module.config_schema(), & &1.key)
        assert keys == Enum.uniq(keys), "duplicate keys in #{inspect(module)}: #{inspect(keys)}"
      end
    end

    test "expected connection fields exist per backend" do
      sotptp_keys = key_set(AtpClient.SystemOnTptp)
      assert :url in sotptp_keys

      starexec_keys = key_set(AtpClient.StarExec)
      assert :base_url in starexec_keys
      assert :username in starexec_keys
      assert :password in starexec_keys

      isabelle_keys = key_set(AtpClient.Isabelle)
      assert :host in isabelle_keys
      assert :port in isabelle_keys
      assert :password in isabelle_keys
      assert :local_dir in isabelle_keys

      local_exec_keys = key_set(AtpClient.LocalExec)
      assert :binary in local_exec_keys
    end

    test "password fields are marked secret?" do
      for module <- [AtpClient.StarExec, AtpClient.Isabelle] do
        field = Enum.find(module.config_schema(), &(&1.key == :password))
        assert field.secret?, "#{inspect(module)}.password should be secret?"
      end
    end
  end

  describe "verify/1" do
    test "LocalExec verify returns :ok for a binary on PATH" do
      assert :ok = AtpClient.LocalExec.verify(binary: "sh")
    end

    test "LocalExec verify returns {:error, {:prover_not_found, _}} for a missing binary" do
      assert {:error, {:prover_not_found, "definitely_not_a_real_binary_xyz"}} =
               AtpClient.LocalExec.verify(binary: "definitely_not_a_real_binary_xyz")
    end

    test "Isabelle verify returns {:error, _} against an unreachable host" do
      # Port 1 is reserved; the connection should fail fast.
      assert {:error, _reason} =
               AtpClient.Isabelle.verify(
                 host: "127.0.0.1",
                 port: 1,
                 password: "x",
                 local_dir: "/tmp",
                 session_start_timeout_ms: 1_000
               )
    end

    test "StarExec verify returns {:error, _} against an unreachable host" do
      assert {:error, _reason} =
               AtpClient.StarExec.verify(
                 base_url: "http://127.0.0.1:1",
                 username: "u",
                 password: "p",
                 request_timeout_ms: 1_000,
                 connect_options: [timeout: 500]
               )
    end
  end

  describe "query/2" do
    test "Isabelle query/2 returns {:error, _} against an unreachable host" do
      assert {:error, _reason} =
               AtpClient.Isabelle.query("thf(c,conjecture,$true).",
                 host: "127.0.0.1",
                 port: 1,
                 password: "x",
                 local_dir: "/tmp",
                 session_start_timeout_ms: 1_000
               )
    end

    test "StarExec query/2 returns {:error, _} against an unreachable host" do
      assert {:error, _reason} =
               AtpClient.StarExec.query("fof(c,conjecture,$true).",
                 base_url: "http://127.0.0.1:1",
                 username: "u",
                 password: "p",
                 request_timeout_ms: 1_000,
                 connect_options: [timeout: 500]
               )
    end

    test "LocalExec query/2 returns {:error, _} for a missing binary" do
      assert {:error, {:prover_not_found, "definitely_not_a_real_binary_xyz"}} =
               AtpClient.LocalExec.query("fof(c,conjecture,$true).",
                 binary: "definitely_not_a_real_binary_xyz"
               )
    end
  end

  defp key_set(module) do
    module.config_schema() |> Enum.map(& &1.key) |> MapSet.new()
  end
end
