# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

`jido-hpc` — an Elixir agent built on **Jido** + **jido_ai** that runs on an HPC login node, drives Slurm, and performs typical coding-agent file/bash operations.

## The plan is the source of truth

**Read [`plan.md`](./plan.md) before doing anything.** It contains the architecture, the phased implementation roadmap, and a completion tracker checklist at the top.

When you finish a task or make a non-trivial change:

1. **Update the completion tracker** in `plan.md` — flip the relevant `[ ]` to `[x]` (or `[~]` for in-progress, `[-]` for skipped). Do this in the same commit as the work.
2. **Update the plan** if the work changed the design. Don't let `plan.md` drift from reality.
3. **Add new tasks** to the tracker when you discover them mid-implementation rather than silently growing scope.

If a user request is ambiguous, check `plan.md` first — the answer is often already specified there.

## Working agreements (project-specific)

- **No shell strings.** All external commands go through `System.cmd/3` with arg lists, gated by `JidoHpc.Safety.CmdGuard`. Never `bash -c <interpolated_string>`.
- **LLM never writes raw sbatch.** It fills a typed `%JidoHpc.Slurm.JobSpec{}`; we render via `JidoHpc.Slurm.Script.render/1`.
- **Every path goes through `JidoHpc.Safety.PathGuard`** before read/write/list. Reject `..` escapes; honor the allowlist roots from runtime config.
- **Secrets stay out of sbatch scripts.** API keys live in `~/.config/jido_hpc` (chmod 600), sourced on the compute node. Never `#SBATCH --comment="$KEY"`.
- **Slurm parsing prefers `--json`.** `--parsable2 --format=…` is the only acceptable fallback. Never scrape default human output.
- **Use `Jido.Sensor` for async job state** — don't block on `squeue` polls inside actions.

## Conventions

- Branch: `claude/plan-jido-hpc-framework-cqGje` (per session instructions). Develop here, commit, push.
- Style: `mix format` enforced; `mix compile --warnings-as-errors` must pass; `mix test` must pass.
- Tests: ExUnit. Slurm tests use a stubbed `JidoHpc.Slurm.CLI` with fixture JSON — no real cluster in CI.
- File editing: read-before-edit, exact-match replacement (Claude Code default).

## Versions

- Elixir 1.17+, OTP 26+
- `jido ~> 2.2`, `jido_ai ~> 2.1`, `req_llm`

## Quick links

- Architecture & roadmap: [`plan.md`](./plan.md)
- Jido docs: https://github.com/agentjido/jido
- Jido AI docs: https://github.com/agentjido/jido_ai
