# Model trial: can a stronger tool-calling model lift the agent's accuracy ceiling?

A single-candidate trial against the incumbent local model, measured on
[`local-llm-claw-benchmark`](https://github.com/mconcas/local-llm-claw-benchmark)
question bank **v1** (42 questions, sha256 `71bd5a7e1a89…`).

- **Incumbent:** `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` (unsloth).
- **Candidate:** `Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf` (unsloth).
- **Result: 40.5 % vs the incumbent's 83.3 - 97.6 % band. Decisive negative.**
- **Decision: rejected. The incumbent is restored and deployed.** No default was changed;
  this report is the only artefact that ships.

The trial's hypothesis was *confirmed on its own terms* and the swap still lost badly:
the candidate eliminated the tool-call-template failures completely (**0 vs 9**), and
regressed **-49.2 points** overall by ignoring the deployed skill's routing.

## Verdict

| | Incumbent (3 runs) | Candidate (1 run) |
|---|---|---|
| Overall | **89.7 %** (113/126), band 83.3 - 97.6 % | **40.5 %** (17/42) |
| Tool-call-template failures | 9 / 126 (7.1 %) | **0 / 42 (0 %)** |
| Substantive misses | 4 / 126 (3.2 %) | **25 / 42 (59.5 %)** |
| Mean tool calls / question (gateway-reported `agent.tool_calls`) | 2.40 | 6.69 |
| Wall-clock per 42-question run | 307.9 s | 1019.3 s |

The gap is ~50 points against a measured run-to-run spread of ±7 points. No plausible
amount of variance closes it.

## Results

Incumbent reference = `results/v1-shipped-{1,2,3}` from the benchmark repo: the same
shipped skill, the same stack, measured in the same session as this trial's reference
point. (`local-claw`'s `TUNING-REPORT.md` quotes 90.5 % for an earlier 3-run set of the
same artefact; both sets are cited so the incumbent's band is not cherry-picked.)

### Overall and per-category

| Model | Runs | Overall | cluster-health-ops | index-metadata | log-analytics | metric-telemetry | multi-step |
|---|---|---|---|---|---|---|---|
| Incumbent Qwen3-Coder-30B | 37/42, 35/42, 41/42 | **89.7 %** (113/126) | 95.8 % (23/24) | 90.5 % (19/21) | 85.4 % (41/48) | 85.7 % (18/21) | 100 % (12/12) |
| Candidate Qwen3-30B-Instruct-2507 | 17/42 | **40.5 %** (17/42) | 75.0 % (6/8) | 71.4 % (5/7) | **25.0 %** (4/16) | **14.3 %** (1/7) | **25.0 %** (1/4) |

The regression is concentrated exactly where the skill's routing does the work:
log-analytics (-60.4 pp), metric-telemetry (-71.4 pp) and multi-step (-75.0 pp) are the
categories whose answers require a real aggregation. The topology categories, which need
one endpoint call and little discipline, hold up comparatively well.

### Per-difficulty and cost

| Model | easy | medium | hard | used a data tool | hallucinations | mean `agent.tool_calls` | wall-clock / run |
|---|---|---|---|---|---|---|---|
| Incumbent | 94.4 % (17/18) | 87.3 % (55/63) | 91.1 % (41/45) | 117/126 (92.9 %) | 0 | 2.40 | 307.9 s |
| Candidate | 83.3 % (5/6) | 33.3 % (7/21) | 33.3 % (5/15) | 42/42 (100 %) | 0 | 6.69 | 1019.3 s |

Note the candidate's **100 % "used a data tool"** against **40.5 %** accuracy. It always
calls something; it calls the wrong thing. This is the same decoupling of tool-use from
correctness that the benchmark's original baseline report flagged (90.5 % tool use, 23.8 %
accuracy), returning through a different door. Neither model hallucinated: both fail by
giving up or by reporting a number they genuinely read, never by inventing one.

### Residual-failure diagnostics - the point of the trial

Classification is mechanical over the saved run traces: a **tool-call-template failure**
is a wrong answer whose turn either made zero tool calls or carried a raw
`<function=` / `<tool_call>` / `<parameter=` tag as plain text in the answer body.

| Model | Wrong | Tool-call-template failures | raw `<function=` tag | preamble-only (0 calls) | Substantive misses |
|---|---|---|---|---|---|
| Incumbent | 13/126 | **9** (7.1 % of bank, 69 % of its misses) | 1 | 8 | 4 |
| Candidate | 25/42 | **0** (0 %) | 0 | 0 | 25 |

**The hypothesis was right about the mechanism and wrong about the payoff.** Switching to
the single-tag JSON tool-call format removed the failure mode entirely - not reduced it,
removed it - and the model that emits perfect tool calls is the one that gets the answers
wrong.

## Why this candidate was chosen

### The failure being targeted

`local-claw`'s `TUNING-REPORT.md` closes with the finding that the tuned skill's residual
~10 % is **not skill-fixable**:

> The agent sometimes emits a preamble ("I'll count the documents in …") and ends the turn
> with zero tool calls, or emits a malformed `<function=…>` tag as plain text. […] It is a
> model/tool-call-template failure; prompt wording reduced it but did not remove it. This,
> not knowledge, is now the accuracy ceiling.

That reproduces on the incumbent's three runs: 9 of 13 wrong answers are this mode, and
one shows the mechanism unambiguously - 0 tool calls, and this in the answer body:

```
I need to find the index in the ALICE OpenSearch cluster that occupies the most storage.
I'll use the opensearch__ListIndexTool to get information about all indices and their
storage sizes.

<function=opensearch__ListIndexTool>
```

The model emitted `<function=…>` **without the enclosing `<tool_call>` wrapper**, so
llama.cpp never parsed it as a tool call and it landed in the content stream as text.

### Why the incumbent's template makes that likely

Qwen3-Coder's GGUF template (read live from the running server's `/props`) requires a
**nested, two-tag XML** emission and says so in the prompt:

