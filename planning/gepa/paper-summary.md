# GEPA — Paper & Library Summary

Reference notes for `JidoHpc.Gepa` planning. Not a deliverable in itself; the design plan
in `plan.md` builds on this.

- **Paper:** Agrawal et al., "GEPA: Reflective Prompt Evolution Can Outperform
  Reinforcement Learning," arXiv:2507.19457 (Jul 2025; accepted ICLR 2026, Oral).
- **Library:** `gepa-ai/gepa` on GitHub, `pip install gepa`, public entry point
  `gepa.optimize(...)`. Integrated into DSPy as `dspy.GEPA`.
- **Tagline:** "Genetic-Pareto" — evolutionary prompt search that uses an LLM to *reflect*
  on execution traces in natural language and propose mutations, while maintaining a
  Pareto frontier of candidates over per-instance scores.

---

## 1. What GEPA optimizes

GEPA optimizes the **textual components** of a compound AI system. Concretely a
*candidate* is a `dict[str, str]` mapping component-name to component-text:

```python
candidate = {
    "system_prompt": "You are a helpful assistant. ...",
    "router_prompt": "Decide whether to call tool X ...",
    "summarizer_prompt": "Summarize the trajectory ...",
}
```

Components can be prompts, code snippets, configs, SVGs, or any other text artifact —
GEPA does not interpret them. The user-supplied **adapter** is responsible for
instantiating a runnable system from a candidate and executing it.

Crucially, **LM weights are frozen**. GEPA does no gradient step. The only "learning
signal" is the per-example score returned by the adapter plus the trajectories the
adapter exposes to the reflection LM.

## 2. Why it matters (vs RL)

GRPO and other PPO-style RL methods on a 7B-class policy require thousands to tens of
thousands of rollouts to converge on a task. The paper reports **35x fewer rollouts**
than GRPO on average and up to **78x** on individual tasks, while beating GRPO by
~10% mean and beating the prior SOTA prompt optimizer MIPROv2 by ~14%.

The intuition: each rollout in RL contributes a scalar gradient through a giant policy
network. In GEPA each rollout is converted, *via natural-language reflection*, into a
high-leverage, human-readable patch to the prompt — extracting orders of magnitude more
information per rollout.

## 3. Core algorithm (Algorithm 1)

State maintained across iterations:

- **Candidate pool** `P = [c_0, c_1, ...]` — every candidate ever accepted.
- **Score matrix** `S[i, j] = score(candidate_i, train_instance_j)` for every accepted
  candidate (often subsampled — see "frontier_type" below).
- **Pareto frontier** `F ⊆ P` — every candidate that achieves the max score on at least
  one training instance is on the frontier, regardless of its mean.
- **Budget** `metric_calls` — total number of (candidate, instance) evaluations.

Each iteration:

1. **Select parent** from `F`. Default strategy `"pareto"`: a candidate's selection
   probability is proportional to the number of training instances on which it is the
   current per-instance leader (frequency-weighted sampling). Alternatives:
   `"current_best"`, `"epsilon_greedy"`, `"top_k_pareto"`.
2. **Pick a component** to mutate. Default `module_selector="round_robin"` — cycle
   through component names so all of them eventually get refined.
3. **Sample a minibatch** from the trainset (default `batch_sampler="epoch_shuffled"`).
4. **Capture traces.** Call `adapter.evaluate(batch, parent, capture_traces=True)`. This
   returns an `EvaluationBatch` with `outputs`, `scores`, and `trajectories` per example.
5. **Build reflective dataset.** Call
   `adapter.make_reflective_dataset(parent, eval_batch, components_to_update)`. Returns
   `dict[component_name, list[{"Inputs", "Generated Outputs", "Feedback"}]]`.
6. **Reflect & propose.** Either the default proposer or `adapter.propose_new_texts`
   feeds the reflective dataset to a **reflection LM** (e.g. GPT-5) using a meta-prompt
   that asks the LM to diagnose failures and write a new instruction. Returns updated
   `dict[component_name, str]`. The new candidate is the parent with those components
   replaced.
