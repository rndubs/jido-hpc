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
- [ ] TODO - high priority! Add a graceful fallback if the .env variables are not set, such as the anthropic API key.

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
- [x] `JidoHpc.Skills.SlurmSkill` (`use Jido.Plugin`) bundles all `Slurm.*` actions
- [x] `SlurmSkill.child_spec/1` starts the `SlurmJobSensor` under the skill (sensor opts forwarded via `config[:sensor]`)
- [x] Signal routes: `slurm.job.completed` → `Sacct`, `slurm.job.failed` → `Sacct`, `slurm.job.preempted` → `Status` (declared in the plugin's `signal_routes:`)
- [x] `JidoHpc.Agents.CodingAgent` (`use Jido.AI.Agent`) wires in `[SlurmSkill, ShellSkill, GitSkill]` with an HPC-specific system prompt
- [-] Live agent boot + tool dispatch test deferred — requires `mix deps.get` (blocked in this sandbox, see Phase 0). Static loadable/contract tests added in `test/jido_hpc/skills/skills_test.exs` and `test/jido_hpc/agents/coding_agent_test.exs`.

### Phase 4 — Agent UX
- [x] CLI entry point: `mix jido_hpc.repl` (`lib/mix/tasks/jido_hpc.repl.ex`) thin wrapper around `JidoHpc.REPL.run/1`. Flags: `--autonomous`, `--session <id>`, `--agent <module>`.
- [x] "Plan first" mode: when `slurm_submit` returns `submitted: false, reason: :awaiting_confirmation`, the REPL prints the rendered script + path and prompts `approve and submit? [y/N]:`. Approval re-runs `Slurm.Submit` with `confirm: true`. Configurable via `--autonomous` or `JIDO_HPC_AUTONOMY`.
- [x] Autonomy levels honored end-to-end: `:confirm_on_submit` (default) gates submission; `:autonomous` submits immediately. Both paths are audit-logged.
- [x] `JidoHpc.AuditLog` writes JSON-lines (Jason hard-required) with `{ts, session_id, prompt_hash, job_id, sbatch_path, autonomy, submitted, event, error}`. Path resolved from `:jido_hpc, :audit_log_path` → `JIDO_HPC_AUDIT_LOG` → `$XDG_CONFIG_HOME/jido_hpc/audit.log` → `~/.config/jido_hpc/audit.log`. Set to `:disabled` (or env `disabled`) to opt out. File chmod 0600 (touched-then-chmod'd before any data is written, so the file is never world-readable even briefly), dir 0700, `:global` lock keyed only on `__MODULE__` (so the lock is actually a cross-pid mutex, not a per-pid no-op).
- [x] Streaming via injectable `JidoHpc.REPL.Dispatcher` (Live impl forwards to `Jido.AI.Agent.ask_stream/3` + `await/2`). `:assistant_token`, `:tool_call`, `:tool_result`, `:request_completed` are rendered explicitly; unknown event kinds are surfaced via `inspect/2` rather than dropped.
- [-] Live REPL boot test deferred — needs `mix deps.get`. Static tests cover: AuditLog write/encode/perm bits/hash determinism/concurrent appends (`test/jido_hpc/audit_log_test.exs`), REPL token rendering / tool-call rendering / plan-first approve+skip / EOF + exit (`test/jido_hpc/repl_test.exs`, via `JidoHpc.Test.REPLDispatcherStub`), audit-log integration in `Slurm.Submit` (`test/jido_hpc/actions/slurm/submit_test.exs`), banner symmetry + identifier injection guards (`test/jido_hpc/regression_test.exs`).

### Phase 4.5 — Cross-module review pass (done in-band)
- [x] Set up offline static lint (`bin/lint/lint.exs` + `bin/lint/jido_stubs.ex`) — installs apt elixir 1.14 + erlang OTP 25, parallel-compiles every project file against minimal Jido / Jido.AI / Jason stubs. Caught zero undefined-ref / arity-drift bugs across 40 lib + 27 test modules. Behavioural bugs were then surfaced by six parallel review subagents (Safety / Slurm core / Slurm actions / FS+Bash+Git actions / Sensor+Skills+Agent / Phase 4).
- [x] Fixed: `AuditLog` `:global` lock id was `{__MODULE__, self()}` — re-entrant per-pid → no cross-pid mutex; now `__MODULE__` only. `:delayed_write` dropped (audit lines must be durable on close). File touched + chmod 0600 *before* the first write (no world-readable window). `Jason` is now hard-required (the `inspect/2` fallback emitted Elixir term syntax that no JSON tool could parse).
- [x] Fixed: `Slurm.Submit` audit was inside the `with`'s happy path — failed sbatch left no audit row. Audit now fires on every outcome (confirm-skipped, autonomous success, sbatch-failed). `session_id` is read from `params` → `ctx` → newly-generated, in that order, and is returned in the result so the caller (REPL plan-first) can carry it through a second invocation.
- [x] Fixed: `JidoHpc.REPL` plan-first re-submission was dropping `session_id` and `prompt_hash`, breaking audit-log correlation. The REPL now stashes the prompt hash on its state and threads it (plus the session id from the original result) into the second `Slurm.Submit.run/2` call. Banner is symmetric (open and close are both 60-char wide), and the Mix task `--agent` flag uses `String.to_existing_atom/1` + `Code.ensure_loaded/1` instead of `Module.concat/1` (avoids atom-table DoS).
- [x] Fixed: `SlurmJobSensor` would silently swallow a terminal state when a job was tracked-from-startup and reached terminal on the very first refresh (`transitioned?` was false). Sensor now emits the terminal signal whenever `Job.terminal?(updated)` is true, regardless of `transitioned?`. Stuck-pending jobs (both `squeue` and `sacct` empty) now log a warning instead of being polled forever silently.
- [x] Fixed: `SlurmSkill` only routed completed/failed/preempted; timeout/oom/cancelled/node_fail emitted by the sensor were unhandled. All seven terminal states now have signal routes.
- [x] Fixed: `Slurm.Job.parse_state/1` mis-classified `"CANCELLED by 1234"` (a real sacct emission) as `:unknown` — split on whitespace too. `Slurm.Job.update/2` refuses terminal → non-terminal regressions.
- [x] Fixed: `Slurm.JobSpec` accepted `partition: "main; rm -rf /"`, `name: "--uid=0"`, etc. New `@ident_re` allowlist + leading-char anchor on `@name_re` block forging fake `#SBATCH` directive lines.
- [x] Fixed: `Slurm.CLI.Real` was passing `stderr_to_stdout: true` for JSON commands — Slurm warnings would corrupt the JSON document on stdout. JSON commands no longer merge stderr.
- [x] Fixed: `WaitForJob` was returning `{:ok, %{state: :running}}` from a non-terminal sacct fallback row, violating the action's "returns when terminal" contract. Non-terminal sacct rows now keep the poll loop running until terminal-or-timeout.
- [x] Fixed: `Git.Diff` / `Git.Log` accepted `rev: "--output=/etc/foo"` and `paths: ["--upload-pack=evil"]`. Both now reject `-`-prefixed values and always insert `--` before paths.
- [x] Fixed: `TemplateScript` accepted `output: "/etc/cron.d/x"` (absolute path bypassing the allowlist). Absolute output/error paths are now run through `PathGuard.validate/1`; relative paths still pass through (Slurm resolves them against `--chdir`).
- [x] Fixed: `CodingAgent` system prompt referenced action names that didn't exist (`grep`, bare `status`, …). Prompt now uses the real `name:` strings (`fs_grep`, `slurm_status`, `git_status`, …).
- [x] Regression tests added in `test/jido_hpc/regression_test.exs` covering: terminal-state regression refusal, `CANCELLED by N` parsing, identifier injection guards, absolute-output PathGuard check, git rev / path flag-injection guards, `:disabled` audit behaviour, banner width symmetry. 19 tests, 0 failures (against real elixir 1.14 + the lint stubs).

### Lint stubs — replacement task
- [ ] **Delete `bin/lint/jido_stubs.ex` and `bin/lint/lint.exs`** once `mix deps.get` works in the target environment, and rely on `mix compile --warnings-as-errors` instead. The stubs are a hand-written approximation of the `Jido` / `Jido.AI` / `Jason` surface our code touches — the `__using__` macros, callback declarations, and key function signatures are educated guesses. They produce zero warnings against our codebase but give *no* guarantee of behavioural compatibility with the real packages. See the header comment in `bin/lint/jido_stubs.ex` for the verification checklist.
- [ ] When the real deps land, run `mix format --check-formatted && mix compile --warnings-as-errors && mix test` and triage anything that surfaces.

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
