"""Wires configuration, database, repository, updater and scheduler together."""

from __future__ import annotations

import logging
import logging.handlers
from dataclasses import dataclass

from .config import Config
from .db import Database
from .manifest import sync_manifests
from .repository import Repository
from .scheduler import Scheduler
from .updater import Updater


@dataclass
class AppContext:
    config: Config
    db: Database
    repo: Repository
    updater: Updater
    scheduler: Scheduler

    def sync(self) -> dict:
        result = sync_manifests(self.db, self.config.manifests_dir)
        if result["added_or_updated"]:
            self.scheduler.bump_revision()
        self.scheduler.reload()
        return result


def setup_logging(config: Config) -> None:
    cfg = config.section("logging")
    handlers: list[logging.Handler] = [logging.StreamHandler()]
    if cfg.get("file"):
        handlers.append(logging.handlers.RotatingFileHandler(
            cfg["file"], maxBytes=10 * 1024 * 1024, backupCount=5, encoding="utf-8"))
    logging.basicConfig(level=getattr(logging, str(cfg.get("level", "INFO")).upper(), logging.INFO),
                        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s", handlers=handlers,
                        force=True)


def build_context(config: Config) -> AppContext:
    db = Database(config.database_url)
    db.create_all()
    repo = Repository(config)
    updater = Updater(config, db, repo)
    sched_cfg = config.section("schedule")
    scheduler = Scheduler(db, updater, default_global=sched_cfg.get("global", "0 3 * * *"),
                          timezone=sched_cfg.get("timezone"))
    return AppContext(config, db, repo, updater, scheduler)
