"""
Database backup utilities: pg_dump, list, delete, status.
Backups stored in BACKUP_DIR (default /app/backups inside container).
"""

import logging
import os
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import settings

logger = logging.getLogger(__name__)

BACKUP_DIR = Path(os.environ.get("BACKUP_DIR", "/app/backups"))


def ensure_backup_dir() -> None:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)


def _parse_db_url():
    parsed = urlparse(settings.database_url)
    return {
        "host": parsed.hostname or "localhost",
        "port": str(parsed.port or 5432),
        "user": parsed.username or "postgres",
        "password": parsed.password or "",
        "dbname": parsed.path.lstrip("/"),
    }


def create_backup() -> dict:
    """Run pg_dump and save to BACKUP_DIR. Returns file info dict."""
    ensure_backup_dir()
    db_info = _parse_db_url()
    timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    filename = f"aro_backup_{timestamp}.sql"
    filepath = BACKUP_DIR / filename

    env = os.environ.copy()
    env["PGPASSWORD"] = db_info["password"]

    cmd = [
        "pg_dump",
        "-h", db_info["host"],
        "-p", db_info["port"],
        "-U", db_info["user"],
        "-d", db_info["dbname"],
        "--no-password",
        "-f", str(filepath),
    ]

    result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        raise RuntimeError(f"pg_dump thất bại: {result.stderr.strip()}")

    size = filepath.stat().st_size
    logger.info("backup: created %s (%d bytes)", filename, size)
    return {"filename": filename, "size": size, "created_at": datetime.utcnow()}


def list_backups() -> list[dict]:
    """Return list of backup files sorted newest first."""
    ensure_backup_dir()
    files = []
    for f in BACKUP_DIR.glob("aro_backup_*.sql"):
        stat = f.stat()
        files.append({
            "filename": f.name,
            "size": stat.st_size,
            "created_at": datetime.utcfromtimestamp(stat.st_mtime),
        })
    files.sort(key=lambda x: x["created_at"], reverse=True)
    return files


def delete_backup(filename: str) -> bool:
    """Delete a backup file by name. Returns True if deleted."""
    # Sanitize: only allow expected filename pattern
    if not filename.startswith("aro_backup_") or not filename.endswith(".sql"):
        return False
    filepath = BACKUP_DIR / filename
    if filepath.exists():
        filepath.unlink()
        logger.info("backup: deleted %s", filename)
        return True
    return False


def prune_backups(keep: int) -> int:
    """Delete oldest backups keeping only `keep` most recent. Returns count deleted."""
    if keep <= 0:
        return 0
    files = list_backups()
    to_delete = files[keep:]
    for f in to_delete:
        delete_backup(f["filename"])
    return len(to_delete)


def get_db_status(db: Session) -> dict:
    """Return database statistics."""
    try:
        size_row = db.execute(
            text("SELECT pg_size_pretty(pg_database_size(current_database())) AS size,"
                 " pg_database_size(current_database()) AS size_bytes")
        ).fetchone()

        version_row = db.execute(text("SELECT version()")).fetchone()
        version_str = version_row[0].split(" ")[1] if version_row else "unknown"

        # row counts for key tables
        counts = {}
        for tbl in ("nodes", "node_status", "node_history", "node_error_log", "node_daily_score", "commands"):
            row = db.execute(text(f"SELECT COUNT(*) FROM {tbl}")).fetchone()
            counts[tbl] = row[0] if row else 0

        # table disk sizes
        table_sizes_rows = db.execute(text(
            "SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS size"
            " FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 8"
        )).fetchall()
        table_sizes = [{"table": r[0], "size": r[1]} for r in table_sizes_rows]

        db_info = _parse_db_url()

        return {
            "db_size": size_row[0] if size_row else "N/A",
            "db_size_bytes": size_row[1] if size_row else 0,
            "pg_version": version_str,
            "host": db_info["host"],
            "dbname": db_info["dbname"],
            "counts": counts,
            "table_sizes": table_sizes,
        }
    except Exception as exc:
        logger.error("get_db_status error: %s", exc)
        return {"error": str(exc)}


def scheduled_backup(db: Session, interval_hours: int, retention_count: int) -> Optional[str]:
    """Create a backup if enough time has elapsed since the last one."""
    backups = list_backups()
    if backups:
        last_dt = backups[0]["created_at"]
        elapsed_hours = (datetime.utcnow() - last_dt).total_seconds() / 3600
        if elapsed_hours < interval_hours:
            return None  # not yet

    try:
        info = create_backup()
        pruned = prune_backups(retention_count)
        logger.info("scheduled_backup: created %s, pruned %d old backups", info["filename"], pruned)
        return info["filename"]
    except Exception as exc:
        logger.error("scheduled_backup error: %s", exc)
        return None
