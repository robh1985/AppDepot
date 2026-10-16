"""Database models and session handling (SQLAlchemy 2.x).

SQLite is the default. Any SQLAlchemy URL works, e.g.
``postgresql+psycopg://user:pw@host/appdepot`` or
``mssql+pyodbc://@SQL01/AppDepot?driver=ODBC+Driver+18+for+SQL+Server``.
"""

from __future__ import annotations

import datetime as dt
from contextlib import contextmanager
from typing import Any, Iterator

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    create_engine,
    event,
    inspect,
    select,
    text,
)
from sqlalchemy.orm import (
    DeclarativeBase,
    Mapped,
    Session,
    mapped_column,
    relationship,
    sessionmaker,
)


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)


class Base(DeclarativeBase):
    pass


class Application(Base):
    """An application tracked by the repository (one row per manifest)."""

    __tablename__ = "applications"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    app_id: Mapped[str] = mapped_column(String(200), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(200))
    publisher: Mapped[str | None] = mapped_column(String(200))
    description: Mapped[str | None] = mapped_column(Text)
    homepage: Mapped[str | None] = mapped_column(String(500))
    license: Mapped[str | None] = mapped_column(String(200))
    category: Mapped[str | None] = mapped_column(String(100))
    tags: Mapped[list | None] = mapped_column(JSON, default=list)

    # Where/how to find new versions on the internet
    source_type: Mapped[str] = mapped_column(String(50))
    source_config: Mapped[dict] = mapped_column(JSON, default=dict)
    source_state: Mapped[dict | None] = mapped_column(JSON, default=dict)

    # Silent install information (manifest overrides; per-version values win)
    installer_type: Mapped[str | None] = mapped_column(String(30))
    install_args: Mapped[str | None] = mapped_column(Text)
    uninstall_command: Mapped[str | None] = mapped_column(Text)
    uninstall_args: Mapped[str | None] = mapped_column(Text)
    architecture: Mapped[str | None] = mapped_column(String(20))
    scope: Mapped[str | None] = mapped_column(String(20))
    upgrade_behavior: Mapped[str] = mapped_column(String(30), default="install")
    detection: Mapped[dict | None] = mapped_column(JSON, default=dict)
    success_exit_codes: Mapped[list | None] = mapped_column(JSON, default=list)
    preferred_types: Mapped[list | None] = mapped_column(JSON)   # None = server default
    # Further installer options: setup_file (archives), signer, update_with
    extra: Mapped[dict | None] = mapped_column(JSON)

    # Scheduling
    schedule: Mapped[str | None] = mapped_column(String(100))  # from manifest; None = global
    # Set through the API/CLI; wins over the manifest value and survives re-syncs.
    schedule_override: Mapped[str | None] = mapped_column(String(100))
    retain_versions: Mapped[int | None] = mapped_column(Integer)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)

    # Status
    latest_version: Mapped[str | None] = mapped_column(String(100))
    last_checked_at: Mapped[dt.datetime | None] = mapped_column(DateTime)
    last_updated_at: Mapped[dt.datetime | None] = mapped_column(DateTime)
    last_check_status: Mapped[str | None] = mapped_column(String(30))
    last_error: Mapped[str | None] = mapped_column(Text)

    manifest_path: Mapped[str | None] = mapped_column(String(500))
    manifest_hash: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[dt.datetime] = mapped_column(DateTime, default=utcnow)
    updated_at: Mapped[dt.datetime] = mapped_column(DateTime, default=utcnow, onupdate=utcnow)

    versions: Mapped[list["AppVersion"]] = relationship(
        back_populates="application", cascade="all, delete-orphan"
    )

    @property
    def is_manual(self) -> bool:
        return all(src.get("type") == "manual" for src in self.source_list)

    @property
    def source_list(self) -> list[dict]:
        """All sources of the application, in preference order."""
        cfg = self.source_config or {}
        if self.source_type == "multi":
            return [dict(x) for x in cfg.get("sources") or []]
        return [dict(cfg, type=self.source_type)]

    @property
    def effective_schedule(self) -> str | None:
        """Cron expression, 'manual', or None (= use the global schedule)."""
        return self.schedule_override or self.schedule


