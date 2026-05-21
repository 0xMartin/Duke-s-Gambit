"""Logging setup: console + daily rotating file handler.

Each calendar day gets its own log file named ``YYYY-MM-DD.log`` inside
the configured log directory (default ``logs/``).  Both the console and
the file use the same format so operators can tail either one.

The :class:`_DailyFileHandler` is a thin wrapper around
:class:`logging.FileHandler` that checks the wall-clock date on every
``emit`` call and silently rolls over to a new file at midnight without
any background thread or timer.
"""

from __future__ import annotations

import datetime
import logging
from pathlib import Path


class _DailyFileHandler(logging.FileHandler):
    """FileHandler that opens a new file at midnight (local time).

    Files are named ``YYYY-MM-DD.log`` inside *log_dir*; the directory
    is created on first use if it does not yet exist.
    """

    def __init__(self, log_dir: Path, encoding: str = "utf-8") -> None:
        self.log_dir = log_dir
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self._current_date: datetime.date | None = None
        today = datetime.date.today()
        super().__init__(self._path_for(today), mode="a", encoding=encoding, delay=False)
        self._current_date = today

    # ------------------------------------------------------------------
    def _path_for(self, date: datetime.date) -> str:
        return str(self.log_dir / f"{date:%Y-%m-%d}.log")

    def emit(self, record: logging.LogRecord) -> None:
        today = datetime.date.today()
        if today != self._current_date:
            # Double-checked lock — only rotate once even under rapid emission.
            self.acquire()
            try:
                if today != self._current_date:
                    self._current_date = today
                    if self.stream:
                        self.stream.close()
                        self.stream = None
                    self.baseFilename = self._path_for(today)
                    self.stream = self._open()
            finally:
                self.release()
        super().emit(record)


# ── Public API ─────────────────────────────────────────────────────────────

def setup_logging(log_level: int, log_dir: str = "logs") -> None:
    """Attach a console handler and a daily file handler to the root logger.

    Parameters
    ----------
    log_level:
        Numeric logging level, e.g. ``logging.INFO``.
    log_dir:
        Directory for daily ``.log`` files.  Created automatically.
    """
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")

    console = logging.StreamHandler()
    console.setFormatter(fmt)

    daily = _DailyFileHandler(Path(log_dir))
    daily.setFormatter(fmt)

    root = logging.getLogger()
    root.setLevel(log_level)
    root.addHandler(console)
    root.addHandler(daily)
