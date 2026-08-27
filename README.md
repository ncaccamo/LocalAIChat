# LocalAIChat

On-demand local chat / general-purpose LLM serving: **Open WebUI** in
front of a self-contained model-serving container (ROCm 7.2.4 + Vulkan +
llama.cpp, with [llama-swap](https://github.com/mostlygeek/llama-swap) for
on-demand model switching). Runs entirely on local hardware — no cloud API
calls.

Tuned for an AMD RX 9070 XT (RDNA4, 16 GB) + Ryzen 7 5700X3D on Ubuntu
24.04. Sibling project to `BookTranslator`, but **fully independent at the
setup level** — either can be deployed alone on a machine that has never
seen the other.

## Quick start

**1. Host prerequisites** — Ubuntu 24.04, kernel ≥ 6.12, AMD GPU driver,
Docker. Work through **`docs/HOST_PREREQUISITES.md`** (standalone, no
dependency on BookTranslator's copy).

**2. Setup** — one script: verifies the host, writes `.env` with your
machine's real UID/GID and GPU group IDs, builds the image, brings the
stack up.

```bash
bash scripts/setup.sh
# Open WebUI: http://localhost:3000 — create an account, pick a model
```

**3. Everyday use:**

```bash
bash scripts/start.sh                  # bring it up
docker compose logs -f model-server    # watch model download / load
bash scripts/stop.sh                   # frees the GPU
```

Models (`gpt-oss-20b-MXFP4` chat, `Qwen2.5-Coder-14B-Instruct-Q4_K_M`
code) download into `~/llm_models` on first chat if absent (~21 GB).
They're placeholder picks — change `CHAT_MODEL_FILE` / `CODE_MODEL_FILE`
in `.env` (and the URLs in `docker/entrypoint.sh`) to use others.
`setup.sh` and `start.sh` both seed `.env` / `backend.env` from the
`*.example` templates if missing.

## How it works

- `model-server` runs **one llama-swap process on `:11500`**, an
  OpenAI-compatible endpoint. Its `/v1/models` lists `chat` and `code`;
  both show in the Open WebUI dropdown.
- Picking a model loads it; picking the other one **unloads the first**.
  Only one model is in VRAM at a time — the 16 GB card can't hold both.
- Open WebUI persists accounts, chats, and RAG data to
  `config/open-webui/` (bind-mounted, gitignored) — survives
  `stop.sh`/`start.sh` and rebuilds.
- Every service is `restart: "no"`. Nothing auto-starts; `scripts/start.sh`
  / `scripts/stop.sh` are the only entry points.

## Backends

`backend.env` selects where inference runs:

- **`BACKEND_MODE=local`** + `LLAMA_BACKEND=vulkan | rocm7 | rocm714` —
  llama-swap runs in the container. Switching `vulkan` ↔ `rocm7` is
  `stop.sh`/`start.sh`, **no rebuild** (both binaries are in the image).
  `rocm714` is parked upstream and fails fast.
- **`BACKEND_MODE=remote`** — points Open WebUI straight at a
  `llama-server` on another LAN machine (bearer-token auth); no local
  server starts and `model-server` isn't created. This is the "run
  `llama-server.exe` on the Windows gaming PC" mode.

Details, including the Windows-side setup: **`docs/design-backend-selection.md`**.

## Relationship to BookTranslator

Siblings, not a client/dependency pair. **Not shared:** base image,
Dockerfile, compose, containers, code, host-prereqs doc. **Shared, safely:**
the `ai-net` docker network name (a convention — `start.sh` creates it
idempotently), the port-numbering convention (this project uses `11500`;
`11501` is reserved, unused), and `~/llm_models` (a directory mount, not a
repo dependency). Not meant to run at the same time — one GPU.

The ROCm/Vulkan build stage in `docker/Dockerfile` is a synced copy of
`BackendBuildstage/Dockerfile.buildstage`, kept between `# BUILDSTAGE
START` / `# END` markers. Re-sync with
`BackendBuildstage/sync_to_product.sh docker/Dockerfile` when it changes —
it never touches the product-specific tail below the markers.

## Docs

| File | For |
|---|---|
| `README.md` | this — the front door |
| `docs/STATUS.md` | current state, open items, decisions worth not re-litigating |
| `docs/design-backend-selection.md` | `backend.env` local/remote design + Windows remote setup |
| `docs/HOST_PREREQUISITES.md` | bare-metal host setup (standalone) — do this first |
| `CLAUDE.md` | orientation + hard invariants for AI coding agents |

Session history: `git log` (HANDOFF.md was retired 2026-08-27).
