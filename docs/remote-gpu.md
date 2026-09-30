# Backends & Remote GPU

`backend.env` (gitignored; `backend.env.example` is the template) is the
one knob for where inference runs. `scripts/start.sh` sources and
validates it on every run.

```
BACKEND_MODE=local            # local | hybrid | remote

# BACKEND_MODE=local only
LLAMA_BACKEND=vulkan          # vulkan | rocm7 | rocm714

# BACKEND_MODE=remote and hybrid
REMOTE_HOST=192.168.1.50
REMOTE_PORT=11500
REMOTE_API_KEY=<shared-secret>

# BACKEND_MODE=hybrid only
FALLBACK_MODEL_FILE=Qwen2.5-3B-Instruct-Q4_K_M.gguf
FALLBACK_CTX=8192
```

Only the variable groups its mode uses matter; the rest are ignored.

---

## Local mode

`start.sh` → `docker compose up -d` (both services). `docker/entrypoint.sh`
maps `LLAMA_BACKEND` to a binary the buildstage baked into the image:

| `LLAMA_BACKEND` | binary | lib dir |
|---|---|---|
| `vulkan` | `/usr/local/bin/llama-server-vulkan` | `/usr/local/lib/llama-vulkan` |
| `rocm7` (or legacy `rocm`) | `/usr/local/bin/llama-server-rocm` | `/usr/local/lib/llama-rocm` |
| `rocm714` | — **fails fast** | not built (parked upstream) |

The entrypoint sets `LD_LIBRARY_PATH` to the matching lib dir, writes
`/tmp/llama-swap.config.yaml`, and `exec`s llama-swap on `:11500`.

Switching `vulkan` ↔ `rocm7`: edit `backend.env`, then `scripts/stop.sh`
&& `scripts/start.sh`. **No `docker compose build`** — both binaries are
already in the image.

`rocm714` is a valid value from day one so nothing changes when it's
un-parked. Until then it exits with an error rather than silently falling back.
It's parked because the ROCm 7.14 preview wheel ships no
`hip-lang-config.cmake`, so CMake can't configure a HIP build.

---

## Remote mode

Point Open WebUI at a `llama-server` on another LAN machine (e.g.
`llama-server.exe` on a Windows gaming PC using its GPU via Vulkan).

`start.sh` in this mode:

- `docker compose rm -sf model-server` (in case it was running)
- exports `OWUI_OPENAI_BASE_URLS=http://$REMOTE_HOST:$REMOTE_PORT/v1` and
  `OWUI_OPENAI_KEYS=$REMOTE_API_KEY` (the plural Open WebUI vars — a
  one-entry list in this mode)
- `docker compose up -d --no-deps open-webui searxng` — `--no-deps` so
  `open-webui`'s `depends_on` doesn't pull `model-server` back in;
  `searxng` is named explicitly so web search still works remote

No local `llama-server` runs and `model-server` isn't created.
`docker-compose.yml` feeds the `OWUI_*` vars into Open WebUI's
`OPENAI_API_BASE_URLS` / `OPENAI_API_KEYS` (a one-entry list here); Open
WebUI sends the key as `Authorization: Bearer …`, which is what
`llama-server --api-key` expects — no proxy or header-injection layer
needed.

Whether the remote hot-swaps models is up to the remote: a bare
`llama-server` serves one, a remote running its own `llama-swap` (as the
gaming PC does) serves several. `docker/entrypoint.sh` treats
`BACKEND_MODE=remote` as "log and idle", as defense in depth.

---

## Hybrid mode

Remote GPU **plus** an always-on local CPU chat model, for a deploy where
the GPU system gets powered off (e.g. a homelab whose GPU lives on a Windows
gaming PC). Open WebUI is pointed at **both** endpoints and merges their
model lists; when the GPU system is off its models drop from the dropdown
and the CPU one stays.

`start.sh` in this mode:

- exports
  `OWUI_OPENAI_BASE_URLS=http://$REMOTE_HOST:$REMOTE_PORT/v1;http://model-server:11500/v1`
  and the paired `OWUI_OPENAI_KEYS=$REMOTE_API_KEY;sk-local`
- `docker compose up -d` — **all** services. `model-server` here runs the
  portable **`llama-server-cpu`** binary (never the GPU ones —
  `LLAMA_BACKEND` is ignored in hybrid) serving one model, `chat-cpu`,
  via llama-swap on `:11500`.

`docker/entrypoint.sh` fetches `FALLBACK_MODEL_FILE` into the models dir
on first run if absent (default `Qwen2.5-3B-Instruct-Q4_K_M`, chat-only —
a CPU coder is too slow to bother with; swap to a 7B via
`FALLBACK_MODEL_FILE` for more standalone knowledge at fewer tok/s).

