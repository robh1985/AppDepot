"""Adding applications to the repository.

* :class:`WingetCatalog` searches the winget catalog. It uses winget's own
  package index (the ``source.msix`` file the winget client downloads), cached
  for a day, and falls back to GitHub code search (needs ``sources.github_token``).
* :func:`manifest_from_winget` builds a complete AppDepot manifest from a winget
  package: name, publisher, description, licence, homepage, tags, a category
  guess and a detection rule.
* :func:`preview` shows what a manifest would download - every candidate from
  every source, whether an MSI exists and which installer would be chosen -
  without downloading anything.
* :func:`save_application` / :func:`remove_application` write or retire the
  manifest file and update the database, so files and database never disagree.
"""

from __future__ import annotations

import copy
import datetime as dt
import io
import logging
import re
import sqlite3
import time
import zipfile
from pathlib import Path
from typing import Any

import httpx
import yaml

from .config import Config
from .db import Database
from .manifest import ManifestError, manifest_sources, upsert_manifest, validate_manifest
from .repository import safe_segment
from .selection import (
    MSI_FAMILY,
    apply_declared_type,
    candidate_type,
    describe,
    gather,
    rank,
    selection_note,
)
from .sources import SourceContext, make_client
from .sources.winget import RAW, WingetSource
from .versioning import sort_versions

log = logging.getLogger("appdepot.onboarding")

INDEX_URLS = ["https://cdn.winget.microsoft.com/cache/source.msix",
              "https://cdn.winget.microsoft.com/cache/source2.msix"]
INDEX_MAX_AGE = 24 * 3600

CATEGORY_KEYWORDS = [
    ("Browsers", ("browser", "web browser")),
    ("Development", ("developer", "development", "ide", "editor", "code", "git", "programming", "sdk", "compiler")),
    ("Office", ("office", "pdf", "document", "spreadsheet", "word processor", "notes")),
    ("Multimedia", ("video", "audio", "media", "player", "music", "image", "photo", "graphics")),
    ("Communication", ("chat", "meeting", "messaging", "voip", "communication", "email", "mail")),
    ("Networking", ("ssh", "ftp", "network", "vpn", "remote", "terminal", "telnet")),
    ("Security", ("security", "antivirus", "password", "encryption", "firewall", "vpn client")),
    ("Utilities", ("archive", "zip", "compression", "utility", "tool", "backup")),
]


class OnboardingError(RuntimeError):
    pass


