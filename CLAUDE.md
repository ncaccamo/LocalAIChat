# CLAUDE.md — LocalAIChat

## What this is
On-demand local chat / general-purpose LLM serving: Open WebUI plus a
model-serving container, for interactive use unrelated to the
translation pipeline. Separate product from `BookTranslator` — not a
frontend for it, not dependent on it.

## Sibling projects — read this before assuming a dependency exists
- `BookTranslator` — separate product, separate repo. No build or
  runtime dependency in either direction. Not intended to run at the
  same time (both expect the full GPU).
- `BackendBuildstage` — offline sandbox for the ROCm/Vulkan build stage.
  Never a build or runtime dependency of this repo. The
  `# BUILDSTAGE START` / `# BUILDSTAGE END` block in `docker/Dockerfile`
  is now filled in — a byte-identical copy of
  `BackendBuildstage/Dockerfile.buildstage` (ROCm 7.2.4 + Vulkan dual
  llama.cpp build). This repo is fully self-contained. When the buildstage
  changes upstream, re-sync with
  `BackendBuildstage/sync_to_product.sh docker/Dockerfile` — it only
  touches the marked block, never the product-specific tail below it.

## Key invariants
- `restart: "no"` everywhere. Explicit `scripts/start.sh` /
  `scripts/stop.sh`, nothing auto-starts.
- `start.sh` checks for running `booktranslator-*` containers and warns
  (doesn't block) — this GPU is not sized for both projects running at
  once. The check is a no-op if BookTranslator isn't installed on this
  machine at all.
- Port range 11500–11501 — deliberately different from BookTranslator's
  11434/11435, purely for log/tooling legibility. Only `11500` is bound:
  `llama-swap` multiplexes both models onto it. `11501` is reserved,
  unused.
- `HOST_PREREQUISITES.md` in this repo is a full standalone copy of the
  host setup checklist, not a pointer to BookTranslator's — keep it that
  way so this repo never requires BookTranslator's docs to bring up a
  bare machine.
- Open WebUI is pinned to `v0.11.0`, not `latest`.

## Serving model (decided + built)
- **One model resident at a time.** `docker/entrypoint.sh` runs
  `llama-swap` as a single OpenAI-compatible endpoint on `11500`; its
  `/v1/models` lists `chat` + `code`. Selecting one in the Open WebUI
  dropdown stops the running `llama-server` and starts the other. VRAM
  never holds both (16 GB card).
- `entrypoint.sh` sets `LD_LIBRARY_PATH` for the chosen backend
  (`vulkan`|`rocm`), resolves model files (env → glob → download), writes
  `/tmp/llama-swap.config.yaml`, `exec`s llama-swap. It does not start a
  `llama-server` itself — llama-swap does, as children.
- Built and verified 2026-08-27 (RX 9070 XT): both models chat via Open
  WebUI, swap confirmed, conversations persist. See `README.md` →
  "Build status" and `HANDOFF.md` top section.

## Known open gaps
- `LLAMA_BACKEND=rocm` untested — only `vulkan` verified. Binaries for
  both are in the image; switching is a one-line `.env` change.
- Cold model load ~3.5 min (`~/llm_models` on slow disk). `llama-swap`
  `healthCheckTimeout` is 300 s to cover it.
- `CHAT_MODEL_FILE`/`CODE_MODEL_FILE` (`gpt-oss-20b`, `qwen2.5-coder-14b`)
  are still the placeholder picks — swap to taste; downloads happen on
  first start if the file is absent.
- Backend-mode config (local vs. remote GPU) not wired in — design is the
  "Backend Selection & Remote GPU" appendix at the bottom of `HANDOFF.md`.
  BookTranslator-first per that doc.

## Where to look for more
- `README.md` — directory structure, usage, "Build status".
- `HANDOFF.md` — LocalAIChat status (top), then BookTranslator's handoff
  copy, then the backend-selection design appendix.
