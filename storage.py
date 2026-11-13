"""
Tiny SQLite persistence layer for download tasks and per-client history.

Only state *transitions* are written here (created / completed / failed / served / expired).
Live, high-frequency progress updates stay in memory (see `downloads` in main.py),
so the database is never hammered by progress lines.
"""
import os
import sqlite3
import threading
import time
from typing import Optional

SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
    task_id     TEXT PRIMARY KEY,
    client_id   TEXT NOT NULL,
    kind        TEXT NOT NULL DEFAULT 'video',      -- video | playlist
    status      TEXT NOT NULL DEFAULT 'processing', -- processing | completed | failed | expired
    title       TEXT,
    thumbnail   TEXT,
    format_id   TEXT,
    url         TEXT,
    filepath    TEXT,
    media_type  TEXT,
    error       TEXT,
    note        TEXT,
    created_at  REAL NOT NULL,
    finished_at REAL,
    served_at   REAL
);
CREATE INDEX IF NOT EXISTS idx_tasks_client ON tasks (client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks (status);
"""

_COLUMNS = {
    "client_id", "kind", "status", "title", "thumbnail", "format_id", "url", "filepath",
    "media_type", "error", "note", "created_at", "finished_at", "served_at",
}


class Store:
    def __init__(self, path: str):
        directory = os.path.dirname(os.path.abspath(path))
        os.makedirs(directory, exist_ok=True)
        # One shared connection guarded by a lock: downloads run in worker threads.
        self._conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None, timeout=30)
        self._conn.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA synchronous=NORMAL")
            self._conn.executescript(SCHEMA)

    # --- helpers -----------------------------------------------------------
    def _execute(self, sql: str, params=()):
        with self._lock:
            return self._conn.execute(sql, params)

    def _query(self, sql: str, params=()) -> list:
        with self._lock:
            return [dict(r) for r in self._conn.execute(sql, params).fetchall()]

    # --- tasks -------------------------------------------------------------
    def create_task(self, task_id: str, **fields):
        fields = {k: v for k, v in fields.items() if k in _COLUMNS}
        fields.setdefault("created_at", time.time())
        cols = ["task_id"] + list(fields.keys())
        placeholders = ",".join("?" for _ in cols)
        self._execute(
            f"INSERT INTO tasks ({','.join(cols)}) VALUES ({placeholders})",
            [task_id] + list(fields.values()),
        )

    def update_task(self, task_id: str, **fields):
        fields = {k: v for k, v in fields.items() if k in _COLUMNS}
        if not fields:
            return
        assignments = ",".join(f"{k}=?" for k in fields)
        self._execute(f"UPDATE tasks SET {assignments} WHERE task_id=?", list(fields.values()) + [task_id])

    def get_task(self, task_id: str) -> Optional[dict]:
        rows = self._query("SELECT * FROM tasks WHERE task_id=?", (task_id,))
        return rows[0] if rows else None

    def recent_for_client(self, client_id: str, limit: int = 50, max_age_seconds: Optional[int] = None) -> list:
        if max_age_seconds and max_age_seconds > 0:
            cutoff = time.time() - max_age_seconds
            return self._query(
                "SELECT task_id, title, thumbnail, format_id AS format, kind, status, error, note, created_at AS timestamp "
                "FROM tasks WHERE client_id=? AND (created_at >= ? OR status = 'processing') "
                "ORDER BY created_at DESC LIMIT ?",
                (client_id, cutoff, limit),
            )
        return self._query(
            "SELECT task_id, title, thumbnail, format_id AS format, kind, status, error, note, created_at AS timestamp "
            "FROM tasks WHERE client_id=? ORDER BY created_at DESC LIMIT ?",
            (client_id, limit),
        )

    def clear_client_history(self, client_id: str) -> list:
        with self._lock:
            rows = [
                dict(r)
                for r in self._conn.execute(
                    "SELECT task_id, filepath FROM tasks WHERE client_id=? AND status != 'processing'",
                    (client_id,),
                ).fetchall()
            ]
            self._conn.execute(
                "DELETE FROM tasks WHERE client_id=? AND status != 'processing'",
                (client_id,),
            )
            return rows

    def tasks_with_status(self, status: str) -> list:
        return self._query("SELECT * FROM tasks WHERE status=?", (status,))

    def mark_interrupted(self, message: str) -> int:
        """Tasks that were running when the server stopped can never finish: mark them failed."""
        cur = self._execute(
            "UPDATE tasks SET status='failed', error=?, finished_at=? WHERE status='processing'",
            (message, time.time()),
        )
        return cur.rowcount

    def purge_older_than(self, timestamp: float) -> int:
        cur = self._execute(
            "DELETE FROM tasks WHERE created_at < ? AND status != 'processing'", (timestamp,)
        )
        return cur.rowcount

    def trim_client_history(self, client_id: str, keep: int = 50):
        self._execute(
            "DELETE FROM tasks WHERE client_id=? AND status != 'processing' AND task_id NOT IN "
            "(SELECT task_id FROM tasks WHERE client_id=? ORDER BY created_at DESC LIMIT ?)",
            (client_id, client_id, keep),
        )