# --------------------------------------------------------------------------- search
class WingetCatalog:
    def __init__(self, config: Config):
        self.config = config
        self.cache_dir = config.repo_root / ".cache" / "winget"   # never served (dot folder)

    # -- public
    def search(self, query: str, limit: int = 25) -> list[dict[str, Any]]:
        query = query.strip()
        if not query:
            return []
        errors = []
        try:
            return self._rank(self._search_index(query), query)[:limit]
        except Exception as exc:  # noqa: BLE001
            errors.append(f"winget index: {exc}")
            log.warning("winget index search failed: %s", exc)
        try:
            return self._rank(self._search_github(query), query)[:limit]
        except Exception as exc:  # noqa: BLE001
            errors.append(f"GitHub search: {exc}")
        raise OnboardingError("winget search is unavailable (" + "; ".join(errors) + "). "
                              "You can still add an application by its exact winget id.")

    # -- winget index
    def _index_path(self) -> Path:
        db = self.cache_dir / "index.db"
        if db.exists() and time.time() - db.stat().st_mtime < INDEX_MAX_AGE:
            return db
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        last: Exception | None = None
        with make_client(self.config.section("sources")) as client:
            for url in INDEX_URLS:
                try:
                    resp = client.get(url)
                    resp.raise_for_status()
                    with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
                        name = next(n for n in zf.namelist() if n.lower().endswith("index.db"))
                        tmp = db.with_suffix(".tmp")
                        tmp.write_bytes(zf.read(name))
                    tmp.replace(db)
                    return db
                except Exception as exc:  # noqa: BLE001
                    last = exc
        if db.exists():  # stale cache is better than nothing
            return db
        raise OnboardingError(f"could not download the winget index: {last}")

    def _search_index(self, query: str) -> list[dict[str, Any]]:
        return search_index_db(self._index_path(), query)

    # -- GitHub fallback
    def _search_github(self, query: str) -> list[dict[str, Any]]:
        token = self.config.section("sources").get("github_token")
        if not token:
            raise OnboardingError("needs sources.github_token")
        with make_client(self.config.section("sources")) as client:
            resp = client.get("https://api.github.com/search/code", params={
                "q": f"{query} repo:microsoft/winget-pkgs path:manifests extension:yaml", "per_page": 100},
                headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"})
            resp.raise_for_status()
            found: dict[str, dict[str, Any]] = {}
            for item in resp.json().get("items", []):
                parts = item["path"].split("/")
                if len(parts) < 5:
                    continue
                pkg = re.sub(r"(\.locale\.[^.]+|\.installer)?\.yaml$", "", parts[-1])
                entry = found.setdefault(pkg, {"id": pkg, "name": pkg.split(".", 1)[-1], "version": None,
                                               "versions": []})
                entry["versions"].append(parts[-2])
            for entry in found.values():
                entry["version"] = sort_versions(entry.pop("versions"))[0]
            return list(found.values())

    @staticmethod
    def _rank(results: list[dict[str, Any]], query: str) -> list[dict[str, Any]]:
        q = query.lower()

        def score(r: dict[str, Any]) -> tuple:
            rid, name = r["id"].lower(), (r.get("name") or "").lower()
            return (0 if q in (rid, name) else 1 if rid.startswith(q) or name.startswith(q) else 2,
                    len(rid), rid)

        return sorted(results, key=score)


def search_index_db(db_path: Path, query: str) -> list[dict[str, Any]]:
    """Search a winget ``index.db`` (schema v1 or v2), newest version per package."""
    like = f"%{query}%"
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}

        def cols(t: str) -> set[str]:
            return {r[1] for r in con.execute(f"PRAGMA table_info({t})")}

        rows: list[tuple] = []
        if {"manifest", "ids", "names", "versions"} <= tables and {"id", "name", "version"} <= cols("manifest"):
            moniker_join, moniker_where = "", ""
            if "monikers" in tables and "moniker" in cols("manifest"):
                moniker_join = "LEFT JOIN monikers ON manifest.moniker = monikers.rowid"
                moniker_where = "OR monikers.moniker LIKE :q"
            rows = con.execute(f"""
                SELECT ids.id, names.name, versions.version FROM manifest
                JOIN ids ON manifest.id = ids.rowid
                JOIN names ON manifest.name = names.rowid
                JOIN versions ON manifest.version = versions.rowid
                {moniker_join}
                WHERE ids.id LIKE :q OR names.name LIKE :q {moniker_where}
                LIMIT 2000""", {"q": like}).fetchall()
        elif "packages" in tables and {"id", "name"} <= cols("packages"):
            version_col = "latest_version" if "latest_version" in cols("packages") else "NULL"
            moniker = "OR moniker LIKE :q" if "moniker" in cols("packages") else ""
            rows = con.execute(f"""SELECT id, name, {version_col} FROM packages
                                   WHERE id LIKE :q OR name LIKE :q {moniker} LIMIT 2000""",
                               {"q": like}).fetchall()
        else:
            raise OnboardingError(f"unrecognised winget index schema (tables: {sorted(tables)[:12]})")
    finally:
        con.close()

    best: dict[str, dict[str, Any]] = {}
    for pid, name, version in rows:
        cur = best.get(pid)
        if cur is None or (version and sort_versions([version, cur["version"] or "0"])[0] == version):
            best[pid] = {"id": pid, "name": name, "version": version}
    return list(best.values())


