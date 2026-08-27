# LocalAIChat

On-demand local chat / general-purpose LLM serving (Open WebUI + model
backends). Sibling project to `BookTranslator` — deliberately **fully
independent from a setup perspective**. Either project can be deployed
alone, on a machine that has never seen the other, with no missing
dependency.

---

## Relationship to other projects

This machine currently hosts two things: `BookTranslator` (HEMA manual
translation pipeline) and `LocalAIChat` (this project). They are siblings,
not a client/dependency pair.

**What is NOT shared (by design):**
- No shared base Docker image. This project's `docker/Dockerfile` builds
  its own ROCm+Vulkan llama.cpp stage — it does not `FROM` anything that
  lives in BookTranslator's repo. If you only ever deploy LocalAIChat on
  a given machine, BookTranslator's code is never required to exist
  there.
- No shared host-prerequisites doc. See `HOST_PREREQUISITES.md` in this
  repo — it's a full, standalone copy, not a pointer to BookTranslator's.
- No shared compose file, containers, or Python code.

**What IS shared, and why it's safe to share:**
- The Docker network name `ai-net`. This is a naming convention, not a
  file dependency — `scripts/start.sh` creates it idempotently if it
  doesn't already exist. A solo LocalAIChat deployment just creates it
  fresh and never notices BookTranslator doesn't exist on that machine.
