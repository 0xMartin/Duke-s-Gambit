#!/usr/bin/env bash
# Attach to the Duke's Gambit server admin CLI.
# Type 'exit' or press Ctrl-C to disconnect (server keeps running).

set -euo pipefail

CONTAINER="dukes-gambit-server"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Container '${CONTAINER}' is not running."
    echo "Start it with:  docker compose up -d"
    exit 1
fi

echo "Connecting to '${CONTAINER}'…  Type 'exit' or press Ctrl-C to disconnect."
exec docker exec -it "${CONTAINER}" python3 -m duke_server._cli_client