# --------------------------------------------------------------------------- manifest builder
def guess_category(*texts: str | None, tags: list[str] | None = None) -> str:
    blob = " ".join([t or "" for t in texts] + list(tags or [])).lower()
    for category, words in CATEGORY_KEYWORDS:
        if any(re.search(rf"\b{re.escape(w)}\b", blob) for w in words):
            return category
    return "Utilities"


def detection_regex(display_name: str) -> str:
    """'7-Zip 24.08 (x64)' -> '^7-Zip' : drop version numbers and architecture suffixes."""
    base = re.split(r"\s+v?\d+(?:\.\d+)+", display_name, maxsplit=1)[0]
    base = re.sub(r"\s*\((x64|x86|64-bit|32-bit|arm64)\)\s*$", "", base, flags=re.IGNORECASE).strip()
    return "^" + re.escape(base or display_name.strip())


def _fetch_yaml(client: httpx.Client, url: str) -> dict[str, Any] | None:
    resp = client.get(url)
    if resp.status_code != 200:
        return None
    return yaml.safe_load(resp.text)


def manifest_from_winget(config: Config, package_id: str, category: str | None = None,
                         architecture: str = "x64") -> tuple[dict[str, Any], dict[str, Any]]:
    """Return (manifest, info) for a winget package. ``info`` describes the installers found."""
    src = WingetSource({"package": package_id, "architecture": architecture})
    with make_client(config.section("sources")) as client:
        ctx = SourceContext(client=client, github_token=config.section("sources").get("github_token"))
        try:
            versions = src.list_versions(ctx)
        except LookupError as exc:
            raise OnboardingError(str(exc)) from exc
        version = versions[0]
        base = f"{RAW}{src._manifest_dir()}/{version}/{package_id}"
        root = _fetch_yaml(client, base + ".yaml") or {}
        locale_name = root.get("DefaultLocale") or "en-US"
        locale = _fetch_yaml(client, f"{base}.locale.{locale_name}.yaml") or root
        installer = src.fetch_installer_manifest(ctx, version)

    candidates = src.installer_candidates(installer)
    all_types = sorted({str(i.get("InstallerType", installer.get("InstallerType", ""))).lower()
                        for i in installer.get("Installers") or []} - {""})
    arp = list(installer.get("AppsAndFeaturesEntries") or [])
    for inst in installer.get("Installers") or []:
        arp += inst.get("AppsAndFeaturesEntries") or []
    arp_name = next((e.get("DisplayName") for e in arp if e.get("DisplayName")), None)

    name = locale.get("PackageName") or package_id.split(".", 1)[-1]
    tags = [str(t) for t in (locale.get("Tags") or [])][:10]
    description = (locale.get("ShortDescription") or locale.get("Description") or "").strip()
    manifest: dict[str, Any] = {
        "id": package_id,
        "name": name,
        "publisher": locale.get("Publisher"),
        "description": description or None,
        "homepage": locale.get("PackageUrl") or locale.get("PublisherUrl"),
        "license": locale.get("License"),
        "category": category or guess_category(name, description, tags=tags),
        "tags": tags or None,
        "source": {"type": "winget", "package": package_id, "architecture": architecture},
        "detection": {"display_name": detection_regex(arp_name or name)},
    }
    manifest = {k: v for k, v in manifest.items() if v not in (None, "", [])}
    validate_manifest(copy.deepcopy(manifest), package_id)

    usable_types = [str(c.get("InstallerType", "")).lower() for c in candidates]
    info = {
        "winget_version": version,
        "installer_types": usable_types,
        "all_installer_types": all_types,
        "msi_available": any(t in MSI_FAMILY for t in usable_types),
        "msi_other_architecture": any(t in MSI_FAMILY for t in all_types) and
        not any(t in MSI_FAMILY for t in usable_types),
    }
    return manifest, info


# --------------------------------------------------------------------------- preview
def probe_url(client: httpx.Client, url: str) -> bool:
    """True if the URL exists. Uses HEAD, or a 1-byte ranged GET where HEAD is refused."""
    try:
        resp = client.head(url)
        if resp.status_code in (403, 405, 501):
            with client.stream("GET", url, headers={"Range": "bytes=0-0"}) as r:
                return r.status_code < 400
        return resp.status_code < 400
    except httpx.HTTPError:
        return False