- Port-numbering convention (this project's range is 11500–11501, distinct
  from BookTranslator's 11434/11435) — purely for log/tooling legibility
  if both happen to be installed on the same box, not a functional link.
  Only `11500` is actually bound (llama-swap multiplexes both models onto
  it); `11501` is reserved but unused.
- The physical GPU, on machines where both happen to be installed. Not a
  setup dependency, a runtime scheduling fact — see "Usage pattern" below.

**The tradeoff this buys, and its cost:** the ROCm+Vulkan build stage
inside `docker/Dockerfile` is real, previously-debugged work (see
BookTranslator's HANDOFF.md — hip-lang-config.cmake issues, backend
selection, a parked ROCm 7.14 attempt). Keeping both projects independent
means that build stage is **duplicated**, not centralized. When you
upgrade ROCm or llama.cpp, you patch it in one project and manually copy
the same block into the other. That's a real, ongoing cost — accepted
deliberately in exchange for either project being deployable completely
on its own.

## Assumptions baked into this skeleton

- **On-demand only, not continuous.** Every service uses `restart: "no"`.
  Nothing auto-starts on boot or after a crash. Explicit `start.sh` /
  `stop.sh`, matching the pattern BookTranslator's pipeline already moved
  to.
- **Not intended to run at the same time as BookTranslator on a shared
  GPU.** `scripts/start.sh` checks for running `booktranslator-*`
  containers and warns (doesn't block). This check is a no-op — not an
  error — on a machine where BookTranslator was never installed.
- **Host prerequisites are documented in this repo directly** —
  `HOST_PREREQUISITES.md` — so this project doesn't require reading
  BookTranslator's docs to bring up a bare machine.
- **Model choices below are placeholders** (`gpt-oss-20b` general chat,
  `qwen2.5-coder-14b` coding), carried over from earlier planning notes —
  confirm before first real run. If a file is absent on start, the
  container downloads it once into `~/llm_models`.
- **One model resident at a time.** The 16 GB RX 9070 XT can't hold both,
  so `docker/entrypoint.sh` runs [llama-swap](https://github.com/mostlygeek/llama-swap)
  as a single OpenAI-compatible endpoint on `11500`. Its `/v1/models`
  advertises both `chat` and `code`; picking one in the Open WebUI
  dropdown stops the running `llama-server` and starts the other.
- **Models live in `~/llm_models`** (bind-mounted), shared with
  BookTranslator by directory-naming convention — not a repo/build
  dependency. A solo deployment just creates the dir. There is no in-repo
  `models/` folder; `docker/entrypoint.sh` downloads missing `.gguf`
  files into the mount on first start.
- **Open WebUI version is pinned** (`v0.11.0`), not `latest`, so an
  upstream update doesn't silently change behavior.

## Directory structure

```
LocalAIChat/
├── README.md                   # this file
├── HOST_PREREQUISITES.md        # standalone — no dependency on BookTranslator's copy
├── .gitignore
├── .env.example                 # copy to .env and edit before first run
├── docker-compose.yml
├── docker/
│   ├── Dockerfile               # self-contained — ROCm+Vulkan build stage
│   │                             # (synced buildstage block) + llama-swap tail
│   └── entrypoint.sh            # resolves backend/models, writes llama-swap
│   │                             # config, exec's llama-swap
├── scripts/
│   ├── start.sh                  # seeds .env, creates ai-net if missing, warns
│   │                              # (not blocks) on BookTranslator, compose up
│   └── stop.sh                   # docker compose down
└── config/                       # Open WebUI persistent data (gitignored)
```

`.gguf` files are **not** in this repo — they live in `~/llm_models`
(bind-mounted to `/models`), downloaded on first start if absent.

## Usage

```bash
cp .env.example .env          # start.sh also does this if you skip it
# edit .env: confirm CHAT_MODEL_FILE / CODE_MODEL_FILE, check GPU GIDs

docker compose build          # first time only (~ROCm+Vulkan+llama.cpp build)
bash scripts/start.sh
docker compose logs -f model-server   # watch first-run model download
# Open WebUI: http://localhost:3000  — create an account, pick a model

bash scripts/stop.sh
# frees the GPU
```

## Build status

Verified end-to-end on `nicholas-Ubuntu-AI` (RX 9070 XT, gfx1201) on
2026-08-27:

- `docker compose build` — buildstage layers all cache-hit from
  BookTranslator's image; only the llama-swap tail built.
- First run downloaded `gpt-oss-20b-MXFP4.gguf` (12.1 GB) and
  `Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf` (9 GB) into `~/llm_models`.
- llama-swap up on `:11500`; `/v1/models` lists `chat` + `code`; Open
  WebUI (`:3000`, healthy) sees both.
- `chat` inference: ~160 tok/s prompt, ~110–150 tok/s gen (Vulkan).
- `code` inference: `lambda x: x**2`, ~286 tok/s prompt, ~60 tok/s gen.
- **Swap confirmed**: requesting `code` tore down the `chat` llama-server
  and started `code`; VRAM stayed ~13 GB (one model resident), never
  doubled.

Implemented:

- `docker/Dockerfile` — buildstage block synced from
  `BackendBuildstage/Dockerfile.buildstage` (byte-identical), plus a
  product-specific tail that installs llama-swap and wires the entrypoint.
- `docker/entrypoint.sh` — resolves `LLAMA_BACKEND` (`vulkan`/`rocm`) and
  its `LD_LIBRARY_PATH`, resolves the two model files (env path → glob →
  download), generates `/tmp/llama-swap.config.yaml`, exec's llama-swap.
- `docker-compose.yml` — carries over BookTranslator's GPU fixes
  (`HSA_OVERRIDE_GFX_VERSION=12.0.1`, numeric `video`/`render` GIDs,
  `user:` mapping), single `11500` port, shared `~/llm_models` mount,
  `restart: "no"`. Open WebUI points at the one llama-swap endpoint.
- Open WebUI auth: `WEBUI_AUTH` confirmed current for v0.11.x.

Notes / rough edges:

- **Cold model load is ~3.5 min** — `~/llm_models` is on a slow disk and
  llama.cpp mmap-faults the whole file in. `llama-swap`'s
  `healthCheckTimeout` is set to 300 s to cover it; a shorter timeout
  would fail the first request. Faster storage for `~/llm_models` is the
  real fix.
- gpt-oss is a reasoning model (harmony format) — it emits a
  `reasoning_content` channel before the answer, so give it a real token
  budget. Open WebUI renders the split natively.

Still open:

- **Backend-selection / remote-GPU config** (`backend.env` schema in
  `HANDOFF.md` §Backend Selection) — deferred; do BookTranslator first
  per that doc's suggested order.
- When BookTranslator's ROCm/Vulkan build stage changes, sync it here via
  `BackendBuildstage/sync_to_product.sh docker/Dockerfile` — no automated
  link between the two Dockerfiles by design.
