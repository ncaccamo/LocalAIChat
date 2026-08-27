#!/usr/bin/env bash
# One-time setup for LocalAIChat.
#
# Assumes you have already worked through docs/HOST_PREREQUISITES.md
# (OS / kernel / GPU driver / Docker install). This script does NOT install
# system packages — it verifies the host is ready, then:
#   - writes .env with your machine's real UID/GID + GPU group IDs
#   - writes backend.env (local / vulkan) if absent
#   - creates the ai-net docker network
#   - builds the model-server image
#   - brings the stack up and waits for it
#
# Safe to re-run. For everyday use after this, just scripts/start.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

PREREQ="docs/HOST_PREREQUISITES.md"
fail=0
ok()   { printf '  \033[32m ok \033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
note() { printf '       %s\n' "$*"; }

echo "== 1/5  Host prerequisites =="

if grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null; then
  ok "Ubuntu 24.04"
else
  bad "not Ubuntu 24.04 — see $PREREQ section 1"
fi

kv=$(uname -r); kmaj=${kv%%.*}; krest=${kv#*.}; kmin=${krest%%.*}
if [ "${kmaj:-0}" -gt 6 ] || { [ "${kmaj:-0}" -eq 6 ] && [ "${kmin:-0}" -ge 12 ]; }; then
  ok "kernel $kv (>= 6.12)"
else
  bad "kernel $kv is < 6.12 — RDNA4 needs 6.12+; see $PREREQ section 2"
fi

if lspci 2>/dev/null | grep -iE 'vga|display|3d' | grep -iqE 'amd|ati|radeon'; then
  ok "AMD GPU present on PCI bus"
else
  note "warn: no AMD GPU seen via lspci — continuing anyway"
fi

for d in /dev/kfd /dev/dri/renderD128; do
  [ -e "$d" ] && ok "$d present" \
    || bad "$d missing — amdgpu driver not loaded; see $PREREQ sections 2 and 4"
done

miss=""
for g in render video; do id -nG | tr ' ' '\n' | grep -qx "$g" || miss="$miss $g"; done
if [ -z "$miss" ]; then
  ok "in groups: render video"
else
  bad "not in group(s):$miss — run: sudo usermod -aG${miss// /,} \"\$USER\" then log out/in ($PREREQ section 5)"
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker usable without sudo"
  else
    bad "docker present but needs sudo — add \$USER to the 'docker' group, log out/in ($PREREQ section 6)"
  fi
else
  bad "docker not installed — see $PREREQ section 6"
fi
docker compose version >/dev/null 2>&1 && ok "docker compose plugin" \
  || bad "docker compose plugin missing — see $PREREQ section 6"

if [ -d "$HOME/llm_models" ]; then
  ok "~/llm_models exists"
else
  mkdir -p "$HOME/llm_models"
  note "created ~/llm_models (models download on first start, ~21 GB)"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "Prerequisites not met — fix the FAIL lines above ($PREREQ), then re-run."
  exit 1
fi

echo
echo "== 2/5  Config =="
RENDER_GID=$(getent group render | cut -d: -f3 || true); RENDER_GID=${RENDER_GID:-992}
VIDEO_GID=$(getent group video  | cut -d: -f3 || true); VIDEO_GID=${VIDEO_GID:-44}
HOST_UID=$(id -u); HOST_GID=$(id -g)

if [ -f .env ]; then
  note ".env exists — left as-is (detected: UID:GID $HOST_UID:$HOST_GID, video=$VIDEO_GID render=$RENDER_GID)"
else
  sed -e "s/^HOST_UID=.*/HOST_UID=$HOST_UID/" \
      -e "s/^HOST_GID=.*/HOST_GID=$HOST_GID/" \
      -e "s/^VIDEO_GID=.*/VIDEO_GID=$VIDEO_GID/" \
      -e "s/^RENDER_GID=.*/RENDER_GID=$RENDER_GID/" \
      .env.example > .env
  ok ".env written (UID:GID $HOST_UID:$HOST_GID, video=$VIDEO_GID render=$RENDER_GID)"
fi
if [ -f backend.env ]; then
  note "backend.env exists — left as-is"
else
  cp backend.env.example backend.env
  ok "backend.env written (BACKEND_MODE=local, LLAMA_BACKEND=vulkan)"
fi

echo
echo "== 3/5  Docker network =="
if docker network inspect ai-net >/dev/null 2>&1; then
  ok "ai-net exists"
else
  docker network create ai-net >/dev/null && ok "ai-net created"
fi

echo
echo "== 4/5  Build image =="
echo "   First build compiles llama.cpp twice (ROCm + Vulkan): 20-30 min."
echo "   Much faster if BookTranslator's image is already built (shared layers)."
docker compose build

echo
echo "== 5/5  Bring up =="
bash scripts/start.sh

set -a; . ./backend.env 2>/dev/null || true; set +a
if [ "${BACKEND_MODE:-local}" = "local" ]; then
  printf "   waiting for llama-swap on :11500 "
  for _ in $(seq 1 60); do
    if curl -sf http://localhost:11500/v1/models >/dev/null 2>&1; then printf " up\n"; break; fi
    printf "."; sleep 3
  done
fi

echo
echo "============================================================"
echo " Setup complete.  Open WebUI: http://localhost:3000"
echo " First chat triggers a model download (~21 GB) + load —"
echo "   docker compose logs -f model-server   to watch."
echo " Everyday use:  scripts/start.sh  /  scripts/stop.sh"
echo "============================================================"
