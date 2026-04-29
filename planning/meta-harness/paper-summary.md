# Meta-Harness — Paper Summary

## Citation

Lee, Y., Nair, R., Zhang, Q., Lee, K., Khattab, O., & Finn, C. (2026).
**Meta-Harness: End-to-End Optimization of Model Harnesses.**
arXiv preprint arXiv:2603.28052. Submitted March 30, 2026.

- arXiv abstract: https://arxiv.org/abs/2603.28052
- arXiv v1: https://arxiv.org/abs/2603.28052v1
- HTML: https://arxiv.org/html/2603.28052v1
- PDF: https://arxiv.org/pdf/2603.28052
- Project page: https://yoonholee.com/meta-harness/
- Reference implementation: https://github.com/stanford-iris-lab/meta-harness
- Author note (Hugo Cisneros): https://hugocisneros.com/notes/leemetaharnessendtoend2026/
- ArxivIQ summary: https://arxiviq.substack.com/p/meta-harness-end-to-end-optimization
- Softmax Data writeup: https://softmaxdata.com/blog/a-new-harness-in-town-meta-harness/
- Maxim AI writeup: https://www.getmaxim.ai/blog/meta-harness-what-if-we-let-an-agent-optimize-the-code-around-an-llm/
- HuggingFace paper page: https://huggingface.co/papers/2603.28052

The user described the paper as "ICLR 2026". The version we located is the
March 2026 arXiv preprint from Stanford IRIS (Finn lab). It may have been
submitted to or accepted at ICLR 2026, but the citation above is the
authoritative one we can verify.

## One-line takeaway

Treat the **harness** — every line of code that surrounds the model call:
prompt construction, retrieval, memory updates, tool routing, post-processing —
as the search variable, and let a coding-agent proposer evolve it end-to-end
against an evaluation suite, using a filesystem of prior candidates' source
code, scores, and traces as its working memory.

## Key definition

A **harness** is a *stateful program* `H` that wraps a fixed base model `M`.
Given a task instance `x`, `H` is responsible for:

1. **Storage**: what context, examples, prior turns, tool outputs are persisted.
2. **Retrieval**: which subset of stored content is surfaced for the next call.
3. **Prompt construction**: how the surfaced content is laid out (ordering,
   templating, label primers, contrastive examples, system prompts).
4. **Tool / action selection**: which tools the model is offered, with what
   descriptions and routing.
5. **Post-processing**: parsing, retry, self-critique, error handling.
6. **Control flow**: when to stop, when to ask for clarification, when to
   spawn a sub-call.

A rollout `τ = H(M, x)` produces a trajectory; a task-specific reward
`r(τ)` scores it. The optimization target is `argmax_H E_x[r(H(M, x))]` over
the space of executable harness programs.

## Algorithm — Meta-Harness outer loop

```
Inputs:
  M           : fixed base model (or set of models)
  D_search    : search-set task distribution (with rewards)
  D_test      : held-out test set (proposer NEVER sees scores from this)
  H_0         : seed harness (a working program, scored on D_search)
  P           : agentic proposer (a coding agent, e.g., Claude Code)
  K           : iteration budget
  workspace   : filesystem rooted at iter_0/, iter_1/, ... iter_K/

Init:
  store H_0 source, traces, scores under workspace/iter_0/

For k = 1..K:
  # Propose
  P is invoked with grep/read access to the entire workspace.
  P reads:
    - source code of every prior H_i
    - execution traces of every (H_i, x) rollout: prompts, model outputs,
      tool calls, errors, intermediate state
    - score summaries per H_i
  P proposes a new harness program H_k by writing source files
  into workspace/iter_k/. P also writes a rationale.txt explaining
  why this edit is expected to help.

  # Evaluate
  Run rollouts τ_j = H_k(M, x_j) for x_j in D_search.
  Compute search_score(H_k) = mean reward.
  Persist all rollout traces under workspace/iter_k/traces/.

  # Commit
  Append search_score and metadata to workspace/iter_k/score.json.

After K iterations:
  Pick H* = argmax_k search_score(H_k).
  Final report: evaluate H* once on D_test (only at this final step).
```

The proposer is **not** a raw next-token mutation; it is a coding agent
that browses the workspace via standard file tools (`grep`, `cat`, `ls`,
`rg`), forms a hypothesis about a failure mode by reading raw traces, and
edits source files accordingly. The paper reports the proposer reads a
median of **82 files per iteration**, split roughly 41% prior harness
source / 40% execution traces / 6% score summaries / 13% other.

## What gets edited

The proposer can edit **any file in the harness program**. Concretely
across the paper's three settings, observed edits include:

- system prompts and few-shot example layouts
- retrieval indexes (TF-IDF, embedding, hybrid) and `top-k` policy
- memory-update rules (when/what to store)
- prompt section ordering: label primer → coverage block → contrastive pairs
- tool descriptions and tool selection logic
- retry / self-critique scaffolding
- token-budget and truncation policies
- decomposition: should the harness call the model once or twice; a planner
  call followed by an executor call; etc.
