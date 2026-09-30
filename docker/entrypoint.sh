#!/usr/bin/env bash
set -euo pipefail

# LocalAIChat model-server entrypoint.
#
# Unlike FencingManualTranslator (whose pipeline scripts own server lifecycle), this
# project serves interactive chat through Open WebUI, so it needs a
# long-lived front door. That front door is llama-swap: one
# OpenAI-compatible listener on $LISTEN_PORT that hot-swaps a single
# resident llama-server between the configured models. Selecting a
# different model in the Open WebUI dropdown makes llama-swap stop the
# running model and start the new one -- only one is in VRAM at a time,
# which is what fits the 16 GB RX 9070 XT.
#
# BACKEND_MODE (from backend.env, passed through by scripts/start.sh):
#   local  - run llama-swap here serving chat + code; LLAMA_BACKEND picks
#            the prebuilt GPU binary.
#   hybrid - GPU is a remote system (Open WebUI talks to it directly). This
#            container serves ONLY a small always-on CPU chat fallback so
#            something answers when that system is powered off. Always the
#            portable cpu binary; LLAMA_BACKEND is ignored. Handled in the
#            0b block below, which exec's llama-swap and never returns.
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
    local|hybrid) ;;
    remote)
        echo "[INFO] BACKEND_MODE=remote -- model-server serves nothing."
        echo "       Open WebUI is pointed straight at the remote llama-server"
        echo "       (\${REMOTE_HOST}:\${REMOTE_PORT}). scripts/start.sh normally"
        echo "       does not start this container in remote mode."
        exec tail -f /dev/null ;;
    *)
        echo "[FATAL] BACKEND_MODE='$BACKEND_MODE' invalid -- want 'local', 'hybrid' or 'remote'." >&2
        exit 1 ;;
esac

LISTEN_PORT="${LISTEN_PORT:-11500}"
MODELS_DIR="${MODELS_DIR:-/models}"