class AppVersion(Base):
    """A downloaded installer for a specific application version."""

    __tablename__ = "app_versions"
    __table_args__ = (UniqueConstraint("application_id", "version", name="uq_app_version"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    application_id: Mapped[int] = mapped_column(ForeignKey("applications.id", ondelete="CASCADE"), index=True)
    version: Mapped[str] = mapped_column(String(100))
    status: Mapped[str] = mapped_column(String(20), default="available")  # available | purged
    is_latest: Mapped[bool] = mapped_column(Boolean, default=False)

    # Installer file
    filename: Mapped[str] = mapped_column(String(300))
    setup_path: Mapped[str | None] = mapped_column(String(500))  # setup file inside an archive
    relative_path: Mapped[str] = mapped_column(String(500))  # relative to repo root, '/' separated
    local_path: Mapped[str] = mapped_column(String(1000))
    unc_path: Mapped[str | None] = mapped_column(String(1000))
    sha256: Mapped[str] = mapped_column(String(64))
    size_bytes: Mapped[int] = mapped_column(Integer)
    source_url: Mapped[str | None] = mapped_column(Text)
    source_type: Mapped[str | None] = mapped_column(String(30))  # source that supplied the file
    release_notes_url: Mapped[str | None] = mapped_column(Text)

    # Silent install details for this exact file
    installer_type: Mapped[str] = mapped_column(String(30))
    architecture: Mapped[str | None] = mapped_column(String(20))
    scope: Mapped[str | None] = mapped_column(String(20))
    source_silent_args: Mapped[str | None] = mapped_column(Text)   # published by the source (winget)
    source_custom_args: Mapped[str | None] = mapped_column(Text)
    install_executable: Mapped[str] = mapped_column(String(300))
    install_arguments: Mapped[str] = mapped_column(Text)
    install_command: Mapped[str] = mapped_column(Text)
    uninstall_executable: Mapped[str | None] = mapped_column(String(300))
    uninstall_arguments: Mapped[str | None] = mapped_column(Text)
    uninstall_command: Mapped[str | None] = mapped_column(Text)
    product_code: Mapped[str | None] = mapped_column(String(64))
    upgrade_code: Mapped[str | None] = mapped_column(String(64))
    msi_info: Mapped[dict | None] = mapped_column(JSON)

    # Intune artefacts
    intunewin_relative_path: Mapped[str | None] = mapped_column(String(500))
    intune_info_relative_path: Mapped[str | None] = mapped_column(String(500))
    intune_detection_relative_path: Mapped[str | None] = mapped_column(String(500))
    intune_status: Mapped[str | None] = mapped_column(String(20))  # ok | failed | disabled
    intune_error: Mapped[str | None] = mapped_column(Text)

    downloaded_at: Mapped[dt.datetime] = mapped_column(DateTime, default=utcnow)
    purged_at: Mapped[dt.datetime | None] = mapped_column(DateTime)

    application: Mapped[Application] = relationship(back_populates="versions")


class Event(Base):
    """Audit log of everything the server does."""

    __tablename__ = "events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    timestamp: Mapped[dt.datetime] = mapped_column(DateTime, default=utcnow, index=True)
    app_id: Mapped[str | None] = mapped_column(String(200), index=True)
    version: Mapped[str | None] = mapped_column(String(100))
    level: Mapped[str] = mapped_column(String(10), default="info")
    event: Mapped[str] = mapped_column(String(50))
    message: Mapped[str] = mapped_column(Text)
    details: Mapped[dict | None] = mapped_column(JSON)


class Setting(Base):
    __tablename__ = "settings"

    key: Mapped[str] = mapped_column(String(100), primary_key=True)
    value: Mapped[Any] = mapped_column(JSON)
    updated_at: Mapped[dt.datetime] = mapped_column(DateTime, default=utcnow, onupdate=utcnow)


class Database:
    def __init__(self, url: str):
        connect_args = {}
        if url.startswith("sqlite"):
            connect_args = {"check_same_thread": False, "timeout": 30}
        self.engine = create_engine(url, connect_args=connect_args, future=True)
        if url.startswith("sqlite"):
            @event.listens_for(self.engine, "connect")
            def _sqlite_pragmas(dbapi_conn, _):  # pragma: no cover - trivial
                cur = dbapi_conn.cursor()
                cur.execute("PRAGMA journal_mode=WAL")
                cur.execute("PRAGMA foreign_keys=ON")
                cur.close()
        self._factory = sessionmaker(bind=self.engine, expire_on_commit=False)

    def create_all(self) -> None:
        Base.metadata.create_all(self.engine)
        self.migrate()

    def migrate(self) -> list[str]:
        """Add columns introduced by newer AppDepot versions to existing tables."""
        added = []
        insp = inspect(self.engine)
        add_kw = "ADD" if self.engine.dialect.name == "mssql" else "ADD COLUMN"
        with self.engine.begin() as conn:
            for table in Base.metadata.sorted_tables:
                if not insp.has_table(table.name):
                    continue
                existing = {c["name"] for c in insp.get_columns(table.name)}
                for col in table.columns:
                    if col.name not in existing:
                        ddl = col.type.compile(dialect=self.engine.dialect)
                        conn.execute(text(f"ALTER TABLE {table.name} {add_kw} {col.name} {ddl}"))
                        added.append(f"{table.name}.{col.name}")
        return added

    @contextmanager
    def session(self) -> Iterator[Session]:
        s = self._factory()
        try:
            yield s
            s.commit()
        except Exception:
            s.rollback()
            raise
        finally:
            s.close()

    # -- helpers -------------------------------------------------------------
    def log_event(self, event_name: str, message: str, *, app_id: str | None = None,
                  version: str | None = None, level: str = "info", details: dict | None = None) -> None:
        with self.session() as s:
            s.add(Event(event=event_name, message=message, app_id=app_id, version=version,
                        level=level, details=details))

    def get_setting(self, key: str, default: Any = None) -> Any:
        with self.session() as s:
            row = s.get(Setting, key)
            return default if row is None else row.value

    def set_setting(self, key: str, value: Any) -> None:
        with self.session() as s:
            row = s.get(Setting, key)
            if row is None:
                s.add(Setting(key=key, value=value))
            else:
                row.value = value

    def get_app(self, session: Session, app_id: str) -> Application | None:
        return session.scalar(select(Application).where(Application.app_id == app_id))
