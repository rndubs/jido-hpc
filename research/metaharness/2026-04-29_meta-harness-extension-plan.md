# Meta-Harness on jido-hpc — Summary, Architecture, and Implementation Plan

**Source paper:** Lee, Nair, Zhang, Lee, Khattab, Finn. *Meta-Harness: End-to-End Optimization of Model Harnesses.* arXiv:2603.28052v1, 30 Mar 2026.
**Companion artifact:** `research/metaharness/2026-03-30_lee_finn_meta-harness-end-to-end-harness-optimization.pdf` (this folder).
**Status:** design proposal. Nothing in `lib/` yet. Phase 1–4 of `plan.md` are landed; this document is the proposal for a new top-level capability that sits *alongside* the existing `JidoHpc.Agents.CodingAgent` and treats it as the optimization target.

---

## 0. Terminology

To keep the rest of this document unambiguous:

- **Baseline harness** — the current `JidoHpc.Agents.CodingAgent` + its skills + its actions, as committed to the repo. This is the *thing being optimized*.
- **Candidate harness** — a proposed variant of the baseline, materialized as a directory of Elixir source files under `archive/runs/<run>/candidates/<id>/harness/`. Compiled and evaluated as a distinct, isolated process.
- **Meta-harness** — the outer search loop: proposer agent + archive + evaluator + Pareto frontier. Lives in new modules under `lib/jido_hpc/meta_harness/` and never modifies the baseline at runtime.
- **Proposer** — `JidoHpc.MetaHarness.ProposerAgent`, a `use Jido.AI.Agent` instance whose job is to read the archive, reason, and emit a new candidate harness directory.
- **Evaluator** — a Slurm job (one per candidate, or one job-array task) that compiles a candidate, boots it, runs fixtures through it, and writes scores + traces back to the archive.

The proposer and the baseline harness share zero source files. The candidate harness is a *copy* of the baseline-harness scope (defined in §2.4), modified by the proposer.

---

## 1. What Meta-Harness is

### 1.1 The problem

A *harness* is the code that wraps an LLM and decides what it sees at every step — prompt construction, retrieval policy, memory updates, tool-use logic, completion-detection heuristics. Empirically, swapping the harness around a fixed model can produce a 6× performance gap on the same benchmark. Harness engineering — iterating on this code by inspecting failures, adjusting heuristics, and re-running — is therefore a major lever, but today it is almost entirely manual.

Existing automated text-optimization methods (OPRO, TextGrad, GEPA, OpenEvolve, AlphaEvolve, Feedback Descent, TTT-Discover) are a poor fit for this regime because they compress feedback aggressively: they condition on the latest candidate only, on scalar scores, or on short LLM-generated summaries. The paper documents that real harness evaluations can produce up to **10 million tokens of diagnostic information per run**, three orders of magnitude beyond the largest feedback budgets prior text optimizers were designed for.

### 1.2 The method

Meta-Harness is an outer-loop search over harness *code*, with three deliberate design choices:

1. **The proposer is a coding agent**, not a raw LLM. In the paper this is Claude Code with Opus 4.6; the agent can `grep`, `cat`, navigate directories, and edit files. This matters because the experience corpus quickly exceeds any context window — the proposer must retrieve adaptively, the same way a human researcher does.
2. **Full history lives on a filesystem.** Every prior candidate has its own directory containing source code, evaluation scores, and raw execution traces. The proposer reads a *median of 82 files per iteration* (Table 8), referencing 20+ prior candidates per step. There is no compression layer, no summarizer, no embedded memory module.
3. **The outer loop is intentionally minimal.** The pseudocode is six lines. There is no parent-selection rule, no fixed mutation operator, no scaffold the proposer must fill in — just *propose, validate-interface, evaluate, log*. The proposer decides *what to inspect, what to change, and how big the edit is*, ranging from a one-line tweak to a full rewrite.

#### Algorithm 1 — outer loop

```
Input:  task distribution X, base LLM M, proposer P, iterations N
Init:   population H (seed harnesses), filesystem D ← ∅
For H in H: evaluate, store (H, E_H) in D
For t = 1..N:
    P queries D
    P proposes k new harnesses {H_1, ..., H_k}
    For each H_i:
        if H_i passes interface validation:
            evaluate(H_i, M, X), store in D
Return: Pareto frontier of D
```

The base model M is *frozen*; only the harness changes. Validation is a cheap interface test that catches malformed candidates before they hit the expensive evaluator.

### 1.3 What the proposer actually does (Appendix A)

The TerminalBench-2 trajectory is the strongest evidence the loop is doing real work, not random mutation. Starting from the **Terminus-KIRA Opus-4.6 baseline at 74.7%**:

- **Iterations 1–2 regress sharply.** Both candidates bundled prompt-template edits with a structural bugfix.
- **Iteration 3 — the proposer identifies the confound.** It explicitly notes that prompt edits, *not* the structural fixes, caused the regression, and isolates the structural fix by reverting the prompt change.
- **Iterations 4–6** continue probing the same hypothesis, attribute remaining failures to specific state-machine bugs, and confirm they are still high-risk.
- **Iteration 7 — the winner.** After six regressions touching the control flow, the proposer pivots to a *purely additive* change (`evo_env_bootstrap`): inject a one-shot environment snapshot into the initial prompt. This adds information without modifying the (fragile) completion logic. It wins.
- **Iteration 8** composes the additive winner with an earlier orthogonal fix.
- **Iteration 10** explicitly cites results from a *different prior search run* in the same archive ("don't cleanup service artifacts was worth +18pp in earlier evolution").

This is not search-as-mutation. This is search as *causal reasoning over prior failures*, made possible by giving the proposer raw logs to grep. Compressed-feedback optimizers structurally cannot do step 3 — they only see scalar deltas.

### 1.4 Empirical results

| Domain | Setting | Result |
|---|---|---|
| Online text classification (USPTO/S2D/LawBench) | search vs. ACE, MCE, GEPA, OpenEvolve, TTT-Discover | **48.6% acc / 11.4K tokens** vs. ACE 40.9%/50.8K. Matches best prior optimizer in 0.1× the evals. |
| OOD text classification | 9 unseen datasets | Best avg accuracy (73.1%), tops 7/9 datasets vs. ACE/few-shot. |
| Retrieval-augmented IMO math | 200 IMO-level problems × 5 held-out models | +4.7 pp over no-retriever; matches/beats BM25 baseline; single discovered harness transfers across models. |
| TerminalBench-2 (Opus 4.6) | discovery on the official 89-task benchmark | **76.4%, ranks #2 overall** (behind only ForgeCode); +1.7 pp over the 74.7% Terminus-KIRA baseline. |
| TerminalBench-2 (Haiku 4.5) | same benchmark | **37.6%, ranks #1 among Haiku agents**; +3.9 pp over the 33.7% baseline. |

