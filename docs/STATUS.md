# Open Items & Decisions

Prioritized open items, and the non-obvious decisions worth not
re-litigating. Current behavior lives in `README.md` and
`docs/remote-gpu.md` (kept current as features land); session-by-session
narrative lives in `git log`.

This file used to also carry a "current state" summary and dated
verification tables from initial development — trimmed 2026-09-23 once
the project was running in production rather than being newly built:
that content either duplicated README/`docs/remote-gpu.md` (which are
actively kept in sync and are the better source), was a one-time test log
whose facts are now stale or superseded by real usage, or already lived
as a comment next to the code it explains (`docker/entrypoint.sh`,
`docker-compose.yml`). See `git log` for that history if needed.

---

## Open items

1. **`rocm714`** — accepted as a config value but the binary isn't built
   (parked upstream: the preview wheel ships no `hip-lang-config.cmake`).
   Selecting it fails fast. Build it in `BackendBuildstage`, then re-sync
   the buildstage here.

## Decisions worth not re-litigating

- **llama-swap, not two static servers.** gpt-oss-20b + coder-14b don't
  both fit in 16 GB, and the wanted UX is "pick a model in the dropdown,
  it swaps." One endpoint, one resident model.
- **Remote mode routes Open WebUI straight at the remote** — no local
  proxy, no `model-server` container. Open WebUI already sends
  `Authorization: Bearer <key>`; that's all the remote needs.
- **Hybrid mode: Open WebUI queries both endpoints directly** (the
  remote GPU system and the local CPU fallback), rather than routing
  through a local llama-swap that passes through to the remote. Rejected
  the pass-through: llama-swap can't inject the remote's `Authorization`
  header, and its `/v1/models` would keep listing the GPU models even
  when the remote system is off — the whole point of hybrid is that they
  drop out.
- **No CPU code fallback in hybrid** — only a chat model. A 14B coder on
  CPU runs at ~3 tok/s, not worth the always-on RAM/disk cost.
- **`scripts/start.sh` owns mode logic.** No pipeline scripts here (Open
  WebUI is the only client), so start.sh sources `backend.env`, validates,
  and brings up the right services. Compose stays declarative.
- **`restart: "no"` in the base compose; always-on is an opt-in per
  deployment.** On-demand is the default and stays it for a workstation.
  Always-on (`restart: unless-stopped` via `docker-compose.override.yml`)
  is for deployments whose GPU is dedicated — homelab `remote` / `hybrid`,
  or a single-purpose local inference server. A `local` system that also
  games stays manual. `restart:` policy and llama-swap `ttl` (idle-model
  unload, currently hardcoded `ttl: 0`) are separate knobs. Full scheme:
  "Deployment lifecycle" in `docs/remote-gpu.md`.
- **Independent from FencingManualTranslator at the setup level.** No shared image,
  compose, or code. The ROCm/Vulkan build stage is duplicated on purpose;
  re-sync via `BackendBuildstage/sync_to_product.sh` when it changes.
- **`~/llm_models` shared with FencingManualTranslator** by directory convention
  only — not a repo/build dependency. A solo system just creates it.
- **`backend.env` is related to FencingManualTranslator's by convention, not kept
  identical.** The shared concepts (`BACKEND_MODE`, `LLAMA_BACKEND`,
  `REMOTE_*`) stay aligned where they overlap, but new modes are
  per-product: LocalAIChat adds `hybrid`, FencingManualTranslator does not (a CPU
  chat fallback makes no sense for a batch pipeline). No need to mirror
  additions.
