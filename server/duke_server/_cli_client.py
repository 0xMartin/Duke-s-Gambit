"""CLI client: connect to the server's Unix socket and proxy stdin/stdout.

Invoked inside the container by server-cli.sh::

    docker exec -it dukes-gambit-server python3 -m duke_server._cli_client

When you type 'exit' the server closes the connection and this process exits
cleanly.  Pressing Ctrl-C also exits cleanly — the server keeps running.
"""

from __future__ import annotations

import os
import select
import socket
import sys

from .cli import CLI_SOCKET_PATH


def main() -> None:
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(CLI_SOCKET_PATH)
    except FileNotFoundError:
        sys.exit("CLI socket not found — is the server fully started?")
    except ConnectionRefusedError:
        sys.exit("CLI socket exists but connection was refused.")

    stdin_fd = sys.stdin.fileno()
    sock_fd = sock.fileno()

    try:
        while True:
            try:
                readable, _, _ = select.select([stdin_fd, sock_fd], [], [])
            except KeyboardInterrupt:
                break

            # Receive from server → write to terminal
            if sock_fd in readable:
                data = sock.recv(4096)
                if not data:
                    break  # server closed connection (exit / shutdown)
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()

            # Read from terminal → send to server
            if stdin_fd in readable:
                data = os.read(stdin_fd, 4096)
                if not data:
                    break  # stdin closed
                try:
                    sock.sendall(data)
                except BrokenPipeError:
                    break
    finally:
        sock.close()


if __name__ == "__main__":
    main()
