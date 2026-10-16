"""REST API (FastAPI). Interactive documentation is served at ``/docs``.

Read endpoints are open to the LAN so every client can browse the catalog.
Administrative endpoints require the ``X-Api-Key`` header; when no key is
configured they are only accepted from the server itself (localhost).
"""

from __future__ import annotations

import hmac
import html
import shutil
import tempfile
from pathlib import Path

import yaml
from contextlib import asynccontextmanager
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel, Field
from sqlalchemy import or_, select

from . import __version__
from .context import AppContext
from .db import Application, AppVersion, Event
from .manifest import ManifestError, export_manifest
from .onboarding import (
    TEMPLATES,
    OnboardingError,
    WingetCatalog,
    manifest_from_winget,
    preview,
    remove_application,
    save_application,
)
from .versioning import is_newer, sort_versions


# ----------------------------------------------------------------- serialisers
def _iso(value) -> str | None:
    return value.isoformat() + "Z" if value else None


def serialize_version(ctx: AppContext, app: Application, v: AppVersion) -> dict[str, Any]:
    repo = ctx.repo
    return {
        "app_id": app.app_id,
        "version": v.version,
        "status": v.status,
        "is_latest": v.is_latest,
        "filename": v.filename,
        "setup_path": v.setup_path,
        "installer_type": v.installer_type,
        "architecture": v.architecture,
        "scope": v.scope,
        "sha256": v.sha256,
        "size_bytes": v.size_bytes,
        "downloaded_at": _iso(v.downloaded_at),
        "purged_at": _iso(v.purged_at),
        "source_url": v.source_url,
        "release_notes_url": v.release_notes_url,
        "product_code": v.product_code,
        "location": {
            "relative": v.relative_path,
            "unc": v.unc_path,
            "http": repo.http(v.relative_path) if v.status == "available" else None,
        },
        "install": {"executable": v.install_executable, "arguments": v.install_arguments,
                    "command": v.install_command},
        "uninstall": {"executable": v.uninstall_executable, "arguments": v.uninstall_arguments,
                      "command": v.uninstall_command},
        "success_exit_codes": sorted(set([0, 1707, 3010, 1641] + list(app.success_exit_codes or []))),
        "reboot_exit_codes": [3010, 1641],
        "upgrade_behavior": app.upgrade_behavior,
        "target_product_codes": (v.msi_info or {}).get("TargetProductCodes") or [],
        "intune": {
            "status": v.intune_status,
            "error": v.intune_error,
            "package": {"unc": repo.unc(v.intunewin_relative_path), "http": repo.http(v.intunewin_relative_path)},
            "info": {"unc": repo.unc(v.intune_info_relative_path), "http": repo.http(v.intune_info_relative_path)},
            "detection_script": {"unc": repo.unc(v.intune_detection_relative_path),
                                 "http": repo.http(v.intune_detection_relative_path)},
        },
    }