```
<tool_call>
<function=example_function_name>
<parameter=example_parameter_1>
value_1
</parameter>
</function>
</tool_call>
```

with the reminder *"an inner `<function=...></function>` block must be nested within
`<tool_call></tool_call>`"*. Two independent tags must both be right before a call parses;
dropping the outer one yields plain text, silently.

`Qwen3-30B-A3B-Instruct-2507` instead uses the **Hermes-style single wrapper**:

```
<tool_call>
{"name": <function-name>, "arguments": <args-json-object>}
</tool_call>
```

One tag, JSON payload - the oldest and most exercised tool-call path in llama.cpp.

### Why it was the best-controlled swap available

| Axis | Incumbent | Candidate | Effect |
|---|---|---|---|
| Architecture | MoE 30B-A3B | MoE 30B-A3B (same) | same speed class, same VRAM |
| Quant / size | Q4_K_M, 17.3 GiB | Q4_K_M, 17.3 GiB | fits 32 GB at `CTX_SIZE=65536` identically |
| Native context | 262144 | 262144 | no context-budget change |
| Prompt family | Qwen / ChatML | Qwen / ChatML (same) | the tuned skill transfers unmodified |
| **Tool-call format** | **nested `<tool_call>`+`<function=>`** | **single `<tool_call>` + JSON** | **the variable under test** |
| Tuning emphasis | agentic coding | general instruction following | should also help the preamble-only mode |

Dense alternatives that also advertise improved function calling
(Mistral-Small-3.2-24B, Devstral-Small-2507) were rejected: a dense 24-32B model carries a
far larger KV cache and roughly 3-5x the per-token cost of a 3B-active MoE at this context
size, and a different prompt family would confound the template change with prompt-fit
against a skill tuned on Qwen. 70B-class was excluded by the brief's VRAM constraint.

## Provenance

| Field | Value |
|---|---|
| Source | `unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF`, HF revision `eea7b2be5805a5f151f8847ede8e5f9a9284bf77` |
| File | `Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf` |
| Size | 18 556 686 752 B (17.28 GiB) |
| sha256 | `6c997b8af17debdfb01d890214400ccbab00db6acc0ba8da5de1cc906c4774d0` |
| Command | `scripts/download-model.sh unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf` |
| Download time | ~3 min |

The incumbent GGUF was never deleted, so the restore needed no re-download.

## Tool-calling probe

Run **before** benchmarking, per the brief's disqualification rule.

**Server level** - `POST /v1/chat/completions` with one tool schema:

