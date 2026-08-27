# CLAUDE.md — LocalAIChat

## What this is
On-demand local chat / general-purpose LLM serving: Open WebUI in front of
a self-contained model-serving container. Interactive use, unrelated to
the `BookTranslator` translation pipeline. Runs fully locally, no cloud
API calls.

## Sibling projects — read this before assuming a dependency exists
This repo is **fully self-contained** — it does not depend on
`BookTranslator` or `BackendBuildstage` to build or run.

- `BookTranslator` — separate product, separate repo. No build or runtime
  dependency in either direction. Not run at the same time (shared GPU).
- `BackendBuildstage` — offline sandbox for the ROCm/Vulkan/llama.cpp
  build stage. Never a build or runtime dependency. `docker/Dockerfile`
  carries a synced, byte-identical copy of its `Dockerfile.buildstage`
  between `# BUILDSTAGE START` / `# END` markers; re-sync with
  `BackendBuildstage/sync_to_product.sh docker/Dockerfile` when it
  changes (it never touches the product tail below the markers). The
  cross-project backend-selection spec also lives there
  (`BACKEND_SELECTION_HANDOFF.md`).

## Hardware this is tuned for
AMD RX 9070 XT (RDNA4, gfx1201, 16 GB VRAM), Ryzen 7 5700X3D, Ubuntu
24.04 + kernel ≥ 6.12.

## Key invariants — don't violate without a deliberate decision
- `restart: "no"` everywhere. On-demand, not a long-running service.
  `scripts/start.sh` / `scripts/stop.sh` are the only entry points;
  nothing auto-starts.
- **One llama-swap process on `:11500`**, one model resident at a time
  (16 GB can't hold both). Open WebUI's dropdown drives the swap. Don't
  reintroduce two static per-model servers.
- **`scripts/start.sh` owns backend-mode logic** — it sources + validates
  `backend.env` and brings up the right services. `docker/entrypoint.sh`
  maps `LLAMA_BACKEND` (`vulkan`→`-vulkan`, `rocm7`/`rocm`→`-rocm`,
  `rocm714`→fail fast) and sets `LD_LIBRARY_PATH` for the backend lib dir.
- **Remote mode starts nothing locally** — `model-server` isn't created;
  Open WebUI is pointed straight at the remote and sends the key as
  `Authorization: Bearer`. No proxy layer.
- `backend.env` schema is duplicated in BookTranslator by convention, not
  shared via any file — keep the two identical by hand.
- `entrypoint.sh` is `COPY`'d into the image (not mounted): changing it
  needs `docker compose build`. Switching `vulkan` ↔ `rocm7` afterward is
  `stop.sh`/`start.sh` only, no rebuild.
- `docs/HOST_PREREQUISITES.md` is a full standalone copy, not a pointer to
  BookTranslator's — keep it that way.
- `scripts/setup.sh` = one-time (verify host prereqs, detect GPU GIDs →
  `.env`, build, up). `scripts/start.sh` = per-run bring-up (owns the
  `backend.env` mode logic). `setup.sh` calls `start.sh` at the end.
  Neither installs system packages — that's `docs/HOST_PREREQUISITES.md`.
- Open WebUI pinned to `v0.11.0`, not `latest`.

## Where to look
- `docs/STATUS.md` — current state, prioritized open items, decisions
  worth not re-litigating. **Start here.**
- `README.md` — the user manual: install, use, configure.
- `docs/remote-gpu.md` — `backend.env`, the `LLAMA_BACKEND`→binary
  mapping, remote-GPU mode + remote-machine setup.
- `docs/HOST_PREREQUISITES.md` — bare-metal host setup.
- Session history: `git log` (HANDOFF.md retired, and
  docs/design-backend-selection.md folded into README + docs/remote-gpu.md,
  2026-08-27).
