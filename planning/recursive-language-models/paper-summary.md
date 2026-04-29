# Recursive Language Models — Paper Summary

Reference for the `jido-hpc` implementation plan in `./plan.md`. Not exhaustive;
captures the parts of the paper that load-bear on the design.

## Citation

- Title: **Recursive Language Models**
- Authors: Alex L. Zhang, Tim Kraska, Omar Khattab (MIT CSAIL)
- arXiv: `2512.24601`  (preprint date Jan 2026; concept first published as a
  blog post mid-2025)
- Paper:  https://arxiv.org/abs/2512.24601
- HTML:   https://arxiv.org/html/2512.24601v1
- Blog:   https://alexzhang13.github.io/blog/2025/rlm/
- Code:   https://github.com/alexzhang13/rlm
- Coverage: VentureBeat, MarkTechPost, Towards Data Science, Prime Intellect blog
  (the last describes Prime's `RLMEnv` sandbox integration).

## Thesis in one sentence

A standard LLM call `llm.completion(prompt, model)` is replaced by an
`rlm.completion(prompt, model)` in which the **prompt is offloaded as a
variable inside a Python REPL**, and a **root LM** drives that REPL with the
ability to recursively call **sub-LMs** on slices of the variable. The result
is a task-agnostic inference paradigm that handles inputs orders of magnitude
larger than the underlying model's context window without "context rot".

Quote (blog): *"RLMs offload the context as a variable in a REPL environment
that the LM can interact with and launch sub-LM calls inside of."*

## The recursion primitive

There is no special "recurse(prompt, chunk, depth)" tool exposed by name.
Instead, the LM is given a Python REPL (Jupyter-style cells) where:

1. The user's full prompt/context is bound to a Python variable (typically
   `ctx` or similarly named — the paper's reference implementation calls this
   the "context variable"). It is **not** placed in the LM's chat context;
   only its existence and a brief description (length, type) are.
2. The LM emits Python code in cells; each cell is exec'd in the REPL and the
   stdout/return value is fed back to the LM as the cell output.
3. Inside that REPL, the LM has a function — semantically
   `llm(prompt: str, ...) -> str` — that performs a **sub-LM call**. The
   sub-LM runs in its own freshly-instantiated REPL with its own scoped
   context variable (typically a slice/derivative of the parent's `ctx`).
4. The sub-LM's REPL is identical in shape; it can recurse further, up to
   a configured depth limit.

Effectively, recursion is *implicit*: it happens whenever the LM writes code
like `chunks = ctx.split(...)` followed by
`answers = [llm(prompt=q, ctx=c) for c in chunks]`. The recursion primitive is
**a Python-callable LM bound into the REPL namespace**, not a JSON tool.

## Depth and breadth control

- **Depth.** The root LM is `depth=0`. Each `llm(...)` call inside the REPL
  spawns a child at `depth+1`. The library lets you bound max depth (the
  GitHub README mentions "Depth > 1 support" in release notes). The reference
  paper's experiments use small depths (1–2) — most useful work is done by a
  depth-1 child handed a chunk.
- **Breadth.** Determined by the LM itself — it decides, in code, how to split
  `ctx` and how many sub-calls to issue. Typical patterns: map over chunks
  produced by `ctx[i:i+N]`, by document boundaries, by a `re.findall`, or by a
  recursive halving.
- **Budget.** Cost is bounded by max depth × max breadth × per-call token
  cap. The library exposes `verbose=True` and an `RLMLogger` that records
  the full trajectory (every cell, every sub-call) for offline analysis.

## Cost model

- Each cell execution is a single LM completion at the parent level.
- Each `llm(...)` cell-call inside the REPL is one extra completion *at the
  child level*, plus its REPL trajectory — i.e. itself a recursive cost.
- The dominant cost is **sub-LM calls × child token usage**, *not* the parent
  LM's tokens, because the parent never sees the full context — it only sees
  the slice descriptions and the children's small returned strings.
- Empirically the paper claims RLMs are **comparable in cost** to vanilla
  long-context calls while drastically improving quality, because each child
  sees a small, focused window.

## Tasks where RLM shines

The paper evaluates four long-context tasks; results are headlined as:

- **BrowseComp-Plus** (multi-doc browse-and-answer; inputs 6M–11M tokens):
  base LMs score **0%** at that scale; **RLM-GPT-5 reaches 91.33%** on a
  20-question subsample with 10/50/100/1000 docs in context. (Blog reports
  preliminary numbers; arXiv version expands this to the full benchmark.)
- **OOLONG** (long-context reasoning over structured documents).
- **Loong** (long-context QA).
- **NIAH-style** retrieval at extreme depths.

Headline summary claim (HuggingFace abstract): *"RLMs can successfully process
inputs up to two orders of magnitude beyond model context windows and, even
for shorter prompts, dramatically outperform the quality of vanilla frontier
LLMs and common long-context scaffolds across four diverse long-context tasks
while having comparable cost."*

Specific cross-model claim: **RLM-Qwen3-8B outperforms vanilla Qwen3-8B by
+28.3 points on average** and approaches **GPT-5** quality on three tasks.

## API contract (reference implementation)

From `alexzhang13/rlm`:

```python
from rlm import RLM
client = RLM(
    backend="openai",                              # or anthropic, openrouter, ...
    backend_kwargs={"model_name": "gpt-5-nano"},
    environment="local",                           # or ipython, docker, modal,
                                                   #    prime, daytona, e2b
    environment_kwargs={...},
    verbose=True,
    logger=RLMLogger(log_dir="./logs"),
)

result = client.completion(prompt=user_prompt, context=huge_context_blob)
# result.response   -> final answer string
# result.metadata   -> full trajectory: every cell, every sub-LM call
```

Inside the REPL the model has roughly:

- `ctx` — the bound context variable (str, list, or other).
- `llm(prompt: str, ctx=None, **kwargs) -> str` — sub-LM call. `ctx=None`
  means "no extra context"; otherwise a slice/derivative of the parent ctx.
- Standard Python (string ops, regex, list comprehensions, file I/O if the
  sandbox allows).

Sandbox tiers (controls how Python code is exec'd):

- *Non-isolated*: `local` (in-process `exec`), `ipython`, `docker`.
- *Isolated/cloud*: `modal`, `prime`, `daytona`, `e2b` — the sub-LM call is
  routed back to the host process from inside the sandbox.

## Why this matters for `jido-hpc`

Two relevant properties:

1. **Hierarchical decomposition without context rot.** A coding agent on a
   large repo can split work across files / directories and recurse, avoiding
   the failure mode where a flat 200k-token prompt degrades reasoning quality.
2. **Embarrassingly parallel sub-calls.** Map-style breadth (`ctx.split` →
   N children) is exactly the workload Slurm job arrays are good at. Each
   recursive sub-call is independent; an HPC backend can dispatch them as
   array tasks on compute nodes instead of serializing them on the login
   node.

The plan in `./plan.md` adapts the RLM paradigm to Elixir/Jido and adds an
HPC-native dispatch path (Phase 2) where deep / expensive sub-recursions
become Slurm jobs running headless agent processes.
