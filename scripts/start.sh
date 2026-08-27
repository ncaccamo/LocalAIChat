#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# First run: seed .env from the template so HOST_UID / GID vars resolve.
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example — review it (models, GPU GIDs) before a real run."
fi

# Idempotent, and safe even if BookTranslator was never installed on this
# machine — this is a naming convention, not a file/repo dependency.
docker network inspect ai-net >/dev/null 2>&1 || docker network create ai-net

# Not intended to run alongside BookTranslator on a shared GPU. This check
# is a no-op (finds nothing, proceeds) on a machine where BookTranslator
# was never installed at all.
if docker ps --format '{{.Names}}' | grep -q '^booktranslator-'; then
  echo "WARNING: BookTranslator containers appear to be running."
  echo "This GPU is not sized for both projects at once."
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

docker compose up -d
echo
echo "LocalAIChat is up. Open WebUI: http://localhost:3000"
echo "First run downloads the model(s) into ~/llm_models — follow with:"
echo "  docker compose logs -f model-server"
