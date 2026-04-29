# jido-hpc — Implementation Plan

An Elixir agent built on **Jido v2.2** + **jido_ai v2.1** that runs on an HPC login node. The agent uses an LLM (Anthropic via `req_llm`) to plan and call **Actions** that either (a) do lightweight login-node work (read/edit/grep/git), or (b) drive Slurm to do heavy work on compute nodes.

> **For Claude / contributors:** Keep the completion tracker below in sync with reality. When a task is finished, flip its checkbox. When the plan changes, edit the relevant section. This file is the single source of truth for project status.

---

## Completion Tracker

Legend: `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` skipped/deferred

### Phase 0 — Project skeleton
- [x] `mix new jido_hpc --sup` scaffold committed
- [x] `mix.exs` deps: `:jido ~> 2.2`, `:jido_ai ~> 2.1`, `:jason` (req_llm pulled in transitively by jido_ai)
- [x] App supervision tree includes the Jido instance (`JidoHpc.Jido`)
- [x] `config/{config,dev,test,prod,runtime}.exs` stubs
- [x] Smoke test scaffold: `test/integration/llm_smoke_test.exs` tagged `:smoke`, skipped by default; runs with `ANTHROPIC_API_KEY=… mix test --include smoke`
- [x] Toolchain installed: **Erlang/OTP 25.3 (apt) + Elixir 1.18.4 (precompiled, `elixir-otp-25.zip`) + Hex 2.4.1 (built from github source)**. Replication script at `bin/setup.sh`.
- [x] `mix format --check-formatted` ✓ verified.
- [x] All `.ex`/`.exs` files parse cleanly (validated with `Code.string_to_quoted!`).
- [-] `mix compile` and `mix test` blocked in this sandbox: `repo.hex.pm` denied by firewall, so `mix deps.get` cannot fetch tarballs. NOT a tooling issue — runs fine on any host with unrestricted network. (Tip: behind a TLS-intercepting proxy, set `HEX_UNSAFE_HTTPS=1`.) Phase 2 was likewise written without local compilation; once deps are installed run `mix format --check-formatted && mix compile --warnings-as-errors && mix test`.

### Phase 1 — Login-node primitives
- [x] `JidoHpc.Safety.PathGuard` (allowlist roots, reject `..` escapes)
- [x] `JidoHpc.Safety.CmdGuard` (binary allowlist, arg-list only — no shell strings)
- [x] `JidoHpc.Safety.RateLimiter` (max concurrent subprocesses; `prlimit` wrapping deferred to Phase 2 once we wire it into Slurm submissions)
- [x] `JidoHpc.Actions.Bash.Run`
- [x] `JidoHpc.Actions.FS.{Read, Write, Edit, Grep, Ls, Glob}`
- [x] `JidoHpc.Actions.Git.{Status, Diff, Log}`
- [x] `JidoHpc.Skills.ShellSkill` (`use Jido.Plugin`) bundles Bash + FS actions
- [x] `JidoHpc.Skills.GitSkill`
- [x] ExUnit tests cover happy paths AND every guardrail rejection — 84 tests, 0 failures (safety + actions + skills) running offline against a local Jido stub; will re-run against real `jido` deps once `mix deps.get` is available.
- [ ] Manual smoke: agent edits a file via tool calls (deferred — needs live LLM + working `mix deps.get`; Phase 1 code is in place for it)

### Phase 2 — Slurm integration
- [x] `JidoHpc.Slurm.CLI` wrapper around `sbatch / squeue / sacct / scancel / sinfo / scontrol` (behaviour + `Real` impl; `impl()` swappable via `Application.get_env(:jido_hpc, :slurm_cli)`)
- [x] `--json` parsing with `--parsable2 --format=…` fallback (and `scontrol` key=value fallback)
- [-] Opportunistic `slurmrestd` path when `SLURM_JWT` + `SLURMRESTD_URL` are set — deferred; CLI behaviour leaves a clean seam for a `JidoHpc.Slurm.CLI.Restd` impl in a later phase
- [x] `JidoHpc.Slurm.JobSpec` typed struct + validating `new/1`
- [x] `JidoHpc.Slurm.Script.render/1` — turns `JobSpec` into a sbatch script (single-quote bash quoting, no ambient env leakage)
- [x] `JidoHpc.Slurm.Job` state struct + state machine (`PENDING → RUNNING → COMPLETED|FAILED|TIMEOUT|OOM|CANCELLED|NODE_FAIL|PREEMPTED`, plus `:unknown`)
- [x] `JidoHpc.Actions.Slurm.Submit` — honors `:confirm_on_submit` vs `:autonomous` (plus per-call `confirm:` / `autonomy:` overrides)
- [x] `JidoHpc.Actions.Slurm.Cancel` (rejects non-numeric job ids before reaching the CLI)
- [x] `JidoHpc.Actions.Slurm.Status`
- [x] `JidoHpc.Actions.Slurm.Sacct`
- [x] `JidoHpc.Actions.Slurm.Sinfo`
- [x] `JidoHpc.Actions.Slurm.TemplateScript`
- [x] `JidoHpc.Actions.Slurm.WaitForJob` (squeue → sacct fallback when job leaves the queue)
- [x] `JidoHpc.Sensors.SlurmJobSensor` polls `Slurm.CLI.squeue/1`, dispatches `slurm.job.<state>` / `slurm.job.transition` signals, untracks terminal jobs
- [x] Tests use a stubbed `Slurm.CLI` (`JidoHpc.Test.SlurmCLIStub`, ETS-backed FIFO queue keyed by owner pid) — no real cluster needed in CI

