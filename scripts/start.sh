#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# First run: seed env files from templates. (scripts/setup.sh does a fuller
# job — host prereq checks + build; this keeps start.sh usable on its own.)
if [[ ! -f .env ]]; then
  rgid=$(getent group render | cut -d: -f3 || true); rgid=${rgid:-992}
  vgid=$(getent group video  | cut -d: -f3 || true); vgid=${vgid:-44}
  sed -e "s/^HOST_UID=.*/HOST_UID=$(id -u)/" \
      -e "s/^HOST_GID=.*/HOST_GID=$(id -g)/" \
      -e "s/^VIDEO_GID=.*/VIDEO_GID=$vgid/" \
      -e "s/^RENDER_GID=.*/RENDER_GID=$rgid/" \
      .env.example > .env
  echo "Created .env (UID:GID $(id -u):$(id -g), video=$vgid render=$rgid) - check model filenames."
fi
[[ -f backend.env ]] || { cp backend.env.example backend.env; \
  echo "Created backend.env from template - review it (mode / backend)."; }

# Load backend selection. `set -a` exports each KEY=value so `docker compose`
# (a child process) picks them up for ${VAR} interpolation; shell-environment
# values take precedence over anything in .env.
set -a
# shellcheck disable=SC1091
. ./backend.env
set +a

BACKEND_MODE="${BACKEND_MODE:-local}"

case "$BACKEND_MODE" in
  local)
    LLAMA_BACKEND="${LLAMA_BACKEND:-vulkan}"
    case "$LLAMA_BACKEND" in
      vulkan|rocm7) ;;
      rocm) echo "note: LLAMA_BACKEND=rocm accepted as an alias for rocm7." ;;
      rocm714)
        echo "backend.env: LLAMA_BACKEND=rocm714 is parked - not built into the image."
        echo "Use vulkan or rocm7, or build rocm714 in BackendBuildstage first."
        exit 1 ;;
      *)
        echo "backend.env: LLAMA_BACKEND='$LLAMA_BACKEND' invalid - want vulkan | rocm7 | rocm714."
        exit 1 ;;
    esac
    export BACKEND_MODE LLAMA_BACKEND
    up_cmd=(docker compose up -d)
    target_msg="local ($LLAMA_BACKEND) - llama-swap on :11500"
    ;;
  remote)
    : "${REMOTE_HOST:?backend.env: REMOTE_HOST must be set for remote mode}"
    REMOTE_PORT="${REMOTE_PORT:-11500}"
    [[ -n "${REMOTE_API_KEY:-}" ]] || echo \
      "backend.env: REMOTE_API_KEY is empty - the remote llama-server must then run without --api-key."
    export BACKEND_MODE
    # Plural forms: a one-entry list. Compose feeds these to Open WebUI's
    # OPENAI_API_BASE_URLS / OPENAI_API_KEYS.
    export OWUI_OPENAI_BASE_URLS="http://${REMOTE_HOST}:${REMOTE_PORT}/v1"
    export OWUI_OPENAI_KEYS="${REMOTE_API_KEY:-sk-none}"
    # open-webui + searxng, but NOT model-server (--no-deps skips the
    # depends_on chain; we name searxng explicitly so web search still works).
    up_cmd=(docker compose up -d --no-deps open-webui searxng)
    target_msg="remote - Open WebUI -> ${OWUI_OPENAI_BASE_URLS}"
    ;;
  hybrid)
    : "${REMOTE_HOST:?backend.env: REMOTE_HOST must be set for hybrid mode}"
    REMOTE_PORT="${REMOTE_PORT:-11500}"
    [[ -n "${REMOTE_API_KEY:-}" ]] || echo \
      "backend.env: REMOTE_API_KEY is empty - the remote llama-server must then run without --api-key."
    : "${FALLBACK_MODEL_FILE:=Qwen2.5-3B-Instruct-Q4_K_M.gguf}"
    export BACKEND_MODE FALLBACK_MODEL_FILE
    # Two endpoints: remote GPU box first, local CPU fallback second. Order
    # is cosmetic (Open WebUI merges both); keeping the GPU models first
    # groups them at the top of the dropdown. Keys pair by index.
    export OWUI_OPENAI_BASE_URLS="http://${REMOTE_HOST}:${REMOTE_PORT}/v1;http://model-server:11500/v1"
    export OWUI_OPENAI_KEYS="${REMOTE_API_KEY:-sk-none};sk-local"
    # Everything: model-server (CPU fallback), open-webui, searxng.
    up_cmd=(docker compose up -d)
    target_msg="hybrid - GPU -> http://${REMOTE_HOST}:${REMOTE_PORT} + local CPU fallback (chat-cpu)"
    ;;
  *)
    echo "backend.env: BACKEND_MODE='$BACKEND_MODE' invalid - want local | hybrid | remote."
    exit 1 ;;
esac

# ai-net: idempotent; a naming convention, not a repo dependency.
docker network inspect ai-net >/dev/null 2>&1 || docker network create ai-net

# Not sized to run alongside BookTranslator on a shared GPU. No-op if BT
# isn't installed. Irrelevant in remote mode (nothing runs on this GPU).
if [[ "$BACKEND_MODE" == "local" ]] && docker ps --format '{{.Names}}' | grep -q '^booktranslator-'; then
  echo "WARNING: BookTranslator containers appear to be running."
  echo "This GPU is not sized for both projects at once."
  if [[ "${ASSUME_YES:-}" == "1" ]]; then
    echo "(ASSUME_YES=1 — continuing)"
  elif [[ -t 0 ]]; then
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
  else
    echo "(non-interactive — continuing; set ASSUME_YES=1 to silence)"
  fi
fi

# Tear down the model-server if we're going remote (compose up --no-deps
# won't stop it, and it would keep holding the GPU).
if [[ "$BACKEND_MODE" == "remote" ]]; then
  docker compose rm -sf model-server >/dev/null 2>&1 || true
fi

"${up_cmd[@]}"
echo
echo "LocalAIChat is up - $target_msg"
echo "Open WebUI: http://localhost:3000"
if [[ "$BACKEND_MODE" == "local" || "$BACKEND_MODE" == "hybrid" ]]; then
  echo "First run downloads the model(s) into the models dir - follow with:"
  echo "  docker compose logs -f model-server"
fi
if [[ "$BACKEND_MODE" == "hybrid" ]]; then
  echo "GPU models appear once the remote box is reachable; 'chat-cpu' is always up."
fi