### 1.5 Practical-implementation tips (Appendix D)

The paper crystallizes its engineering lessons into a checklist, which doubles as the spec for our extension:

1. **Write a good skill.** A natural-language file describing role, directory layout, CLI commands, output format, what is forbidden, what artifacts to produce, what to optimize. The proposer reads this once per iteration. Plan on 3–5 short tuning runs *just* to debug the skill before a real run.
2. **Start with a baseline harness and a hard search set.** ~50–100 instances that the baseline gets wrong; small enough for ~50 full evaluations per run.
3. **Log everything in JSON, hierarchically, with regex-friendly file names.**
4. **Optional: a small CLI** that lists the Pareto frontier, top-k candidates, and diffs across runs — saves the proposer tokens it would otherwise burn navigating raw filesystems.
5. **Lightweight interface validation** before the expensive evaluator (compile, boot the agent, run one fake fixture).
6. **Automate evaluation outside the proposer.** A separate harness scores candidates and writes results back to D — the proposer never has to drive evaluation itself.

These map cleanly onto an OTP supervision tree, which is why this fits Jido well.

---

## 2. Review of the current jido-hpc framework

### 2.1 What's already built (Phases 0–4 in `plan.md`)

- **`JidoHpc.Agents.CodingAgent`** — `use Jido.AI.Agent` with a fixed system prompt, three skill plugins, and a hand-listed `tools:` list kept in sync via regression test. ReAct-style loop driven by `req_llm` against Anthropic Claude.
- **Skills** — `SlurmSkill`, `ShellSkill`, `GitSkill`. Each is a `Jido.Plugin` with `actions:`, `signal_routes:`, and an optional `child_spec/1` for supervised processes (e.g. `SlurmSkill` boots `SlurmJobSensor`).
- **Actions** — typed Jido actions for filesystem (`FS.Read/Write/Edit/Grep/Ls/Glob`), bash (`Bash.Run`), Slurm (`Slurm.Submit/Cancel/Status/Sacct/Sinfo/TemplateScript/WaitForJob`), and read-only git.
- **Slurm core** — `Slurm.JobSpec` typed struct, `Slurm.Script.render/1` (LLM never writes raw sbatch), `Slurm.CLI` behaviour with `Real` impl + test stub, `Slurm.Job` state machine over `PENDING → terminal`.
- **Sensors** — `SlurmJobSensor` polls `squeue`/`sacct` outside the action path and emits `slurm.job.<state>` signals for every terminal state. Exactly the pattern we need to track *parallel evaluation jobs* without blocking the proposer's reasoning loop.
- **Safety** — `PathGuard` (allowlist roots, `..` rejection), `CmdGuard` (binary allowlist, arg lists only — no shell strings), `RateLimiter`.
- **Audit** — `JidoHpc.AuditLog` writes JSON-lines with `{ts, session_id, prompt_hash, job_id, sbatch_path, autonomy, submitted, event, error}`, `chmod 0600`, cross-pid mutex via `:global`.
- **REPL/UX** — `mix jido_hpc.repl` with `:confirm_on_submit` / `:autonomous` autonomy levels, plan-first approval flow, streamed token rendering via `Jido.AI.Agent.ask_stream/3`.

### 2.2 What this means for Meta-Harness

The framework is *better suited* to Meta-Harness than the paper's reference implementation, because two of the paper's bottlenecks already have first-class primitives here:

| Paper concern | jido-hpc primitive |
|---|---|
| "Evaluation is expensive — automate it outside the proposer" | `JidoHpc.Slurm.Submit` + `SlurmJobSensor`. The proposer submits an evaluation as a Slurm job, walks away, and gets a signal when it terminates. |
| "Run candidates in parallel" | `JobSpec.array: "0-49%10"` — Slurm job arrays evaluate 50 candidates with a parallelism cap of 10, automatically. |
| "Filesystem access for the proposer" | `FS.Read/Grep/Ls/Glob` already gated by `PathGuard`. The archive root just needs to be added to the allowlist. |
| "No raw shell strings" | `CmdGuard` already enforces this. Candidate runtime commands inherit the same guarantee — and we extend the safety perimeter to candidate code via AST checks (§3.9). |
| "Audit trail of every iteration" | `JidoHpc.AuditLog` already writes JSON-lines per submit. We extend the schema, not the mechanism. |
| "The proposer is a coding agent with skills" | `Jido.AI.Agent` + `Jido.Plugin` is exactly that. We add one skill (`MetaHarnessSkill`) and a separate proposer agent (`ProposerAgent`). |

The pieces that do *not* exist yet are (a) the **archive**, (b) the **per-candidate Elixir build/run isolation**, and (c) the **AST-level safety guard** for candidate code. These are the load-bearing new components.

### 2.3 What we deliberately don't change

- The base `JidoHpc.Agents.CodingAgent` keeps working untouched. The meta-harness reads its source as the *baseline* and produces *copies* of it for evaluation — it never modifies it at runtime. Operators can keep editing `lib/jido_hpc/agents/coding_agent.ex` directly while a search runs; the running search has its own snapshot in the archive.
- Existing skills, actions, and signal routes stay as-is. The new skill adds routes; it doesn't modify existing ones.
- Autonomy levels remain meaningful: `:confirm_on_submit` should gate the *outer* `metaharness_run` action (the user reviews the search plan), but per-iteration evaluator submissions inherit the parent run's autonomy and don't re-prompt.
- Safety, Slurm core, audit, and sensors are *out of candidate scope* (§2.4). The proposer cannot edit them, and any candidate that tries to bypass them fails interface validation.

### 2.4 Candidate scope — what the proposer can and cannot edit

This is the most important boundary in the design. The candidate-harness scope is the *minimal set of files* whose mutation defines a new harness without compromising the safety perimeter or the framework substrate.

**In scope** (proposer may rewrite freely; copy lives in candidate dir):

```
lib/jido_hpc/agents/coding_agent.ex          # system prompt, model, mounted skills, tool list
lib/jido_hpc/skills/git_skill.ex             # signal routes, action exposure
lib/jido_hpc/skills/shell_skill.ex
lib/jido_hpc/skills/slurm_skill.ex
lib/jido_hpc/actions/**/*.ex                 # all action implementations:
                                             #   output formatting, truncation,
                                             #   error shapes, retry logic.
                                             #   These are huge harness levers.
priv/jido_hpc/prompts/**                     # any prompt fragments referenced by
                                             # the agent (if/when we externalize them)
```