The homelab **never** contacts the GPU system except through Open WebUI's
normal model-list / completion calls — no health poll, no wake-on-LAN.
`AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST` (compose, default 5 s) caps how long a
powered-off system can stall the dropdown.

Model IDs: the remote advertises `chat` / `code`; the local fallback is
`chat-cpu` — distinct on purpose, so the dropdown always shows which one
you're on. Open WebUI displays each model's `name` field (from the
upstream `/v1/models`) and falls back to the id when there is none — so a
remote llama-swap whose models carry only keys shows a bare `chat` /
`code`. Give them `name:` fields to see the real model in the dropdown
(see [Setting up the remote machine](#setting-up-the-remote-machine));
the local `chat-cpu` already reports `name` = its file (e.g.
`Qwen2.5-3B-Instruct (CPU)`).

Reverting `hybrid` → `remote` is a `backend.env` edit + `stop`/`start`,
no rebuild. The `cpu` binary stays in the image, unused.

**Why Open WebUI queries both endpoints directly:** the alternative was a
local llama-swap that passes requests through to the remote. Rejected —
llama-swap can't inject the remote's `Authorization` header, and its
`/v1/models` would keep listing the GPU models even when the remote
system is off, which defeats the point of hybrid. Likewise no coder model
on the CPU side: a 14B coder runs at ~3 tok/s, not worth the always-on
RAM/disk cost.

### GPU-less host

`docker-compose.yml` always mounts `/dev/kfd` + `/dev/dri` and joins the
`video`/`render` groups on `model-server` — needed for `local`, dead
weight (but a hard startup failure) on a system with no AMD GPU, which is the
normal hybrid deploy. Fix once:

```
cp docker-compose.override.yml.example docker-compose.override.yml
```

Compose auto-loads `docker-compose.override.yml` from the repo root; it
`!reset`s the device/group wiring for `model-server` only. The live file
is gitignored (host-specific, like `.env` / `backend.env`); add other
host-specific tweaks here if needed (a `restart:` policy, say — but set
model / data paths via `LLM_MODELS_DIR` / `OWUI_DATA_DIR` in `.env`, not
here). Do **not** use it in `local` mode — it removes the GPU access `local`
needs. (`remote` never starts `model-server`, so it neither needs nor is
harmed by the override.)

### Setting up the remote machine

Non-Docker, runs directly on the remote. No code from this repo lives
there.

1. Download a Vulkan build of llama.cpp (upstream publishes prebuilt
   binaries; Vulkan uses the GPU's gaming driver — no ROCm install on the
   remote). AMD also ships ROCm-validated Windows builds for more
   performance later, at the cost of installing ROCm runtime components.
2. Run it bound to the LAN, with auth:
   ```
   llama-server.exe -m your_model.gguf --host 0.0.0.0 --port 11500 --api-key <shared-secret>
   ```
   A bare `llama-server` serves one model; to offer several (and to match
   this project's `chat` / `code` ids) run **llama-swap** there instead.
   Give each entry a `name:` so the homelab dropdown shows the real model,
   not a bare `chat` / `code`:
   ```yaml
   models:
     "chat":
       name: "gpt-oss-20b"
       cmd: llama-server.exe -m ...\gpt-oss-20b.gguf --port ${PORT} --api-key <shared-secret>
     "code":
       name: "qwen2.5-coder-14b"
       cmd: llama-server.exe -m ...\Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf --port ${PORT} --api-key <shared-secret>
   ```
   Keep the ids `chat` / `code` — hybrid mode needs them distinct from the
   local `chat-cpu`.
3. Firewall: allow inbound TCP on that port, ideally scoped to this
   machine's IP rather than the whole LAN.
4. Give the remote a static IP / DHCP reservation so `REMOTE_HOST`
   doesn't go stale.
5. Start it manually before a chat session — same on-demand pattern as
   everything else here.

Then set `backend.env` to `BACKEND_MODE=remote` (or `hybrid`) with
matching `REMOTE_HOST` / `REMOTE_PORT` / `REMOTE_API_KEY` and run
`scripts/start.sh`.

---

## Image generation (optional)

Open WebUI can drive image generation from the same chat interface, through
a second, independent backend — unrelated to the `chat` / `code` endpoints
above. `ENABLE_IMAGE_GENERATION` / `IMAGE_GENERATION_ENGINE` /
`AUTOMATIC1111_BASE_URL` (`.env`) are all this repo owns; the backend itself
runs entirely outside it — same "no code from this repo lives there"
boundary as the remote llama-server.

Recommended engine: **[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)**'s
`sd-server` — same `ggml` foundation as llama.cpp, Vulkan-native (no
ROCm / PyTorch / DirectML detour needed on a Windows remote), and GGUF
weight support for the same quantize-to-fit-VRAM tradeoff already used for
`chat` / `code`. It exposes a compatibility API at `/sdapi/v1/...`, which
is what `IMAGE_GENERATION_ENGINE=automatic1111` means below — a wire
protocol, **not** the actual AUTOMATIC1111 webui (that project's last real
commit was mid-2024; nothing from it runs here).

```
ENABLE_IMAGE_GENERATION=true
IMAGE_GENERATION_ENGINE=automatic1111
AUTOMATIC1111_BASE_URL=http://<remote-host>:<port>
```

`ENABLE_IMAGE_PROMPT_GENERATION` defaults **false**: Open WebUI can
optionally have the currently-loaded chat model expand a short prompt
before generating, but that pulls `chat`/`code` into every image request.
Off means an image request never touches the chat model at all — no
dependency, and no extra model swap if the remote serves both from one GPU.

Whether `sd-server` runs as its own manually-started process or as another
entry in an existing llama-swap instance on the remote is a deployment
choice this repo doesn't make — see [Deployment lifecycle](#deployment-lifecycle--on-demand-vs-always-on)
below for the on-demand-vs-always-on tradeoffs that apply either way.

---

## Deployment lifecycle — on-demand vs. always-on

The base `docker-compose.yml` ships `restart: "no"` on all three
services: on-demand, `scripts/start.sh` / `scripts/stop.sh` the only
entry points, nothing back after a reboot. That is the right default for
a workstation and stays the default. Whether a particular deployment
should instead run **always-on** turns on one question — **is this
system's GPU dedicated to LocalAIChat, or shared with other work** — and
two independent knobs: the compose `restart:` policy, and llama-swap's
`ttl` (seconds of idle before a loaded model is unloaded and its VRAM
freed; `0` = never).

| Deployment | GPU on this system | `restart:` | `ttl` | Lifecycle |
|---|---|---|---|---|
| **Homelab** (`remote` / `hybrid`) | none — GPU is a separate system (or only the tiny `chat-cpu` fallback runs here) | `unless-stopped` | n/a locally; the remote owns its own | boots with the host. The remote GPU system is still started by hand — same on-demand pattern, just on the other system. |
| **Dedicated local server** (`local`) | yes, and the system does nothing else | `unless-stopped` | non-zero — let an idle model release VRAM even though the stack stays up | boots with the host |
| **Multipurpose system** (`local` on a gaming PC / workstation) | yes, shared with games / other GPU work | `"no"` (the shipped default) | optional non-zero — lets you leave the stack up between chat sessions without a model squatting in VRAM | manual `scripts/start.sh` / `scripts/stop.sh`; **never auto-resurrects on boot** |

**Why GPU ownership decides it.** The homelab always-on component
(`open-webui` + `searxng`, plus `model-server` on the CPU-only binary in
`hybrid`) never touches a GPU, so always-on costs a little RAM and
nothing else — a clear win for "there when I want it". On a system whose
GPU is shared, the always-on container *is* the GPU holder; `restart:
unless-stopped` also means the stack comes back on every boot, so you
boot to game and the inference stack is running anyway. Manual
start/stop is the explicit "the GPU is mine again" boundary.

**Why `ttl` is not a full substitute for stopping.** A non-zero `ttl`
unloads *idle* models, but any incoming request — a stray Open WebUI tab,
the dropdown polling `/v1/models`, a phone left logged in — still
triggers a full model load: a CPU + disk + PCIe spike, not just VRAM.
With the stack down that request has nothing to hit. So `ttl` is a good
fit for a *dedicated* server (frees VRAM between uses, no one else cares
about a background load) and a convenience on a *multipurpose* system
(leave it up within an uptime), but it does not make always-on safe
there.

**Applying it.** Always-on is opt-in and host-specific:

```
cp docker-compose.override.yml.example docker-compose.override.yml
```

The shipped example sets `restart: unless-stopped` on all three services
(and `!reset`s `model-server`'s GPU wiring for a GPU-less `hybrid` host —
see [GPU-less host](#gpu-less-host)). Delete the three `restart:` lines to
keep the on-demand default. `ttl` currently has no env knob — it is
written as `ttl: 0` into the llama-swap config `docker/entrypoint.sh`
generates (both the `local` and `hybrid` heredocs); change that value and
`docker compose build` for idle-unload.
