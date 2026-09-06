# Status & Roadmap

Current state, what's next, and the non-obvious decisions worth not
re-litigating. Session-by-session narrative lives in `git log`.

---

## Current state (2026-08-27)

- **Runs end-to-end.** Both models chat through Open WebUI (`:3000`),
  local GPU only, no cloud calls. Conversations persist
  (`config/open-webui/webui.db`, bind-mounted).
- **Serving:** one llama-swap process on `:11500` presents an
  OpenAI-compatible endpoint; its `/v1/models` lists `chat` + `code`.
  Picking one in the Open WebUI dropdown stops the running `llama-server`
  and starts the other — one model resident at a time (16 GB card).
- **Models:** `gpt-oss-20b-MXFP4` (chat, ~12 GB) and
  `Qwen2.5-Coder-14B-Instruct-Q5_K_M` (code, ~10.5 GB), in `~/llm_models`
  (bind-mounted), downloaded on first start if absent. Confirmed picks
  for a 16 GB card. Coder runs at `CODE_CTX=16384` → 13.6 GB VRAM,
  ~1.3 GB free (fits; drop `CODE_CTX` to 12288 for more margin). Swap via
  `.env` (`CHAT_MODEL_FILE` / `CODE_MODEL_FILE` + URLs in
  `docker/entrypoint.sh`) for others.
- **Backend selection:** `backend.env` switches local
  (`vulkan` | `rocm7` | `rocm714`) vs. remote (LAN llama-server + bearer
  token). All three states verified. See `docs/remote-gpu.md`.
- **Container:** `restart: "no"`, runs as the host UID, comes up and
  starts llama-swap (local mode) or isn't created at all (remote mode).
- **Host has no ROCm / Vulkan / Mesa.** All of it is in the image. The
  host only needs the in-kernel `amdgpu` driver (`/dev/kfd`, `/dev/dri`)
  and `render`/`video` group membership. Host ROCm was removed 2026-08-27
  (freed ~22 GB) with no effect on inference — verified below.
- **Image:** `docker/Dockerfile` = the synced `BUILDSTAGE` block
  (byte-identical to `BackendBuildstage/Dockerfile.buildstage`) + a
  product tail that installs llama-swap. Buildstage layers cache-hit
  from BookTranslator's image.
- **Setup:** `scripts/setup.sh` (one-time) verifies host prereqs, detects
  the host's real render/video GIDs → `.env`, creates `ai-net`, builds,
  and brings up. It does not install system packages — that's the manual
  `docs/HOST_PREREQUISITES.md` step. `scripts/start.sh` is the per-run
  bring-up.

## Open items

1. **`BACKEND_MODE=hybrid` — remote GPU + always-on local CPU fallback.**
   For the homelab deploy: the GPU is remote on a Windows gaming PC
   (`llama-server.exe`, Vulkan) that the user kills to play games, so a
   chat model that is *always* reachable has to run on the homelab (48 GB
   RAM, no GPU) alongside Open WebUI. Design agreed 2026-09-06 — see
   "Hybrid mode design" below. Build order: **this first, then web
   search** (item 2 — independent, not coupled).

2. **Web search for the chat model** — wanted, after hybrid. Open WebUI's
   built-in web search: retrieval, not model tool-calling; **opt-in per
   message via the UI toggle** (do NOT enable the always-on global
   setting) — the required user control, given it's the first feature
   that sends anything off the box (query text + page fetches leave via
   the `open-webui` container; the "no cloud calls" line gets an
   asterisk). Plan: self-hosted **SearXNG** on `ai-net` (no API key), the
   built-in CPU embedder (`all-MiniLM-L6-v2`, ~90 MB, downloads
   in-container on first use), bump `CHAT_CTX` 8192 → ~16384 and re-check
   VRAM. **Config via env, not Admin UI** — hybrid sets
   `ENABLE_PERSISTENT_CONFIG=false` (see below), so all Open WebUI config
   (connections, web search, RAG, model aliases) must come from env /
   compose, not from settings persisted in `webui.db`.

3. **Remote mode against real Windows hardware** — `remote` (and the
   remote half of `hybrid`) is only verified against a local stand-in
   `llama-server --api-key`. Windows-side steps: `docs/remote-gpu.md` →
   "Setting up the remote machine".

