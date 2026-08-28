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

---

## Install

### 1. Host prerequisites

Ubuntu 24.04 **or newer**, kernel ≥ 6.12 (in-kernel `amdgpu` driver), the
`render`/`video` groups, Docker. **No host ROCm / Vulkan / Mesa** — all in
the image, which stays `FROM ubuntu:24.04` regardless of the host. Work
through
**[`docs/HOST_PREREQUISITES.md`](docs/HOST_PREREQUISITES.md)** once — it's
`sudo apt` / kernel / BIOS steps on bare metal. Standalone, no dependency
on BookTranslator's copy.

### 2. Setup

One script — verifies the host is ready, writes `.env` with this machine's
real UID/GID and GPU group IDs, creates the `ai-net` docker network,
builds the image, brings the stack up:

```bash
bash scripts/setup.sh
```

First build compiles llama.cpp twice (ROCm + Vulkan): 20–30 min, much
faster if BookTranslator's image is already built (shared layers).

---

## Use

Open **http://localhost:3000**, create an account (local, stays on the
box), and pick a model from the dropdown:

- **`gpt-oss-20b`** — general chat / reasoning
- **`qwen2.5-coder-14b`** — coding

Switching models in the dropdown unloads the running one and loads the
other — only one is in VRAM at a time (the 16 GB card can't hold both).
First use of a model downloads it into `~/llm_models` (~23 GB total) and
loads it, which takes a minute or two; watch with
`docker compose logs -f model-server`.

```bash
bash scripts/start.sh    # bring the stack up
bash scripts/stop.sh     # stop it, free the GPU
```

Everything is `restart: "no"` — nothing auto-starts; `start.sh` /
`stop.sh` are the only entry points. Open WebUI persists accounts, chats,
and uploaded files under `config/open-webui/` (gitignored) — survives
`stop`/`start` and image rebuilds.

---

## Configure

### Models

`.env` (seeded from `.env.example` on first run):

| Var | Default | Notes |
|---|---|---|
| `CHAT_MODEL_FILE` | `gpt-oss-20b.gguf` | file in `~/llm_models` |
| `CODE_MODEL_FILE` | `Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf` | " |

To use different models, set the filename here **and** the matching
download URL in `docker/entrypoint.sh`, then `stop.sh` / `start.sh`.
Per-model context size is `CHAT_CTX` / `CODE_CTX` (compose environment).

### Backend

`backend.env` (seeded from `backend.env.example`) picks where inference
runs:

- **`BACKEND_MODE=local`** + `LLAMA_BACKEND=vulkan | rocm7` — llama-swap
  runs in the container. Switching `vulkan` ↔ `rocm7` is `stop.sh` /
  `start.sh`, **no rebuild** (both binaries are in the image). `rocm714`
  is a valid value but parked upstream — it fails fast.
- **`BACKEND_MODE=remote`** — points Open WebUI at a `llama-server` on
  another LAN machine (bearer-token auth); nothing runs locally, no model
  hot-swap. The "run `llama-server.exe` on the Windows gaming PC" mode.

Full reference incl. the remote-machine setup:
**[`docs/remote-gpu.md`](docs/remote-gpu.md)**.

---

## How it works

`model-server` runs one **llama-swap** process on `:11500` — an
OpenAI-compatible endpoint whose `/v1/models` advertises `chat` and
`code`. Selecting a model in Open WebUI routes through llama-swap, which
starts that model's `llama-server` (and stops the previous one).
`docker/entrypoint.sh` resolves the backend binary + model files, writes
the llama-swap config, and `exec`s it.

## Relationship to BookTranslator

Siblings, not a client/dependency pair. **Not shared:** base image,
Dockerfile, compose, containers, code, host-prereqs doc. **Shared,
safely:** the `ai-net` docker network name (a convention — `start.sh`
creates it idempotently), the port-numbering convention (this project
uses `11500`; `11501` is reserved, unused), and `~/llm_models` (a
directory mount, not a repo dependency). Not meant to run at the same
time — one GPU.

The ROCm/Vulkan build stage in `docker/Dockerfile` is a synced copy of
`BackendBuildstage/Dockerfile.buildstage`, kept between
`# BUILDSTAGE START` / `# END` markers. Re-sync with
`BackendBuildstage/sync_to_product.sh docker/Dockerfile` when it changes —
it never touches the product-specific tail below the markers.

## Docs

| File | For |
|---|---|
| `README.md` | this — install, use, configure |
| [`docs/HOST_PREREQUISITES.md`](docs/HOST_PREREQUISITES.md) | bare-metal host setup — do this first |
| [`docs/remote-gpu.md`](docs/remote-gpu.md) | `backend.env`, local backend switching, remote-GPU mode |
| [`docs/STATUS.md`](docs/STATUS.md) | current state, open items, decisions worth not re-litigating |
| `CLAUDE.md` | orientation + hard invariants for AI coding agents |

Session history: `git log` (HANDOFF.md was retired 2026-08-27).
