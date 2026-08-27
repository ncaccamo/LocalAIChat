#!/usr/bin/env bash
set -euo pipefail

# LocalAIChat model-server entrypoint.
#
# Unlike BookTranslator (whose pipeline scripts own server lifecycle), this
# project serves interactive chat through Open WebUI, so it needs a
# long-lived front door. That front door is llama-swap: one
# OpenAI-compatible listener on $LISTEN_PORT that hot-swaps a single
# resident llama-server between the configured models. Selecting a
# different model in the Open WebUI dropdown makes llama-swap stop the
# running model and start the new one -- only one is in VRAM at a time,
# which is what fits the 16 GB RX 9070 XT.
#
# BACKEND_MODE (from backend.env, passed through by scripts/start.sh):
#   local  - run llama-swap here; LLAMA_BACKEND picks the prebuilt binary.
#   remote - serve nothing; Open WebUI talks straight to REMOTE_HOST. This
#            container is normally not even started in remote mode; the
#            branch below is just defense in depth.
#
# In local mode this entrypoint:
#   1. maps LLAMA_BACKEND (vulkan|rocm7|rocm714) to a prebuilt binary + libdir
#   2. resolves the two model files (env path, else glob in /models)
#   3. downloads either model if missing (first-run convenience)
#   4. writes /tmp/llama-swap.config.yaml from those values
#   5. exec's llama-swap
#
# It never starts a llama-server directly -- llama-swap spawns them as
# children and inherits the LD_LIBRARY_PATH exported here.

# ---------------------------------------------------------------------------
# 0. Backend mode
# ---------------------------------------------------------------------------
: "${BACKEND_MODE:=local}"
case "$BACKEND_MODE" in
    local) ;;
    remote)
        echo "[INFO] BACKEND_MODE=remote -- model-server serves nothing."
        echo "       Open WebUI is pointed straight at the remote llama-server"
        echo "       (\${REMOTE_HOST}:\${REMOTE_PORT}). scripts/start.sh normally"
        echo "       does not start this container in remote mode."
        exec tail -f /dev/null ;;
    *)
        echo "[FATAL] BACKEND_MODE='$BACKEND_MODE' invalid -- want 'local' or 'remote'." >&2
        exit 1 ;;
esac

LISTEN_PORT="${LISTEN_PORT:-11500}"
MODELS_DIR="${MODELS_DIR:-/models}"

CHAT_MODEL_PATH="${CHAT_MODEL_PATH:-$MODELS_DIR/gpt-oss-20b.gguf}"
CODE_MODEL_PATH="${CODE_MODEL_PATH:-$MODELS_DIR/qwen2.5-coder-14b.gguf}"

# Context sizes per model -- override via compose environment if needed.
CHAT_CTX="${CHAT_CTX:-8192}"
CODE_CTX="${CODE_CTX:-16384}"

# HF download URLs used only when the file is absent. Placeholders per
# README ("confirm before first real run"); change the *_MODEL_FILE in
# .env plus these URLs together if you switch models.
CHAT_MODEL_URL="${CHAT_MODEL_URL:-https://huggingface.co/ggml-org/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-MXFP4.gguf}"
CODE_MODEL_URL="${CODE_MODEL_URL:-https://huggingface.co/bartowski/Qwen2.5-Coder-14B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf}"

# ---------------------------------------------------------------------------
# 1. Backend binary selection
# ---------------------------------------------------------------------------
# LLAMA_BACKEND is the config-facing name; BE is the on-disk suffix that the
# buildstage produced (llama-server-<BE>, /usr/local/lib/llama-<BE>/).
: "${LLAMA_BACKEND:=vulkan}"
case "$LLAMA_BACKEND" in
    vulkan)      BE=vulkan ;;
    rocm7|rocm)  BE=rocm ;;
    rocm714)
        echo "[FATAL] LLAMA_BACKEND=rocm714 is not built into this image." >&2
        echo "        The ROCm 7.14 llama.cpp build is parked (the preview wheel" >&2
        echo "        ships no hip-lang-config.cmake). Build + smoke-test it in" >&2
        echo "        BackendBuildstage first, then re-sync the buildstage here." >&2
        echo "        See BackendBuildstage/ROCM714_NOTES.md." >&2
        exit 1 ;;
    *)
        echo "[WARN] Unknown LLAMA_BACKEND='$LLAMA_BACKEND' -- defaulting to vulkan"
        LLAMA_BACKEND=vulkan; BE=vulkan ;;
esac