```json
"finish_reason": "tool_calls",
"content": "",
"tool_calls": [{"type":"function","function":{"name":"get_weather","arguments":"{\"city\": \"Geneva\"}"}}]
```

**End-to-end through OpenClaw** - the documented verification turn:

```
docker compose --profile cli run --rm openclaw-cli \
  agent --session-id fm-probe-… -m "Read probe.txt from your workspace and echo its contents."
→ hello from host
```

**The candidate passed the probe and was not disqualified.** No template override
(`LLAMA_ARG_CHAT_TEMPLATE_FILE`) was needed - the embedded template is correct. Deployment
fit was clean: 21.9 GiB of 32.6 GiB VRAM at `CTX_SIZE=65536` with `q8_0` KV cache, the
same footprint as the incumbent.

The probe is worth keeping in mind when reading the result: this candidate is *not* a
broken-template rejection like Bartowski's Qwen2.5-Coder-32B. Its tool calling is
mechanically better than the incumbent's. It lost on what it chose to call.

## Why it lost: the skill is co-adapted to the incumbent

The deployed `opensearch` skill's central instruction is a **negative constraint**: do not
use the MCP `SearchIndexTool` for numbers, shell out to `exec` + `curl` instead. That rule
exists because the tool is structurally broken in this deployment - the cluster advertises
its `query` parameter as an object with no properties, so constrained decoding can only
ever emit `{}`, and every call silently degrades to `match_all` and returns arbitrary
sampled documents. `TUNING-REPORT.md` identifies this as one of the two root causes of the
original 23.8 % baseline, and routing around it is most of what the tuning bought.

The two models obey that rule to completely different degrees:

| | Questions touching `SearchIndexTool` | Questions using `exec` | `SearchIndexTool` trace entries | `exec` trace entries |
|---|---|---|---|---|
| Incumbent (126 q) | 5 (4.0 %) | 104 (82.5 %) | 14 | 264 |
| Candidate (42 q) | **27 (64.3 %)** | 9 (21.4 %) | **356** | 10 |

The raw counts in the last two columns are `agent.tool_trace` entries from the session
JSONL, a different measurement from the gateway-reported `agent.tool_calls` mean in the cost
tables above, so the two do not reconcile by multiplication. Both are run-1-only figures for
the candidate: 281 `agent.tool_calls` (mean 6.69) against 382 trace entries (mean 9.10, of
which 356 `SearchIndexTool`, 10 `exec`, 16 other). They agree on 39 of 42 questions and
diverge on exactly three, all runaway loops: `telegraf-error-jul20` (9 vs 68),
`xindex-total-three-streams-jul20` (1 vs 28) and `aliecs-loglevels-jul20` (2 vs 17). The
per-question share columns are unaffected by the choice of metric.

A worked example - `nginx-total-jul20`, oracle `557513`:

```
incumbent  → exec: curl -s '…/p2-prod-logs-app-nginx/_count' -d '{"query":{"range":{"@timestamp":…}}}'
             answer: 557513                                                          ✓

candidate  → opensearch__SearchIndexTool {"index":"p2-prod-logs-app-nginx","query":{}}   (x3)
             answer: 10                                                              ✗
```

`10` is the default page size. The candidate never queried anything; it counted the
documents that happened to come back and reported that.

**This is the general lesson.** The ~90 % is not a property of the model alone, nor of the
skill alone - it is a property of the pair. The skill was tuned by watching *this* model's
behaviour and writing prompt text that corrects *its* specific priors, and `TUNING-REPORT.md`
already showed how sensitive that coupling is: merely moving ~45 correct words to the front
of the injected `description` cost 16.6 points. A model with different priors reads the
same description and routes differently. The candidate's prior is to prefer a named,
purpose-looking MCP tool over shelling out - a reasonable prior in general, and exactly
wrong here.

So the residual ~10 % is real and this candidate really does fix it, but it cannot be
harvested by a drop-in swap. **Beating 90 % requires co-tuning the model and the skill
together, not exchanging one for the other.** A future attempt should budget for
re-tuning the skill's `description` against the new model - re-running the tuning loop, not
just the benchmark - and should treat the tool-call-template win as the *starting* asset
rather than the expected end result.

## Honest limitations

