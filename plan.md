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
- [x] `mix format --check-formatted && mix compile --warnings-as-errors && mix test` — verified on macOS with **Elixir 1.19.5 / OTP 28** and the real `jido 2.2 / jido_ai 2.1 / req_llm` deps installed. **186 tests, 0 failures** (1 excluded — `:smoke`).
- [x] Graceful API-key preflight (`JidoHpc.Config.api_key_status/0`). The REPL runs it before the read loop and exits cleanly with an actionable message that names the env var, the `Application` config key, and the `.env` path when no key is set. Read-only ops (`mix test`, `mix compile`) don't need a key. Tests cover both the missing- and present-key branches.

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
- [~] Manual smoke: agent edits a file via tool calls. Harness landed as `mix jido_hpc.smoke` (`lib/mix/tasks/jido_hpc.smoke.ex`) — boots the app, starts `CodingAgent`, asks it to read a scratch file under `$HOME/.cache/jido_hpc/`, and verifies the reply contains the file's random token. Exits 0 on success, 1 on failure (incl. missing API key). Pending one live execution with a real `ANTHROPIC_API_KEY`.

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
- [x] `JidoHpc.Agents.CodingAgent` (`use Jido.AI.Agent`) mounts `[SlurmSkill, ShellSkill, GitSkill]` via `plugins:` and hand-lists the same actions under `tools:` (the `Jido.AI.Agent` macro requires both as literal-list ASTs — it won't evaluate `tools_from_skills/1` calls or `@module_attribute` references). A regression test in `JidoHpc.SkillsTest` asserts the two stay in sync (`agent.actions/0 == union(skill.actions/0)`).
- [x] Live agent boot + tool dispatch test (no LLM): `JidoHpc.Agents.CodingAgentTest` boots the agent via `JidoHpc.Jido.start_agent/2` against the real Jido supervision tree and asserts: process is alive + registered, `Jido.AgentServer.state/1` returns `agent_module: JidoHpc.Agents.CodingAgent`, `state.children` contains a `{:plugin, SlurmSkill, SlurmJobSensor}` entry with a live pid, and `agent.actions/0` resolves all three skills' actions. The `:smoke`-tagged `LLMSmokeTest` still owns the actual round-trip-through-LLM check; it stays parked until an `ANTHROPIC_API_KEY` is available.

### Phase 4 — Agent UX
- [x] CLI entry point: `mix jido_hpc.repl` (`lib/mix/tasks/jido_hpc.repl.ex`) thin wrapper around `JidoHpc.REPL.run/1`. Flags: `--autonomous`, `--session <id>`, `--agent <module>`.
- [x] "Plan first" mode: when `slurm_submit` returns `submitted: false, reason: :awaiting_confirmation`, the REPL prints the rendered script + path and prompts `approve and submit? [y/N]:`. Approval re-runs `Slurm.Submit` with `confirm: true`. Configurable via `--autonomous` or `JIDO_HPC_AUTONOMY`.
- [x] Autonomy levels honored end-to-end: `:confirm_on_submit` (default) gates submission; `:autonomous` submits immediately. Both paths are audit-logged.
- [x] `JidoHpc.AuditLog` writes JSON-lines (Jason hard-required) with `{ts, session_id, prompt_hash, job_id, sbatch_path, autonomy, submitted, event, error}`. Path resolved from `:jido_hpc, :audit_log_path` → `JIDO_HPC_AUDIT_LOG` → `$XDG_CONFIG_HOME/jido_hpc/audit.log` → `~/.config/jido_hpc/audit.log`. Set to `:disabled` (or env `disabled`) to opt out. File chmod 0600 (touched-then-chmod'd before any data is written, so the file is never world-readable even briefly), dir 0700, `:global` lock keyed only on `__MODULE__` (so the lock is actually a cross-pid mutex, not a per-pid no-op).
- [x] Streaming via injectable `JidoHpc.REPL.Dispatcher` (Live impl forwards to `Jido.AI.Agent.ask_stream/3` + `await/2`). `:assistant_token`, `:tool_call`, `:tool_result`, `:request_completed` are rendered explicitly; unknown event kinds are surfaced via `inspect/2` rather than dropped.
- [x] Live REPL boot test (no LLM): `JidoHpc.REPLTest` "live boot under real Jido supervision" boots `CodingAgent` via `JidoHpc.Jido.start_agent/2`, runs `JidoHpc.REPL.run/1` with the stub dispatcher (`agent: <live pid>`, `skip_api_key_check: true`), asserts `exit\n` returns `:ok`, the canned token stream renders, the agent process outlives the REPL, and the `SlurmJobSensor` plugin child is still alive after the run. Static tests still cover: AuditLog write/encode/perm bits/hash determinism/concurrent appends (`test/jido_hpc/audit_log_test.exs`), REPL token rendering / tool-call rendering / plan-first approve+skip / EOF + exit (`test/jido_hpc/repl_test.exs`, via `JidoHpc.Test.REPLDispatcherStub`), audit-log integration in `Slurm.Submit` (`test/jido_hpc/actions/slurm/submit_test.exs`), banner symmetry + identifier injection guards (`test/jido_hpc/regression_test.exs`). The `:smoke`-tagged variant (real LLM round-trip) stays parked until an `ANTHROPIC_API_KEY` is available.

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
- [x] **Deleted `bin/lint/jido_stubs.ex` and `bin/lint/lint.exs`.** Real deps now compile + test green on this machine (Elixir 1.18.4 / OTP 25.3, `mix deps.get` works), so `mix compile --warnings-as-errors` is authoritative and the hand-written stubs were retired.
- [x] `mix format --check-formatted && mix compile --warnings-as-errors && mix test` runs green against the real deps (verified at commit `ef5fddd`).

### Phase 4.6 — Review follow-ups (framework alignment)

Triggered by a cross-read of our `CodingAgent` against `Jido.AI.Agent` / `Jido.AI.Plugins.Chat`. The core architecture matched the framework idiom; these are tunings.

- [x] **CodingAgent: explicit `model:`** — the macro default is `:fast`, which under-serves a coding agent. Set `model: :capable`.
- [x] **CodingAgent: `tool_timeout_ms: 60_000`** — `sacct` on a busy cluster, `sbatch` round-trips, and `WaitForJob` will all blow past the 15s default.
- [x] **CodingAgent: explicit `request_policy: :reject` + `max_iterations: 20`** — rely on defaults less; document our autonomy-vs-concurrency stance at the call site.
- [x] **CodingAgent: `effect_policy` set** — bounded emitted effects to `Jido.Agent.StateOp.SetState` + `Jido.Agent.Directive.Emit`; `strategy_effect_policy` constrains emit prefixes to `slurm.*` / `jido_hpc.*`.
- [x] **CodingAgent: `tool_context` for `autonomy`** — `tool_context: %{autonomy: :confirm_on_submit}` is the literal compile-time default; the REPL overrides per-request via `MyAgent.ask(pid, prompt, tool_context: %{autonomy: state.autonomy, session_id: …, prompt_hash: …})`. `Slurm.Submit.effective_autonomy/2` reads `params.autonomy` first, then `ctx.autonomy`, then `Application.get_env(:jido_hpc, :autonomy)`.
- [x] **Skills: implement `mount/2` and `schema/0`** — `ShellSkill.mount/2` snapshots `path_allowlist` + `cmd_allowlist` into `agent.state.shell`; `SlurmSkill.mount/2` snapshots `path_allowlist` + `sensor_name`; `GitSkill.mount/2` snapshots `path_allowlist`. Each skill exposes a Zoi `schema/0` describing its config shape. Both map and keyword config are accepted.
- [x] **Safety guards read from ctx first** — `PathGuard.validate(path, ctx)` and `CmdGuard.validate(cmd, args, ctx)` accept either keyword opts (back-compat) or an action ctx map. With a map, they look up `ctx[:state][:shell][:path_allowlist]` / `ctx[:state][:slurm][:path_allowlist]` / `ctx[:state][:git][:path_allowlist]` for paths and `ctx[:state][:shell][:cmd_allowlist]` for commands. Empty / missing → fall back to Application env. All 12 actions that touched `PathGuard`/`CmdGuard` now thread `ctx` through.
- [x] **`Slurm.Submit` registers job_id with `SlurmJobSensor`** — after a successful sbatch, calls `SlurmJobSensor.track(sensor_name, job_id)`. Sensor name is read from `ctx[:state][:slurm][:sensor_name]` (set by `SlurmSkill.mount/2`) with a default of `JidoHpc.Sensors.SlurmJobSensor`. A missing/dead sensor is treated as no-op (e.g. tests that run Submit without booting an agent).
- [x] **System prompt: list all 17 actions by category** — replaced the partial-enumeration intro with a complete category listing so the model isn't biased toward only the actions named earlier.
- [x] Regression tests added (14 new): ctx-aware `PathGuard.validate/2` (4), ctx-aware `CmdGuard.validate/3` + `allowlist/1` (3), `mount/2` for all three skills + `schema/0` smoke (6), `Slurm.Submit` registers with sensor on success (1). Full suite: **215 tests, 0 failures**.

### Phase 4.7 — Extending for specialized agents

`CodingAgent` is the generalist. Specialized agents (e.g. `TrainingJobAgent`, `AnalysisAgent`, `TriageAgent`) inherit the same framework with three composition surfaces.

#### Recipe — narrow a generalist into a specialist

```elixir
defmodule JidoHpc.Agents.TrainingJobAgent do
  use Jido.AI.Agent,
    name: "jido_hpc_training_agent",
    description: "Specialized for ML training jobs: GPU partitions, multi-node DDP, checkpointing.",
    # 1. Model: heavier reasoning for capacity planning + hyperparameter tradeoffs.
    model: :reasoning,
    # 2. Skills: same base + a domain-specific one.
    plugins: [
      JidoHpc.Skills.SlurmSkill,
      JidoHpc.Skills.ShellSkill,
      JidoHpc.Skills.GitSkill,
      JidoHpc.Skills.TrainingSkill        # Lmod, dataset stage-in, checkpoint mgmt
    ],
    # 3. Tools: union of the four skills' actions (regression test enforces).
    tools: [
      # ... (per the Phase 4.6 mount/2 plumbing, this can shrink to skill-derived)
    ],
    # 4. Effect policy: narrower than CodingAgent.
    effect_policy: %{mode: :allow_list, allow: [Jido.Agent.StateOp.SetState, Jido.Agent.Directive.Emit]},
    strategy_effect_policy: %{constraints: %{emit: %{allowed_signal_prefixes: ["slurm.", "training."]}}},
    # 5. Tool context: domain-specific defaults the LLM gets for free.
    tool_context: %{
      autonomy: :confirm_on_submit,
      default_partition: "gpu",
      default_walltime: "24:00:00",
      checkpoint_root: "/scratch/$USER/ckpt"
    },
    # 6. System prompt: domain rules the generalist doesn't have.
    system_prompt: """
    You are a training-job agent. In addition to the generalist rules:
      * Always use a GPU partition; reject CPU-only requests.
      * Cap walltime at 24h unless the user explicitly overrides.
      * Stage datasets to $SCRATCH before training; never read from $HOME at scale.
      * Emit a checkpoint plan before submission; require confirm: true to submit.
    """
end
```

#### Composition axes (when to reach for which surface)

| Goal | Surface | Example |
| --- | --- | --- |
| New domain capability (Lmod, quota, data movers) | **New `Skill` (`use Jido.Plugin`)** | `JidoHpc.Skills.TrainingSkill` bundles `Modules.Load`, `Quota.CheckDisk`, `Stage.In`, `Stage.Out` |
| New atomic operation (one tool call) | **New `Action` (`use Jido.Action`)** | `JidoHpc.Actions.Modules.Spider` |
| Domain-specific reasoning loop | **New strategy** (rare; prefer ReAct + tools) | A "submit → wait → analyze logs → resubmit on OOM" loop as a custom `Jido.AI.Reasoning.*.Strategy` |
| Domain guardrails on existing tools | **`tool_context` + system prompt** | `tool_context: %{default_partition: "gpu"}`; prompt enforces "use only the gpu partition" |
| Domain blast-radius bound | **`effect_policy` + `strategy_effect_policy`** | restrict signal prefixes to `training.*` |
| Domain memory/RAG | **`Jido.AI.Plugins.Retrieval`** | mount with a per-domain `namespace:` so memories don't leak across agents |

#### Conventions for new skills

A specialist skill is just a `Jido.Plugin` that follows the conventions already established for `SlurmSkill` / `ShellSkill` / `GitSkill`:

- One module per **capability** (not per action). `TrainingSkill` is one module bundling 4-6 training actions; don't make a `DatasetStageInSkill`.
- `name:` snake_case, `state_key:` matches the conceptual name (`:training`, not `:training_skill`).
- Implement `mount/2` to read configuration from agent config (or runtime env) into `agent.state.<state_key>`.
- Implement `schema/0` describing the mount config shape (Zoi).
- Implement `child_spec/1` only when the skill owns a long-lived process (sensor / connection pool / cache).
- Declare `signal_routes:` for asynchronous events the skill emits (terminal job states, new file arrivals, etc).
- Actions belonging to the skill follow the same `JidoHpc.Actions.<Domain>.<Verb>` naming.

#### Conventions for narrowing vs broadening

Two specialization patterns that come up:

- **Narrowing** — strip a skill out (`AnalysisAgent` drops `ShellSkill` for read-only auditing) or restrict via `allowed_tools: [...]` on `ask/3` for per-request scopes.
- **Broadening** — add a skill or hand-list extra actions. The same regression test pattern (`agent.actions/0 == union(skill.actions/0)`) keeps the literal `tools:` list honest.

Tighter `effect_policy` stacks: an agent can narrow what its parent policy already permits, but never broaden it (`Jido.AI.Agent` enforces this).

#### What NOT to do

- Don't subclass `CodingAgent`. The `Jido.AI.Agent` macro produces a finished module; treat it as a recipe target, not a base class.
- Don't redefine the framework plugins (`Jido.AI.Plugins.TaskSupervisor`, `ModelRouting`, `Policy`) — those are mounted automatically; a duplicate-instance error is the symptom.
- Don't paste the same `tools:` list into every specialist. Define it once on a `Skill`, derive the list, keep one regression test.

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