LLAMA_SERVER_BIN="/usr/local/bin/llama-server-$BE"
if [ ! -x "$LLAMA_SERVER_BIN" ]; then
    echo "[WARN] $LLAMA_SERVER_BIN missing -- falling back to vulkan"
    LLAMA_BACKEND=vulkan; BE=vulkan
    LLAMA_SERVER_BIN="/usr/local/bin/llama-server-vulkan"
fi
[ -x "$LLAMA_SERVER_BIN" ] || { echo "[FATAL] no usable llama-server binary"; exit 1; }

# Newer llama.cpp links libllama-server-impl.so (etc.) dynamically from a
# backend-specific dir. llama-swap's child processes inherit this.
export LD_LIBRARY_PATH="/usr/local/lib/llama-$BE:${LD_LIBRARY_PATH:-}"

NTHREADS="${NTHREADS:-$(nproc)}"

# ---------------------------------------------------------------------------
# 2 + 3. Resolve + fetch model files
# ---------------------------------------------------------------------------
resolve_model () {  # $1=configured_path  $2=glob  -> prints a path
    local want="$1" glob="$2" hit
    if [ -f "$want" ]; then echo "$want"; return; fi
    hit="$(find "$MODELS_DIR" -maxdepth 1 -type f -iname "$glob" -print -quit 2>/dev/null || true)"
    if [ -n "$hit" ]; then
        echo "[INFO] $want not found; using match: $hit" >&2
        echo "$hit"
    else
        echo "$want"   # caller will try to download to this name
    fi
}

fetch_if_missing () {  # $1=path  $2=url  $3=label
    local path="$1" url="$2" label="$3"
    [ -f "$path" ] && { echo "[OK] $label: $path"; return; }
    if [ -z "$url" ]; then
        echo "[FATAL] $label missing ($path) and no download URL set." >&2
        echo "        Put the .gguf in ~/llm_models and set the *_MODEL_FILE in .env." >&2
        exit 1
    fi
    echo "[..] Downloading $label -> $path"
    echo "     $url"
    # -c resumes a half-finished .partial from a previous interrupted run.
    wget -c --progress=bar:force:noscroll --tries=5 -O "$path.partial" "$url"
    mv "$path.partial" "$path"
    echo "[OK] $label downloaded"
}

CHAT_MODEL_PATH="$(resolve_model "$CHAT_MODEL_PATH" '*gpt-oss*20b*.gguf')"
CODE_MODEL_PATH="$(resolve_model "$CODE_MODEL_PATH" '*qwen2.5*coder*14b*.gguf')"

fetch_if_missing "$CHAT_MODEL_PATH" "$CHAT_MODEL_URL" "chat model"
fetch_if_missing "$CODE_MODEL_PATH" "$CODE_MODEL_URL" "code model"

# ---------------------------------------------------------------------------
# 4. Generate llama-swap config
# ---------------------------------------------------------------------------
# gpt-oss speaks the harmony format -- llama-server needs --jinja for it.
CFG=/tmp/llama-swap.config.yaml
cat > "$CFG" <<EOF
# Generated by docker/entrypoint.sh on container start -- do not edit here.
# Mode: $BACKEND_MODE   Backend: $LLAMA_BACKEND -> $LLAMA_SERVER_BIN
healthCheckTimeout: 300
logLevel: info
startPort: 5800

models:
  "chat":
    name: "gpt-oss-20b (chat)"
    cmd: |
      $LLAMA_SERVER_BIN
      --model $CHAT_MODEL_PATH
      --host 127.0.0.1 --port \${PORT}
      --ctx-size $CHAT_CTX
      --n-gpu-layers 999
      --threads $NTHREADS
      --jinja
    ttl: 0

  "code":
    name: "qwen2.5-coder-14b (code)"
    cmd: |
      $LLAMA_SERVER_BIN
      --model $CODE_MODEL_PATH
      --host 127.0.0.1 --port \${PORT}
      --ctx-size $CODE_CTX
      --n-gpu-layers 999
      --threads $NTHREADS
    ttl: 0
EOF

echo "========================================================"
echo "  LocalAIChat model-server"
echo "  Mode    : $BACKEND_MODE"
echo "  Backend : $LLAMA_BACKEND  ($LLAMA_SERVER_BIN)"
echo "  chat    : $CHAT_MODEL_PATH (ctx $CHAT_CTX)"
echo "  code    : $CODE_MODEL_PATH (ctx $CODE_CTX)"
echo "  Listen  : 0.0.0.0:$LISTEN_PORT  (OpenAI-compatible, via llama-swap)"
echo "  Models load on demand -- only one resident at a time."
echo "========================================================"

# ---------------------------------------------------------------------------
# 5. Run
# ---------------------------------------------------------------------------
exec llama-swap --config "$CFG" --listen "0.0.0.0:$LISTEN_PORT"