def preview(config: Config, manifest: dict[str, Any]) -> dict[str, Any]:
    """Resolve every source of a manifest without downloading anything."""
    m = validate_manifest(copy.deepcopy(manifest), manifest.get("id", "<manifest>"))
    installer = m.get("installer") or {}
    preferred = installer.get("preferred_types") or config.preferred_types
    sources = manifest_sources(m)
    with make_client(config.section("sources")) as client:
        candidates, errors = gather(sources, client, config.section("sources").get("github_token"), {})
        apply_declared_type(candidates, installer.get("type"))
        ranked = rank(candidates, preferred)
        # Check that the best candidates really exist (templated URLs are guesses), so the
        # preview reports what the download will actually get. Nothing is downloaded.
        missing = []
        for c in ranked[:8]:
            if not probe_url(client, c.url):
                missing.append(c)
        ranked = [c for c in ranked if c not in missing]
    unknown = [c for c in candidates if not c.version]   # url + version_from: msi
    selected = ranked[0] if ranked else (unknown[0] if unknown else None)
    errors += [f"not available: {c.url}" for c in missing]
    if selected is None:
        note = "No source returned an installer"
    elif selected.version:
        note = selection_note(selected, candidates, len(sources))
    else:
        note = "The version is read from the MSI when it is downloaded"
    newest = [c for c in ranked if selected and c.version == selected.version]
    return {
        "id": m["id"],
        "ok": selected is not None,
        "latest_version": selected.version if selected else None,
        "selected": describe(selected) if selected else None,
        "msi_available": any(candidate_type(c) in MSI_FAMILY for c in (newest or unknown)),
        "note": note,
        "candidates": [describe(c) for c in ranked + unknown],
        "errors": errors,
        "preferred_types": preferred,
    }


# --------------------------------------------------------------------------- save / remove
def manifest_file_for(config: Config, app_id: str, existing_path: str | None = None) -> Path:
    mdir = config.manifests_dir.resolve()
    if existing_path:
        p = Path(existing_path).resolve()
        if mdir in p.parents:
            return p
    return mdir / f"{safe_segment(app_id)}.yaml"


