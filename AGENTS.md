# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Scope

This repo is a standalone service: llama.cpp behind an nginx mTLS front end. It has no
coupling to consumer projects; do not carry constraints from former companion checkouts.

## Deployment state is gitignored

`.env` is live deployment state, not tracked config. Changing the served model means
editing it and recreating `llama-server`. Back it up before touching it.

## mTLS is the access control

nginx rejects clients without a certificate signed by `certs/ca.crt`
(`ssl_verify_client on`); there is no API-key auth. Issue per-client certs with
`./scripts/gen-certs.sh --client NAME`. `nginx.conf` and the certs are single-file bind
mounts: after editing them run `docker compose up -d --force-recreate nginx`; an in-place
`nginx -s reload` keeps serving the pre-edit file because the container still holds the
old inode. Verify enforcement with one certless curl (expect 400) and one with
`--cert/--key` (expect 200).

## Chat template override is model-specific

`llama-server` runs with `LLAMA_ARG_CHAT_TEMPLATE_FILE` (default in `docker-compose.yml`,
overridable via `CHAT_TEMPLATE_FILE` in `.env`) instead of the GGUF-embedded template.
`templates/qwen3.8-27b-relaxed.jinja` (the default, for the reference Qwen3.8 27B) and
`templates/devstral-small-2-relaxed.jinja` are the respective embedded templates relaxed
to hoist `system` messages from any position and to drop the strict role-alternation
check; without this, Anthropic-API clients such as Claude Code get Jinja 500s. When
swapping the model, swap this file for one matching the new model. An empty
`CHAT_TEMPLATE_FILE` is a startup error, not a fallback to the embedded template.
Regression-check template edits by diffing `POST /apply-template` output for a canonical
conversation before and after.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
