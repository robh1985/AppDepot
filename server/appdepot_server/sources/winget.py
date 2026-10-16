"""Use the public winget-pkgs repository as a source.

This is the easiest way to add an application: winget manifests already
contain the download URL, SHA-256, installer technology, silent switches and
MSI product code for thousands of applications.

    source:
      type: winget
      package: 7zip.7zip          # winget PackageIdentifier
      architecture: x64           # x64 | x86 | arm64 | neutral (default x64)
      installer_type: msi         # optional preference (string or list)
      scope: machine              # optional preference (default machine)
      locale: en-US               # optional
      version_filter: '^\\d+\\.\\d+$'  # optional regex; versions must match
"""

from __future__ import annotations

import re
from typing import Any

import yaml

from ..versioning import sort_versions
from .base import ReleaseInfo, Source, SourceContext, filename_from_url

API = "https://api.github.com/repos/microsoft/winget-pkgs/contents/"
RAW = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/"

WINGET_TYPE_MAP = {
    "msi": "msi", "wix": "wix", "nullsoft": "nullsoft", "inno": "inno", "burn": "burn",
    "exe": "exe", "msix": "msix", "appx": "appx",
}
UNSUPPORTED = {"zip", "portable", "pwa", "msstore"}


class WingetSource(Source):
    type_name = "winget"
    required = ("package",)

    def _manifest_dir(self) -> str:
        pkg = self.config["package"]
        return f"manifests/{pkg[0].lower()}/{'/'.join(pkg.split('.'))}"

    def _headers(self, ctx: SourceContext) -> dict[str, str]:
        h = {"Accept": "application/vnd.github+json"}
        if ctx.github_token:
            h["Authorization"] = f"Bearer {ctx.github_token}"
        return h

    def list_versions(self, ctx: SourceContext) -> list[str]:
        resp = ctx.client.get(API + self._manifest_dir(), headers=self._headers(ctx))
        if resp.status_code == 404:
            raise LookupError(f"winget package '{self.config['package']}' not found")
        resp.raise_for_status()
        flt = re.compile(self.config["version_filter"]) if self.config.get("version_filter") else None
        versions = [
            e["name"] for e in resp.json()
            if e.get("type") == "dir" and re.match(r"^v?\d", e["name"])
            and (flt is None or flt.search(e["name"]))
        ]
        if not versions:
            raise LookupError(f"No versions found for winget package '{self.config['package']}'")
        return sort_versions(versions)

    def fetch_installer_manifest(self, ctx: SourceContext, version: str) -> dict[str, Any]:
        pkg = self.config["package"]
        base = f"{RAW}{self._manifest_dir()}/{version}/{pkg}"
        for suffix in (".installer.yaml", ".yaml"):
            resp = ctx.client.get(base + suffix)
            if resp.status_code == 200:
                return yaml.safe_load(resp.text)
        raise LookupError(f"Installer manifest for {pkg} {version} not found")

    def select_installer(self, manifest: dict[str, Any]) -> dict[str, Any]:
        root_keys = ("InstallerType", "InstallerSwitches", "Scope", "ProductCode",
                     "NestedInstallerType", "InstallerLocale", "ReleaseNotesUrl")
        candidates = []
        for inst in manifest.get("Installers") or []:
            merged = {k: manifest[k] for k in root_keys if k in manifest}
            merged.update(inst)
            switches = dict(manifest.get("InstallerSwitches") or {})
            switches.update(inst.get("InstallerSwitches") or {})
            merged["InstallerSwitches"] = switches
            itype = str(merged.get("InstallerType", "")).lower()
            if itype in UNSUPPORTED:
                continue
            candidates.append(merged)
        if not candidates:
            raise LookupError("No supported installers in winget manifest (zip/portable/store are skipped)")

        arch_pref = [self.config.get("architecture", "x64")]
        if arch_pref[0] == "x64":
            arch_pref += ["neutral", "x86"]
        elif arch_pref[0] == "x86":
            arch_pref += ["neutral"]
        types = self.config.get("installer_type")
        type_pref = [types] if isinstance(types, str) else list(types or [])
        scope_pref = self.config.get("scope", "machine")
        locale = self.config.get("locale")

        def score(c: dict[str, Any]) -> tuple:
            arch = str(c.get("Architecture", "neutral")).lower()
            itype = str(c.get("InstallerType", "")).lower()
            scope = str(c.get("Scope", "")).lower()
            return (
                arch_pref.index(arch) if arch in arch_pref else 99,
                type_pref.index(itype) if itype in type_pref else (0 if not type_pref else 50),
                0 if scope == scope_pref else (1 if not scope else 2),
                0 if not locale or c.get("InstallerLocale") in (None, locale) else 1,
            )

        best = min(candidates, key=score)
        s = score(best)
        if s[0] == 99:
            raise LookupError(f"No installer for architecture {arch_pref[0]}")
        if type_pref and s[1] == 50 and self.config.get("strict_type", False):
            raise LookupError(f"No installer of type {type_pref}")
        return best

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        versions = self.list_versions(ctx)
        last_error: Exception | None = None
        # The newest folder can occasionally contain only a locale manifest;
        # fall back to the next version in that case.
        for version in versions[:3]:
            try:
                manifest = self.fetch_installer_manifest(ctx, version)
                inst = self.select_installer(manifest)
                break
            except LookupError as exc:
                last_error = exc
        else:
            raise last_error or LookupError("No usable winget manifest")

        switches = inst.get("InstallerSwitches") or {}
        itype = WINGET_TYPE_MAP.get(str(inst.get("InstallerType", "")).lower(), "exe")
        url = inst["InstallerUrl"]
        return ReleaseInfo(
            version=str(manifest.get("PackageVersion", version)),
            url=url,
            filename=filename_from_url(url),
            installer_type=itype,
            sha256=(inst.get("InstallerSha256") or "").lower() or None,
            install_args=switches.get("Silent"),   # replaces the type defaults
            extra_args=switches.get("Custom"),      # appended
            product_code=inst.get("ProductCode"),
            architecture=str(inst.get("Architecture", "")).lower() or None,
            scope=str(inst.get("Scope", "")).lower() or None,
            release_notes_url=inst.get("ReleaseNotesUrl"),
        )
