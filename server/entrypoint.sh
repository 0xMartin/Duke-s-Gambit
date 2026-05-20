#!/usr/bin/env sh
set -e

# Ensure cert dir exists when TLS is enabled (server auto-generates if missing).
if [ "${DUKE_TLS}" = "1" ]; then
    mkdir -p "${DUKE_CERT_DIR}"
fi

exec python -m duke_server "$@"
