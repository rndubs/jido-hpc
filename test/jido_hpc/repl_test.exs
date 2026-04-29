defmodule JidoHpc.REPLTest do
  use ExUnit.Case, async: false

  alias JidoHpc.REPL
  alias JidoHpc.Test.REPLDispatcherStub

  setup do
    REPLDispatcherStub.reset()
    on_exit(&REPLDispatcherStub.reset/0)
    :ok
  end

  defp test_io(input_lines, confirm_answer \\ false) do
    parent = self()
    inputs = :queue.from_list(input_lines)
    {:ok, agent} = Agent.start_link(fn -> %{inputs: inputs, output: []} end)

    %{
      io: %{
        read_line: fn _prompt ->
          Agent.get_and_update(agent, fn %{inputs: q} = s ->
            case :queue.out(q) do
              {{:value, line}, q2} -> {line, %{s | inputs: q2}}
              {:empty, _} -> {:eof, s}
            end
          end)
        end,
        write: fn data ->
          send(parent, {:repl_write, IO.iodata_to_binary(data)})
          Agent.update(agent, fn s -> %{s | output: [data | s.output]} end)
        end,
        confirm: fn _ -> confirm_answer end
      },
      output: fn -> Agent.get(agent, & &1.output) |> Enum.reverse() |> IO.iodata_to_binary() end
    }
  end

  defp run_with(opts) do
    REPL.run(
      Keyword.merge(
        [
          dispatcher: REPLDispatcherStub,
          agent: __MODULE__.FakeAgent,
          session_id: "test-session",
          skip_api_key_check: true
        ],
        opts
      )
    )
  end

  test "renders an assistant token stream and exits on EOF" do
    REPLDispatcherStub.expect_stream([
      %{kind: :assistant_token, data: %{token: "hello "}},
      %{kind: :assistant_token, data: %{token: "world"}},
      %{kind: :request_completed}
    ])

    %{io: io, output: out} = test_io(["hi\n"])

    assert :ok = run_with(io: io)

    output = out.()
    assert output =~ "hello world"
    assert output =~ "session test-session"
    assert output =~ "bye."
  end

  test "renders tool calls and tool results" do
    REPLDispatcherStub.expect_stream([
      %{kind: :tool_call, data: %{name: "fs_read", args: %{path: "/tmp/x"}}},
      %{kind: :tool_result, data: %{name: "fs_read", result: %{content: "hi"}}},
      %{kind: :request_completed}
    ])

    %{io: io, output: out} = test_io(["read /tmp/x\n"])

    assert :ok = run_with(io: io)

    output = out.()
    assert output =~ "→ tool: fs_read"
    assert output =~ "← tool result (fs_read)"
    assert output =~ "content"
  end

  test "plan-first: prompts for approval and resubmits on yes" do
    spec = %JidoHpc.Slurm.JobSpec{
      name: "demo",
      time: "00:10:00",
      nodes: 1,
      ntasks: 1,
      cpus_per_task: 1,
      workdir: "/tmp",
      command: ["echo", "hi"]
    }

    REPLDispatcherStub.expect_stream([
      %{
        kind: :tool_result,
        data: %{
          name: "slurm_submit",
          result: %{
            submitted: false,
            reason: :awaiting_confirmation,
            script: "#!/bin/bash\n# rendered script\n",
            script_path: "/tmp/foo.sh",
            spec: spec
          }
        }
      },
      %{kind: :request_completed}
    ])

    REPLDispatcherStub.expect_action(
      JidoHpc.Actions.Slurm.Submit,
      {:ok, %{submitted: true, job_id: "9001"}}
    )

    %{io: io, output: out} = test_io(["go\n"], _confirm = true)

    assert :ok = run_with(io: io)

    output = out.()
    assert output =~ "[plan-first]"
    assert output =~ "rendered script"
    assert output =~ "[approved] submitted as 9001"
  end

  test "plan-first: skips submission on no" do
    spec = %JidoHpc.Slurm.JobSpec{
      name: "demo",
      time: "00:10:00",
      nodes: 1,
      ntasks: 1,
      cpus_per_task: 1,
      workdir: "/tmp",
      command: ["echo", "hi"]
    }

    REPLDispatcherStub.expect_stream([
      %{
        kind: :tool_result,
        data: %{
          name: "slurm_submit",
          result: %{
            submitted: false,
            reason: :awaiting_confirmation,
            script: "#!/bin/bash\n",
            script_path: "/tmp/foo.sh",
            spec: spec
          }
        }
      },
      %{kind: :request_completed}
    ])

    %{io: io, output: out} = test_io(["go\n"], _confirm = false)

    assert :ok = run_with(io: io)

    output = out.()
    assert output =~ "[skipped]"
    refute output =~ "[approved]"
  end

  test "exit command terminates cleanly" do
    %{io: io, output: out} = test_io(["exit\n"])
    assert :ok = run_with(io: io)
    output = out.()
    refute output =~ "[event]"
  end

  test "preflight: exits cleanly with friendly message when no API key is set" do
    saved_app = Application.get_env(:req_llm, :anthropic_api_key)
    saved_sys = System.get_env("ANTHROPIC_API_KEY")
    Application.delete_env(:req_llm, :anthropic_api_key)
    System.delete_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      if saved_app, do: Application.put_env(:req_llm, :anthropic_api_key, saved_app)
      if saved_sys, do: System.put_env("ANTHROPIC_API_KEY", saved_sys)
    end)

    %{io: io, output: out} = test_io([])

    # Bypass run_with's skip_api_key_check so the preflight actually runs.
    assert :ok =
             REPL.run(
               dispatcher: REPLDispatcherStub,
               agent: __MODULE__.FakeAgent,
               session_id: "test-session",
               io: io
             )

    output = out.()
    assert output =~ "No API key found"
    assert output =~ "ANTHROPIC_API_KEY"
    refute output =~ "jido-hpc REPL — session"
  end

  defmodule FakeAgent do
    @moduledoc false
  end
end