7. **Local acceptance check.** Re-run `evaluate` of the *child* on the same minibatch.
   Acceptance criterion (default `"strict_improvement"`): child's summed minibatch
   score must strictly beat parent's. If not, discard.
8. **Validate (Pareto promotion).** If accepted on the minibatch, evaluate on the
   validation set (or on the same Pareto-tracking instance pool, depending on
   `val_evaluation_policy`). Update `S` for the new candidate. Recompute `F`.
9. **Optional merge.** Periodically (`use_merge=True`, capped by
   `max_merge_invocations`), pick two frontier members that excel on disjoint instance
   sets and **merge** them: produce a new candidate by componentwise picking, for each
   component, the version from whichever parent has the better aggregate score. This
   is the genetic crossover step.
10. **Loop** until `max_metric_calls` exhausted or stop callback fires.

After the loop, **final selection** picks the candidate with the best aggregate score
on the validation set (or the best per a custom selector). Returns `GEPAResult`.

## 4. The reflection LM call

The reflection LM is what differentiates GEPA from prior prompt optimizers. It is given:

- The **current text** of the component being mutated.
- The **reflective dataset**: a small set of records, each typically `{"Inputs": ...,
  "Generated Outputs": ..., "Feedback": ...}`. The "Feedback" field is the key
  channel — it's where the adapter encodes whatever diagnostic info the system can
  produce: error messages, traceback, evaluator critique, profiler output, executor
  stderr, judge LLM rationale, etc.
- A **meta-prompt template** asking the LM to identify the failure pattern and write a
  better instruction.

The default meta-prompt is in `gepa/strategies/instruction_proposal.py`. Users can fully
override it via `reflection_prompt_template` or supply a `custom_candidate_proposer`.

Cost is governed by `max_reflection_cost` (dollars/tokens estimate) and
`reflection_lm_kwargs` (sampling params).

## 5. Pareto frontier mechanics

The frontier exists per-instance, not per-aggregate. Concretely: if the trainset has
N instances, then for each instance `i` we track the best-scoring candidate. The union
of those argmax candidates is the frontier `F`. A candidate can sit on the frontier
even if its mean score is mediocre, as long as it's the unique champion of some
instance. This is what gives GEPA its diversity property — it actively preserves
specialists, then later merges them into generalists.

The frontier size is bounded by `min(|P|, N)`. `frontier_type="instance"` is the
default; `"objective"` switches to multi-objective (per `objective_scores`) tracking.

`top_k_pareto` retains the top-K highest-aggregate frontier members rather than all
champions; `epsilon_greedy` mixes pareto sampling with current-best exploitation.

## 6. The adapter contract

Verbatim from `src/gepa/core/adapter.py` (TypeVar names preserved):

```python
RolloutOutput = TypeVar("RolloutOutput")
Trajectory    = TypeVar("Trajectory")
DataInst      = TypeVar("DataInst")
Candidate     = dict[str, str]

@dataclass
class EvaluationBatch(Generic[Trajectory, RolloutOutput]):
    outputs: list[RolloutOutput]
    scores: list[float]
    trajectories: list[Trajectory] | None = None
    objective_scores: list[dict[str, float]] | None = None
    num_metric_calls: int | None = None

class GEPAAdapter(Protocol[DataInst, Trajectory, RolloutOutput]):
    def evaluate(
        self,
        batch: list[DataInst],
        candidate: dict[str, str],
        capture_traces: bool = False,
    ) -> EvaluationBatch[Trajectory, RolloutOutput]: ...

    def make_reflective_dataset(
        self,
        candidate: dict[str, str],
        eval_batch: EvaluationBatch[Trajectory, RolloutOutput],
        components_to_update: list[str],
    ) -> Mapping[str, Sequence[Mapping[str, Any]]]: ...

    propose_new_texts: ProposalFn | None = None  # optional override
```

Where:

