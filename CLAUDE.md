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
AMD RX 9070 XT (RDNA4, gfx1201, 16 GB VRAM), Ryzen 7 5700X3D. Host:
Ubuntu 24.04+ (tested on 24.04), kernel ≥ 6.12 for the in-kernel amdgpu
driver. `FROM ubuntu:24.04` is the image's pin, not the host's.

## Key invariants — don't violate without a deliberate decision
- **`restart: "no"` in the base `docker-compose.yml`** — on-demand by
  default, `scripts/start.sh` / `scripts/stop.sh` the only entry points,
  nothing auto-starts. A deployment *opts into* always-on
  (`restart: unless-stopped`, survives reboot) through
  `docker-compose.override.yml`, and only when that box's GPU is
  dedicated to this: homelab `remote` / `hybrid` and a dedicated local
  inference server run always-on; `local` on a multipurpose box (gaming
  PC / workstation) stays on-demand so games and boot aren't disrupted.
  `restart:` policy and llama-swap `ttl` (idle-model unload) are separate
  knobs — full scheme in README "Lifecycle" and `docs/remote-gpu.md`.
  Don't re-assert "`restart: "no"` everywhere" as universal.
- **One llama-swap process on `:11500`**, one model resident at a time
  (16 GB can't hold both). Open WebUI's dropdown drives the swap. Don't
  reintroduce two static per-model servers.
- **`scripts/start.sh` owns backend-mode logic** — it sources + validates
  `backend.env` and brings up the right services, and builds the
  `OWUI_OPENAI_BASE_URLS` / `OWUI_OPENAI_KEYS` lists (always the *plural*
  Open WebUI vars — one entry for `local`/`remote`, two for `hybrid`).
  `docker/entrypoint.sh` maps `LLAMA_BACKEND` (`vulkan`→`-vulkan`,
  `rocm7`/`rocm`→`-rocm`, `rocm714`→fail fast) for `local`, forces
  `-cpu` for `hybrid`, and sets `LD_LIBRARY_PATH` for the backend lib dir.
- **Three modes.** `local` — GPU in-container, serves `chat` + `code`.
  `remote` — `model-server` isn't created; Open WebUI points straight at
  the remote (`Authorization: Bearer`, no proxy). `hybrid` — `remote`
  plus `model-server` running the portable `llama-server-cpu` serving one
  always-on model `chat-cpu`; Open WebUI lists both endpoints and merges
  them, GPU models drop when the remote system is off. `hybrid`'s local
  side is **always** the cpu binary — `LLAMA_BACKEND` is ignored there.
- **Three containers:** `model-server`, `open-webui`, and `searxng`
  (self-hosted metasearch for the web-search feature, on `ai-net`, not
  host-published). `start.sh` brings `searxng` up in every mode incl.
  `remote` (named explicitly there so `--no-deps` doesn't skip it).
- **Open WebUI config is env-authoritative** —
  `ENABLE_PERSISTENT_CONFIG=false`. Connections, web search, RAG, model
  aliases must be set via env/compose; the Admin UI's copies of those
  won't persist (the `config` table in `webui.db` is bypassed). Chat
  history and accounts are separate tables and still persist. Anything
  that used to be set only in the UI (e.g. `ENABLE_SIGNUP`) must be
  pinned in env.
- **Web search is opt-in per message** via the Open WebUI toggle — never
  the always-on global. It's the only outbound traffic the project makes;
  keep it that way.
- `backend.env` is related to BookTranslator's by convention, not kept
  identical. Shared concepts (`BACKEND_MODE`, `LLAMA_BACKEND`, `REMOTE_*`)
  stay aligned; new modes are per-product (LocalAIChat has `hybrid`,
  BookTranslator does not).
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