def serialize_app(ctx: AppContext, app: Application, detail: bool = False) -> dict[str, Any]:
    available = sort_versions([v for v in app.versions if v.status == "available"], key=lambda v: v.version)
    latest = available[0] if available else None
    patch_targets = set((latest.msi_info or {}).get("TargetProductCodes") or []) \
        if latest and latest.installer_type == "msp" else set()
    data: dict[str, Any] = {
        "id": app.app_id,
        "name": app.name,
        "publisher": app.publisher,
        "description": app.description,
        "homepage": app.homepage,
        "license": app.license,
        "category": app.category,
        "tags": app.tags or [],
        "enabled": app.enabled,
        "latest_version": app.latest_version,
        "versions": [v.version for v in available],
        "installer_type": latest.installer_type if latest else app.installer_type,
        "architecture": latest.architecture if latest else app.architecture,
        "scope": app.scope,
        "size_bytes": latest.size_bytes if latest else None,
        "downloaded_at": _iso(latest.downloaded_at) if latest else None,
        "upgrade_behavior": app.upgrade_behavior,
        "update_with": (app.extra or {}).get("update_with"),
        "requires": (app.extra or {}).get("requires") or [],
        "is_patch": (latest.installer_type if latest else app.installer_type) == "msp",
        "manual": app.is_manual,
        "detection": {
            "display_name": (app.detection or {}).get("display_name"),
            "publisher": (app.detection or {}).get("publisher"),
            "key_pattern": (app.detection or {}).get("key_pattern"),
            "exclude": (app.detection or {}).get("exclude"),
            "appx_name": (app.detection or {}).get("appx_name"),
            "product_codes": sorted({v.product_code for v in app.versions if v.product_code}
                                    | set(filter(None, [(app.detection or {}).get("product_code")]))
                                    | patch_targets),
            # A patch only applies to the products it targets (read from the .msp itself)
            "match_codes_only": bool(patch_targets),
        },
        "schedule": app.effective_schedule or "global",
        "last_checked_at": _iso(app.last_checked_at),
        "last_updated_at": _iso(app.last_updated_at),
        "last_check_status": app.last_check_status,
        "last_error": app.last_error,
    }
    if detail:
        data["source"] = {"type": app.source_type, **(app.source_config or {})}
        data["setup_file"] = (app.extra or {}).get("setup_file")
        data["next_check"] = ctx.scheduler.next_run(app.app_id)
        data["version_details"] = [serialize_version(ctx, app, v) for v in available]
        data["manifest"] = export_manifest(app)
    return data


# ----------------------------------------------------------------- request models
class InstalledItem(BaseModel):
    id: str
    version: str | None = None


class UpdateQuery(BaseModel):
    installed: list[InstalledItem] = Field(default_factory=list)


class ScheduleBody(BaseModel):
    schedule: str | None = Field(None, description="Cron expression, 'manual', or 'global'/null")


class CheckBody(BaseModel):
    app_ids: list[str] | None = None
    force: bool = False