**Out of scope** (baseline copy is shared; AST guard rejects any candidate that touches them):

```
lib/jido_hpc/safety/**                       # PathGuard, CmdGuard, RateLimiter
lib/jido_hpc/slurm/{cli,job,job_spec,script}.ex  # typed JobSpec + sbatch renderer
lib/jido_hpc/audit_log.ex                    # JSONL audit trail
lib/jido_hpc/sensors/**                      # observability primitives
lib/jido_hpc/{application,config,jido,repl}.ex   # OTP boot + UX
lib/jido_hpc/repl/**
lib/jido_hpc/meta_harness/**                 # the proposer/evaluator/archive itself
mix.exs, config/**                           # build config
```

Concretely: the candidate may change *what the LLM sees* and *how a tool result is shaped*, but it may not redefine what an sbatch script looks like, bypass the path allowlist, or skip the audit log. This is the boundary that turns "harness search" from "code-mod free-for-all" into "search constrained to behavior changes the safety perimeter already mediates."

§3.9 specifies the AST checks that enforce this.

---

## 3. Architectural sketch

### 3.1 Conceptual mapping

```
PAPER                       jido-hpc
─────                       ────────
Filesystem D            →   JidoHpc.MetaHarness.Archive (on-disk JSONL + per-candidate
                            directories under an allowlisted archive root)

Proposer P              →   JidoHpc.MetaHarness.ProposerAgent (use Jido.AI.Agent,
                            Opus 4.7 default) mounted with: ShellSkill (read-only
                            subset), GitSkill, and the new MetaHarnessSkill.

Coding-agent skills     →   MetaHarnessSkill actions: archive_grep, archive_cat,
                            archive_pareto, archive_diff, archive_top_k,
                            propose_candidate, validate_candidate, submit_eval.

Single-file Python      →   Multi-file Elixir candidate-scope subtree (see §2.4).
                            Candidate dir mirrors the baseline lib/ layout for
                            scope files only; everything else is shared.

Evaluation Evaluate(H,M,X)
                        →   JidoHpc.Slurm.Submit on a JobSpec whose `command:`
                            invokes mix jido_hpc.metaharness.eval_one against the
                            candidate's harness dir and the search-set fixtures.

Outer loop              →   JidoHpc.MetaHarness.Loop (a GenServer + a Jido.Action
                            wrapper). Drives N iterations, k candidates per
                            iteration, with backpressure on the eval queue,
                            and resumable from the archive (§3.10).

State-change signal     →   slurm.job.completed routed to MetaHarnessSkill, which
                            ingests results into the archive and wakes the loop.

Pareto frontier         →   JidoHpc.MetaHarness.Pareto module + materialized JSON
                            view in the archive, refreshed on each ingest.

Skill text (Appendix D) →   priv/metaharness/skills/coding_agent/skill.md, loaded
                            into the ProposerAgent's system_prompt at boot.
```

### 3.2 Two-tier agent topology

The paper conflates "proposer agent" and "evaluator runtime" because in their setup both are Python in the same process. In an Elixir/HPC deployment they are *very different beasts* and must not share a process:

```
    ┌────────────────────────────────────────────────────────────────────┐
    │ Login node (BEAM VM, JidoHpc.Application)                          │
    │                                                                    │
    │  ┌──────────────────────────────────────────────────────────────┐  │
    │  │ JidoHpc.MetaHarness.Loop (GenServer, owner of one run)       │  │
    │  │    ↕                                                         │  │
    │  │ JidoHpc.MetaHarness.ProposerAgent (Jido.AI.Agent, Opus 4.7)  │  │
    │  │   plugins: [MetaHarnessSkill, ShellSkill (RO), GitSkill]     │  │
    │  └──────────────────────────────────────────────────────────────┘  │
    │            │                                                       │
    │            │ propose harness dir → archive/<run>/<id>/harness/     │
    │            ▼                                                       │
    │  ┌──────────────────────────────────────────────────────────────┐  │
    │  │ JidoHpc.MetaHarness.Validator (in-process, fast path)        │  │
    │  │    1. AST scope check (§3.9)                                 │  │
    │  │    2. mix compile --warnings-as-errors                       │  │
    │  │    3. boot agent + one stub fixture                          │  │
    │  │    bounded to ~30s via prlimit; uses shared deps cache       │  │
    │  └──────────────────────────────────────────────────────────────┘  │
    │            │ ok                                                    │
    │            ▼                                                       │
    │  JidoHpc.Actions.Slurm.Submit(JobSpec{command=mix … eval_one …})   │
    │            │                                                       │
    │            ▼                                                       │
    │  JidoHpc.Sensors.SlurmJobSensor   <─── slurm.job.completed signal  │
    │                                          → MetaHarness.Ingest      │
    └────────────────────────────────────────────────────────────────────┘
                 │ sbatch
                 ▼
    ┌────────────────────────────────────────────────────────────────────┐
    │ Compute node (one Slurm job per candidate, or one job-array task)  │
    │                                                                    │
    │  mix jido_hpc.metaharness.eval_one --candidate <run>/<id>          │
    │                                    --search-set <path>             │
    │                                    --out  archive/<run>/<id>/      │
    │    spawned in a *fresh BEAM* with:                                 │
    │      - candidate harness dir overlaid on baseline source           │
    │      - shared deps cache via MIX_DEPS_PATH                         │
    │      - per-job _build dir inside the candidate dir                 │
    │    1. mix compile (incremental against shared deps)                │
    │    2. boot CodingAgent under candidate-overlaid modules            │
    │    3. iterate over search-set fixtures                             │
    │    4. for each: agent.ask(fixture) → trace + score                 │
    │    5. write archive/<run>/<id>/{traces/, scores.json, logs/}       │
    │                                                                    │
    │  This BEAM talks to the LLM directly via req_llm. The proposer     │
    │  BEAM on the login node is NOT involved in evaluation.             │
    └────────────────────────────────────────────────────────────────────┘
```

Three points worth calling out:

1. **The proposer never executes the candidate harness.** It writes the harness dir and submits an evaluator job. This separation is what lets the evaluator run on a node with the right network egress / GPU policy while the proposer runs on the cheap login node where reasoning lives.
2. **Candidates run in their own BEAM.** Not just a different OTP supervision tree — a different VM. This means a candidate that infinite-loops, leaks ports, or crashes on boot cannot wedge the proposer. Cleanup is "kill the BEAM and remove the directory."
3. **The archive is the contract.** Both the proposer (read) and the evaluator (write) speak only via the on-disk archive. They never message each other directly. This is the same observability pattern Slurm itself uses, and it survives login-node restarts.