def save_application(config: Config, db: Database, manifest: dict[str, Any], *, replace: bool = False,
                     added_by: str = "AppDepot") -> dict[str, Any]:
    """Validate, write the manifest file and load it into the database."""
    m = validate_manifest(copy.deepcopy(manifest), manifest.get("id", "<manifest>"))
    with db.session() as s:
        app = db.get_app(s, m["id"])
        exists, existing_path = app is not None, (app.manifest_path if app else None)
    if exists and not replace:
        raise ManifestError(f"Application '{m['id']}' already exists (use replace to overwrite it)")
    path = manifest_file_for(config, m["id"], existing_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    header = (f"# {m['name']} - {'updated' if exists else 'added'} by {added_by} on "
              f"{dt.datetime.now():%Y-%m-%d %H:%M}\n# Reference: docs/manifest-reference.md\n")
    path.write_text(header + yaml.safe_dump(m, sort_keys=False, allow_unicode=True, width=120),
                    encoding="utf-8")
    app_id, changed = upsert_manifest(db, m, str(path))
    return {"id": app_id, "changed": changed, "created": not exists, "manifest_path": str(path)}


def remove_application(db: Database, repo, app_id: str, delete_files: bool = False) -> dict[str, Any]:
    from .db import Application
    from sqlalchemy import select

    with db.session() as s:
        app = s.scalar(select(Application).where(Application.app_id.ilike(app_id)))
        if app is None:
            raise KeyError(app_id)
        real_id, manifest_path = app.app_id, app.manifest_path
        versions = [v.version for v in app.versions]
        s.delete(app)
    retired = None
    if manifest_path and Path(manifest_path).exists():
        retired = Path(manifest_path).with_name(Path(manifest_path).name + ".removed")
        Path(manifest_path).replace(retired)   # sync ignores *.removed, so it is not re-added
    if delete_files:
        for v in versions:
            repo.delete_version(real_id, v)
    db.log_event("manifest", "Application removed" + (" with its files" if delete_files else ""),
                 app_id=real_id, details={"manifest_retired_to": str(retired) if retired else None})
    return {"id": real_id, "manifest_retired_to": str(retired) if retired else None,
            "files_deleted": delete_files}


TEMPLATES: dict[str, str] = {
    "manual": """id: Contoso.LineOfBusinessApp      # unique id
name: Contoso Line-of-Business App
publisher: Contoso
description: In-house application; installers are uploaded, not downloaded.
category: Business
source:
  type: manual                    # no automatic checks: upload each version
installer:
  type: msi                       # msi | inno | nullsoft | burn | exe | msix ...
  # install_args: '/qn /norestart'                 # required for type exe
  # uninstall_command: '"%ProgramFiles%\\Contoso\\uninstall.exe" /S'
  # setup_file: setup.exe          # for .zip uploads: the file to run inside the archive
detection:
  display_name: '^Contoso Line-of-Business App'
""",
    "adobe": """id: Adobe.Acrobat.Reader.64-bit.Update
name: Adobe Acrobat Reader (64-bit) - update
publisher: Adobe
category: Office
retain_versions: 2
source:
  type: adobe
  product: reader                 # reader | acrobat
  package: update                 # update (.msp patch) | installer (full installer)
  architecture: x64               # x64 | x86
  language: MUI                   # Reader: MUI | en_US
installer:
  signer: Adobe                   # Authenticode signer check (Windows servers)
detection:
  display_name: '^Adobe Acrobat'
  key_pattern: '^\\{AC76BA86-'
""",
    "winget": """id: Publisher.App                 # unique id (winget ids work well)
name: App Name
publisher: Publisher
description: What the application does.
homepage: https://example.com
category: Utilities
source:
  type: winget
  package: Publisher.App          # winget PackageIdentifier
  architecture: x64
detection:
  display_name: '^App Name'       # regex on the Programs and Features name
""",
    "github": """id: Publisher.App
name: App Name
publisher: Publisher
category: Utilities
source:
  type: github
  repo: owner/repository
  asset_pattern: 'App-[\\d.]+-x64\\.(msi|exe)$'   # matches the release assets; the MSI is preferred
  version_regex: '^v?(\\d+(?:\\.\\d+)+)'
detection:
  display_name: '^App Name'
""",
    "web": """id: Publisher.App
name: App Name
publisher: Publisher
category: Utilities
source:
  type: web
  url: https://example.com/download
  version_regex: 'Version (?P<version>[\\d.]+)'
  download_url:                   # tried in order of installer preference (MSI first)
    - https://example.com/files/app-{version}-x64.msi
    - https://example.com/files/app-{version}-x64.exe
installer:
  type: inno                      # technology of the .exe (msi files are detected automatically)
detection:
  display_name: '^App Name'
""",
    "json": """id: Publisher.App
name: App Name
publisher: Publisher
category: Utilities
source:
  type: json
  url: https://example.com/api/latest.json
  version_path: version
  download_url: https://example.com/files/app-{version}-x64.msi
detection:
  display_name: '^App Name'
""",
    "url": """id: Publisher.App
name: App Name
publisher: Publisher
category: Utilities
source:
  type: url
  url: https://example.com/download/latest/app-x64.msi
  version_from: msi               # msi | filename | redirect
detection:
  display_name: '^App Name'
""",
    "multi": """id: Publisher.App
name: App Name
publisher: Publisher
category: Utilities
# Several sources: all are checked, the newest version wins and an MSI is preferred.
sources:
  - type: web
    url: https://example.com/download
    version_regex: 'Version (?P<version>[\\d.]+)'
    download_url: https://example.com/files/app-{version}-x64.msi
  - type: winget
    package: Publisher.App
detection:
  display_name: '^App Name'
""",
}