def create_app(ctx: AppContext, start_scheduler: bool = True) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if start_scheduler:
            ctx.scheduler.start(run_now=bool(ctx.config.section("schedule").get("run_on_startup")))
        ctx.db.log_event("server", f"AppDepot server {__version__} started")
        yield
        ctx.scheduler.shutdown()

    api = FastAPI(title="AppDepot", version=__version__, lifespan=lifespan,
                  description="Self-hosted application repository with Intune packaging.")

    def require_admin(request: Request) -> None:
        key = ctx.config.api_key
        supplied = request.headers.get("x-api-key")
        if key:
            if not supplied or not hmac.compare_digest(supplied, key):
                raise HTTPException(401, "A valid X-Api-Key header is required")
        elif request.client is None or request.client.host not in ("127.0.0.1", "::1", "testclient"):
            raise HTTPException(403, "No API key is configured; admin calls are only allowed from localhost")

    def get_app_or_404(session, app_id: str) -> Application:
        app = session.scalar(select(Application).where(Application.app_id.ilike(app_id)))
        if app is None:
            raise HTTPException(404, f"Application '{app_id}' not found")
        return app

    # ---------------------------------------------------------------- public
    @api.get("/api/v1/health", tags=["status"])
    def health():
        with ctx.db.session() as s:
            count = len(s.scalars(select(Application.id)).all())
        return {"status": "ok", "version": __version__, "applications": count,
                "unc_root": ctx.config.unc_root, "public_url": ctx.config.public_url,
                "running_checks": ctx.updater.running}

    @api.get("/api/v1/apps", tags=["catalog"])
    def list_apps(search: str | None = Query(None, description="Matches id, name, publisher, tags"),
                  category: str | None = None, include_empty: bool = False):
        with ctx.db.session() as s:
            q = select(Application).where(Application.enabled.is_(True)).order_by(Application.name)
            if search:
                like = f"%{search}%"
                q = q.where(or_(Application.app_id.ilike(like), Application.name.ilike(like),
                                Application.publisher.ilike(like), Application.description.ilike(like)))
            if category:
                q = q.where(Application.category.ilike(category))
            apps = s.scalars(q).all()
            out = [serialize_app(ctx, a) for a in apps]
        return [a for a in out if include_empty or a["latest_version"]]

    @api.get("/api/v1/apps/{app_id}", tags=["catalog"])
    def get_app(app_id: str):
        with ctx.db.session() as s:
            return serialize_app(ctx, get_app_or_404(s, app_id), detail=True)

    @api.get("/api/v1/apps/{app_id}/versions", tags=["catalog"])
    def list_versions(app_id: str, include_purged: bool = False):
        with ctx.db.session() as s:
            app = get_app_or_404(s, app_id)
            rows = [v for v in app.versions if include_purged or v.status == "available"]
            return [serialize_version(ctx, app, v) for v in sort_versions(rows, key=lambda v: v.version)]

    @api.get("/api/v1/apps/{app_id}/versions/{version}", tags=["catalog"])
    def get_version(app_id: str, version: str):
        with ctx.db.session() as s:
            app = get_app_or_404(s, app_id)
            available = [v for v in app.versions if v.status == "available"]
            if version.lower() == "latest":
                row = next((v for v in available if v.is_latest), None)
            else:
                row = next((v for v in available if v.version == version), None)
            if row is None:
                raise HTTPException(404, f"Version '{version}' of '{app_id}' is not available")
            return serialize_version(ctx, app, row)

    @api.post("/api/v1/updates", tags=["catalog"])
    def find_updates(body: UpdateQuery):
        """Given a client's installed versions, return which applications have updates."""
        result = []
        with ctx.db.session() as s:
            for item in body.installed:
                app = s.scalar(select(Application).where(Application.app_id.ilike(item.id)))
                if app is None or not app.latest_version:
                    continue
                result.append({"id": app.app_id, "name": app.name, "installed_version": item.version,
                               "latest_version": app.latest_version,
                               "update_available": bool(item.version) and is_newer(app.latest_version, item.version)})
        return result

    @api.get("/api/v1/categories", tags=["catalog"])
    def categories():
        with ctx.db.session() as s:
            cats = s.scalars(select(Application.category).distinct()).all()
        return sorted(c for c in cats if c)

    @api.get("/api/v1/events", tags=["status"])
    def events(app_id: str | None = None, level: str | None = None, limit: int = Query(100, le=1000)):
        with ctx.db.session() as s:
            q = select(Event).order_by(Event.id.desc()).limit(limit)
            if app_id:
                q = q.where(Event.app_id.ilike(app_id))
            if level:
                q = q.where(Event.level == level)
            return [{"id": e.id, "timestamp": _iso(e.timestamp), "app_id": e.app_id, "version": e.version,
                     "level": e.level, "event": e.event, "message": e.message, "details": e.details}
                    for e in s.scalars(q)]

    @api.get("/api/v1/schedule", tags=["schedule"])
    def get_schedule():
        return {"global": ctx.scheduler.global_schedule, "timezone": ctx.scheduler.timezone,
                "jobs": ctx.scheduler.jobs()}

    @api.get("/files/{path:path}", tags=["files"], include_in_schema=True)
    def download(path: str):
        if path.startswith(".") or "/." in path:
            raise HTTPException(404)
        try:
            target = ctx.repo.abs(path)
        except ValueError:
            raise HTTPException(404) from None
        if not target.is_file():
            raise HTTPException(404)
        return FileResponse(target, filename=target.name)

    # ---------------------------------------------------------------- admin
    admin = [Depends(require_admin)]

    def _save(manifest: dict[str, Any], replace: bool, check: bool) -> dict[str, Any]:
        try:
            result = save_application(ctx.config, ctx.db, manifest, replace=replace, added_by="the API")
        except ManifestError as exc:
            status = 409 if "already exists" in str(exc) else 422
            raise HTTPException(status, str(exc)) from None
        ctx.scheduler.bump_revision()
        ctx.scheduler.reload()
        if check:
            ctx.scheduler.run_in_background([result["id"]], reason="new application")
            result["check_queued"] = True
        return result

    @api.post("/api/v1/apps", tags=["admin"], dependencies=admin, status_code=201)
    def add_app(manifest: dict[str, Any], replace: bool = False, check: bool = False):
        """Add an application from a manifest (JSON, same schema as the YAML files).

        The manifest is written to the manifests folder and loaded into the database.
        `replace=true` overwrites an existing application; `check=true` downloads it now.
        """
        return _save(manifest, replace, check)

    @api.post("/api/v1/apps/yaml", tags=["admin"], dependencies=admin, status_code=201)
    async def add_app_yaml(request: Request, replace: bool = False, check: bool = False):
        """Add an application from a YAML manifest sent as the raw request body."""
        try:
            manifest = yaml.safe_load((await request.body()).decode("utf-8"))
        except (yaml.YAMLError, UnicodeDecodeError) as exc:
            raise HTTPException(422, f"Invalid YAML: {exc}") from None
        if not isinstance(manifest, dict):
            raise HTTPException(422, "The YAML document must be a mapping")
        return await run_in_threadpool(_save, manifest, replace, check)

    @api.post("/api/v1/apps/preview", tags=["admin"], dependencies=admin)
    def preview_manifest(manifest: dict[str, Any]):
        """Resolve a manifest's sources without saving or downloading: what would be installed?"""
        try:
            return preview(ctx.config, manifest)
        except ManifestError as exc:
            raise HTTPException(422, str(exc)) from None

    @api.post("/api/v1/apps/preview/yaml", tags=["admin"], dependencies=admin)
    async def preview_manifest_yaml(request: Request):
        """Like /apps/preview, for a YAML manifest sent as the raw request body."""
        try:
            manifest = yaml.safe_load((await request.body()).decode("utf-8"))
        except (yaml.YAMLError, UnicodeDecodeError) as exc:
            raise HTTPException(422, f"Invalid YAML: {exc}") from None
        if not isinstance(manifest, dict):
            raise HTTPException(422, "The YAML document must be a mapping")
        return await run_in_threadpool(preview_manifest, manifest)

    @api.post("/api/v1/apps/{app_id}/preview", tags=["admin"], dependencies=admin)
    def preview_existing(app_id: str):
        with ctx.db.session() as s:
            manifest = export_manifest(get_app_or_404(s, app_id))
        return preview(ctx.config, manifest)

    @api.get("/api/v1/winget/search", tags=["admin"], dependencies=admin)
    def winget_search(q: str = Query(..., min_length=2), limit: int = Query(25, le=100)):
        """Search the winget catalog. Results include whether the app is already in the repository."""
        try:
            results = WingetCatalog(ctx.config).search(q, limit)
        except OnboardingError as exc:
            raise HTTPException(503, str(exc)) from None
        with ctx.db.session() as s:
            known = {a.lower() for a in s.scalars(select(Application.app_id))}
        for r in results:
            r["in_repository"] = r["id"].lower() in known
        return results

    @api.get("/api/v1/winget/packages/{package_id}", tags=["admin"], dependencies=admin)
    def winget_manifest(package_id: str, category: str | None = None, architecture: str = "x64",
                        include_preview: bool = True):
        """Generate an AppDepot manifest for a winget package (not saved), plus a preview."""
        try:
            manifest, info = manifest_from_winget(ctx.config, package_id, category, architecture)
        except OnboardingError as exc:
            raise HTTPException(404, str(exc)) from None
        result = {"manifest": manifest, "info": info}
        if include_preview:
            result["preview"] = preview(ctx.config, manifest)
        with ctx.db.session() as s:
            result["in_repository"] = ctx.db.get_app(s, package_id) is not None
        return result

    @api.get("/api/v1/templates/{source_type}", tags=["admin"], dependencies=admin)
    def manifest_template(source_type: str):
        if source_type not in TEMPLATES:
            raise HTTPException(404, f"Templates: {', '.join(TEMPLATES)}")
        return {"type": source_type, "yaml": TEMPLATES[source_type]}

    @api.delete("/api/v1/apps/{app_id}", tags=["admin"], dependencies=admin)
    def delete_app(app_id: str, delete_files: bool = False):
        """Remove an application. Its manifest file is renamed to *.removed so it is not re-added."""
        try:
            result = remove_application(ctx.db, ctx.repo, app_id, delete_files)
        except KeyError:
            raise HTTPException(404, f"Application '{app_id}' not found") from None
        ctx.scheduler.bump_revision()
        ctx.scheduler.reload()
        return {"deleted": result["id"], **result}

    @api.post("/api/v1/apps/{app_id}/check", tags=["admin"], dependencies=admin)
    def check_app(app_id: str, force: bool = False, wait: bool = False):
        with ctx.db.session() as s:
            real_id = get_app_or_404(s, app_id).app_id
        if wait:
            return ctx.updater.check_app(real_id, force=force).to_dict()
        ctx.scheduler.run_in_background([real_id], force=force, reason="manual")
        return {"queued": [real_id]}

    @api.post("/api/v1/check", tags=["admin"], dependencies=admin)
    def check_many(body: CheckBody):
        ids = body.app_ids or ctx.updater.enabled_app_ids()
        ctx.scheduler.run_in_background(ids, force=body.force, reason="manual")
        return {"queued": ids}

    @api.put("/api/v1/schedule", tags=["admin"], dependencies=admin)
    def set_global_schedule(body: ScheduleBody):
        if not body.schedule:
            raise HTTPException(422, "schedule is required")
        try:
            ctx.scheduler.set_global_schedule(body.schedule)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from None
        return get_schedule()

    @api.put("/api/v1/apps/{app_id}/schedule", tags=["admin"], dependencies=admin)
    def set_app_schedule(app_id: str, body: ScheduleBody):
        with ctx.db.session() as s:
            real_id = get_app_or_404(s, app_id).app_id
        try:
            ctx.scheduler.set_app_schedule(real_id, body.schedule)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from None
        return {"id": real_id, "schedule": body.schedule or "global", "next_check": ctx.scheduler.next_run(real_id)}

    @api.post("/api/v1/apps/{app_id}/versions", tags=["admin"], dependencies=admin, status_code=201)
    async def upload_version(app_id: str, request: Request, filename: str = Query(..., min_length=1),
                             version: str | None = None, replace: bool = False):
        """Upload an installer file (raw request body) as a new version of an application.

        Used for manual applications, and to add a version the server cannot download itself.
        The version is read from MSI files when not given. ZIP archives are unpacked using the
        application's installer.setup_file. The file goes through the same packaging as a download
        (commands, Intune package, retention).
        """
        with ctx.db.session() as s:
            real_id = get_app_or_404(s, app_id).app_id
        tmp_dir = Path(tempfile.mkdtemp(dir=ctx.repo.tmp, prefix="upload-"))
        tmp = tmp_dir / "upload.bin"
        try:
            size = 0
            with open(tmp, "wb") as fh:
                async for chunk in request.stream():
                    fh.write(chunk)
                    size += len(chunk)
            if size == 0:
                raise HTTPException(422, "The request body (the installer file) is empty")
            try:
                result = await run_in_threadpool(ctx.updater.import_installer, real_id, tmp,
                                                 Path(filename).name, version, replace, "upload")
            except ValueError as exc:
                status = 409 if "already in the repository" in str(exc) else 422
                raise HTTPException(status, str(exc)) from None
            return result.to_dict()
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    @api.post("/api/v1/apps/{app_id}/versions/{version}/repackage", tags=["admin"], dependencies=admin)
    def repackage(app_id: str, version: str):
        with ctx.db.session() as s:
            real_id = get_app_or_404(s, app_id).app_id
        try:
            return ctx.updater.repackage(real_id, version)
        except KeyError:
            raise HTTPException(404, "Version not found") from None

    @api.delete("/api/v1/apps/{app_id}/versions/{version}", tags=["admin"], dependencies=admin)
    def delete_version(app_id: str, version: str):
        with ctx.db.session() as s:
            real_id = get_app_or_404(s, app_id).app_id
        try:
            ctx.updater.delete_version(real_id, version)
        except KeyError:
            raise HTTPException(404, "Version not found") from None
        return {"deleted": f"{real_id} {version}"}

    @api.post("/api/v1/manifests/sync", tags=["admin"], dependencies=admin)
    def sync():
        return ctx.sync()

    # ---------------------------------------------------------------- dashboard
    @api.get("/", response_class=HTMLResponse, include_in_schema=False)
    def dashboard():
        with ctx.db.session() as s:
            apps = s.scalars(select(Application).order_by(Application.name)).all()
            rows = []
            for a in apps:
                status = a.last_check_status or "never checked"
                versions = ", ".join(v.version for v in sort_versions(
                    [v for v in a.versions if v.status == "available"], key=lambda v: v.version))
                rows.append(
                    f"<tr><td><b>{html.escape(a.name)}</b><br><small>{html.escape(a.app_id)}</small></td>"
                    f"<td>{html.escape(a.latest_version or '-')}</td><td>{html.escape(versions)}</td>"
                    f"<td><span class='s {html.escape(status.replace(' ', '_'))}'>{html.escape(status)}</span>"
                    f"{'<br><small>' + html.escape(a.last_error[:200]) + '</small>' if a.last_error else ''}</td>"
                    f"<td>{html.escape(_iso(a.last_checked_at) or '-')}</td>"
                    f"<td>{html.escape(a.effective_schedule or 'global')}</td></tr>")
        return DASHBOARD.format(version=__version__, schedule=html.escape(ctx.scheduler.global_schedule),
                                count=len(apps), rows="\n".join(rows) or "<tr><td colspan=6>No applications</td></tr>")

    return api


