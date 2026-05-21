#!/usr/bin/env bash
# Attach to the Duke's Gambit server admin CLI.
# Detach with: Ctrl-P  Ctrl-Q  (does NOT stop the server)
# Type 'exit' inside the CLI to detach via the server's own command.

set -euo pipefail

CONTAINER="dukes-gambit-server"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Container '${CONTAINER}' is not running."
    echo "Start it with:  docker compose up -d"
    exit 1
fi

echo "Attaching to '${CONTAINER}'…  Detach with Ctrl-P Ctrl-Q"
exec docker attach --detach-keys="ctrl-p,ctrl-q" "${CONTAINER}"