- **The candidate got one scored run, not three.** Runs 2 and 3 were aborted to save GPU
  time once the gap proved decisive. Run 2 reached 35 of 42 questions before it was
  stopped and stood at **28.6 % (10/35)** with **0** template failures and 6.83 mean tool
  calls - corroborating run 1 rather than adding to it, so it is reported as partial and
  excluded from every scored table above. A single run cannot establish the candidate's
  *band*, and none is claimed: a ±7-point spread around 40.5 % does not reach a band whose
  floor is 83.3 %, which is the only comparison the ship decision needs. The narrower
  question this trial does **not** answer is whether the candidate's true mean is 40 % or
  50 %.
- **The comparison is deliberately unfair to the candidate, and that is the design.** The
  skill was tuned on the incumbent, so the incumbent enjoys an advantage the candidate
  never had. Holding the skill fixed is what the brief requires (tuning it for the
  candidate would be tuning the harness to flatter a model), and it is the right test for
  the actual question - *can we drop in a better model?* - but it is **not** a measurement
  of the two models' intrinsic capability. The honest claim is narrow: *this candidate,
  with this skill, is much worse*. It is not evidence that Qwen3-Coder-30B is the better
  model in general, and this report should not be cited for that.
- **`used_data_tool` is not a quality signal.** The candidate scored 100 % on it while
  answering 59.5 % of questions wrong. The diagnostic detects that a tool ran, not that it
  answered the question.
- **The template-failure classifier is a heuristic**, though a conservative one: zero tool
  calls on a wrong answer, or a raw tool-call tag in the answer text. It could in principle
  count a question the model declined for an unrelated reason. It was validated against
  `TUNING-REPORT.md`'s independent hand-analysis of the same failure mode and agrees with
  it, and the incumbent traces it flags read unambiguously as preamble-then-stop.
- **Bank v2 was not run.** It measures generalization of a *skill*, and there is no shipping
  candidate whose generalization is in question. Spending ~40 more slow agent turns to
  characterize a rejected model was not worth the GPU time.
- **Cluster state drifts between runs**, so topology answers are not comparable across runs
  as absolute values. The oracle recomputes live per run, so scoring stays valid within a
  run.
- **Read-only throughout.** No write reached the cluster: the benchmark client enforces a
  read-endpoint allow-list, and every command issued in this investigation was a `GET` or
  a read `POST`.

## Final state

- `local-llm-setup/.env` and `local-claw/config/openclaw.json` are **byte-identical to the
  backups taken before the trial** (`diff -q` clean on both). The only transient difference
  during restore was the `mcp.servers` block that the gateway's boot hook materializes from
  `config/mcp-enabled.json`; setting MCP back to its original OFF state restored exact
  identity.
- Both services are healthy and self-consistent on the incumbent: llama-server serves
  `/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` at `n_ctx=65536`, the gateway reports
  `{"ok":true,"status":"live"}`, and an end-to-end tool-using agent turn returns the
  expected result.
  - Worth recording: the *first* post-restore verification turn produced a preamble and
    zero tool calls - a live instance of the very failure mode this trial set out to remove.
    The retry succeeded. The ceiling is still there, and it is still stochastic.
- The candidate GGUF is left in `models/` (17.28 GiB). It is not referenced by any config
  and can be deleted; it is kept so the trial can be re-run without a re-download.
- **No model default and no model reference was changed anywhere**, which is the correct
  outcome for a negative result and the first thing to check: `.env.example` still carries
  its generic `MODEL_FILE` placeholder and `local-claw`'s example config still names the
  incumbent. The branch's tracked edits are this report, the project-memory notes, and two
  incidental documentation-drift fixes to `README.md` and `.env.example` - undocumented
  KV-cache knobs and a stale `DEBUG_PORT` - that the trial surfaced but did not cause. The
  trial itself touched only gitignored deployment state, so nothing it did needs unwinding
  in version control.

## Reproducing

```bash
git clone git@github.com:mconcas/local-llm-claw-benchmark.git && cd local-llm-claw-benchmark
cp .env.example .env          # set OS_URL and LOCAL_CLAW_DIR
pip install -r requirements.txt

# with the candidate deployed (see Provenance for the exact GGUF):
scripts/run_benchmark.sh --run-id my-cand-run
```

Compare `results/my-cand-run/scorecard.md` against `results/v1-shipped-{1,2,3}/`. Same bank
hash, same skill, same stack; the model is the only variable.