4. **`rocm714`** — accepted as a config value but the binary isn't built
   (parked upstream: the preview wheel ships no `hip-lang-config.cmake`).
   Selecting it fails fast. Build it in `BackendBuildstage`, then re-sync
   the buildstage here.

## Hybrid mode design (agreed 2026-09-06 — do not re-litigate)

**Shape.** `BACKEND_MODE=hybrid` reuses `remote`'s `REMOTE_HOST` /
`REMOTE_PORT` / `REMOTE_API_KEY` and adds `FALLBACK_MODEL_FILE` +
`FALLBACK_CTX`. The local side is **always** the CPU binary — no
`LLAMA_BACKEND` choice in hybrid. `scripts/start.sh` brings up **both**
services (`model-server` runs llama-swap serving the one fallback model;
`open-webui` runs).

**Wiring (option 2A — Open WebUI talks to both endpoints).**
`start.sh` sets Open WebUI's `OPENAI_API_BASE_URLS` (plural) to
`http://<REMOTE_HOST>:<REMOTE_PORT>/v1 ; http://model-server:11500/v1`
with matching `OPENAI_API_KEYS`. Open WebUI queries both and merges the
model lists. Rejected 2C (homelab llama-swap fronts a pass-through to the
remote): llama-swap can't inject the remote's `Authorization` header, and
its `/v1/models` would keep listing the GPU models even when the box is
off.

**Gaming-PC-off behaviour.** Open WebUI's `/v1/models` call to the remote
fails → its models (`gpt-oss-20b`, `qwen2.5-coder-14b`) **drop from the
dropdown**; only the CPU fallback shows. Box back + page refresh → they
return. The homelab **never** contacts the gaming PC otherwise — no
health poll, no wake-on-LAN, no retry loop. Set a **short Open WebUI
model-list HTTP timeout** so a dead remote doesn't stall the dropdown
(~default is very long).

**Env-authoritative config.** `open-webui` gets
`ENABLE_PERSISTENT_CONFIG=false` so connections (and everything else) are
re-read from env on every start and nothing is written to / read from the
`config` table in `webui.db`. Consequence: reverting `hybrid` → `remote`
is *only* the `backend.env` change + restart — no stale second connection
left behind. Trade-off: web-search / RAG / model-alias config must also be
env-driven from here on (see item 2). Chat **history / accounts** are
unaffected — those are separate tables, still persisted.

**Fallback model.** `Qwen2.5-3B-Instruct-Q4_K_M` (snappy on CPU,
~15–30 tok/s; `.env`-swappable to a 7B for better standalone knowledge).
`docker/entrypoint.sh` fetches it if absent (repeatable fresh setup).
**Chat / general-purpose only** — no CPU code fallback (a CPU 14B coder is
~3 tok/s).

**Build items.**
1. **BackendBuildstage:** add a `cpu` llama.cpp build —
   `-DGGML_VULKAN=OFF -DGGML_HIP=OFF`, **portable**
   (`-DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON`)
   so an image built on the Zen 3 dev box runs on any homelab CPU.
   Produces `llama-server-cpu` + `/usr/local/lib/llama-cpu/`. Re-sync to
   both products; **BookTranslator carries it unused** (accepted — it's a
   power-hungry batch pipeline, a CPU fallback makes no sense there).
2. **`docker/entrypoint.sh`:** `BACKEND_MODE=hybrid` branch;
   `LLAMA_BACKEND=cpu` → `BE=cpu`; llama-swap config with the single
   fallback model; fetch `FALLBACK_MODEL_FILE` if absent.
3. **`docker-compose.yml`:** `open-webui` env → plural
   `OPENAI_API_BASE_URLS` / `OPENAI_API_KEYS` (singular becomes a
   one-element list for `local`/`remote`), `ENABLE_PERSISTENT_CONFIG=false`,
   short model-list timeout. Parameterize volume paths so the homelab
   override can point them at real storage.
4. **`scripts/start.sh`:** `hybrid` case — validate `REMOTE_*` +
   `FALLBACK_MODEL_FILE`, bring up both services, compose the plural OWUI
   vars.