### 3.3 Repo layout (new modules only)

```
lib/jido_hpc/meta_harness/
  application.ex                        # optional sub-supervisor for active runs
  loop.ex                               # GenServer: one per run; drives iterations;
                                        # resumable from archive (§3.10)
  proposer_agent.ex                     # use Jido.AI.Agent (Opus 4.7 default)
  archive.ex                            # filesystem layout + JSONL append + indexes
  archive/
    run.ex                              # %Run{id, root, base_model, search_set, ...}
    candidate.ex                        # %Candidate{id, parent_id, files, scores, traces}
    pareto.ex                           # frontier computation + materialization
    cli.ex                              # in-process query API (used by skill actions)
  candidate.ex                          # @behaviour for what a candidate must export
  candidate_overlay.ex                  # builds the per-candidate Mix project on disk:
                                        # baseline source + candidate scope overlay
                                        # + shared deps cache + per-candidate _build
  validator.ex                          # AST scope check + compile + boot smoke test
  ast_guard.ex                          # candidate AST scanner (§3.9)
  evaluator.ex                          # builds the JobSpec for a candidate
  search_set.ex                         # %SearchSet{fixtures, scoring_fn}
  cost_meter.ex                         # tracks per-run $ spend; refuses past ceiling
  skill_text.ex                         # loads priv/metaharness/skills/<domain>/skill.md

lib/jido_hpc/skills/
  meta_harness_skill.ex                 # use Jido.Plugin
                                        #   actions: archive_*, propose_candidate,
                                        #            validate_candidate, submit_eval,
                                        #            metaharness_run, metaharness_resume
                                        #   signal_routes: slurm.job.completed →
                                        #                    MetaHarness.Ingest
                                        #   child_spec/1 starts MetaHarness.Loop on demand

lib/jido_hpc/actions/meta_harness/
  archive_grep.ex                       # regex search across the archive (cross-run)
  archive_cat.ex                        # read a file by candidate id + path
  archive_pareto.ex                     # list current Pareto frontier
  archive_diff.ex                       # diff two candidates (handles multi-file)
  archive_top_k.ex                      # top-k by metric
  propose_candidate.ex                  # write candidate scope files (PathGuard +
                                        # AstGuard pre-flight)
  validate_candidate.ex                 # AST + compile + smoke
  submit_eval.ex                        # build JobSpec + Slurm.Submit
  ingest_result.ex                      # called by signal route, not by LLM
  metaharness_run.ex                    # entry point: kicks off a Loop GenServer
  metaharness_resume.ex                 # resumes a crashed/stopped run from archive

lib/jido_hpc/sensors/
  (no new sensors — SlurmJobSensor already does the right thing.
   We just declare a new signal route in MetaHarnessSkill.)

priv/metaharness/
  skills/
    coding_agent/skill.md               # the only skill text for v1; one per future
                                        # domain after that
  evaluators/
    # (no Python — evaluator is mix jido_hpc.metaharness.eval_one)
  baseline_snapshot/                    # immutable copy of the baseline-harness
                                        # scope files at the moment a run starts
                                        # (each run snapshots into archive)
  fixtures/
    coding_agent_v1/                    # the HPC-flavored hard search set
      tasks/0001_write_sbatch_for_X.json
      tasks/0002_debug_failed_job.json
      ...
      grader.exs                        # task-specific scoring logic

bin/
  metaharness                           # thin CLI wrapper around mix tasks

lib/mix/tasks/
  jido_hpc.metaharness.run.ex           # mix task: --task <domain> --iters N --k K
  jido_hpc.metaharness.resume.ex        # mix task: resume <run_id>
  jido_hpc.metaharness.eval_one.ex      # mix task: invoked by Slurm on compute node
  jido_hpc.metaharness.show.ex          # mix task: cat / pareto / diff / logs
  jido_hpc.metaharness.search_set.ex    # mix task: build/validate fixtures

test/jido_hpc/meta_harness/
  archive_test.exs
  ast_guard_test.exs                    # rejects candidates that import Safety.*, etc.
  validator_test.exs
  candidate_overlay_test.exs            # round-trip a candidate, compile, boot
  loop_test.exs                         # uses SlurmCLIStub, fakes a 5-iter run
  loop_resume_test.exs                  # crash-and-resume scenarios
  pareto_test.exs
  cost_meter_test.exs
  end_to_end_test.exs                   # tagged :slow, runs 2 iters with stub LLM
```

Roughly 30–35 new files. No existing files change except `application.ex` (one new child) and the test for skill-action sync.

### 3.4 Archive layout on disk

```
$JIDO_HPC_ARCHIVE_ROOT/                 # configured + PathGuard-allowlisted
  runs/
    2026-04-30T14-22-01_coding-agent/   # one directory per run
      run.json                          # {id, base_model, proposer_model,
                                        #  search_set_hash, iters, k, started_at,
                                        #  status, ended_at, cost_ceiling_usd,
                                        #  cost_spent_usd, baseline_git_sha}
      pareto.json                       # materialized frontier (refreshed on ingest)
      iterations.jsonl                  # one row per iteration: proposer turn,
                                        #   k candidates submitted, eval job ids
      baseline/                         # snapshot of baseline-harness scope at run
                                        # start; archive `parent` IDs reference this
        lib/jido_hpc/agents/coding_agent.ex
        lib/jido_hpc/skills/*.ex
        lib/jido_hpc/actions/**
      candidates/
        000_seed_baseline/              # the unmodified baseline as candidate 0
          parent.txt                    # → "baseline"
          harness/                      # candidate-scope files only (overlay)
            lib/jido_hpc/agents/coding_agent.ex
            ...
          ast_check.json                # passed scope check
          compile.json                  # mix compile result
          eval_job_id
          scores.json                   # {pass_rate: 0.27, ctx_tokens: 0, ...}
          traces/                       # one file per fixture
            fixture_0001.jsonl
            fixture_0002.jsonl
          logs/
            slurm.out
            slurm.err
            mix_compile.log
            agent_boot.log
        001_proposed_t1_c0/             # iter 1, candidate 0
          parent.txt                    # → "000_seed_baseline"
          proposer_reasoning.md         # what the proposer wrote about why
          harness/
            lib/jido_hpc/agents/coding_agent.ex   # diverged
            lib/jido_hpc/actions/fs/grep.ex       # diverged
          ...
```