### Phase 3 — Skills wiring
- [ ] `JidoHpc.Skills.SlurmSkill` (`use Jido.Plugin`) bundles all `Slurm.*` actions
- [ ] `SlurmSkill.child_spec/1` starts the `SlurmJobSensor` under the skill
- [ ] Signal routes: `slurm.job.completed`, `slurm.job.failed`, `slurm.job.preempted`
- [ ] `JidoHpc.Agents.CodingAgent` (`use Jido.AI.Agent`) wires in `[SlurmSkill, ShellSkill, GitSkill]`

### Phase 4 — Agent UX
- [ ] CLI entry point (`mix jido_hpc.repl` or escript) — prompt → stream → render tool calls
- [ ] "Plan first" mode: render `JobSpec` for human approval before `sbatch` (configurable)
- [ ] Autonomy levels: `:confirm_on_submit` (default) and `:autonomous` (audit-only)
- [ ] Structured audit log: `{session_id, prompt_hash, JobID, sbatch_path}` per submission
- [ ] Streaming token output in the CLI

### Phase 5 — Quality of life
- [ ] Lmod actions: `Modules.{Load, List, Spider}`
- [ ] Quota actions: `Quota.{CheckDisk, CheckInode}`
- [ ] `Sinfo` partition picker (helps LLM choose a sane partition)
- [ ] Stage-in/stage-out helpers between `$HOME` and `$SCRATCH`
- [ ] Optional Phoenix LiveView dashboard (live agent + job table)
- [ ] Job templates library: ML training, MPI, GPU inference, array sweeps

---

## Architecture

### Why Jido fits

In jido_ai, **tools are `Jido.Action` modules** — same contract as everything else. So every capability we add to the agent is automatically usable by the LLM with no extra wiring. Skills (`Jido.Plugin`) bundle related actions and can supervise their own children, which is perfect for a Slurm sensor / connection pool.

### Repo layout

```
lib/jido_hpc/
  application.ex                 # supervision tree
  jido.ex                        # use Jido, otp_app: :jido_hpc
  agents/
    coding_agent.ex              # use Jido.AI.Agent (ReAct loop)
  skills/
    slurm_skill.ex               # use Jido.Plugin — bundles Slurm actions + sensor
    shell_skill.ex               # bundles login-node bash/file actions
    git_skill.ex                 # git read-only + safe writes
  actions/
    slurm/{submit,cancel,status,sacct,sinfo,template_script,wait_for_job}.ex
    fs/{read,write,edit,grep,ls,glob}.ex
    bash/run.ex
    modules/{load,list,spider}.ex     # Lmod
    quota/{check_disk,check_inode}.ex
    git/{status,diff,log}.ex
  sensors/
    slurm_job_sensor.ex          # polls squeue/sacct, emits signals on state change
  slurm/
    cli.ex                       # System.cmd/3 wrapper, parses --json
    job.ex                       # %Job{} struct + state machine
    job_spec.ex                  # typed inputs to script renderer
    script.ex                    # sbatch script templating
  safety/
    path_guard.ex                # allowlist roots, reject ".." escapes
    cmd_guard.ex                 # allowlist binaries, no shell strings
    rate_limiter.ex              # cap concurrent subprocesses on login node
config/
  config.exs                     # static jido / jido_ai config
  runtime.exs                    # ANTHROPIC_API_KEY, cluster URLs, allowlist roots
test/                            # ExUnit; mock Slurm via stub CLI
```

### Key safety / architectural decisions (locked in)

