"""Application manifests.

Each application is described by a YAML manifest in ``manifests_dir``. See
``docs/manifest-reference.md`` for the full schema. Manifests are synchronised
into the ``applications`` table on startup and whenever ``sync`` is run; the
database then holds the authoritative state used by the scheduler and API.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

import yaml
from sqlalchemy import select

from .db import Application, Database
from .installers import INSTALLER_TYPES
from .sources import SOURCE_TYPES

APP_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+\-]{1,199}$")


class ManifestError(ValueError):
    pass


def _cron_ok(expr: str) -> bool:
    from apscheduler.triggers.cron import CronTrigger

    try:
        CronTrigger.from_crontab(expr)
        return True
    except ValueError:
        return False


def validate_manifest(m: dict[str, Any], origin: str = "<manifest>") -> dict[str, Any]:
    """Validate and normalise a manifest dict. Raises ManifestError."""
    if not isinstance(m, dict):
        raise ManifestError(f"{origin}: manifest must be a mapping")
    errors: list[str] = []

    app_id = m.get("id")
    if not app_id or not APP_ID_RE.match(str(app_id)):
        errors.append("'id' is required and may only contain letters, digits, '.', '_', '+' and '-'")
    if not m.get("name"):
        errors.append("'name' is required")

    source = m.get("source") or {}
    stype = source.get("type")
    if stype not in SOURCE_TYPES:
        errors.append(f"source.type must be one of {sorted(SOURCE_TYPES)}")
    else:
        try:
            SOURCE_TYPES[stype].validate(source)
        except ValueError as exc:
            errors.append(f"source: {exc}")

    installer = m.get("installer") or {}
    itype = installer.get("type")
    if itype and itype not in INSTALLER_TYPES:
        errors.append(f"installer.type must be one of {sorted(INSTALLER_TYPES)}")
    if itype == "exe" and not installer.get("install_args"):
        errors.append("installer.install_args is required for generic 'exe' installers")
    behavior = installer.get("upgrade_behavior", "install")
    if behavior not in ("install", "uninstall_previous"):
        errors.append("installer.upgrade_behavior must be 'install' or 'uninstall_previous'")

    schedule = m.get("schedule")
    if schedule not in (None, "", "global", "manual") and not _cron_ok(str(schedule)):
        errors.append(f"schedule '{schedule}' is not a valid cron expression")

    retain = m.get("retain_versions")
    if retain is not None and (not isinstance(retain, int) or retain < 1):
        errors.append("retain_versions must be a positive integer")

    detection = m.get("detection") or {}
    for key in ("display_name", "publisher"):
        if detection.get(key):
            try:
                re.compile(detection[key])
            except re.error as exc:
                errors.append(f"detection.{key} is not a valid regex: {exc}")

    if errors:
        raise ManifestError(f"{origin}: " + "; ".join(errors))

    if schedule in ("", "global"):
        m["schedule"] = None
    return m


def load_manifest_file(path: Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    return validate_manifest(data, str(path))


def manifest_hash(m: dict[str, Any]) -> str:
    return hashlib.sha256(json.dumps(m, sort_keys=True, default=str).encode()).hexdigest()


def apply_manifest(app: Application, m: dict[str, Any]) -> None:
    installer = m.get("installer") or {}
    detection = dict(m.get("detection") or {})
    if not detection.get("display_name"):
        detection["display_name"] = "^" + re.escape(m["name"])

    app.app_id = m["id"]
    app.name = m["name"]
    app.publisher = m.get("publisher")
    app.description = m.get("description")
    app.homepage = m.get("homepage")
    app.license = m.get("license")
    app.category = m.get("category")
    app.tags = list(m.get("tags") or [])
    app.enabled = bool(m.get("enabled", True))
    app.schedule = m.get("schedule")
    app.retain_versions = m.get("retain_versions")
    app.source_type = m["source"]["type"]
    app.source_config = dict(m["source"])
    app.installer_type = installer.get("type")
    app.install_args = installer.get("install_args")
    app.uninstall_command = installer.get("uninstall_command")
    app.uninstall_args = installer.get("uninstall_args")
    app.architecture = installer.get("architecture") or m["source"].get("architecture")
    app.scope = installer.get("scope", "machine")
    app.upgrade_behavior = installer.get("upgrade_behavior", "install")
    app.success_exit_codes = list(installer.get("success_exit_codes") or [])
    app.detection = detection
    app.manifest_hash = manifest_hash(m)


def upsert_manifest(db: Database, m: dict[str, Any], manifest_path: str | None = None) -> tuple[str, bool]:
    """Insert or update one application. Returns (app_id, changed)."""
    m = validate_manifest(m, manifest_path or m.get("id", "<api>"))
    with db.session() as s:
        app = db.get_app(s, m["id"])
        created = app is None
        if created:
            app = Application(app_id=m["id"], name=m["name"], source_type=m["source"]["type"])
            s.add(app)
        elif app.manifest_hash == manifest_hash(m):
            return m["id"], False
        apply_manifest(app, m)
        if manifest_path:
            app.manifest_path = manifest_path
    db.log_event("manifest", f"{'Added' if created else 'Updated'} application definition",
                 app_id=m["id"], details={"manifest": manifest_path})
    return m["id"], True


def sync_manifests(db: Database, directory: Path) -> dict[str, list[str]]:
    """Load every *.yaml / *.yml manifest from ``directory`` into the database."""
    result: dict[str, list[str]] = {"added_or_updated": [], "unchanged": [], "errors": []}
    if not directory.exists():
        return result
    files = sorted(list(directory.rglob("*.yaml")) + list(directory.rglob("*.yml")))
    for path in files:
        try:
            m = load_manifest_file(path)
            app_id, changed = upsert_manifest(db, m, str(path))
            result["added_or_updated" if changed else "unchanged"].append(app_id)
        except Exception as exc:  # noqa: BLE001 - report every bad manifest
            result["errors"].append(str(exc))
            db.log_event("manifest", f"Invalid manifest {path.name}: {exc}", level="error")
    return result


def export_manifest(app: Application) -> dict[str, Any]:
    """Rebuild a manifest dict from a database row (used by the API)."""
    installer = {
        k: v for k, v in {
            "type": app.installer_type,
            "install_args": app.install_args,
            "uninstall_command": app.uninstall_command,
            "uninstall_args": app.uninstall_args,
            "architecture": app.architecture,
            "scope": app.scope,
            "upgrade_behavior": app.upgrade_behavior,
            "success_exit_codes": app.success_exit_codes or None,
        }.items() if v
    }
    return {
        k: v for k, v in {
            "id": app.app_id,
            "name": app.name,
            "publisher": app.publisher,
            "description": app.description,
            "homepage": app.homepage,
            "license": app.license,
            "category": app.category,
            "tags": app.tags or None,
            "enabled": app.enabled,
            "schedule": app.schedule,
            "retain_versions": app.retain_versions,
            "source": app.source_config,
            "installer": installer or None,
            "detection": app.detection or None,
        }.items() if v is not None
    }


def list_app_ids(db: Database) -> list[str]:
    with db.session() as s:
        return list(s.scalars(select(Application.app_id).order_by(Application.app_id)))