```python
ProposalFn = Callable[
    [
        dict[str, str],                                          # candidate
        Mapping[str, Sequence[Mapping[str, Any]]],               # reflective dataset
        list[str],                                               # components_to_update
    ],
    dict[str, str],                                              # new component texts
]
```

Higher score = better (GEPA assumes maximization). Scores are floats; they're summed
on the minibatch and averaged on validation.

## 7. Public entry point — `gepa.optimize`

Full signature, copied from `src/gepa/api.py`:

```python
def optimize(
    seed_candidate: dict[str, str],
    trainset: list[DataInst] | DataLoader[DataId, DataInst],
    valset: list[DataInst] | DataLoader[DataId, DataInst] | None = None,
    adapter: GEPAAdapter[DataInst, Trajectory, RolloutOutput] | None = None,
    task_lm: str | ChatCompletionCallable | None = None,
    evaluator: Evaluator | None = None,
    reflection_lm: LanguageModel | str | None = None,
    reflection_lm_kwargs: dict[str, Any] | None = None,
    candidate_selection_strategy:
        CandidateSelector
        | Literal["pareto", "current_best", "epsilon_greedy", "top_k_pareto"]
        = "pareto",
    frontier_type: FrontierType = "instance",
    skip_perfect_score: bool = True,
    batch_sampler: BatchSampler | Literal["epoch_shuffled"] = "epoch_shuffled",
    reflection_minibatch_size: int | None = None,
    perfect_score: float = 1.0,
    reflection_prompt_template: str | dict[str, str] | None = None,
    custom_candidate_proposer: ProposalFn | None = None,
    module_selector: ReflectionComponentSelector | str = "round_robin",
    use_merge: bool = False,
    max_merge_invocations: int = 5,
    merge_val_overlap_floor: int = 5,
    max_metric_calls: int | None = None,
    max_reflection_cost: float | None = None,
    stop_callbacks: StopperProtocol | Sequence[StopperProtocol] | None = None,
    logger: LoggerProtocol | None = None,
    run_dir: str | None = None,
    callbacks: list[GEPACallback] | None = None,
    use_wandb: bool = False,
    wandb_api_key: str | None = None,
    wandb_init_kwargs: dict[str, Any] | None = None,
    wandb_attach_existing: bool = False,
    use_mlflow: bool = False,
    mlflow_tracking_uri: str | None = None,
    mlflow_experiment_name: str | None = None,
    mlflow_attach_existing: bool = False,
    tracking_key_prefix: str = "",
    track_best_outputs: bool = True,
    display_progress_bar: bool = False,
    use_cloudpickle: bool = False,
    cache_evaluation: bool = False,
    seed: int = 0,
    raise_on_exception: bool = True,
    val_evaluation_policy:
        EvaluationPolicy[DataId, DataInst] | Literal["full_eval"] | None = None,
    acceptance_criterion:
        AcceptanceCriterion
        | Literal["strict_improvement", "improvement_or_equal"]
        = "strict_improvement",
) -> GEPAResult[RolloutOutput, DataId]
```

Minimal call shape:

```python
result = gepa.optimize(
    seed_candidate={"system_prompt": "You are a helpful assistant. ..."},
    trainset=trainset,
    valset=valset,
    task_lm="openai/gpt-4.1-mini",
    reflection_lm="openai/gpt-5",
    max_metric_calls=150,
)
# result.best_candidate -> dict[str, str]
# result.best_outputs   -> per-instance outputs from best
# result.history        -> trajectory of accepted candidates and scores
```

## 8. Bundled adapters

The library ships with several adapters that demonstrate the pattern:

- `DefaultAdapter` — single-turn single-component prompt optimization with
  string-equality or callable metric. Used by the bare-bones `optimize(...)` call.
- `ConfidenceAdapter` — classification with logprob-aware scoring.
- `DSPyFullProgramAdapter` — wraps an arbitrary DSPy program; mutates module signatures.
- `GenericRAGAdapter` — RAG pipeline (retriever prompt + generator prompt as components).
- `MCPAdapter` — Model-Context-Protocol agent loops.
- `TerminalBenchAdapter` — agentic terminal benchmarks (closest analog to our
  coding-agent self-optimization use case).
