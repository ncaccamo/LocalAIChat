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

Related to BookTranslator's `backend.env` by convention, not kept
identical — the shared keys (`BACKEND_MODE`, `LLAMA_BACKEND`, `REMOTE_*`)
stay aligned, but `hybrid` is LocalAIChat-only.

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
un-parked. Until then it exits with a pointer to
`BackendBuildstage/ROCM714_NOTES.md` rather than silently falling back.

---

## Remote mode

Point Open WebUI at a `llama-server` on another LAN machine (e.g.
`llama-server.exe` on a Windows gaming PC using its GPU via Vulkan).

`start.sh` in this mode:

- `docker compose rm -sf model-server` (in case it was running)
- exports `OWUI_OPENAI_BASE_URL=http://$REMOTE_HOST:$REMOTE_PORT/v1` and
  `OWUI_OPENAI_KEY=$REMOTE_API_KEY`
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
the GPU box gets powered off (e.g. a homelab whose GPU lives on a Windows
gaming PC). Open WebUI is pointed at **both** endpoints and merges their
model lists; when the GPU box is off its models drop from the dropdown
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

The homelab **never** contacts the GPU box except through Open WebUI's
normal model-list / completion calls — no health poll, no wake-on-LAN.
`AIOHTTP_CLIENT_TIMEOUT_MODEL_LIST` (compose, default 5 s) caps how long a
powered-off box can stall the dropdown.

Model IDs: the remote advertises `chat` / `code`; the local fallback is
`chat-cpu` — distinct on purpose, so the dropdown always shows which one
you're on.

Reverting `hybrid` → `remote` is a `backend.env` edit + `stop`/`start`,
no rebuild. The `cpu` binary stays in the image, unused.

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

The full cross-project design + rationale is in
`BackendBuildstage/BACKEND_SELECTION_HANDOFF.md`. What's been verified
here is in `docs/STATUS.md`.
