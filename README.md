# LocalAIChat

A self-hosted chat and coding assistant: **[Open WebUI](https://github.com/open-webui/open-webui)**
in front of a **llama.cpp** model server, with model switching handled by
[llama-swap](https://github.com/mostlygeek/llama-swap). Docker Compose,
one command to start. Inference stays on hardware you control — no cloud
LLM APIs. Web search is opt-in per message and goes through a self-hosted
SearXNG container, not a third-party API.

```
 browser ──> Open WebUI ──> llama-swap ──> llama-server (ROCm / Vulkan / CPU)
                 │              └─ one model resident at a time (chat | code)
                 └──> SearXNG   (only when web search is toggled on)
```

**Three ways to run it** (set in `backend.env`):

| Mode | Where inference runs |
|---|---|
| `local` | GPU in the container on this system |
| `remote` | a llama-server on another LAN system (e.g. a gaming PC), Bearer-token auth |
| `hybrid` | `remote`, plus an always-on CPU model here for when the GPU system is off |

Optional image generation via a separate stable-diffusion.cpp backend is
also supported (see [Image generation](#image-generation)).

**Status:** a personal project, run daily and tested on one setup — AMD RX
9070 XT (RDNA4, 16 GB) on Ubuntu 24.04, plus a Windows GPU host in `remote`
mode. The container is wired for AMD GPUs (`/dev/kfd`, `/dev/dri`); other
GPUs are untested. The chat/code models and paths are defaults you'd
expect to change. Provided as-is; forks welcome.

**Security:** intended for a trusted LAN. Open WebUI has accounts with
signup closed by default, but the model endpoints use a placeholder key
(`sk-local`) — don't expose ports 3000 or 11500 to the internet.

---

## Install

Two paths: **local mode** (steps 1–2, GPU in the container on this host)
or a GPU-less host running **`remote` / `hybrid`** (the alternative below).

### 1. Host prerequisites (local mode)

Ubuntu 24.04 **or newer**, kernel ≥ 6.12 (in-kernel `amdgpu` driver), the
`render`/`video` groups, Docker. **No host ROCm / Vulkan / Mesa** — all in
the image, which stays `FROM ubuntu:24.04` regardless of the host. Work
through
**[`docs/HOST_PREREQUISITES.md`](docs/HOST_PREREQUISITES.md)** once — it's
`sudo apt` / kernel / BIOS steps on bare metal.

### 2. Setup

One script — verifies the host is ready, writes `.env` with this machine's
real UID/GID and GPU group IDs, creates the `ai-net` docker network,
builds the image, brings the stack up:

```bash
bash scripts/setup.sh
```

First build compiles llama.cpp three times (ROCm + Vulkan + a portable
CPU build): 25–35 min.

### Alternative: remote / hybrid on a GPU-less host

`scripts/setup.sh` checks for a local AMD GPU and exits if there isn't
one — it's local-mode only. For `remote` or `hybrid` on a host with no
GPU (the usual case: the GPU is on another machine), prerequisites shrink
to **Docker + the compose plugin** (`docs/HOST_PREREQUISITES.md` §6 only;
skip the kernel / `amdgpu` / group steps), and the bring-up is manual:

```bash
cp backend.env.example backend.env
# edit backend.env: BACKEND_MODE=remote|hybrid, REMOTE_* (+ FALLBACK_* for hybrid)

# hybrid only — strips model-server's /dev/kfd wiring, and builds the CPU image:
cp docker-compose.override.yml.example docker-compose.override.yml
docker compose build

bash scripts/start.sh    # seeds .env, creates ai-net, starts the right services
```

`remote` needs neither the override nor a build — `model-server` never
starts, and `open-webui` / `searxng` are pulled images. Full `backend.env`
reference + the remote-machine (Windows) setup:
**[`docs/remote-gpu.md`](docs/remote-gpu.md)**.

---

## Use

Open **http://localhost:3000**, create an account (local, stays on the
system), and pick a model from the dropdown:


- **`gpt-oss-20b`** — general chat / reasoning
- **`qwen2.5-coder-14b`** — coding

Switching models in the dropdown unloads the running one and loads the
other — only one is in VRAM at a time (the 16 GB card can't hold both).
First use of a model downloads it into `~/llm_models` (~23 GB total) and
loads it, which takes a minute or two; watch with
`docker compose logs -f model-server`.

To let a reply use live web results, toggle **web search** on in the
message bar before sending (it resets per chat session). See
[Web search](#web-search).

```bash
bash scripts/start.sh    # bring the stack up
bash scripts/stop.sh     # stop it, free the GPU
```

If port 3000 is already in use on this system (a homelab system running
another dashboard, say), set `OWUI_PORT` in `.env` — the URL shifts with
it.

By default everything is `restart: "no"` — nothing auto-starts;
`start.sh` / `stop.sh` are the only entry points. A dedicated deployment
can opt into always-on instead; see
[Lifecycle: on-demand vs. always-on](#lifecycle-on-demand-vs-always-on).
Open WebUI persists accounts, chats, and uploaded files under
`config/open-webui/` (gitignored) — survives `stop`/`start` and image
rebuilds.

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
  another LAN machine (bearer-token auth); nothing runs locally. The "run
  it on the Windows gaming PC" mode.
- **`BACKEND_MODE=hybrid`** — `remote` **plus** an always-on CPU chat
  model (`chat-cpu`) in the local container, for when the remote GPU system
  gets powered off. Open WebUI lists both; the GPU models come and go with
  the system. Needs `FALLBACK_MODEL_FILE` / `FALLBACK_CTX` in `backend.env`,
  and on a GPU-less host `cp docker-compose.override.yml.example
  docker-compose.override.yml` (strips the `/dev/kfd` mount `model-server`
  otherwise requires).

Full reference incl. the remote-machine setup:
**[`docs/remote-gpu.md`](docs/remote-gpu.md)**.

### Lifecycle: on-demand vs. always-on

The base `docker-compose.yml` ships `restart: "no"` on every service —
the on-demand default: `scripts/start.sh` brings the stack up,
`scripts/stop.sh` takes it down, nothing returns after a reboot. Whether
a deployment *should* stay always-on comes down to **who owns that
system's GPU**. `restart:` policy and llama-swap's `ttl` (unload an idle
model to free VRAM) are independent knobs:

| Deployment | GPU on this system | `restart:` | llama-swap `ttl` | Lifecycle |
|---|---|---|---|---|
| **Homelab** — `remote` / `hybrid` | none (or just the CPU fallback) | `unless-stopped` | n/a locally | boots with the host; you still start the remote GPU system by hand |
| **Dedicated local server** — `local`, system does nothing else | yes, single-purpose | `unless-stopped` | non-zero — free VRAM when idle | boots with the host |
| **Multipurpose system** — `local` on a gaming PC / workstation | yes, shared with games / other work | `"no"` (default) | optional non-zero | manual `start.sh` / `stop.sh`; never auto-resurrects on boot |

Always-on is opt-in: `cp docker-compose.override.yml.example
docker-compose.override.yml` (gitignored, auto-loaded) — it sets
`restart: unless-stopped` on all three services. Delete those lines to
return to on-demand. This is also the file that strips `model-server`'s
GPU wiring for a GPU-less `hybrid` host.

`ttl` is currently hardcoded `ttl: 0` (never unload) in the llama-swap
config `docker/entrypoint.sh` generates; set a non-zero seconds value
there for the dedicated / multipurpose local cases (next request reloads
the model — seconds, warm). It **narrows** GPU contention on a shared
system but doesn't remove it — any request still triggers a full load —
which is why a multipurpose system stays manual rather than always-on.

### Web search

A third container, **SearXNG**, runs on `ai-net` (no API key, no account,
not published to the host). Open WebUI queries it, embeds the top results
with a small local CPU model (`all-MiniLM-L6-v2`, pulled into
`config/open-webui/` on first use), and feeds the best snippets to the
chat model.

It is **opt-in per message**: the toggle in the message bar, off by
default, resetting each chat session. There is no always-on mode. When you
switch it on, that message's query text and the pages SearXNG fetches
leave the system — the only outbound traffic this project makes.

Knobs (`.env`, applied on `start.sh`):

| Var | Default | Notes |
|---|---|---|
| `ENABLE_WEB_SEARCH` | `true` | `false` removes the toggle entirely |
| `WEB_SEARCH_RESULT_COUNT` | `3` | results fetched per query |
| `WEB_SEARCH_CONCURRENT_REQUESTS` | `10` | parallel page fetches |

Open WebUI config here is **env-authoritative** —
`ENABLE_PERSISTENT_CONFIG=false`, so connections, web search, and RAG come
from env every start and the Admin UI's copies of those settings don't
stick. Chat history and accounts are unaffected.

### Interface / background generation

Same deal — set in `.env`, not the Admin UI. Shipped defaults turn off the
hidden per-message model calls (follow-up suggestions, auto-tagging,
input-box autocomplete) and the outbound extras (openwebui.com sharing,
user webhooks, ad-hoc API connections, the Ollama probe); chat
auto-naming and the web-search query rewriter stay on.
`OWUI_PROMPT_SUGGESTIONS=[]` clears the new-chat splash cards. Full list
with per-var comments in `.env.example`.

Your **personal** Settings (theme, language, per-user system prompt, the
per-account follow-up toggle) are stored per user and *do* persist — only
the global **Admin → Settings** panel is env-driven.

### Image generation

Optional, and off by default — a second, independent backend on a remote
system (this repo doesn't run or install it). `ENABLE_IMAGE_GENERATION=false`
in `.env.example`; set it `true` along with `IMAGE_GENERATION_ENGINE` and
`AUTOMATIC1111_BASE_URL` once you have something to point at. Full
reference, including the recommended engine and why prompt-generation
defaults off: **[Image generation](docs/remote-gpu.md#image-generation-optional)**
in `docs/remote-gpu.md`.

---

## How it works

`model-server` runs one **llama-swap** process on `:11500` — an
OpenAI-compatible endpoint whose `/v1/models` advertises `chat` and
`code`. Selecting a model in Open WebUI routes through llama-swap, which
starts that model's `llama-server` (and stops the previous one).
`docker/entrypoint.sh` resolves the backend binary + model files, writes
the llama-swap config, and `exec`s it. (In `hybrid` it serves just one
CPU model, `chat-cpu`; in `remote` it isn't started — see
[Backend](#backend).)

`searxng` is the third container — a self-hosted metasearch engine Open
WebUI calls only when a message has web search toggled on. `start.sh`
brings it up with the rest of the stack (in `remote` mode too).

## Build notes

The ROCm/Vulkan build stage in `docker/Dockerfile` is a vendored copy,
kept between `# BUILDSTAGE START` / `# END` markers and synced in from
outside this repo — edit the product tail below the markers, not the
block. The repo is otherwise self-contained. The `ai-net` Docker network
is created idempotently by `start.sh`.

## Docs

| File | For |
|---|---|
| `README.md` | this — install, use, configure |
| [`docs/HOST_PREREQUISITES.md`](docs/HOST_PREREQUISITES.md) | bare-metal host setup for local mode — do this first (remote/hybrid need only §6) |
| [`docs/remote-gpu.md`](docs/remote-gpu.md) | `backend.env`; local backend switching; remote + hybrid modes; remote-machine setup |
| `CLAUDE.md` | orientation + hard invariants for AI coding agents |

Session history: `git log`.
