defmodule JidoHpc.ConfigTest do
  # async: false because we mutate Application env + System env.
  use ExUnit.Case, async: false

  alias JidoHpc.Config

  setup do
    # Snapshot anything we touch, restore on exit.
    saved_default_model = Application.get_env(:jido_ai, :default_model)
    saved_anthropic_key = Application.get_env(:req_llm, :anthropic_api_key)
    saved_env = System.get_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      restore_app_env(:jido_ai, :default_model, saved_default_model)
      restore_app_env(:req_llm, :anthropic_api_key, saved_anthropic_key)
      restore_sys_env("ANTHROPIC_API_KEY", saved_env)
    end)

    # Clear any ambient key so the "missing" branch is reachable.
    Application.delete_env(:req_llm, :anthropic_api_key)
    System.delete_env("ANTHROPIC_API_KEY")

    :ok
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, val), do: Application.put_env(app, key, val)

  defp restore_sys_env(key, nil), do: System.delete_env(key)
  defp restore_sys_env(key, val), do: System.put_env(key, val)

  describe "default_provider/0" do
    test "extracts provider atom from {:provider, model_name}" do
      Application.put_env(:jido_ai, :default_model, {:anthropic, "claude-sonnet-4-6"})
      assert {:ok, :anthropic} = Config.default_provider()
    end

    test "extracts provider atom from a struct with :provider field" do
      Application.put_env(:jido_ai, :default_model, %{provider: :openai})
      assert {:ok, :openai} = Config.default_provider()
    end

    test "falls back to :anthropic when no model is configured" do
      Application.delete_env(:jido_ai, :default_model)
      assert {:ok, :anthropic} = Config.default_provider()
    end

    test "errors on an unrecognized shape" do
      Application.put_env(:jido_ai, :default_model, "anthropic:claude-sonnet-4-6")
      assert {:error, msg} = Config.default_provider()
      assert msg =~ "Unrecognized"
    end
  end

  describe "api_key_status/0" do
    test "returns {:error, msg} when no key is set anywhere" do
      Application.put_env(:jido_ai, :default_model, {:anthropic, "claude-sonnet-4-6"})

      assert {:error, msg} = Config.api_key_status()
      assert msg =~ "No API key found"
      assert msg =~ "ANTHROPIC_API_KEY"
      assert msg =~ "anthropic_api_key"
    end

    test "returns {:ok, ...} from application env" do
      Application.put_env(:jido_ai, :default_model, {:anthropic, "claude-sonnet-4-6"})
      Application.put_env(:req_llm, :anthropic_api_key, "sk-ant-test-app")

      assert {:ok, %{provider: :anthropic, source: source}} = Config.api_key_status()
      assert source == :application
    end

    test "returns {:ok, ...} from system env" do
      Application.put_env(:jido_ai, :default_model, {:anthropic, "claude-sonnet-4-6"})
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test-sys")

      assert {:ok, %{provider: :anthropic, source: source}} = Config.api_key_status()
      assert source == :system
    end
  end
end