# Dropdown label for a model: the .gguf's basename with the extension and a
# trailing quant tag trimmed, plus an optional role suffix. Open WebUI shows
# llama-swap's `name` field verbatim, so this is what the user sees and picks
# -- derived from the actual file in use, never a hardcoded guess.
#   friendly_name /models/gpt-oss-20b.gguf "(chat)"          -> gpt-oss-20b (chat)
#   friendly_name /models/Qwen2.5-3B-Instruct-Q4_K_M.gguf "(CPU)" -> Qwen2.5-3B-Instruct (CPU)
friendly_name () {
    local n="${1##*/}"; n="${n%.gguf}"
    if [[ "$n" =~ ^(.+)[-.](I?Q[0-9]+([_-][0-9A-Za-z]+)*|f16|bf16|fp16|f32)$ ]]; then
        n="${BASH_REMATCH[1]}"
    fi
    [ -n "${2:-}" ] && n="$n $2"
    printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# 0b. Hybrid mode -- serve ONLY the always-on CPU fallback, then exec.
# ---------------------------------------------------------------------------
# The GPU models (chat, code) live on a remote system and reach Open WebUI
# directly; this process just keeps one small chat model on the CPU so the
# dropdown is never empty. Portable cpu binary, single model, no GPU.
if [ "$BACKEND_MODE" = "hybrid" ]; then
    NTHREADS="${NTHREADS:-$(nproc)}"
    FALLBACK_MODEL_PATH="${FALLBACK_MODEL_PATH:-$MODELS_DIR/Qwen2.5-3B-Instruct-Q4_K_M.gguf}"
    FALLBACK_CTX="${FALLBACK_CTX:-8192}"
    FALLBACK_MODEL_URL="${FALLBACK_MODEL_URL:-https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf}"

    LLAMA_SERVER_BIN=/usr/local/bin/llama-server-cpu
    if [ ! -x "$LLAMA_SERVER_BIN" ]; then
        echo "[FATAL] $LLAMA_SERVER_BIN missing -- this image predates the portable" >&2
        echo "        CPU build (BackendBuildstage v2026.09.06). Rebuild the image:" >&2
        echo "        docker compose build" >&2
        exit 1
    fi
    # Core libs (libllama.so etc.) load from here; the per-microarch
    # ggml-cpu dispatch libs are found via GGML_BACKEND_DIR baked into the
    # binary at build time (it does NOT search LD_LIBRARY_PATH for those).
    export LD_LIBRARY_PATH="/usr/local/lib/llama-cpu:${LD_LIBRARY_PATH:-}"

    if [ ! -f "$FALLBACK_MODEL_PATH" ]; then
        hit="$(find "$MODELS_DIR" -maxdepth 1 -type f -iname '*qwen2.5*3b*instruct*.gguf' -print -quit 2>/dev/null || true)"
        if [ -n "$hit" ]; then
            echo "[INFO] $FALLBACK_MODEL_PATH not found; using match: $hit"
            FALLBACK_MODEL_PATH="$hit"
        fi
    fi
    if [ ! -f "$FALLBACK_MODEL_PATH" ]; then
        [ -n "$FALLBACK_MODEL_URL" ] || { echo "[FATAL] fallback model missing ($FALLBACK_MODEL_PATH) and no FALLBACK_MODEL_URL." >&2; exit 1; }
        echo "[..] Downloading fallback model -> $FALLBACK_MODEL_PATH"
        echo "     $FALLBACK_MODEL_URL"
        wget -c --progress=bar:force:noscroll --tries=5 -O "$FALLBACK_MODEL_PATH.partial" "$FALLBACK_MODEL_URL"
        mv "$FALLBACK_MODEL_PATH.partial" "$FALLBACK_MODEL_PATH"
    fi
    echo "[OK] fallback model: $FALLBACK_MODEL_PATH"

    # Dropdown label -- file's name with "(CPU)" appended, e.g.
    # Qwen2.5-3B-Instruct-Q4_K_M.gguf -> "Qwen2.5-3B-Instruct (CPU)".
    # The API id stays "chat-cpu".
    FALLBACK_MODEL_NAME="$(friendly_name "$FALLBACK_MODEL_PATH" "(CPU)")"

    CFG=/tmp/llama-swap.config.yaml
    cat > "$CFG" <<EOF
# Generated by docker/entrypoint.sh (hybrid mode) -- do not edit here.
# CPU-only fallback. GPU models (chat, code) are served by the remote system
# and reach Open WebUI directly, not through this process.
healthCheckTimeout: 900
logLevel: info
startPort: 5800

models:
  "chat-cpu":
    name: "$FALLBACK_MODEL_NAME"
    cmd: |
      $LLAMA_SERVER_BIN
      --model $FALLBACK_MODEL_PATH
      --host 127.0.0.1 --port \${PORT}
      --ctx-size $FALLBACK_CTX
      --threads $NTHREADS
    ttl: 0
EOF

    echo "========================================================"
    echo "  LocalAIChat model-server  (hybrid -- CPU fallback only)"
    echo "  Binary  : $LLAMA_SERVER_BIN"
    echo "  Model   : $FALLBACK_MODEL_PATH  (ctx $FALLBACK_CTX, $NTHREADS threads)"
    echo "  Serves  : chat-cpu  (shows as \"$FALLBACK_MODEL_NAME\"; 'chat'/'code' come from the remote GPU system)"
    echo "  Listen  : 0.0.0.0:$LISTEN_PORT  (OpenAI-compatible, via llama-swap)"
    echo "========================================================"

    exec llama-swap --config "$CFG" --listen "0.0.0.0:$LISTEN_PORT"
fi

CHAT_MODEL_PATH="${CHAT_MODEL_PATH:-$MODELS_DIR/gpt-oss-20b.gguf}"
CODE_MODEL_PATH="${CODE_MODEL_PATH:-$MODELS_DIR/Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf}"

# Context sizes per model -- override via compose environment if needed.
# CODE_CTX 16384 + the Q5_K_M coder (~10.5 GB) + compute buffers fits a
# 16 GB card. Going to Q6_K (~12 GB) means dropping CODE_CTX to ~8192.
CHAT_CTX="${CHAT_CTX:-8192}"
CODE_CTX="${CODE_CTX:-16384}"

# HF download URLs, used only when the configured file is absent. If you
# switch models, change the *_MODEL_FILE in .env and the matching URL here
# together.
CHAT_MODEL_URL="${CHAT_MODEL_URL:-https://huggingface.co/ggml-org/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-MXFP4.gguf}"
CODE_MODEL_URL="${CODE_MODEL_URL:-https://huggingface.co/bartowski/Qwen2.5-Coder-14B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf}"

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

# Dropdown labels from the resolved files -- "gpt-oss-20b (chat)" etc. The
# API ids stay "chat" / "code" (Open WebUI keys routing off those).
CHAT_MODEL_NAME="$(friendly_name "$CHAT_MODEL_PATH" "(chat)")"
CODE_MODEL_NAME="$(friendly_name "$CODE_MODEL_PATH" "(code)")"

# ---------------------------------------------------------------------------
# 4. Generate llama-swap config
# ---------------------------------------------------------------------------
# gpt-oss speaks the harmony format -- llama-server needs --jinja for it.
CFG=/tmp/llama-swap.config.yaml
cat > "$CFG" <<EOF
# Generated by docker/entrypoint.sh on container start -- do not edit here.
# Mode: $BACKEND_MODE   Backend: $LLAMA_BACKEND -> $LLAMA_SERVER_BIN
# 900s: a stone-cold read of a ~12 GB model off a slow disk (fresh boot,
# no page cache) can take >5 min; warm loads are ~20 s. This ceiling only
# matters on that first cold load.
healthCheckTimeout: 900
logLevel: info
startPort: 5800

models:
  "chat":
    name: "$CHAT_MODEL_NAME"
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
    name: "$CODE_MODEL_NAME"
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
echo "  chat    : $CHAT_MODEL_PATH (ctx $CHAT_CTX)  -> shows as \"$CHAT_MODEL_NAME\""
echo "  code    : $CODE_MODEL_PATH (ctx $CODE_CTX)  -> shows as \"$CODE_MODEL_NAME\""
echo "  Listen  : 0.0.0.0:$LISTEN_PORT  (OpenAI-compatible, via llama-swap)"
echo "  Models load on demand -- only one resident at a time."
echo "========================================================"

# ---------------------------------------------------------------------------
# 5. Run
# ---------------------------------------------------------------------------
exec llama-swap --config "$CFG" --listen "0.0.0.0:$LISTEN_PORT"