1. **No shell strings.** All commands go through `System.cmd/3` with arg lists. `Safety.CmdGuard` rejects anything not on the allowlist. Kills shell injection.
2. **LLM never writes raw sbatch.** It fills a typed `JobSpec`; we render. Prevents `#SBATCH --uid=root` style mischief and keeps audit clean.
3. **Path allowlist from day one.** Every read/write/list goes through `PathGuard`. Agent cannot wander into `/etc` or another user's `$HOME`.
4. **Secrets never enter sbatch scripts.** API keys stay in `~/.config/jido_hpc` (chmod 600). Compute jobs source them from disk, never from `--export` / `#SBATCH --comment`.
5. **Async via Sensors, not blocking polls.** Agent submits and moves on; sensor wakes it on state changes. Critical for multi-hour jobs.
6. **Use `--json` everywhere.** `--parsable2 --format=…` only as fallback. Never scrape default human output.

### Slurm command parsing

| Command | Primary | Fallback |
|---|---|---|
| `sbatch` | parse `Submitted batch job N` | n/a |
| `squeue` | `--json` | `--parsable2 --format=JobID,State,Reason` |
| `sacct` | `--json` | `--parsable2 --format=JobID,State,ExitCode,DerivedExitCode,MaxRSS,Elapsed,ReqMem` |
| `sinfo` | `--json` | `--parsable2 --format=Partition,Avail,Nodes,State` |
| `scontrol show job` | `--json` (newer) | key=value scrape |

Slurm states the state machine recognizes: `PENDING`, `RUNNING`, `COMPLETED`, `FAILED`, `TIMEOUT`, `OUT_OF_MEMORY`, `CANCELLED`, `NODE_FAIL`, `PREEMPTED`.

### `JobSpec` (Phase 2)

```elixir
%JidoHpc.Slurm.JobSpec{
  name: String.t(),
  time: String.t(),                # "01:00:00"
  nodes: pos_integer(),
  ntasks: pos_integer(),
  cpus_per_task: pos_integer(),
  mem: String.t(),                 # "32G"
  gpus: non_neg_integer() | nil,
  partition: String.t() | nil,
  modules: [String.t()],
  env: %{String.t() => String.t()},
  workdir: String.t(),
  command: [String.t()],           # arg list, not shell string
  array: String.t() | nil,         # "0-99%10"
  dependency: String.t() | nil,    # "afterok:12345"
  output: String.t(),              # default "logs/%x-%j.out"
  error:  String.t()               # default "logs/%x-%j.err"
}
```

`Slurm.Script.render/1` produces the sbatch script. The LLM fills the struct via the `Slurm.TemplateScript` action; it never sees the rendered text until rendering.

### Agent autonomy levels

- `:confirm_on_submit` (default) — `Slurm.Submit` returns the rendered script + JobSpec for human approval before submission.
- `:autonomous` — submits immediately, every submission audit-logged.
- Read-only ops (`Status`, `Sacct`, `Sinfo`, `FS.Read`, `Grep`) never require confirmation.

---

## Open questions

These were flagged in planning. Update with answers as we learn:

1. **Target cluster(s)** — partition names, Lmod vs Spack, filesystem layout, slurmrestd availability. A sample `sinfo` and a real sbatch script would let us set sane defaults.
2. **Autonomy default** — `:confirm_on_submit` proposed; confirm or override.
3. **Edit semantics** — full Claude-Code-style read-before-edit + exact-match replacement, or simpler patch?
4. **LLM provider/model defaults** — Claude Opus 4.7 / Sonnet 4.6 / Haiku 4.5? Local vLLM on a compute node? Both?
5. **Phoenix dashboard** — scaffold now or defer to Phase 5?

---

## Versions

- `jido` **2.2.0** (Mar 2026) — Elixir 1.17+, OTP 26+
- `jido_ai` **2.1.0** (Mar 2026) — depends on `jido ~> 2.0`
- `req_llm` — provider transport
- Sibling packages used opportunistically: `jido_action`, `jido_signal`

---

## References

- Jido core: https://github.com/agentjido/jido
- Jido AI: https://github.com/agentjido/jido_ai
- Jido guides: https://github.com/agentjido/jido/tree/main/guides — especially `actions.md`, `plugins.md`, `your-first-plugin.md`, `your-first-sensor.md`, `worker-pools.md`, `scheduling.md`, `phoenix-integration.md`
- Slurm REST API: https://slurm.schedmd.com/rest.html
- Prior art worth reading before building Phase 2: Snakemake's slurm executor, Nextflow `process.executor = 'slurm'`, Meta's `submitit`, PyTorch Lightning's `SLURMEnvironment`
