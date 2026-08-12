# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Deployment state is gitignored

`.env` (and, in the companion `local-claw` checkout, `config/openclaw.json`) are live
deployment state, not tracked config. Changing the served model means editing both plus
recreating `llama-server` and restarting the gateway; `local-claw`'s README documents the
sequence under "Swapping the model". Back both files up before touching them, and note
that the gateway's boot hook rewrites `openclaw.json`'s `mcp.servers` block from
`config/mcp-enabled.json` on every start, so a byte-comparison against a backup only
matches once the MCP toggle is back in its original state.

## Do not swap the model without benchmarking it

The served model and `local-claw`'s tuned `opensearch` skill are **co-adapted**: the skill
is prompt text written to correct one specific model's priors, so a drop-in model swap
regresses hard even when the new model's tool calling is mechanically better. Measured in
the trial report kept in git history (`git show de9bed3:MODEL-TRIAL.md`): a same-size,
same-family, same-quant candidate scored 40.5 % against the incumbent's 83.3 - 97.6 %
band. Validate any model change against
`local-llm-claw-benchmark` bank v1 before shipping it, and budget for re-tuning the skill.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
