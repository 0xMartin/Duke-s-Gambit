"""CLI entry point: ``python -m duke_server``.

Delegates to :func:`duke_server.server.main`, which reads configuration
from environment variables, sets up signal handlers and starts the
asyncio event loop. See :mod:`duke_server.config` for available
``DUKE_*`` environment variables.
"""

from .server import main

if __name__ == "__main__":
    main()