- `AnyMathsAdapter` — math problem solving with a graded final-answer extractor.

The pattern in each: (a) instantiate the system from `candidate`, (b) run on each
batch item, recording structured trace info, (c) score with a task-specific metric,
(d) translate trace + score into `{"Inputs", "Generated Outputs", "Feedback"}` rows.

## 9. Empirical numbers worth quoting

- HotpotQA: matches GRPO best in 402 rollouts vs ~6,438 for GRPO; +19% over GRPO.
- IFBench: 678 rollouts (35x fewer than GRPO), +2.7% over GRPO.
- HoVer: 6,858 rollouts, +13.7% over GRPO.
- PUPA (privacy-preserving delegation): 2,157 rollouts (11x fewer), +5.2% over GRPO.
- AIME-2025: +12% over MIPROv2.
- Aggregate vs MIPROv2: +14% (MIPROv2 itself was +7% over zero-shot, so GEPA more than
  doubles MIPROv2's gain).

Sample-efficiency claims: 78x at peak, ~35x average vs GRPO.

## 10. Mental model for the Elixir port

For `JidoHpc.Gepa`, the salient mapping is:

| Python concept                      | Elixir analog                                       |
| ----------------------------------- | --------------------------------------------------- |
| `dict[str, str]` candidate          | `%Candidate{components: %{atom => String.t()}}`     |
| `GEPAAdapter` Protocol              | `JidoHpc.Gepa.Adapter` behaviour                    |
| `EvaluationBatch`                   | `%JidoHpc.Gepa.EvalBatch{}` struct                  |
| `evaluate(batch, candidate, ...)`   | one Slurm **job array** per candidate (one task per |
|                                     | minibatch element); results aggregated via signals  |
| `make_reflective_dataset`           | runs on the login node from collected job logs      |
| reflection LM call                  | `Jido.AI` / `req_llm` request                       |
| Pareto frontier `F`                 | `%JidoHpc.Gepa.Frontier{}` GenServer state          |
| `max_metric_calls` budget           | `%JidoHpc.Gepa.Budget{}` accumulator                |
| `gepa.optimize(...)` blocking call  | `JidoHpc.Gepa.optimize/1` returning `{:ok, result}` |
|                                     | implemented as a Jido agent / supervised loop       |

The non-obvious win: every minibatch evaluation is embarrassingly parallel and
already maps onto Slurm job arrays we know how to dispatch. The Elixir port can
plausibly be *more* throughput-efficient than the reference Python because the
async sensor architecture means we never block on `squeue`.

---

## Sources

- [GEPA: Reflective Prompt Evolution Can Outperform Reinforcement Learning (arXiv:2507.19457)](https://arxiv.org/abs/2507.19457)
- [arXiv HTML rendering](https://arxiv.org/html/2507.19457v1)
- [gepa-ai/gepa GitHub](https://github.com/gepa-ai/gepa)
- [src/gepa/api.py — `optimize()` source](https://github.com/gepa-ai/gepa/blob/main/src/gepa/api.py)
- [src/gepa/core/adapter.py — `GEPAAdapter` protocol](https://github.com/gepa-ai/gepa/blob/main/src/gepa/core/adapter.py)
- [GEPA docs site](https://gepa-ai.github.io/gepa/)
- [optimize_anything universal API blog post](https://gepa-ai.github.io/gepa/blog/2026/02/18/introducing-optimize-anything/)
- [DSPy GEPA optimizer docs](https://dspy.ai/api/optimizers/GEPA/overview/)
- [DeepWiki gepa-ai/gepa Quick Start](https://deepwiki.com/gepa-ai/gepa/2-quick-start)
- [Demystifying GEPA — Medium](https://medium.com/@parklize/demystifying-gepa-genetic-pareto-prompt-optimizer-53db5081cdb2)
- [Comet blog — GEPA explainer](https://www.comet.com/site/blog/gepa-ai-optimization/)