- result post-processors (regex, JSON parsers, voting)
- the *score* function the harness uses internally (e.g. scoring retrieved
  candidates by both label and similarity rather than similarity alone)

The headline qualitative result on text classification is the
**Label-Primed Query** harness, which the proposer discovered: it spends
its single-call budget on (a) a label primer listing valid output labels,
(b) a coverage section with one query-relevant example per label, and
(c) query-anchored contrastive pairs (similar examples with different
labels). This achieved **48.6%** vs. ACE's **40.9%** while using **4×
fewer context tokens**.

## Comparison to GEPA, OPRO, TextGrad, AlphaEvolve

The paper situates itself against the existing **text-optimization** family
(GEPA, OPRO, TextGrad, AlphaEvolve, DSPy compilers, etc.). Their shared
limitation, per the paper, is that they **compress feedback aggressively**
before handing it to the optimizer:

| dimension | GEPA-family | Meta-Harness |
|---|---|---|
| what is mutated | prompt strings (textual prompts) | the entire harness program |
| feedback to optimizer | aggregated reward signals + short reflections | full source code + raw execution traces of every prior candidate |
| token budget per step | ~0.008M (≤26K) | up to 10M |
| optimizer | text-mutation operator | agentic coding proposer (Claude Code) |
| state | implicit in prompt history | explicit filesystem of prior candidates |
| can rewire control flow? | no | yes |
| can add/remove tools? | no | yes |
| can change retrieval logic? | no (fixed scaffold) | yes |
| can change scoring code? | no | yes |
| risk of overfitting to prompt-tweaks | high | mitigated by code-level edits + held-out test set |

GEPA's domain is "given fixed scaffolding, find better prompt text".
Meta-Harness's domain is "given a fixed base model, find better
scaffolding (which incidentally may include better prompts)". They are
not strictly comparable on the same axis; Meta-Harness subsumes GEPA's
search space.

## Empirical results

### 1. Online text classification (search-vs-ACE)

- 20 evolution iterations × 2 candidates per iteration = 40 candidate
  harnesses scored.
- Best harness ("Label-Primed Query"): **48.6%** vs ACE **40.9%** = **+7.7
  points** while using 4× fewer context tokens.

### 2. Retrieval-augmented math reasoning (IMO-level)

- Search: a single retrieval harness is evolved on a 250-problem search
  set.
- Test: 200 held-out IMO-level problems.
- Result: **+4.7 points average** improvement on five held-out base
  models (transfer across models from different providers and size
  classes — the harness was optimized using one model and generalizes).

### 3. Agentic coding (TerminalBench-2)

- On Claude Opus 4.6: Meta-Harness **76.4%** vs Terminus-KIRA **74.7%**;
  ranks #2 among all Opus 4.6 agents.
- On Claude Haiku 4.5: Meta-Harness **37.6%** vs next-best (Goose)
  **35.5%**; ranks #1 among all Haiku 4.5 agents.

### Sample efficiency

The paper reports Meta-Harness matches competitor final accuracy with
**10× fewer evaluations** and exceeds them by >10 points at the same
budget — credited to the rich, uncompressed diagnostic context the
proposer reads (raw traces) rather than aggregated rewards.

## API / reference implementation

Source: https://github.com/stanford-iris-lab/meta-harness

The reference repo provides:

- `meta_harness.py` — a CLI that runs the outer loop. Example invocation
  from the README: `python meta_harness.py --iterations 1`.
- `reference_examples/text_classification/` — the ACE-comparison setup.
- `reference_examples/terminal_bench_2/` — scaffold-evolution for
  TerminalBench 2.0. Example: `bash scripts/run_eval.sh
  agents.baseline_kira:AgentHarness full 1 1 -i extract-elf`.
- `claude_wrapper.py` files — pluggable proposer-agent integration. The
  shipped examples assume **Claude Code** as the proposer.
- A workspace layout that stores each iteration as its own directory
  (`iter_k/`) containing the proposed source, traces, and scores —
  the proposer is given filesystem access to all prior `iter_*`
  directories.

The framework is deliberately filesystem-native: the proposer is a coding
agent doing ordinary file-IO, not a special bandit/RL policy.

## Why this matters for `jido-hpc`

`jido-hpc` is itself a coding-agent harness (system prompt, action set,
skills, signal routes, sensors, autonomy levels, retry behaviour). The
plan in `plan.md` of this directory adapts the Meta-Harness algorithm to
operate on the Jido v2.2 / jido_ai v2.1 abstractions — proposing typed
patches against the agent's harness, evaluating them against a regression
suite via Slurm job arrays, and committing accepted patches to a
`harness/` git branch — with hard safety invariants (the
`Safety.{PathGuard, CmdGuard, RateLimiter}` modules and the `AuditLog`
writer are NEVER editable).
