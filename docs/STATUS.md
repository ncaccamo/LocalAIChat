# Status & Roadmap

Current state, what's next, and the non-obvious decisions worth not
re-litigating. Session-by-session narrative lives in `git log`.

---

## Current state (2026-09-06)

- **Runs end-to-end.** Both models chat through Open WebUI (`:3000`),
  local GPU only, no cloud calls (bar the opt-in web search below).
  Conversations persist (`config/open-webui/webui.db`, bind-mounted).
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
- **Backend selection:** `backend.env` `BACKEND_MODE` = `local`
  (`vulkan` | `rocm7` | `rocm714` in-container) | `remote` (Open WebUI →
  LAN llama-server, bearer token, nothing local) | `hybrid` (remote GPU
  **plus** an always-on `chat-cpu` fallback in the local container).
  All verified — see the tables below and `docs/remote-gpu.md`.
- **Web search (2026-09-06):** a third container, self-hosted SearXNG on
  `ai-net` (no API key, not host-published). Opt-in per message via the
  Open WebUI toggle — never always-on. Local CPU embedder
  (`all-MiniLM-L6-v2`) ranks results. `CHAT_CTX` raised 8192 → 16384 for
  retrieval headroom. First feature that sends anything off the system.
- **Open WebUI config is env-authoritative** — `ENABLE_PERSISTENT_CONFIG=false`
  shipped early with web search (the hybrid design already called for it).
  Connections / web search / RAG come from env every start; the `config`
  table in `webui.db` is bypassed. Chat history + accounts still persist.
  `ENABLE_SIGNUP=false` is now set explicitly (it used to live only in
  that bypassed table).
- **Container:** base compose ships `restart: "no"` (on-demand); a
  dedicated deployment opts into `restart: unless-stopped` via
  `docker-compose.override.yml` — see "Deployment lifecycle" in
  `docs/remote-gpu.md`. Runs as the host UID; comes up and starts
  llama-swap (local mode) or isn't created at all (remote mode).
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

1. **Remote / hybrid against real Windows hardware** — `remote` and
   `hybrid` are only verified against a local stand-in
   `llama-server --api-key` on `ai-net`. Windows-side steps:
   `docs/remote-gpu.md` → "Setting up the remote machine". The homelab
   deployment handoff is in `homelab/localaichat/README.md`.

2. **`rocm714`** — accepted as a config value but the binary isn't built
   (parked upstream: the preview wheel ships no `hip-lang-config.cmake`).
   Selecting it fails fast. Build it in `BackendBuildstage`, then re-sync
   the buildstage here.

**Done since the roadmap was written:** web search (2026-09-06),
`ENABLE_PERSISTENT_CONFIG=false`, the portable CPU llama.cpp build
(BackendBuildstage `v2026.09.06`), and **`BACKEND_MODE=hybrid`** itself
(2026-09-06 — see "Hybrid mode design" below, all build items complete).

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
its `/v1/models` would keep listing the GPU models even when the system is
off.

**Gaming-PC-off behaviour.** Open WebUI's `/v1/models` call to the remote
fails → its models (`gpt-oss-20b`, `qwen2.5-coder-14b`) **drop from the
dropdown**; only the CPU fallback shows. System back + page refresh → they
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
env-driven from here on. Chat **history / accounts** are unaffected —
those are separate tables, still persisted. **Shipped 2026-09-06 with web
search** (v0.11.0 `Config.get` short-circuits to the env default for
every key when `PERSISTENT_ENABLED` is false — verified the stale
`web.search.enable='false'` DB row is ignored). `ENABLE_SIGNUP=false` had
to be pinned in env because it previously lived only in that table.

**Fallback model.** `Qwen2.5-3B-Instruct-Q4_K_M` (snappy on CPU,
~15–30 tok/s; `.env`-swappable to a 7B for better standalone knowledge).
`docker/entrypoint.sh` fetches it if absent (repeatable fresh setup).
**Chat / general-purpose only** — no CPU code fallback (a CPU 14B coder is
~3 tok/s).

**Build items — all done (2026-09-06).**
1. ✅ **BackendBuildstage `v2026.09.06`:** portable `cpu` llama.cpp build
   (`-DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON
   -DGGML_BACKEND_DIR=/usr/local/lib/llama-cpu`) → `llama-server-cpu` +
   `/usr/local/lib/llama-cpu/`. Synced to both products;
   **BookTranslator carries it unused**. `GGML_BACKEND_DIR` was the one
   surprise — the DL loader searches the exe dir + cwd, not
   `LD_LIBRARY_PATH`, and this layout splits bin from lib.
2. ✅ **`docker/entrypoint.sh`:** section `0b` — `BACKEND_MODE=hybrid`
   forces `llama-server-cpu`, resolves/fetches `FALLBACK_MODEL_FILE`,
   writes a one-model (`chat-cpu`, `ttl: 0`) llama-swap config, execs.
   FATAL with a rebuild hint if the CPU binary is absent (old image).
3. ✅ **`docker-compose.yml`:** `open-webui` → plural
   `OPENAI_API_BASE_URLS` / `OPENAI_API_KEYS`;
   `AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST=5`; `model-server` gets
   `FALLBACK_MODEL_PATH` / `FALLBACK_CTX`; volume paths parameterized
   (`LLM_MODELS_DIR` / `OWUI_DATA_DIR` / `SEARXNG_CONF_DIR`).
