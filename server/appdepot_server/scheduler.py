"""Global and per-application update schedules.

* The **global schedule** (cron) checks every enabled application that does not
  have its own schedule. It is stored in the database (``settings`` table) and
  initialised from ``schedule.global`` in the config file.
* An application can define its own cron expression (manifest ``schedule`` or
  an API/CLI override), or ``manual`` to only check on demand.
"""

from __future__ import annotations

import logging
import threading
from typing import Any

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from sqlalchemy import select

from .db import Application, Database
from .updater import Updater

log = logging.getLogger("appdepot.scheduler")

GLOBAL_JOB = "global"
WATCH_JOB = "_watch"
SETTING_KEY = "global_schedule"
REVISION_KEY = "schedule_revision"


def parse_cron(expr: str, timezone: str | None = None) -> CronTrigger:
    return CronTrigger.from_crontab(expr, timezone=timezone)


class Scheduler:
    def __init__(self, db: Database, updater: Updater, default_global: str, timezone: str | None = None):
        self.db = db
        self.updater = updater
        self.timezone = timezone
        self.default_global = default_global
        self._sched = BackgroundScheduler(timezone=timezone) if timezone else BackgroundScheduler()
        self._lock = threading.Lock()
        self._revision = None

    # ------------------------------------------------------------- lifecycle
    def start(self, run_now: bool = False) -> None:
        self.reload()
        self._sched.start()
        if run_now:
            self.run_in_background(self.updater.enabled_app_ids(), reason="startup")

    def shutdown(self) -> None:
        if self._sched.running:
            self._sched.shutdown(wait=False)

    # ------------------------------------------------------------- schedules
    @property
    def global_schedule(self) -> str:
        return self.db.get_setting(SETTING_KEY) or self.default_global

    def set_global_schedule(self, expr: str) -> None:
        parse_cron(expr, self.timezone)  # validate
        self.db.set_setting(SETTING_KEY, expr)
        self.db.log_event("schedule", f"Global schedule set to '{expr}'")
        self.bump_revision()
        self.reload()

    def set_app_schedule(self, app_id: str, expr: str | None) -> None:
        """expr: cron expression, 'manual', or None/'global' to follow the global schedule."""
        if expr in ("", "global"):
            expr = None
        if expr not in (None, "manual"):
            parse_cron(expr, self.timezone)
        with self.db.session() as s:
            app = self.db.get_app(s, app_id)
            if app is None:
                raise KeyError(app_id)
            app.schedule_override = expr
        self.db.log_event("schedule", f"Schedule set to '{expr or 'global'}'", app_id=app_id)
        self.bump_revision()
        self.reload()

    def bump_revision(self) -> None:
        """Signal other processes (e.g. a running server) that schedules changed."""
        self.db.set_setting(REVISION_KEY, int(self.db.get_setting(REVISION_KEY, 0) or 0) + 1)

    def _watch(self) -> None:
        if self.db.get_setting(REVISION_KEY, 0) != self._revision:
            log.info("Schedule change detected - reloading")
            self.reload()

    def reload(self) -> None:
        """Rebuild all jobs from the database."""
        with self._lock:
            self._revision = self.db.get_setting(REVISION_KEY, 0)
            for job in self._sched.get_jobs():
                job.remove()
            self._sched.add_job(self._watch, "interval", seconds=60, id=WATCH_JOB,
                                name="Schedule change watcher", max_instances=1, coalesce=True)
            self._sched.add_job(self._run_global, parse_cron(self.global_schedule, self.timezone),
                                id=GLOBAL_JOB, name="Global update check", max_instances=1,
                                coalesce=True, misfire_grace_time=3600)
            with self.db.session() as s:
                apps = s.scalars(select(Application).where(Application.enabled.is_(True))).all()
                custom = [(a.app_id, a.effective_schedule) for a in apps
                          if a.effective_schedule not in (None, "manual")]
            for app_id, expr in custom:
                try:
                    trigger = parse_cron(expr, self.timezone)
                except ValueError:
                    log.error("Invalid schedule '%s' for %s - ignored", expr, app_id)
                    continue
                self._sched.add_job(self.updater.check_app, trigger, args=[app_id], id=f"app:{app_id}",
                                    name=f"Update check {app_id}", max_instances=1, coalesce=True,
                                    misfire_grace_time=3600)
        log.info("Scheduler loaded: global '%s', %d custom schedule(s)", self.global_schedule, len(custom))

    def jobs(self) -> list[dict[str, Any]]:
        out = []
        for job in self._sched.get_jobs():
            if job.id == WATCH_JOB:
                continue
            nxt = getattr(job, "next_run_time", None)
            out.append({"id": job.id, "name": job.name,
                        "trigger": str(job.trigger),
                        "next_run": nxt.isoformat() if nxt else None})
        return sorted(out, key=lambda j: j["id"])

    def next_run(self, app_id: str) -> str | None:
        job = self._sched.get_job(f"app:{app_id}")
        if job is None:
            with self.db.session() as s:
                app = self.db.get_app(s, app_id)
                if app is None or not app.enabled or app.effective_schedule == "manual":
                    return None
            job = self._sched.get_job(GLOBAL_JOB)
        nxt = getattr(job, "next_run_time", None) if job else None
        return nxt.isoformat() if nxt else None

    # ------------------------------------------------------------- execution
    def _run_global(self) -> None:
        app_ids = self.updater.enabled_app_ids(only_global_schedule=True)
        self.db.log_event("schedule", f"Global update check started for {len(app_ids)} application(s)")
        results = self.updater.check_many(app_ids)
        summary: dict[str, int] = {}
        for r in results:
            summary[r.status] = summary.get(r.status, 0) + 1
        self.db.log_event("schedule", "Global update check finished", details=summary)

    def run_in_background(self, app_ids: list[str], force: bool = False, reason: str = "manual") -> None:
        def run() -> None:
            self.db.log_event("schedule", f"{reason.capitalize()} check started for {len(app_ids)} application(s)")
            self.updater.check_many(app_ids, force=force)

        threading.Thread(target=run, name=f"check-{reason}", daemon=True).start()
