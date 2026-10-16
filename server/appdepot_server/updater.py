"""Check for, download, package and record new application versions."""

from __future__ import annotations

import hashlib
import logging
import re
import shutil
import tempfile
import threading
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import httpx
from sqlalchemy import select

from .config import Config
from .db import Application, AppVersion, Database, utcnow
from .installers import MSI_TYPES, build_commands, guess_installer_type
from .intune_info import deployment_text, detection_script
from .intunewin import create_intunewin_native, create_intunewin_official
from .msi import msi_summary
from .repository import Repository, safe_segment
from .sources import ReleaseInfo, SourceContext, get_source, make_client
from .versioning import sort_versions, version_key

log = logging.getLogger("appdepot.updater")


@dataclass
class CheckResult:
    app_id: str
    status: str              # updated | up_to_date | failed | skipped | disabled
    version: str | None = None
    message: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _filename_from_disposition(header: str | None) -> str | None:
    if not header:
        return None
    m = re.search(r"filename\*=(?:UTF-8'')?\"?([^\";]+)", header, re.IGNORECASE) or \
        re.search(r'filename="?([^";]+)"?', header, re.IGNORECASE)
    return m.group(1).strip() if m else None


def download_file(client: httpx.Client, url: str, dest_dir: Path,
                  expected_sha256: str | None = None) -> tuple[Path, str, int, str, str | None]:
    """Stream ``url`` into ``dest_dir``. Returns (path, sha256, size, final_url, cd_filename)."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=dest_dir, suffix=".part")
    sha = hashlib.sha256()
    size = 0
    try:
        with open(fd, "wb") as fh, client.stream("GET", url) as resp:
            resp.raise_for_status()
            for chunk in resp.iter_bytes(1024 * 1024):
                fh.write(chunk)
                sha.update(chunk)
                size += len(chunk)
            final_url = str(resp.url)
            cd_name = _filename_from_disposition(resp.headers.get("content-disposition"))
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise
    digest = sha.hexdigest()
    if expected_sha256 and digest.lower() != expected_sha256.lower():
        Path(tmp_name).unlink(missing_ok=True)
        raise ValueError(f"SHA-256 mismatch: expected {expected_sha256}, got {digest}")
    if size == 0:
        Path(tmp_name).unlink(missing_ok=True)
        raise ValueError("Downloaded file is empty")
    return Path(tmp_name), digest, size, final_url, cd_name


class Updater:
    def __init__(self, config: Config, db: Database, repo: Repository):
        self.config = config
        self.db = db
        self.repo = repo
        self._semaphore = threading.BoundedSemaphore(int(config.section("schedule").get("max_concurrent", 2)))
        self._locks: dict[str, threading.Lock] = defaultdict(threading.Lock)
        self._running: set[str] = set()

    # ------------------------------------------------------------------ public
    @property
    def running(self) -> list[str]:
        return sorted(self._running)

    def check_app(self, app_id: str, force: bool = False) -> CheckResult:
        lock = self._locks[app_id]
        if not lock.acquire(blocking=False):
            return CheckResult(app_id, "skipped", message="A check for this application is already running")
        try:
            with self._semaphore:
                self._running.add(app_id)
                try:
                    return self._check(app_id, force)
                finally:
                    self._running.discard(app_id)
        finally:
            lock.release()

    def check_many(self, app_ids: list[str], force: bool = False) -> list[CheckResult]:
        results: list[CheckResult] = []
        threads = []
        lock = threading.Lock()

        def run(aid: str) -> None:
            r = self.check_app(aid, force)
            with lock:
                results.append(r)

        for aid in app_ids:
            t = threading.Thread(target=run, args=(aid,), name=f"check-{aid}", daemon=True)
            t.start()
            threads.append(t)
        for t in threads:
            t.join()
        return sorted(results, key=lambda r: r.app_id)

    def enabled_app_ids(self, only_global_schedule: bool = False) -> list[str]:
        with self.db.session() as s:
            apps = s.scalars(select(Application).where(Application.enabled.is_(True))).all()
            return sorted(a.app_id for a in apps
                          if not only_global_schedule or a.effective_schedule is None)

    def repackage(self, app_id: str, version: str) -> dict[str, Any]:
        with self.db.session() as s:
            app = self.db.get_app(s, app_id)
            if app is None:
                raise KeyError(app_id)
            row = s.scalar(select(AppVersion).where(AppVersion.application_id == app.id,
                                                    AppVersion.version == version,
                                                    AppVersion.status == "available"))
            if row is None:
                raise KeyError(f"{app_id} {version}")
            self._finalize(app, row)
            result = {"intune_status": row.intune_status, "intune_error": row.intune_error}
        self.db.log_event("package", "Repackaged for Intune", app_id=app_id, version=version, details=result)
        return result

    def apply_retention(self, app_id: str) -> list[str]:
        purged: list[str] = []
        with self.db.session() as s:
            app = self.db.get_app(s, app_id)
            if app is None:
                return purged
            keep = app.retain_versions or self.config.retain_versions
            available = sort_versions([v for v in app.versions if v.status == "available"],
                                      key=lambda v: v.version)
            for row in available[keep:]:
                self.repo.delete_version(app_id, row.version)
                row.status = "purged"
                row.is_latest = False
                row.purged_at = utcnow()
                purged.append(row.version)
            self._refresh_latest(app)
        for v in purged:
            self.db.log_event("purge", f"Removed version {v} (retention: keep {keep})", app_id=app_id, version=v)
        return purged

    def delete_version(self, app_id: str, version: str) -> None:
        with self.db.session() as s:
            app = self.db.get_app(s, app_id)
            row = next((v for v in (app.versions if app else []) if v.version == version), None)
            if row is None:
                raise KeyError(f"{app_id} {version}")
            self.repo.delete_version(app_id, version)
            s.delete(row)
            s.flush()
            s.refresh(app)
            self._refresh_latest(app)
        self.db.log_event("purge", f"Deleted version {version}", app_id=app_id, version=version)

    # ----------------------------------------------------------------- internals
    def _set_status(self, app_id: str, status: str, error: str | None = None,
                    state: dict | None = None) -> None:
        with self.db.session() as s:
            app = self.db.get_app(s, app_id)
            if app is None:
                return
            app.last_checked_at = utcnow()
            app.last_check_status = status
            app.last_error = error
            if state is not None:
                app.source_state = {**(app.source_state or {}), **state}

    def _check(self, app_id: str, force: bool) -> CheckResult:
        with self.db.session() as s:
            app = self.db.get_app(s, app_id)
            if app is None:
                raise KeyError(f"Unknown application '{app_id}'")
            source_type, source_cfg = app.source_type, dict(app.source_config or {})
            source_state = dict(app.source_state or {})
            existing = {v.version for v in app.versions if v.status == "available"}
            manifest_type = app.installer_type

        self.db.log_event("check", "Checking for updates", app_id=app_id)
        log.info("Checking %s", app_id)
        client = make_client(self.config.section("sources"))
        temp_dir: Path | None = None
        try:
            source = get_source(source_type, source_cfg)
            ctx = SourceContext(client=client, github_token=self.config.section("sources").get("github_token"),
                                state=source_state)
            release = source.resolve(ctx)

            if not force and (release.unchanged or (release.version and release.version in existing)):
                self._set_status(app_id, "up_to_date", state=release.state)
                self.db.log_event("check", f"Up to date ({release.version or 'unchanged download'})",
                                  app_id=app_id, version=release.version)
                return CheckResult(app_id, "up_to_date", release.version, "Already in repository")

            self.db.log_event("download", f"Downloading {release.url}", app_id=app_id, version=release.version)
            temp_dir = Path(tempfile.mkdtemp(dir=self.repo.tmp, prefix=safe_segment(app_id) + "-"))
            temp_file, sha, size, final_url, cd_name = download_file(client, release.url, temp_dir, release.sha256)
            filename = safe_segment(release.filename or cd_name or Path(final_url).name or "installer.exe")
            named = temp_dir / filename
            temp_file.rename(named)
            temp_file = named

            itype = manifest_type or release.installer_type or guess_installer_type(temp_file)
            msi_info = None
            if itype in MSI_TYPES or temp_file.suffix.lower() == ".msi":
                try:
                    msi_info = msi_summary(temp_file)
                except Exception as exc:  # noqa: BLE001
                    log.warning("Could not read MSI properties of %s: %s", filename, exc)

            version = release.version or (msi_info or {}).get("ProductVersion")
            if not version:
                raise ValueError("The source did not provide a version and none could be read from the file")

            if version in existing and not force:
                self._set_status(app_id, "up_to_date", state=release.state)
                self.db.log_event("check", f"Up to date ({version})", app_id=app_id, version=version)
                return CheckResult(app_id, "up_to_date", version, "Already in repository")
            if version in existing and force:
                self.delete_version(app_id, version)

            result = self._store(app_id, version, temp_file, filename, sha, size, release, itype,
                                 msi_info, final_url)
            self._set_status(app_id, "updated", state=release.state)
            purged = self.apply_retention(app_id)
            msg = f"Downloaded version {version}"
            if purged:
                msg += f"; purged {', '.join(purged)}"
            return CheckResult(app_id, "updated", version, msg + result)
        except Exception as exc:  # noqa: BLE001 - never let one app kill the scheduler
            log.exception("Check failed for %s", app_id)
            self._set_status(app_id, "failed", error=str(exc))
            self.db.log_event("error", f"Update check failed: {exc}", app_id=app_id, level="error")
            return CheckResult(app_id, "failed", None, str(exc))
        finally:
            client.close()
            if temp_dir is not None:
                shutil.rmtree(temp_dir, ignore_errors=True)

    def _store(self, app_id: str, version: str, temp_file: Path, filename: str, sha: str, size: int,
               release: ReleaseInfo, itype: str, msi_info: dict | None, final_url: str) -> str:
        rel = self.repo.store_installer(app_id, version, temp_file, filename)
        with self.db.session() as s:
            app = self.db.get_app(s, app_id)
            row = AppVersion(
                application=app,
                version=version,
                status="available",
                filename=Path(str(rel)).name,
                relative_path=str(rel),
                local_path=str(self.repo.abs(rel)),
                unc_path=self.repo.unc(rel),
                sha256=sha,
                size_bytes=size,
                source_url=final_url,
                release_notes_url=release.release_notes_url,
                installer_type=itype,
                architecture=release.architecture or app.architecture,
                scope=release.scope or app.scope,
                product_code=release.product_code or (msi_info or {}).get("ProductCode"),
                upgrade_code=(msi_info or {}).get("UpgradeCode"),
                msi_info=msi_info,
                downloaded_at=utcnow(),
                source_silent_args=release.install_args,
                source_custom_args=release.extra_args,
                install_executable="", install_arguments="", install_command="",
            )
            s.add(row)
            s.flush()
            self._finalize(app, row)
            self._refresh_latest(app)
            app.last_updated_at = utcnow()
            intune = row.intune_status
        self.db.log_event("update", f"Added version {version} ({filename}, {size:,} bytes)",
                          app_id=app_id, version=version, details={"sha256": sha, "source": final_url})
        return "" if intune in ("ok", "disabled") else f"; Intune packaging {intune}"

    def _finalize(self, app: Application, row: AppVersion) -> None:
        """(Re)build commands, Intune package, deployment sheet and metadata for a version."""
        detection = app.detection or {}
        display_rx = detection.get("display_name") or "^" + re.escape(app.name)

        cmds = build_commands(
            filename=row.filename,
            installer_type=row.installer_type,
            # manifest install_args win over switches published by the source
            install_args=app.install_args if app.install_args is not None else row.source_silent_args,
            extra_args=row.source_custom_args if app.install_args is None else None,
            product_code=row.product_code,
            uninstall_command=app.uninstall_command,
            uninstall_args=app.uninstall_args,
            display_name_regex=display_rx,
            version=row.version,
        )
        row.install_executable = cmds.install_executable
        row.install_arguments = cmds.install_arguments
        row.install_command = cmds.install_command
        row.uninstall_executable = cmds.uninstall_executable
        row.uninstall_arguments = cmds.uninstall_arguments
        row.uninstall_command = cmds.uninstall_command

        self._package_intune(app, row, display_rx)
        self.repo.write_metadata(app.app_id, row.version, self._metadata(app, row))

    def _package_intune(self, app: Application, row: AppVersion, display_rx: str) -> None:
        icfg = self.config.section("intune")
        if not icfg.get("enabled", True):
            row.intune_status, row.intune_error = "disabled", None
            return
        vrel = self.repo.version_rel(app.app_id, row.version)
        base = f"{safe_segment(app.app_id)}_{safe_segment(row.version)}"
        pkg_rel = vrel / "intune" / f"{base}.intunewin"
        txt_rel = vrel / "intune" / f"{base}.intune.txt"
        det_rel = vrel / "intune" / f"{base}.detect.ps1"
        installer_dir = self.repo.abs(row.relative_path).parent
        try:
            out = self.repo.abs(pkg_rel)
            out.parent.mkdir(parents=True, exist_ok=True)
            msi = dict(row.msi_info or {})
            if row.installer_type in MSI_TYPES and row.product_code:
                msi.setdefault("ProductCode", row.product_code)
                msi.setdefault("ProductVersion", row.version)
            if icfg.get("packager") == "official":
                create_intunewin_official(Path(icfg.get("intunewinapputil_path") or ""), installer_dir,
                                          row.filename, out)
            else:
                create_intunewin_native(installer_dir, row.filename, out,
                                        msi_info=msi if row.installer_type in MSI_TYPES else None)
            self.repo.abs(det_rel).write_text(
                detection_script(app_name=app.name, version=row.version, display_name_regex=display_rx,
                                 product_code=row.product_code if row.installer_type in MSI_TYPES else None),
                encoding="utf-8-sig")
            self.repo.abs(txt_rel).write_text(deployment_text(
                app={"name": app.name, "publisher": app.publisher, "description": app.description,
                     "homepage": app.homepage, "category": app.category, "scope": app.scope},
                version={"version": row.version, "installer_type": row.installer_type,
                         "scope": row.scope, "intunewin_name": out.name, "filename": row.filename,
                         "architecture": row.architecture, "sha256": row.sha256,
                         "source_url": row.source_url, "downloaded_at": row.downloaded_at or utcnow(),
                         "install_command": row.install_command,
                         "uninstall_command": row.uninstall_command,
                         "product_code": row.product_code,
                         "msi_product_version": (row.msi_info or {}).get("ProductVersion"),
                         "detection_script_name": Path(str(det_rel)).name}),
                encoding="utf-8")
            row.intunewin_relative_path = str(pkg_rel)
            row.intune_info_relative_path = str(txt_rel)
            row.intune_detection_relative_path = str(det_rel)
            row.intune_status, row.intune_error = "ok", None
        except Exception as exc:  # noqa: BLE001
            log.exception("Intune packaging failed for %s %s", app.app_id, row.version)
            row.intune_status, row.intune_error = "failed", str(exc)
            self.db.log_event("package", f"Intune packaging failed: {exc}", app_id=app.app_id,
                              version=row.version, level="error")

    def _refresh_latest(self, app: Application) -> None:
        available = [v for v in app.versions if v.status == "available"]
        latest = max(available, key=lambda v: version_key(v.version)) if available else None
        for v in app.versions:
            v.is_latest = v is latest
        app.latest_version = latest.version if latest else None

    def _metadata(self, app: Application, row: AppVersion) -> dict[str, Any]:
        return {
            "app_id": app.app_id, "name": app.name, "publisher": app.publisher,
            "version": row.version, "filename": row.filename, "sha256": row.sha256,
            "size_bytes": row.size_bytes, "installer_type": row.installer_type,
            "architecture": row.architecture, "scope": row.scope,
            "install_command": row.install_command, "uninstall_command": row.uninstall_command,
            "product_code": row.product_code, "source_url": row.source_url,
            "downloaded_at": (row.downloaded_at or utcnow()).isoformat() + "Z",
            "intunewin": row.intunewin_relative_path, "intune_status": row.intune_status,
        }