4. ✅ **`scripts/start.sh`:** `hybrid` case — require `REMOTE_HOST`,
   default `FALLBACK_MODEL_FILE`, set the two-entry `OWUI_OPENAI_*`,
   `docker compose up -d` (all three services). `remote` switched to the
   plural var names too.
5. ✅ **`backend.env.example`:** `hybrid` section.
6. ✅ **Docs:** `docs/remote-gpu.md` hybrid section; README backend row;
   this doc. Homelab-side handoff: `homelab/localaichat/README.md`.

**Reversibility.** `backend.env` `hybrid` → `remote` + `stop`/`start` =
back to prior behaviour, no rebuild. Repo changes are additive
(`git revert`-clean). The `cpu` binary stays in the image, inert unless
`BACKEND_MODE=hybrid` selects it.

**Split of concerns.** This repo ships the generic pieces:
`backend.env.example`, a parameterizable `docker-compose.yml`, and
`docker-compose.override.yml.example` (the minimal `!reset` of
`model-server`'s GPU wiring, needed for `hybrid` on a GPU-less host —
`cp` it to `docker-compose.override.yml`, which is gitignored). The
homelab repo owns the instance: the filled-in `backend.env` (gaming PC
IP, key, fallback model), a compose override that *extends* the shipped
one with `restart: unless-stopped` + real volume paths
(`/srv/localaichat/...`), and boot wiring. Neither repo knows the gaming
PC's address at rest.

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
- **`restart: "no"` in the base compose; always-on is an opt-in per
  deployment.** On-demand is the default and stays it for a workstation.
  Always-on (`restart: unless-stopped` via `docker-compose.override.yml`)
  is for deployments whose GPU is dedicated — homelab `remote` / `hybrid`,
  or a single-purpose local inference server. A `local` system that also
  games stays manual. `restart:` policy and llama-swap `ttl` (idle-model
  unload, currently hardcoded `ttl: 0`) are separate knobs. Full scheme:
  "Deployment lifecycle" in `docs/remote-gpu.md`.
- **Independent from BookTranslator at the setup level.** No shared image,
  compose, or code. The ROCm/Vulkan build stage is duplicated on purpose;
  re-sync via `BackendBuildstage/sync_to_product.sh` when it changes.
- **`~/llm_models` shared with BookTranslator** by directory convention
  only — not a repo/build dependency. A solo system just creates it.
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

**Web search (2026-09-06):**

| Check | Result |
|---|---|
| SearXNG JSON API | `localaichat-searxng` up; `GET /search?q=…&format=json` from the `open-webui` container → HTTP 200 with results (the `formats: [json]` delta in `searxng/settings.yml` is what makes it non-403) |
| Open WebUI → SearXNG | `search_searxng()` inside the container returned 3 ranked results for a test query via `SEARXNG_QUERY_URL=http://localaichat-searxng:8080/search?q=<query>` |
| env-authoritative | with `ENABLE_PERSISTENT_CONFIG=false`, `ENABLE_WEB_SEARCH` / `WEB_SEARCH_ENGINE` / `SEARXNG_QUERY_URL` resolve from env despite `webui.db` holding `web.search.enable='false'` from a prior run; `/api/config` shows `enable_signup:true` (DB had `false`) → DB bypass confirmed |
| `all-MiniLM-L6-v2` | present in `config/open-webui/cache/embedding/`, loads on Open WebUI start |
| gpt-oss-20b @ `CHAT_CTX=16384` | cold-loaded to **12.2 GB VRAM of 16.3** (~4 GB free) — the 8192 → 16384 bump costs ~0.5 GB |
| end-to-end chat + search | confirmed in the browser: web-search toggle on a message returns a sourced answer |

**Hybrid (2026-09-06, dev system + a stand-in remote on `ai-net`):**

| Check | Result |
|---|---|
| `start.sh` hybrid | brings up `model-server` + `open-webui` + `searxng`; model-server banner: binary `llama-server-cpu`, `Serves: chat-cpu` |
| local `/v1/models` | `chat-cpu` only (GPU models are the remote's job) |
| Open WebUI merge, both up | `['chat-cpu', 'remote-gpu-chat']` — plural `OPENAI_API_BASE_URLS` queried and merged |
| remote stopped | `['chat-cpu']` — dead endpoint's models drop, fallback survives, `get_all_models` returns fast (error caught) |
| remote back up | re-merges to `['chat-cpu', 'remote-gpu-chat']` |
| `chat-cpu` completion | real inference through the CPU binary: "Paris", `finish_reason: stop`, ~2.5 s (7B Q6 stand-in, warm) |

Not yet exercised: a real powered-off Windows system (the `AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST=5` path — the stand-in test hit DNS failure, which is instant, not the 5 s TCP timeout) and the default `Qwen2.5-3B` fallback (test used an existing 7B to skip the download).

**Cold-load caveat:** a stone-cold read of the ~12 GB chat model off the
USB3 SSD (fresh boot, empty page cache) can take ~5 min and once tripped
llama-swap's health-check timeout, which killed the load. Bumped
`healthCheckTimeout` 300 → **900 s** in `docker/entrypoint.sh` (needs the
image rebuild to take effect). Only the first cold load is affected;
warm loads are ~20 s.