Three properties this gives us:

1. **`grep -r` works.** This is the paper's primary access pattern; the proposer must be able to text-search prior reasoning and traces.
2. **The archive is human-browsable.** When a search misbehaves, the operator can `ls` and `less` their way through it without any tooling.
3. **Atomic appends.** `iterations.jsonl` and the audit log use append-only line-delimited JSON; the materialized indexes (`pareto.json`, top-k caches) are rewritten in full atomically (write-temp + rename). No partial-state corruption on crash.

The candidate's `harness/` directory contains *only the files that diverged from baseline*. Files identical to the baseline snapshot are absent — `archive_diff` and the evaluator's overlay logic compose against `baseline/`. This keeps grep results clean and storage proportional to actual edits.

### 3.5 Signal flow

```
1. metaharness_run action snapshots baseline-harness scope into archive/<run>/baseline/
   and starts a MetaHarness.Loop GenServer.
2. Loop asks ProposerAgent.ask/2 with a system prompt assembled from:
       skill_text(domain) + run.json + pareto.json + last-N iteration summaries
3. ProposerAgent calls archive_grep/archive_cat/... actions to read history,
   then calls propose_candidate (writes harness/ overlay to archive) and
   submit_eval (returns {:ok, job_id}). The Loop tracks pending job_ids.
4. propose_candidate runs AstGuard before writing; rejects out-of-scope edits.
5. submit_eval calls Validator (in-process, fast). Bad candidates short-circuit
   here and are recorded as :failed_validation in iterations.jsonl.
6. Slurm.Submit registers the job_id with SlurmJobSensor.
7. Sensor poll → squeue/sacct → terminal → emits slurm.job.completed.
8. MetaHarnessSkill's signal route fires Ingest action:
       a. read scores.json + traces/ from the candidate's directory
       b. update pareto.json
       c. update run.json cost_spent_usd
       d. cast to MetaHarness.Loop: {:result, candidate_id, scores}
9. Loop checks: pending eval queue empty for this iteration AND
   cost_spent_usd < cost_ceiling_usd?
       yes → start next iteration (back to step 2)
       no  → wait for results / refuse to start next iter / write status
10. On iteration N+1, Loop returns the Pareto frontier as the action's
    final result and writes run.json status: :complete.
```

The only piece that does not exist today is steps 4–5, 8, and 9 — `AstGuard`, `Ingest`, and the loop's iteration-gate. Everything else either already works (`SlurmJobSensor`, signal routing, `Slurm.Submit`) or is straightforward archive plumbing.

### 3.6 The validator