5. **`backend.env.example`:** `hybrid` section — reused `REMOTE_*` +
   `FALLBACK_MODEL_FILE` + `FALLBACK_CTX`.
6. **Docs:** `docs/remote-gpu.md` gains a hybrid section; README backend
   table gets a `hybrid` row.

**Reversibility.** `backend.env` `hybrid` → `remote` + `stop`/`start` =
back to current behaviour, no rebuild. Repo changes are additive
(`git revert`-clean). The `cpu` binary can stay in the image unused.

**Homelab repo owns the instance:** the real `backend.env` (gaming PC IP,
key, `BACKEND_MODE=hybrid`, fallback model) as a plain file on the
homelab box; a compose override (`restart: unless-stopped`, real volume
paths e.g. `/srv/localaichat/...`); and boot wiring (systemd unit /
Docker restart policy / whatever orchestrator the homelab uses). This
repo stays generic — ships `backend.env.example` and a parameterizable
compose, knows nothing about the gaming PC.

## Decisions worth not re-litigating

- **llama-swap, not two static servers.** gpt-oss-20b + coder-14b don't
  both fit in 16 GB, and the wanted UX is "pick a model in the dropdown,
  it swaps." One endpoint, one resident model.
- **Remote mode routes Open WebUI straight at the remote** — no local
  proxy, no `model-server` container. Open WebUI already sends
  `Authorization: Bearer <key>`; that's all the remote needs.
- **`scripts/start.sh` owns mode logic.** No pipeline scripts here (Open
  WebUI is the only client), so start.sh sources `backend.env`, validates,
  and brings up the right services. Compose stays declarative.
- **`restart: "no"` everywhere.** On-demand, not a long-running service.
- **Independent from BookTranslator at the setup level.** No shared image,
  compose, or code. The ROCm/Vulkan build stage is duplicated on purpose;
  re-sync via `BackendBuildstage/sync_to_product.sh` when it changes.
- **`~/llm_models` shared with BookTranslator** by directory convention
  only — not a repo/build dependency. A solo box just creates it.
- **`backend.env` is related to BookTranslator's by convention, not kept
  identical.** The shared concepts (`BACKEND_MODE`, `LLAMA_BACKEND`,
  `REMOTE_*`) stay aligned where they overlap, but new modes are
  per-product: LocalAIChat adds `hybrid`, BookTranslator does not (a CPU
  chat fallback makes no sense for a batch pipeline). No need to mirror
  additions.

## Verified (2026-08-27, RX 9070 XT / gfx1201)

| Check | Result |
|---|---|
| local / vulkan | `Backend: vulkan (llama-server-vulkan)`, completion OK |
| local / rocm7 | edit `backend.env` + `stop`/`start`; **image ID unchanged (no rebuild)**; `Backend: rocm7 (llama-server-rocm)`, completion OK on the ROCm binary |
| remote | stand-in `llama-server --api-key` on the LAN: `start.sh` started **only** `localaichat-webui`; it reached the remote `/v1/models` with the bearer key; 401 without / with a wrong key |
| model swap | requesting `code` tore down `chat`; VRAM held ~13 GB (one model), never doubled |
| persistence | Open WebUI DB survives `stop.sh`/`start.sh` and rebuilds |
| coder Q5_K_M | correct output; ~51 tok/s gen; **13.6 GB VRAM of 15.9 at `CODE_CTX=16384`** (~1.3 GB free — KV is preallocated so it's the steady-state ceiling, no mid-chat growth) |
| host ROCm removed | after purging host ROCm (~22 GB) + reboot: Vulkan in the container still sees the GPU; `llama-server-vulkan` loaded gpt-oss-20b in **21 s** (warm), 180/83 tok/s. Containerised inference is fully independent of host ROCm. |

**Cold-load caveat:** a stone-cold read of the ~12 GB chat model off the
USB3 SSD (fresh boot, empty page cache) can take ~5 min and once tripped
llama-swap's health-check timeout, which killed the load. Bumped
`healthCheckTimeout` 300 → **900 s** in `docker/entrypoint.sh` (needs the
image rebuild to take effect). Only the first cold load is affected;
warm loads are ~20 s.
