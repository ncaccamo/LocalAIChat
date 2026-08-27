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

1. **Remote mode against real Windows hardware** — only verified against a
   local stand-in `llama-server --api-key` (correct URL, bearer header, no
   local process, no `model-server` container). Windows-side steps:
   `docs/remote-gpu.md` → "Setting up the remote machine".
2. **`rocm714`** — accepted as a config value but the binary isn't built
   (parked upstream: the preview wheel ships no `hip-lang-config.cmake`).
   Selecting it fails fast. Build it in `BackendBuildstage`, then re-sync
   the buildstage here.
3. **Web search for the chat model** — wanted, **after the coder-model
   swap**. Open WebUI's built-in web search: retrieval, not model
   tool-calling; **opt-in per message via the UI toggle** (do NOT enable
   the always-on global setting) — this is the required user control,
   given it's the first feature that sends anything off the box (query
   text + page fetches leave via the `open-webui` container; the "no
   cloud calls" line gets an asterisk). Plan: self-hosted **SearXNG** on
   `ai-net` (no API key, as private as search gets), built-in CPU
   embedder (`all-MiniLM-L6-v2`, ~90 MB, downloads in-container on first
   use), bump `CHAT_CTX` 8192 → ~16384 and re-check VRAM, configure in
   Admin Settings then pin working values into `docker-compose.yml`
   (env seeds first launch only; `webui.db` wins after).

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
- **`backend.env` schema is duplicated in BookTranslator by convention**,
  not shared via any file. Both currently match
  (`BACKEND_MODE` / `LLAMA_BACKEND` / `REMOTE_HOST` / `REMOTE_PORT` /
  `REMOTE_API_KEY`). If you change one, mirror the other by hand.

## Verified (2026-08-27, RX 9070 XT / gfx1201)

| Check | Result |
|---|---|
| local / vulkan | `Backend: vulkan (llama-server-vulkan)`, completion OK |
| local / rocm7 | edit `backend.env` + `stop`/`start`; **image ID unchanged (no rebuild)**; `Backend: rocm7 (llama-server-rocm)`, completion OK on the ROCm binary |
| remote | stand-in `llama-server --api-key` on the LAN: `start.sh` started **only** `localaichat-webui`; it reached the remote `/v1/models` with the bearer key; 401 without / with a wrong key |
| model swap | requesting `code` tore down `chat`; VRAM held ~13 GB (one model), never doubled |
| persistence | Open WebUI DB survives `stop.sh`/`start.sh` and rebuilds |
| coder Q5_K_M | correct output; ~51 tok/s gen; **13.6 GB VRAM of 15.9 at `CODE_CTX=16384`** (~1.3 GB free — KV is preallocated so it's the steady-state ceiling, no mid-chat growth) |

One `docker compose build` total, to ship the `COPY`'d `entrypoint.sh`;
`vulkan`↔`rocm7` after that is `stop.sh`/`start.sh` only.
