defmodule JidoHpc.RegressionTest do
  @moduledoc """
  Regression tests for bugs found in the cross-module review pass
  (see `plan.md` "Phase 4.5 — review pass" entry). Each block here
  pins a specific bug we've already fixed; if it ever fails again
  the offending code path has regressed.
  """

  use ExUnit.Case, async: false

  alias JidoHpc.Slurm.{Job, JobSpec}

  # ---- Job state machine ------------------------------------------------

  describe "Job.parse_state/1 (sacct annotations)" do
    test "handles 'CANCELLED by 1234' — sacct emits a uid suffix" do
      assert Job.parse_state("CANCELLED by 1234") == :cancelled
    end

    test "handles trailing whitespace and tabs" do
      assert Job.parse_state("RUNNING\tslurm-host") == :running
    end

    test "still recognises the +-suffixed variants" do
      assert Job.parse_state("CANCELLED+") == :cancelled
    end
  end

  describe "Job.update/2 terminal regression refusal" do
    test "a terminal job stays terminal when sacct returns a stale running row" do
      now = DateTime.utc_now()

      done = %Job{
        id: "1",
        state: :completed,
        updated_at: now
      }

      {next, transitioned?} = Job.update(done, %{state: "RUNNING"})

      assert next.state == :completed
      refute transitioned?
    end

    test "a non-terminal job still transitions normally" do
      now = DateTime.utc_now()
      job = %Job{id: "1", state: :pending, updated_at: now}

      {next, transitioned?} = Job.update(job, %{state: "RUNNING"})

      assert next.state == :running
      assert transitioned?
    end
  end

  # ---- JobSpec validation ----------------------------------------------

  describe "JobSpec.new/1 identifier validation" do
    @base %{
      name: "demo",
      time: "01:00:00",
      workdir: "/tmp",
      command: ["echo", "ok"]
    }

    test "rejects partition with a shell metachar" do
      assert {:error, {:invalid, :partition, :unsafe_characters}} =
               JobSpec.new(Map.put(@base, :partition, "main; rm -rf /"))
    end

    test "rejects qos with whitespace" do
      assert {:error, {:invalid, :qos, :unsafe_characters}} =
               JobSpec.new(Map.put(@base, :qos, "high priority"))
    end

    test "rejects account containing #" do
      assert {:error, {:invalid, :account, :unsafe_characters}} =
               JobSpec.new(Map.put(@base, :account, "abc#sbatch"))
    end

    test "rejects name beginning with '-' (would inject as a flag)" do
      assert {:error, {:invalid, :name, :unsafe_characters}} =
               JobSpec.new(Map.put(@base, :name, "-uid=0"))
    end

    test "still accepts standard array spec like '0-99%10'" do
      assert {:ok, %JobSpec{array: "0-99%10"}} =
               JobSpec.new(Map.put(@base, :array, "0-99%10"))
    end

    test "still accepts dependency like 'afterok:12345'" do
      assert {:ok, %JobSpec{dependency: "afterok:12345"}} =
               JobSpec.new(Map.put(@base, :dependency, "afterok:12345"))
    end
  end

  # ---- TemplateScript ---------------------------------------------------

  describe "TemplateScript output/error path-allowlist" do
    setup do
      root = Path.join(System.tmp_dir!(), "jido_hpc_tmpl_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(root)
      prev = Application.get_env(:jido_hpc, :path_allowlist)
      Application.put_env(:jido_hpc, :path_allowlist, [root])

      on_exit(fn ->
        if prev,
          do: Application.put_env(:jido_hpc, :path_allowlist, prev),
          else: Application.delete_env(:jido_hpc, :path_allowlist)

        File.rm_rf!(root)
      end)

      %{root: root}
    end

    @base_params %{
      name: "demo",
      time: "01:00:00",
      command: ["echo", "ok"]
    }

    test "absolute output path outside allowlist is rejected", %{root: root} do
      params = Map.merge(@base_params, %{workdir: root, output: "/etc/foo.out"})

      assert {:error, _} = JidoHpc.Actions.Slurm.TemplateScript.run(params, %{})
    end

    test "absolute error path inside allowlist is allowed", %{root: root} do
      params =
        Map.merge(@base_params, %{
          workdir: root,
          error: Path.join(root, "logs/foo.err")
        })

      assert {:ok, _} = JidoHpc.Actions.Slurm.TemplateScript.run(params, %{})
    end

    test "relative output paths are passed through (Slurm resolves vs --chdir)", %{root: root} do
      params = Map.merge(@base_params, %{workdir: root, output: "logs/%x-%j.out"})

      assert {:ok, _} = JidoHpc.Actions.Slurm.TemplateScript.run(params, %{})
    end
  end

  # ---- Git rev / paths flag-injection guard ----------------------------

  describe "Git.Diff and Git.Log refuse flag-like rev/paths" do
    @tag :git_rev_guard
    test "Diff: rev starting with '-' is rejected before exec" do
      params = %{
        cwd: System.tmp_dir!(),
        rev: "--output=/etc/foo",
        staged?: false,
        paths: [],
        max_bytes: 1024
      }

      # PathGuard may reject cwd first; we don't care which guard
      # fires, only that no `git diff --output=/etc/foo` ever runs.
      assert {:error, _} = JidoHpc.Actions.Git.Diff.run(params, %{})
    end

    test "Log: paths starting with '-' are rejected before exec" do
      params = %{
        cwd: System.tmp_dir!(),
        limit: 1,
        rev: nil,
        paths: ["--upload-pack=evil"]
      }

      assert {:error, _} = JidoHpc.Actions.Git.Log.run(params, %{})
    end
  end

  # ---- AuditLog disabled-mode safety -----------------------------------

  describe "AuditLog with :disabled" do
    setup do
      prev = Application.get_env(:jido_hpc, :audit_log_path)
      Application.put_env(:jido_hpc, :audit_log_path, :disabled)
      on_exit(fn -> Application.put_env(:jido_hpc, :audit_log_path, prev) end)
      :ok
    end

    test "append/1 returns :disabled and writes nothing" do
      assert :disabled = JidoHpc.AuditLog.append(%{event: :test, foo: 1})
    end

    test "path/0 also returns :disabled (does not crash)" do
      assert :disabled = JidoHpc.AuditLog.path()
    end
  end

  # ---- REPL banner symmetry --------------------------------------------

  describe "REPL banner rendering" do
    test "open and close banners are the same width" do
      # Render a fake plan-first event into a captured buffer and
      # check the two banner lines are equal width.
      ref = make_ref()
      parent = self()

      io = %{
        read_line: fn _ -> "exit\n" end,
        write: fn data -> send(parent, {ref, IO.iodata_to_binary(data)}); :ok end,
        confirm: fn _ -> false end
      }

      JidoHpc.REPL.render_event(
        %{
          io: io,
          dispatcher: nil,
          agent: nil,
          session_id: "x",
          last_prompt_hash: nil,
          autonomy: :confirm_on_submit
        },
        %{
          kind: :tool_result,
          data: %{
            name: "slurm_submit",
            result: %{
              submitted: false,
              reason: :awaiting_confirmation,
              script: "#!/bin/bash\n",
              script_path: "/tmp/x.sh",
              spec: %JidoHpc.Slurm.JobSpec{
                name: "n",
                time: "00:01:00",
                workdir: "/tmp",
                command: ["true"]
              }
            }
          }
        }
      )

      buffer =
        Stream.repeatedly(fn ->
          receive do
            {^ref, s} -> s
          after
            10 -> :done
          end
        end)
        |> Enum.take_while(&(&1 != :done))
        |> Enum.join()

      banner_lines =
        buffer
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "─"))

      assert length(banner_lines) >= 2

      widths = Enum.map(banner_lines, &String.length/1)
      assert Enum.uniq(widths) |> length() == 1, "banner widths differ: #{inspect(widths)}"
    end
  end
end