DASHBOARD = """<!doctype html><html><head><meta charset="utf-8"><title>AppDepot</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body{{font-family:Segoe UI,system-ui,sans-serif;margin:0;background:#f4f6fa;color:#1d2433}}
header{{background:#1f3a8a;color:#fff;padding:18px 28px}}header h1{{margin:0;font-weight:600}}
header p{{margin:4px 0 0;opacity:.8}}main{{padding:24px 28px}}
table{{border-collapse:collapse;width:100%;background:#fff;border-radius:8px;overflow:hidden;
box-shadow:0 1px 3px rgba(0,0,0,.08)}}th,td{{padding:10px 14px;text-align:left;border-bottom:1px solid #eef0f4;
vertical-align:top}}th{{background:#f8f9fc;font-weight:600;font-size:13px;text-transform:uppercase;color:#5b6475}}
small{{color:#6b7280}}.s{{padding:2px 8px;border-radius:10px;font-size:12px;background:#e5e7eb}}
.updated,.up_to_date{{background:#d1fae5;color:#065f46}}.failed{{background:#fee2e2;color:#991b1b}}
a{{color:#1f3a8a}}</style></head><body>
<header><h1>AppDepot</h1><p>Server {version} &middot; {count} applications &middot; global schedule
<code>{schedule}</code> &middot; <a style="color:#fff" href="/docs">API documentation</a></p></header>
<main><table><tr><th>Application</th><th>Latest</th><th>Available versions</th><th>Last check</th>
<th>Checked (UTC)</th><th>Schedule</th></tr>{rows}</table></main></body></html>"""
