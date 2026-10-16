"""Check for, download, package and record new application versions."""

from __future__ import annotations

import hashlib
import logging
import re
import shutil
import tempfile
import threading
import zipfile
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import httpx
from sqlalchemy import select

from .config import Config
from .db import Application, AppVersion, Database, utcnow
from .installers import MSI_TYPES, build_commands
from .intune_info import deployment_text, detection_script
from .intunewin import create_intunewin_native, create_intunewin_official
from .packages import FileInfo, inspect_file, safe_extract, verify_signature
from .repository import Repository, safe_segment
from .selection import apply_declared_type, candidate_type, describe, gather, rank, selection_note, type_rank
from .sources import ReleaseInfo, make_client
from .versioning import sort_versions, version_key

log = logging.getLogger("appdepot.updater")

DOWNLOAD_ERRORS = (httpx.HTTPError, ValueError, OSError, zipfile.BadZipFile)


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


def download_file(client: httpx.Client, url: str, dest_dir: Path, expected_sha256: str | None = None,
                  expected_sha512: str | None = None) -> tuple[Path, str, int, str, str | None]:
    """Stream ``url`` into ``dest_dir``. Returns (path, sha256, size, final_url, cd_filename)."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=dest_dir, suffix=".part")
    sha = hashlib.sha256()
    sha512 = hashlib.sha512() if expected_sha512 else None
    size = 0
    try:
        with open(fd, "wb") as fh, client.stream("GET", url) as resp:
            resp.raise_for_status()
            for chunk in resp.iter_bytes(1024 * 1024):
                fh.write(chunk)
                sha.update(chunk)
                if sha512 is not None:
                    sha512.update(chunk)
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
    if sha512 is not None and sha512.hexdigest().lower() != expected_sha512.lower():
        Path(tmp_name).unlink(missing_ok=True)
        raise ValueError(f"SHA-512 mismatch for {url}")
    if size == 0:
        Path(tmp_name).unlink(missing_ok=True)
        raise ValueError("Downloaded file is empty")
    return Path(tmp_name), digest, size, final_url, cd_name


INSTALLER_EXTENSIONS = {".msi", ".msp", ".exe", ".zip", ".msix", ".msixbundle", ".appx", ".appxbundle"}


def sniff_extension(path: Path) -> str:
    """Extension for a download whose name has none, from the file's first bytes."""
    with open(path, "rb") as fh:
        head = fh.read(8)
    if head.startswith(bytes.fromhex("D0CF11E0A1B11AE1")):
        return ".msi"
    if head.startswith(b"MZ"):
        return ".exe"
    if head.startswith(b"PK"):
        return ".zip"
    return ".bin"


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
            return sorted(a.app_id for a in apps if not a.is_manual
                          and (not only_global_schedule or a.effective_schedule is None))

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
        self.db.log_event("package", "Repackaged for Intune" if result["intune_status"] != "failed"
                          else f"Intune packaging failed: {result['intune_error']}", app_id=app_id,
                          version=version, details=result, level="error" if result["intune_status"] == "failed" else "info")
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
            if app.is_manual:
                return CheckResult(app_id, "skipped", app.latest_version,
                                   "Manual application: new versions are uploaded, not downloaded")
            sources = app.source_list
            source_state = dict(app.source_state or {})
            existing = {v.version: v.installer_type for v in app.versions if v.status == "available"}
            manifest_type = app.installer_type
            extra = dict(app.extra or {})
            preferred = list(app.preferred_types or self.config.preferred_types)

        self.db.log_event("check", f"Checking {len(sources)} source(s) for updates", app_id=app_id)
        log.info("Checking %s", app_id)
        client = make_client(self.config.section("sources"))
        temp_dirs: list[Path] = []
        try:
            candidates, errors = gather(sources, client, self.config.section("sources").get("github_token"),
                                        source_state)
            for err in errors:
                self.db.log_event("check", f"Source failed: {err}", app_id=app_id, level="error")
            if not candidates:
                raise LookupError("No source returned an installer: " + "; ".join(errors))

            # Sources that only reveal the version inside the file (an MSI, or an MSI inside a zip)
            for c in list(candidates):
                if c.version is None:
                    try:
                        c.downloaded = self._download(client, app_id, c, temp_dirs)
                        c.inspected = self._inspect(c, extra, manifest_type)
                    except DOWNLOAD_ERRORS as exc:
                        errors.append(f"{c.url}: {exc}")
                        candidates.remove(c)
                        continue
                    c.version = self._version_from_file(c)
                    c.state = {**c.state, "version": c.version}
            new_state = {str(c.source_index): c.state for c in candidates if c.state}
            apply_declared_type(candidates, manifest_type)

            ranked = rank(candidates, preferred)
            if not ranked:
                raise ValueError("No source provided a version and none could be read from the files"
                                 + (": " + "; ".join(errors) if errors else ""))
            best = ranked[0]
            considered = [describe(c) for c in ranked[:12]]

            replace_type = None
            if best.version in existing and not force:
                stored = existing[best.version]
                if type_rank(candidate_type(best), preferred) < type_rank(stored or "exe", preferred):
                    replace_type = stored   # e.g. an MSI appeared for a version stored as EXE
                else:
                    self._set_status(app_id, "up_to_date", state=new_state)
                    self.db.log_event("check", f"Up to date ({best.version}, {stored})", app_id=app_id,
                                      version=best.version, details={"considered": considered})
                    return CheckResult(app_id, "up_to_date", best.version, "Already in repository")

            chosen, failures = None, []
            for c in ranked:
                if c.version in existing and not force and not (replace_type and c.version == best.version
                        and type_rank(candidate_type(c), preferred) < type_rank(replace_type, preferred)):
                    break   # everything from here on is already stored or worse
                try:
                    if c.downloaded is None:
                        self.db.log_event("download", f"Downloading {c.url}", app_id=app_id, version=c.version)
                        c.downloaded = self._download(client, app_id, c, temp_dirs)
                    if c.inspected is None:
                        c.inspected = self._inspect(c, extra, manifest_type)
                    self._check_signature(app_id, c, extra)
                    chosen = c
                    break
                except DOWNLOAD_ERRORS as exc:
                    kind = c.inspected.installer_type if c.inspected else candidate_type(c)
                    failures.append(f"{kind} {c.version} from {c.source_type}: {exc}")
                    self.db.log_event("download", f"Download failed, trying next candidate: {exc}",
                                      app_id=app_id, version=c.version, level="error")
            if chosen is None:
                if failures and not any(c.version in existing for c in ranked):
                    raise LookupError("All downloads failed: " + "; ".join(failures))
                # Newer files are not (yet) downloadable; what we already have is current
                self._set_status(app_id, "up_to_date", state=new_state)
                return CheckResult(app_id, "up_to_date", best.version,
                                   "Already in repository" + (f" (newer files unavailable: {failures[0]})"
                                                              if failures else ""))

            note = selection_note(chosen, candidates, len(sources))
            self.db.log_event("check", note, app_id=app_id, version=chosen.version,
                              level="info", details={"selected": describe(chosen), "considered": considered,
                                                     "source_errors": errors, "download_failures": failures})
            result = self._ingest(app_id, chosen, existing, replace_type)
            self._set_status(app_id, "updated", state=new_state)
            return CheckResult(app_id, "updated", chosen.version, result + f" {note}")
        except Exception as exc:  # noqa: BLE001 - never let one app kill the scheduler
            log.exception("Check failed for %s", app_id)
            self._set_status(app_id, "failed", error=str(exc))
            self.db.log_event("error", f"Update check failed: {exc}", app_id=app_id, level="error")
            return CheckResult(app_id, "failed", None, str(exc))
        finally:
            client.close()
            for d in temp_dirs:
                shutil.rmtree(d, ignore_errors=True)

    def _ingest(self, app_id: str, chosen: ReleaseInfo, existing: dict, replace_type: str | None) -> str:
        """Store a downloaded or uploaded file as a version, then apply retention."""
        temp_file, sha, size, final_url, _ = chosen.downloaded
        info: FileInfo = chosen.inspected
        version = chosen.version
        if version in existing:
            self.delete_version(app_id, version)
            if replace_type:
                self.db.log_event("update", f"Replacing the stored {replace_type} installer of {version} "
                                  f"with the preferred {info.installer_type}", app_id=app_id, version=version)
        result = self._store(app_id, version, temp_file, temp_file.name, sha, size, chosen, info, final_url)
        purged = self.apply_retention(app_id)
        msg = f"Stored version {version} ({info.installer_type})."
        if purged:
            msg += f" Purged {', '.join(purged)}."
        return msg + result

    def _inspect(self, c: ReleaseInfo, extra: dict, manifest_type: str | None) -> FileInfo:
        path = c.downloaded[0]
        return inspect_file(path, setup_file=extra.get("setup_file"), declared_type=manifest_type,
                            candidate_type=c.installer_type, extract_to=path.parent / "extracted")

    @staticmethod
    def _version_from_file(c: ReleaseInfo) -> str | None:
        info: FileInfo = c.inspected
        rule = c.version_rule or {}
        if rule.get("text_regex"):
            # e.g. Chrome: the MSI ProductVersion is not the product version
            return info.find_text_version(rule["text_regex"]) or rule.get("fallback")
        return info.version or rule.get("fallback")

    def _check_signature(self, app_id: str, c: ReleaseInfo, extra: dict) -> None:
        signer = extra.get("signer")
        if not signer:
            return
        info: FileInfo = c.inspected
        target = info.setup_dir / info.setup_name if info.setup_dir else c.downloaded[0]
        ok, detail = verify_signature(target, signer)
        if ok is False:
            raise ValueError(f"signature check failed for {target.name} ({detail})")
        self.db.log_event("download", f"{target.name}: {'signature OK' if ok else detail}", app_id=app_id,
                          version=c.version, level="info" if ok else "error")

    def import_installer(self, app_id: str, file_path: Path, filename: str | None = None,
                         version: str | None = None, replace: bool = False,
                         source_label: str = "upload") -> CheckResult:
        """Add an installer file supplied by an administrator (manual applications or extra versions)."""
        with self.db.session() as s:
            app = self.db.get_app(s, app_id)
            if app is None:
                raise KeyError(f"Unknown application '{app_id}'")
            app_id = app.app_id
            existing = {v.version: v.installer_type for v in app.versions if v.status == "available"}
            manifest_type = app.installer_type
            extra = dict(app.extra or {})
        temp_dir = Path(tempfile.mkdtemp(dir=self.repo.tmp, prefix=safe_segment(app_id) + "-upload-"))
        try:
            name = safe_segment(filename or file_path.name)
            target = temp_dir / name
            shutil.copyfile(file_path, target)
            sha = hashlib.sha256()
            with open(target, "rb") as fh:
                while chunk := fh.read(1024 * 1024):
                    sha.update(chunk)
            size = target.stat().st_size
            if size == 0:
                raise ValueError("The uploaded file is empty")
            c = ReleaseInfo(version=version, url=f"{source_label}://{name}", filename=name,
                            source_type="manual")
            c.downloaded = (target, sha.hexdigest(), size, f"{source_label}://{name}", None)
            c.inspected = self._inspect(c, extra, manifest_type)
            c.version = version or c.inspected.version
            if not c.version:
                raise ValueError("A version is required: it could not be read from the file "
                                 "(MSI, MSIX and most EXE files carry one)")
            if c.version in existing and not replace:
                raise ValueError(f"Version {c.version} is already in the repository (use replace)")
            self._check_signature(app_id, c, extra)
            self.db.log_event("download", f"Imported {name} as version {c.version}", app_id=app_id,
                              version=c.version)
            msg = self._ingest(app_id, c, existing, None)
            self._set_status(app_id, "updated")
            return CheckResult(app_id, "updated", c.version, msg)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def _download(self, client: httpx.Client, app_id: str, c: ReleaseInfo, temp_dirs: list[Path]):
        temp_dir = Path(tempfile.mkdtemp(dir=self.repo.tmp, prefix=safe_segment(app_id) + "-"))
        temp_dirs.append(temp_dir)
        path, sha, size, final_url, cd_name = download_file(client, c.url, temp_dir, c.sha256, c.sha512)
        filename = safe_segment(c.filename or cd_name or Path(final_url.split("?")[0]).name or "installer")
        if Path(filename).suffix.lower() not in INSTALLER_EXTENSIONS:
            # e.g. fwlink downloads (no extension) or "media.nl?...&_xt=.zip": name it by its content
            sniffed = sniff_extension(path)
            if sniffed != ".bin" or "." not in filename:
                filename = (Path(filename).stem if "." in filename else filename) + sniffed
        named = temp_dir / filename
        path.rename(named)
        return named, sha, size, final_url, cd_name

    def _store(self, app_id: str, version: str, temp_file: Path, filename: str, sha: str, size: int,
               release: ReleaseInfo, info: FileInfo, final_url: str) -> str:
        itype = info.installer_type
        msi_info = dict(info.msi_info) if info.msi_info else None
        if info.target_product_codes:
            msi_info = {**(msi_info or {}), "TargetProductCodes": info.target_product_codes}
        rel = self.repo.store_installer(app_id, version, temp_file, filename)
        with self.db.session() as s:
            app = self.db.get_app(s, app_id)
            row = AppVersion(
                application=app,
                version=version,
                status="available",
                filename=Path(str(rel)).name,
                setup_path=info.setup_path,
                relative_path=str(rel),
                local_path=str(self.repo.abs(rel)),
                unc_path=self.repo.unc(rel),
                sha256=sha,
                size_bytes=size,
                source_url=final_url,
                source_type=release.source_type or None,
                release_notes_url=release.release_notes_url,
                installer_type=itype,
                architecture=release.architecture or app.architecture,
                scope=release.scope or app.scope,
                product_code=release.product_code or (info.msi_info or {}).get("ProductCode"),
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
            intune, intune_error = row.intune_status, row.intune_error
        if intune == "failed":
            self.db.log_event("package", f"Intune packaging failed: {intune_error}", app_id=app_id,
                              version=version, level="error")
        self.db.log_event("update", f"Added version {version} ({filename}, {size:,} bytes)",
                          app_id=app_id, version=version, details={"sha256": sha, "source": final_url})
        return "" if intune in ("ok", "disabled") else f"; Intune packaging {intune}"

    def _finalize(self, app: Application, row: AppVersion) -> None:
        """(Re)build commands, Intune package, deployment sheet and metadata for a version."""
        detection = app.detection or {}
        display_rx = detection.get("display_name") or "^" + re.escape(app.name)

        cmds = build_commands(
            filename=Path(row.setup_path).name if row.setup_path else row.filename,
            installer_type=row.installer_type,
            # manifest install_args win over switches published by the source
            install_args=app.install_args if app.install_args is not None else row.source_silent_args,
            extra_args=row.source_custom_args if app.install_args is None else None,
            product_code=row.product_code,
            uninstall_command=app.uninstall_command,
            uninstall_args=app.uninstall_args,
            display_name_regex=display_rx,
            version=row.version,
            key_pattern=detection.get("key_pattern"),
            exclude=detection.get("exclude"),
            appx_name=detection.get("appx_name"),
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
        setup_name = row.filename
        work_dir = None
        try:
            if row.setup_path:   # archive: package the folder that contains the setup file
                work_dir = Path(tempfile.mkdtemp(dir=self.repo.tmp, prefix="package-"))
                safe_extract(self.repo.abs(row.relative_path), work_dir)
                setup = work_dir / row.setup_path
                installer_dir, setup_name = setup.parent, setup.name
            out = self.repo.abs(pkg_rel)
            out.parent.mkdir(parents=True, exist_ok=True)
            msi = dict(row.msi_info or {})
            if row.installer_type in MSI_TYPES and row.product_code:
                msi.setdefault("ProductCode", row.product_code)
                msi.setdefault("ProductVersion", row.version)
            if icfg.get("packager") == "official":
                create_intunewin_official(Path(icfg.get("intunewinapputil_path") or ""), installer_dir,
                                          setup_name, out)
            else:
                create_intunewin_native(installer_dir, setup_name, out,
                                        msi_info=msi if row.installer_type in MSI_TYPES else None)
            self.repo.abs(det_rel).write_text(
                detection_script(app_name=app.name, version=row.version, display_name_regex=display_rx,
                                 product_code=row.product_code if row.installer_type in MSI_TYPES else None,
                                 key_pattern=(app.detection or {}).get("key_pattern"),
                                 exclude=(app.detection or {}).get("exclude"),
                                 appx_name=(app.detection or {}).get("appx_name")),
                encoding="utf-8-sig")
            self.repo.abs(txt_rel).write_text(deployment_text(
                app={"name": app.name, "publisher": app.publisher, "description": app.description,
                     "homepage": app.homepage, "category": app.category, "scope": app.scope},
                version={"version": row.version, "installer_type": row.installer_type,
                         "scope": row.scope, "intunewin_name": out.name, "filename": setup_name,
                         "archive": row.filename if row.setup_path else None,
                         "target_product_codes": (row.msi_info or {}).get("TargetProductCodes"),
                         "requires": (app.extra or {}).get("requires"),
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
            # Logged by the caller once its transaction is closed (SQLite allows one writer)
            row.intune_status, row.intune_error = "failed", str(exc)
        finally:
            if work_dir is not None:
                shutil.rmtree(work_dir, ignore_errors=True)

    def _refresh_latest(self, app: Application) -> None:
        available = [v for v in app.versions if v.status == "available"]
        latest = max(available, key=lambda v: version_key(v.version)) if available else None
        for v in app.versions:
            v.is_latest = v is latest
        app.latest_version = latest.version if latest else None

    def _metadata(self, app: Application, row: AppVersion) -> dict[str, Any]:
        return {
            "app_id": app.app_id, "name": app.name, "publisher": app.publisher,
            "version": row.version, "filename": row.filename, "setup_path": row.setup_path,
            "sha256": row.sha256,
            "size_bytes": row.size_bytes, "installer_type": row.installer_type,
            "architecture": row.architecture, "scope": row.scope,
            "install_command": row.install_command, "uninstall_command": row.uninstall_command,
            "product_code": row.product_code, "source_url": row.source_url,
            "downloaded_at": (row.downloaded_at or utcnow()).isoformat() + "Z",
            "intunewin": row.intunewin_relative_path, "intune_status": row.intune_status,
        }
