#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# --remove-orphans so a leftover service from the other backend mode
# (e.g. model-server after switching to remote) is cleaned up too.
docker compose down --remove-orphans
echo "LocalAIChat stopped, GPU freed."