Per Appendix D ("lightweight validation before expensive benchmarks"), this catches malformed candidates in seconds. Three sequential checks, all in-process on the login node (no Slurm — they're cheap):

```elixir
defmodule JidoHpc.MetaHarness.Validator do
  @doc "Cheap interface check. Returns :ok or {:error, reason}."
  def validate(candidate_dir) do
    with :ok <- AstGuard.scan(candidate_dir),                    # ~10ms
         :ok <- compile_in_overlay(candidate_dir),               # 1–10s warm
         :ok <- boot_agent_smoke(candidate_dir) do               # 2–5s
      :ok
    end
  end
end
```

- **`AstGuard.scan/1`** parses every `.ex` file in the candidate's `harness/` dir, walks the AST, and rejects on: out-of-scope file paths (§2.4), forbidden module references (§3.9), shell-string usage (`System.cmd/3` with a non-list arg, `:os.cmd`, `Code.eval_string`), or any `Code.eval_*` call.
- **`compile_in_overlay/1`** uses `CandidateOverlay.materialize/1` to build the per-candidate Mix project (baseline source + overlay), then runs `mix compile --warnings-as-errors` against the shared deps cache. Failures are recorded with the compile output.
- **`boot_agent_smoke/1`** spawns a child BEAM with `mix run -e 'JidoHpc.Agents.CodingAgent.smoke_check/0'`, bounded by `prlimit --cpu=30`. The smoke check sends one stub fixture through the agent without hitting the LLM (mock req_llm). Confirms the supervision tree boots and the agent accepts a request.

Total wall time on warm caches: 5–15s. That's the budget; anything slower belongs in the Slurm-side evaluator.

### 3.7 Pareto frontier

Two metrics by default (extensible to more):

- **Search-set pass rate** (higher is better)
- **Context tokens** (additional input tokens vs. baseline — lower is better)

`MetaHarness.Pareto.compute/1` is a 30-line non-dominated-sort over `[%Candidate{scores: %{pass_rate: …, ctx_tokens: …}}]`. The result is materialized as `pareto.json` after every ingest so the proposer can read it as one file rather than scanning all candidates.

### 3.8 Skill text — the most important file

Per Appendix D, *the natural-language skill is the single biggest lever on whether the loop works*. We keep one skill text per domain in `priv/metaharness/skills/<domain>/skill.md`. Loaded into `ProposerAgent.system_prompt` at boot. Constraints (from the paper's checklist):

- Specifies the role ("you are optimizing the JidoHpc CodingAgent for HPC tasks").
- Lists the directory layout the proposer will see, including the exact candidate-scope file set (§2.4) and the out-of-scope baseline files it can read but not modify.
- Names the CLI commands available (`mix jido_hpc.metaharness.show <id>`).
- Defines the output format (a `harness/` overlay directory containing only changed files; AST guard will reject out-of-scope writes).
- States what is forbidden: writing outside the candidate `harness/` directory, importing or aliasing `JidoHpc.Safety.*`, `JidoHpc.AuditLog`, `JidoHpc.Slurm.{CLI,Script,JobSpec}`, calling `System.cmd/3` with a non-list arg, calling `:os.cmd` or `Code.eval_*`.
- Names what to optimize (search-set pass rate; context tokens as a soft secondary).
- *Does not* prescribe a diagnosis procedure. The paper is explicit that this hurts.

Plan on iterating these skill files repeatedly during early bring-up (Phase MH-3 below).

### 3.9 AST scope guard — the new safety primitive

The paper's safety story is "the harness is a Python file in a sandbox." Ours is more rigorous: the candidate is *Elixir code that compiles into the same OTP application as the safety perimeter*, so we have to enforce scope at the source level.

`JidoHpc.MetaHarness.AstGuard.scan/1` walks every `.ex` file in the candidate's `harness/` overlay and rejects on:

| Rule | Rationale |
|---|---|
| File path is in candidate scope (§2.4) | Per-file allowlist; rejects edits to safety/, slurm/, audit_log, sensors/, etc. |
| No `alias`/`import`/`require` of `JidoHpc.Safety.*`, `JidoHpc.AuditLog`, `JidoHpc.Slurm.{CLI,Script,JobSpec,Job}`, `JidoHpc.MetaHarness.*` | Candidate must use these only via the existing typed Action surface; can't reach inside |
| No call to `System.cmd/2`, `System.cmd/3` unless wrapped in `JidoHpc.Safety.CmdGuard.run/2` | Re-enforces the "no shell strings" invariant at candidate scope |
| No call to `:os.cmd/1`, `:os.cmd/2` | Same; this is the obvious bypass |
| No `Code.eval_string/*`, `Code.eval_quoted/*`, `Code.eval_file/*` | Proposer-emitted dynamic eval is unreviewable; ban entirely |
| No `:erlang.binary_to_term/1` with untrusted input | Standard OTP gotcha; surface as a candidate rejection |
| File-write paths in `File.write/2,3`, `File.open/2,3` are literal strings or come from `JidoHpc.Safety.PathGuard.assert!/1` | Forces path discipline at candidate scope |

These run in <100ms over typical candidate dirs (~20 files, ~3K LoC). Rejections are cached against the candidate dir hash so retrying the same candidate skips the scan.

The `ast_guard_test.exs` test case set is the contract; expand it whenever a new bypass is identified.

### 3.10 Resumability

The Loop GenServer is in-memory but its state is fully reconstructible from the archive:

- `iterations.jsonl` — every iteration the loop has started, with the candidate ids submitted and the job ids
- `archive/<run>/candidates/<id>/scores.json` — the scoring outcome (or absence thereof)
- `pareto.json` — current frontier
- `run.json` — top-level run config and status

`Loop.resume(run_id)` rebuilds the in-memory state by:

1. Reading `iterations.jsonl` to find the highest iteration with all candidates ingested → that's the resume point.
2. For each iteration above that, querying `Slurm.Status` for each `eval_job_id`: still pending → re-register with `SlurmJobSensor`; terminal but not ingested → fire `Ingest` synchronously.
3. Once steady-state is reached, decide: continue iterating (if `iter < total_iters` and `cost_spent < ceiling`), or terminate.

`metaharness_resume <run_id>` is exposed as both a Mix task and a Jido action. This is what makes "stop the search to update the proposer skill text and resume" cheap — it's a `:autonomous`-only action because resuming is a behavioral continuation, not a new commitment.

`loop_resume_test.exs` covers four scenarios: (a) login node restart with all evals already terminated, (b) restart with some still-pending evals, (c) restart in the middle of a proposer turn (lose the in-flight proposer call, retry it), (d) restart after AST/compile/smoke validation failure (record as :failed and proceed).

---

## 4. Phased implementation plan

Same legend as `plan.md`: `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` skipped/deferred.

### Phase MH-0 — Spec, search set, seeds

The search set is the long pole. Without a defensibly-built fixture set, MH-7 results are unreviewable. This phase exists to land it before any code.

- [ ] Pin the first target domain: **`coding_agent`** — i.e., the `JidoHpc.Agents.CodingAgent` itself, against HPC-flavored tasks. (Text classification was the paper's smallest-fixture domain, but it's the wrong target for *our* harness.)
- [ ] **Build the HPC-flavored search set.** ~50–100 fixtures where the current `CodingAgent` either fails or produces suboptimal output. Categories:
  - "Write an sbatch for X" (rendering correctness, resource selection)
  - "Debug a failed Slurm job" (log inspection, root-cause naming)
  - "Port a shell pipeline to a bounded Slurm-friendly form" (CmdGuard awareness)
  - "Compose a multi-step plan" (planning + autonomy gating)
  - Each fixture: input prompt, expected behavior, scoring rubric (not just pass/fail — partial credit for known sub-skills).
- [ ] **Decontaminate.** Hold out 20% as `test/`, never visible to the proposer. The 80% `train/` is what the search set scores against. Document the held-out split's hash in `run.json`.
- [ ] Decide base model M for evaluator runs. Default proposal: `claude-haiku-4-5` (fast, cheap). Promote to Sonnet/Opus only after the loop is debugged.
- [ ] Decide proposer model. Default proposal: `claude-opus-4-7`.
- [ ] Decide archive root. Add `JIDO_HPC_ARCHIVE_ROOT` to runtime config + extend `PathGuard` allowlist. Recommend NFS on the cluster shared filesystem (durability + grep speed).
- [ ] **Seed candidate 0 = baseline.** Snapshot the current candidate-scope files into `archive/<run>/baseline/`; reference them as candidate `000_seed_baseline` with `parent: "baseline"`. No additional seed harnesses for v1 — the paper's seeds were domain-specific (zero-shot, few-shot, ACE) and don't translate to "variant of jido-hpc CodingAgent."
- [ ] Cost ceiling default: `max_eval_cost_usd: 50` for debug runs, override at run start.

**Acceptance:** the search set exists in `priv/metaharness/fixtures/coding_agent_v1/`, has a deterministic grader, holds out a documented test split, and the baseline `CodingAgent` scores <70% on the train split (we need failure headroom for the search to find).

### Phase MH-1 — Archive

- [ ] `JidoHpc.MetaHarness.Archive` — directory creation, `Run`/`Candidate` structs, JSONL append helpers, atomic-rename for materialized indexes.
- [ ] `Archive.put_candidate/3`, `Archive.get_candidate/2`, `Archive.list_candidates/1`, `Archive.grep/2` (calls `Bash.Run` with the `grep` binary on the archive root — reuses `CmdGuard`). Cross-run grep is enabled by default.
- [ ] `Archive.append_iteration/3` — one JSONL row per outer-loop turn.
- [ ] `Archive.snapshot_baseline/2` — copies the candidate-scope files from the working tree into `<run>/baseline/` and records the git SHA.
- [ ] `Pareto.compute/1`, `Pareto.materialize/2`.
- [ ] Tests: round-trip a candidate, run grep across 5 candidates and across 2 runs, materialize Pareto across known scores, baseline snapshot reproduces working-tree contents.

### Phase MH-2 — Candidate overlay, AST guard, validator, evaluator

- [ ] `JidoHpc.MetaHarness.CandidateOverlay.materialize/1` — given a candidate dir, builds an evaluation workspace at `<candidate>/eval_workspace/` containing: symlinks to baseline source for unchanged files, copies of overlaid files, symlink to shared `deps/`, per-candidate `_build/`. Idempotent.
- [ ] `JidoHpc.MetaHarness.AstGuard` — implements §3.9. Parses every `.ex` in `harness/`, walks AST, returns `{:ok, []}` or `{:error, [violations]}`.
- [ ] `JidoHpc.MetaHarness.Validator` — composes AstGuard + `mix compile` + boot smoke (§3.6). Tested against synthetic bad candidates: out-of-scope writes, forbidden module imports, `:os.cmd` calls, `Code.eval_string`, infinite loops in init, missing `start_link/1`.
- [ ] `mix jido_hpc.metaharness.eval_one` — the Mix task invoked by Slurm on the compute node. Materializes overlay, compiles, boots the candidate agent, iterates fixtures, writes `scores.json` + `traces/` + `logs/`.
- [ ] `JidoHpc.MetaHarness.Evaluator.build_job_spec/2` — turns a candidate id into a `Slurm.JobSpec` whose `command:` is `["mix", "jido_hpc.metaharness.eval_one", "--candidate", "<run>/<id>", ...]`. Uses array submission when `k > 1`.
- [ ] Tests: validator catches all listed bypass categories; evaluator builds a JobSpec that round-trips through `Slurm.Script.render/1`; `eval_one` runs end-to-end against the SlurmCLIStub with a stubbed LLM.

### Phase MH-3 — Skill text iteration (the paper's hardest unstated step)

The full Loop doesn't exist yet at this phase. Use a one-shot rig instead:

- [ ] `mix jido_hpc.metaharness.skill_debug` — single-iteration debug task. Boots `ProposerAgent` with the current skill text, expects exactly one `propose_candidate + submit_eval` turn, runs validation + evaluation against 5 fixtures, prints the full transcript and score. No Loop, no Slurm (uses CLI stub).
- [ ] Draft `priv/metaharness/skills/coding_agent/skill.md` (~1–2 pages).
- [ ] Run the rig 3–5 times, iterating skill text between runs, per Appendix D guidance. Capture each iteration in `priv/metaharness/skills/coding_agent/CHANGELOG.md`.
- [ ] Codify the working skill text in version control.

### Phase MH-4 — Proposer agent + skill plugin

- [ ] `JidoHpc.MetaHarness.ProposerAgent` — `use Jido.AI.Agent` with model = Opus 4.7, system prompt = loaded skill text + run summary + pareto JSON.
- [ ] `JidoHpc.Skills.MetaHarnessSkill` — `use Jido.Plugin` declaring all archive_* / propose_candidate / validate_candidate / submit_eval actions; signal routes for `slurm.job.completed → Ingest` and the six other terminal Slurm states.
- [ ] All Action modules under `lib/jido_hpc/actions/meta_harness/`. Use `PathGuard` and `CmdGuard` consistently — the proposer must be confined to the archive root.
- [ ] Dedicated safety test: `propose_candidate` rejects writes outside `archive/<active_run>/candidates/<new_id>/harness/` even if the path normalizes to the archive root via symlinks.
- [ ] Regression test: `MetaHarnessSkill.actions/0 == ProposerAgent.actions/0`, mirroring the Phase 3 sync test.

### Phase MH-5 — Outer loop

- [ ] `JidoHpc.MetaHarness.Loop` — `GenServer`. State: `%{run_id, iteration, pending_jobs, completed_this_iter, total_iters, k, cost_meter}`. On each iteration: call `ProposerAgent.ask/3`, expect k `submit_eval` tool calls, register pending job ids; on `{:result, ...}` cast from Ingest, decrement pending; when zero, advance iteration.
- [ ] `Actions.MetaHarness.MetaharnessRun` — entry point Action; under `:confirm_on_submit` autonomy, returns the run plan (domain, iters, k, est. cost) for human approval; under `:autonomous`, kicks off the Loop immediately.
- [ ] `Actions.MetaHarness.IngestResult` — *not* exposed to the LLM (it's invoked by the signal route). Reads `scores.json` + traces from the candidate dir, updates `pareto.json`, updates `cost_meter`, casts the result to the Loop GenServer.
- [ ] **Cost ceiling enforcement (hard).** `MetaharnessRun` refuses to start if `estimated_cost > max_eval_cost_usd`. Loop refuses to start a new iteration if `cost_spent_usd > max_eval_cost_usd * 0.9`. Logged, surfaced in `run.json`.
- [ ] **k recommendation.** Default `k=2` for smoke; recommended `k=5` for real runs. Document in skill text + run UX.
- [ ] Backpressure: cap concurrent Slurm evaluations at `k` per iteration (matches the paper's "wait for batch to finish" semantics).
- [ ] Tests: stub `Slurm.CLI`, drive a 3-iteration run with k=2, assert the Pareto frontier converges as expected; assert cost ceiling halts the loop.

### Phase MH-5.5 — Crash recovery and resume

- [ ] `JidoHpc.MetaHarness.Loop.resume/1` — reconstructs in-memory state from archive (§3.10).
- [ ] `mix jido_hpc.metaharness.resume <run_id>` — Mix-task entry point.
- [ ] `Actions.MetaHarness.MetaharnessResume` — Jido action (autonomous-only).
- [ ] Sensor re-registration: on resume, walk `iterations.jsonl` for unrecorded `eval_job_id`s and re-register them with `SlurmJobSensor`; for terminal-but-not-ingested jobs, fire `Ingest` synchronously.
- [ ] Tests: `loop_resume_test.exs` covers (a) restart with all evals already terminated, (b) restart with pending evals, (c) restart mid-proposer-turn, (d) restart after validation failure.

### Phase MH-6 — UX (mix tasks + bin wrapper)

- [ ] `mix jido_hpc.metaharness.run --task coding_agent --iters 20 --k 5 --autonomous --cost-ceiling 150`
- [ ] `mix jido_hpc.metaharness.resume <run_id>`
- [ ] `mix jido_hpc.metaharness.show pareto <run_id>` — print the frontier table.
- [ ] `mix jido_hpc.metaharness.show candidate <run_id>/<cand_id>` — print harness overlay diff vs baseline + scores.
- [ ] `mix jido_hpc.metaharness.show diff <run_id>/<a> <run_id>/<b>` — colored diff between two candidates.
- [ ] `mix jido_hpc.metaharness.show logs <run_id>/<cand_id>` — tail the Slurm logs.
- [ ] `bin/metaharness` — thin shell wrapper; calls the same Mix tasks.

### Phase MH-7 — End-to-end + soak

- [ ] Live end-to-end test on a real cluster: 3 iterations, k=2, ~6 candidate evaluations, real Anthropic API key for both proposer and evaluator. Cost ceiling: $20.
- [ ] First-real-run: 20 iterations, k=5, 100 candidate evaluations. Cost ceiling: $200. Capture the trajectory and compare to the paper's Figure 4 (best-so-far accuracy over iterations).
- [ ] Tag the test `:metaharness_live` and document the cost envelope.
- [ ] **Promotion criteria** for a discovered candidate to ship to baseline: passes train and held-out test sets within 2 pp of train; manual code review; AST guard re-passes against latest baseline-snapshot rules.

### Phase MH-8 — Optional extensions

- [ ] **Cross-run archive transfer** — already enabled by default in `archive_grep` (§3.4); document the prompt-engineering pattern for the proposer to use it. (The paper attributes +18 pp to this in Iter-10 of TerminalBench-2.)
- [ ] **Multi-domain archive** — share lessons-learned across coding-agent / future domains by indexing skill texts and trajectory summaries.
- [ ] **Phoenix LiveView dashboard** — same one Phase 5 of `plan.md` already considers, extended with a Pareto-frontier panel and an iteration tape.
- [ ] **`slurmrestd` path** — pairs naturally with array submissions; deferred until the Phase 2 stub is replaced.
- [ ] **TerminalBench-2 domain** — wire up the paper's official benchmark for a head-to-head comparison; would be a publishable validation of our port.

---

## 5. Locked-in working agreements (for this extension)

These mirror the project-wide rules in `CLAUDE.md`, with three additions specific to Meta-Harness:

1. **The proposer never executes evaluator code in-process.** Every candidate runs in a separate BEAM as a Slurm job, even in CI (using the `Slurm.CLI` test stub with a real spawned `mix run`). This protects the proposer's BEAM from candidate harnesses with infinite loops, runaway memory, or rogue ports.
2. **Candidate code is bound by AstGuard.** A candidate that imports any out-of-scope module, calls `:os.cmd` or `Code.eval_*`, or writes outside its `harness/` overlay is rejected at validation time. The AST scope rules are version-controlled and reviewed alongside any change to the safety perimeter.
3. **The archive is append-only at the iteration grain.** A finished candidate directory is *immutable*. Re-running a candidate produces a new id. This is what gives the proposer's filesystem-grep workflow stable referents — paper's behavior depends on this.

All other working agreements from `CLAUDE.md` and `plan.md` apply unchanged: no shell strings, no raw sbatch from the LLM, every path through `PathGuard`, secrets out of sbatch, `--json` first.

---

## 6. Open questions

These are the ones not yet resolved by the plan above:

1. **Evaluator BEAM coupling.** Each candidate spawns a fresh BEAM with the candidate-overlaid module set. If two consecutive candidates share enough source that incremental compile is fast, we save 5–10s per eval. Is the per-candidate `_build/` overhead worth the isolation, or do we want a longer-lived "warm evaluator BEAM" that reloads candidate modules under namespaced names? Recommend the per-candidate BEAM for v1; revisit if eval cost dominates.
2. **Search-set difficulty calibration.** A search set where the baseline scores 100% has nothing to optimize; one where it scores 0% gives the proposer no signal. Target band: baseline 30–60% pass rate. Need a manual calibration pass during MH-0.
3. **Promotion workflow.** When a discovered candidate beats the baseline on the held-out test set, what's the merge story? PR with the candidate's overlay applied to `lib/`? Manual review checklist? Recommend a `mix jido_hpc.metaharness.promote <run_id>/<cand_id>` task that produces a draft PR with the diff and the score deltas, but never auto-merges.
4. **Proposer-agent autonomy.** `:confirm_on_submit` gates the *outer* run start (matches existing `Slurm.Submit` UX). Per-iteration evaluator submissions inherit autonomy. Resume actions are autonomous-only by definition. Confirm this matches operator expectations during MH-7.
5. **What lives in `priv/` vs. a separate package.** If we add multiple domain skill texts + baselines, `priv/` will grow. Consider a sibling `jido_metaharness` Hex package later.

---

## 7. Why this is a good investment

Three reasons, ordered by confidence:

1. **The capability gap is concrete and the target is *us*.** The paper demonstrates harness search improving Claude Code's TerminalBench-2 score from 74.7% → 76.4% on Opus-4.6, and from 33.7% → 37.6% on Haiku-4.5 — both with the harness as the *only* lever. Our `JidoHpc.Agents.CodingAgent` is structurally a TerminalBench-2-style harness (system prompt + tool-using loop + state machine over results). Pointing the same technique at it is the most credible 2026 path to making jido-hpc materially better at the work it does.
2. **Our framework is unusually well-positioned.** Most teams reproducing this paper have to build the proposer-as-coding-agent infrastructure from scratch. We already have it: `Jido.AI.Agent` is the proposer, `Slurm.Submit + SlurmJobSensor` is the parallel evaluator, `PathGuard`/`CmdGuard`/`AuditLog` are the safety perimeter. The marginal effort is the archive, the AST guard, the per-candidate overlay, the loop, and the skill text — small, scoped, and matched to existing patterns.
3. **HPC is exactly the regime where this matters.** Harness search amortizes well when evaluation is expensive. Slurm makes evaluation cheap-ish through job arrays. A 20-iteration run with k=5 candidates and a 50-fixture search set is 5,000 LLM calls per iteration — 100,000 total. That's not a laptop workload. It's an HPC workload. We are the framework that should run it.

---

## 8. References within this repo

- Paper: `research/metaharness/2026-03-30_lee_finn_meta-harness-end-to-end-harness-optimization.pdf`
- Paper artifact: https://github.com/stanford-iris-lab/meta-harness-tbench2-artifact (TerminalBench-2 only)
- Paper project page: https://yoonholee.com/meta-harness/
- Existing project plan: `plan.md`
- Existing safety perimeter: `lib/jido_hpc/safety/{path_guard,cmd_guard,rate_limiter}.ex`
- Existing Slurm core: `lib/jido_hpc/slurm/{cli,job,job_spec,script}.ex`
- Existing Sensor pattern (template for any new sensor work): `lib/jido_hpc/sensors/slurm_job_sensor.ex`
- Existing Skill pattern: `lib/jido_hpc/skills/slurm_skill.ex` (signal routes + `child_spec/1`)
- Existing AuditLog (template for archive append semantics): `lib/jido_hpc/audit_log.ex`
- The candidate-scope files (the optimization target): `lib/jido_hpc/agents/coding_agent.ex`, `lib/jido_hpc/skills/{git,shell,slurm}_skill.ex`, `lib/jido_hpc/actions/**`
