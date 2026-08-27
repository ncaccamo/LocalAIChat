# Backend Selection & Remote GPU — LocalAIChat

**Status: implemented and verified** (all three states, 2026-08-27).

`backend.env` is one config file that switches where inference runs —
local container vs. a `llama-server` on another LAN machine — and, in
local mode, which prebuilt backend binary is used. Switching local
backends is a restart, never a rebuild.

The full cross-project design spec and rationale lives in
`BackendBuildstage/BACKEND_SELECTION_HANDOFF.md`. This file is the
LocalAIChat-specific implementation. BookTranslator carries its own copy
of the same schema (duplicated by convention — no shared file).

---

## Schema (`backend.env`)

```
BACKEND_MODE=local            # local | remote

# --- BACKEND_MODE=local only ---
LLAMA_BACKEND=vulkan          # vulkan | rocm7 | rocm714

# --- BACKEND_MODE=remote only ---
REMOTE_HOST=                  # e.g. 192.168.1.50 — the remote machine's LAN address
REMOTE_PORT=11500
REMOTE_API_KEY=               # must match --api-key on the remote llama-server
```

`backend.env` is gitignored; `backend.env.example` is the committed
template. `scripts/start.sh` seeds it on first run, then sources +
validates it. Only one variable group is meaningful per mode; the other
is ignored.

## Local mode

`scripts/start.sh` → `docker compose up -d` (both services).
`docker/entrypoint.sh` maps `LLAMA_BACKEND` to a binary baked into the
image by the buildstage:

| `LLAMA_BACKEND` | binary | lib dir |
|---|---|---|
| `vulkan` | `/usr/local/bin/llama-server-vulkan` | `/usr/local/lib/llama-vulkan` |
| `rocm7` (or legacy `rocm`) | `/usr/local/bin/llama-server-rocm` | `/usr/local/lib/llama-rocm` |
| `rocm714` | — **fails fast** | not built (parked upstream) |

The entrypoint sets `LD_LIBRARY_PATH` to the matching lib dir (newer
llama.cpp links `libllama-server-impl.so` dynamically), writes
`/tmp/llama-swap.config.yaml`, and `exec`s llama-swap on `:11500`.
llama-swap spawns the `llama-server` children and they inherit the env.

Switching `vulkan` ↔ `rocm7`: edit `backend.env`, `scripts/stop.sh`,
`scripts/start.sh`. **No `docker compose build`** — both binaries are
already in the image.

`rocm714` is a valid config value from day one so nothing has to change
when it's un-parked; until then it exits with a message pointing at
`BackendBuildstage/ROCM714_NOTES.md` rather than silently falling back.

## Remote mode

`scripts/start.sh`:
- `docker compose rm -sf model-server` (in case it was running)
- exports `OWUI_OPENAI_BASE_URL=http://$REMOTE_HOST:$REMOTE_PORT/v1` and
  `OWUI_OPENAI_KEY=$REMOTE_API_KEY`
- `docker compose up -d --no-deps open-webui` — `--no-deps` so
  `open-webui`'s `depends_on` doesn't pull `model-server` back in

No local `llama-server` runs; `model-server` isn't even created.
`docker-compose.yml` reads those two `OWUI_*` vars (defaulting to the
local llama-swap endpoint) into Open WebUI's `OPENAI_API_BASE_URL` /
`OPENAI_API_KEY`. Open WebUI sends the key as `Authorization: Bearer …`,
which is exactly what a `llama-server --api-key` expects — so no proxy or
header-injection layer is needed.

There is **no model hot-swap** in remote mode: the remote serves whatever
single model it was launched with. `docker/entrypoint.sh` also handles
`BACKEND_MODE=remote` (log + idle) as defense in depth, in case the
container is ever started directly in this mode.

## Remote setup (the other machine)

Non-Docker, runs directly on the remote (e.g. a Windows gaming PC). No
code from this repo lives there.

1. Download a Vulkan build of llama.cpp (upstream publishes prebuilt
   binaries; Vulkan uses the GPU's gaming driver — no ROCm install on the
   remote). AMD also ships ROCm-validated Windows builds for more
   performance later, at the cost of installing ROCm runtime components.
2. Run it bound to the LAN, with auth:
   ```
   llama-server.exe -m your_model.gguf --host 0.0.0.0 --port 11500 --api-key <shared-secret>
   ```
3. Firewall: allow inbound TCP on that port, ideally scoped to this
   machine's IP rather than the whole LAN.
4. Give the remote a static IP / DHCP reservation so `REMOTE_HOST` doesn't
   go stale.
5. Start it manually before a chat session — same on-demand pattern as
   everything else here; no auto-start.

Then set `backend.env` to `BACKEND_MODE=remote` with matching
`REMOTE_HOST` / `REMOTE_PORT` / `REMOTE_API_KEY` and run
`scripts/start.sh`.

## Verification (2026-08-27)

- **local / vulkan** — banner `Backend: vulkan (llama-server-vulkan)`,
  completion returned.
- **local / rocm7** — edited `backend.env`, `stop`/`start`; image ID
  unchanged; banner `Backend: rocm7 (llama-server-rocm)`; completion
  returned from the ROCm binary; VRAM ~13 GB.
- **remote** — stand-in `llama-server --api-key testkey123` on
  `192.168.1.3`; `start.sh` brought up only `localaichat-webui` (no
  `model-server`); Open WebUI env set from `REMOTE_*`; the webui container
  reached the remote `/v1/models` with the bearer key; requests without /
  with a wrong key got 401.

Not yet tested against real remote hardware over the LAN — only the local
stand-in.
