"""Use the public winget-pkgs repository as a source.

This is the easiest way to add an application: winget manifests already
contain the download URL, SHA-256, installer technology, silent switches and
MSI product code for thousands of applications.

    source:
      type: winget
      package: 7zip.7zip          # winget PackageIdentifier
      architecture: x64           # x64 | x86 | arm64 | neutral (default x64)
      installer_type: msi         # optional: only consider these type(s) (string or list)
      scope: machine              # optional preference (default machine)
      locale: en-US               # optional
      version_filter: '^\\d+\\.\\d+$'  # optional regex; versions must match
"""

from __future__ import annotations

import re
from typing import Any

import yaml

from ..versioning import sort_versions
from .base import ReleaseInfo, Source, SourceContext, as_list, filename_from_url

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

    def installer_candidates(self, manifest: dict[str, Any]) -> list[dict[str, Any]]:
        """Usable installers for the configured architecture, best first.

        Installer *type* preference (MSI first) is applied by the updater across all
        sources; here an explicit ``installer_type`` only narrows the choice.
        """
        root_keys = ("InstallerType", "InstallerSwitches", "Scope", "ProductCode",
                     "NestedInstallerType", "InstallerLocale", "ReleaseNotesUrl")
        candidates = []
        for inst in manifest.get("Installers") or []:
            merged = {k: manifest[k] for k in root_keys if k in manifest}
            merged.update(inst)
            switches = dict(manifest.get("InstallerSwitches") or {})
            switches.update(inst.get("InstallerSwitches") or {})
            merged["InstallerSwitches"] = switches
            if str(merged.get("InstallerType", "")).lower() in UNSUPPORTED:
                continue
            candidates.append(merged)
        if not candidates:
            raise LookupError("No supported installers in winget manifest (zip/portable/store are skipped)")

        # Architecture: the requested one (or neutral) beats a fallback (x86 on x64).
        wanted = str(self.config.get("architecture", "x64")).lower()
        tiers = {wanted: 0, "neutral": 0}
        if wanted == "x64":
            tiers["x86"] = 1
        arch_of = lambda c: str(c.get("Architecture", "neutral")).lower()  # noqa: E731
        usable = [c for c in candidates if arch_of(c) in tiers]
        if not usable:
            raise LookupError(f"No installer for architecture {wanted}")
        best_tier = min(tiers[arch_of(c)] for c in usable)
        usable = [c for c in usable if tiers[arch_of(c)] == best_tier]

        # Scope: drop per-user installers when a machine-wide one exists.
        scope_pref = self.config.get("scope", "machine")
        scope_of = lambda c: str(c.get("Scope", "")).lower()  # noqa: E731
        if any(scope_of(c) in (scope_pref, "") for c in usable):
            usable = [c for c in usable if scope_of(c) in (scope_pref, "")]

        # Explicit type(s) in the source config narrow the choice.
        type_pref = [t.lower() for t in as_list(self.config.get("installer_type"))]
        if type_pref:
            matching = [c for c in usable if str(c.get("InstallerType", "")).lower() in type_pref]
            if matching:
                usable = matching
            elif self.config.get("strict_type", False):
                raise LookupError(f"No installer of type {type_pref}")

        locale = self.config.get("locale")
        type_of = lambda c: str(c.get("InstallerType", "")).lower()  # noqa: E731
        usable.sort(key=lambda c: (
            type_pref.index(type_of(c)) if type_of(c) in type_pref else len(type_pref),
            0 if scope_of(c) == scope_pref else 1,
            0 if not locale or c.get("InstallerLocale") in (None, locale) else 1,
        ))
        return usable

    def select_installer(self, manifest: dict[str, Any]) -> dict[str, Any]:
        return self.installer_candidates(manifest)[0]

    def resolve_all(self, ctx: SourceContext) -> list[ReleaseInfo]:
        versions = self.list_versions(ctx)
        last_error: Exception | None = None
        # The newest folder can occasionally contain only a locale manifest;
        # fall back to the next version in that case.
        for version in versions[:3]:
            try:
                manifest = self.fetch_installer_manifest(ctx, version)
                installers = self.installer_candidates(manifest)
                break
            except LookupError as exc:
                last_error = exc
        else:
            raise last_error or LookupError("No usable winget manifest")

        out = []
        for order, inst in enumerate(installers):
            switches = inst.get("InstallerSwitches") or {}
            url = inst["InstallerUrl"]
            out.append(ReleaseInfo(
                version=str(manifest.get("PackageVersion", version)),
                url=url,
                filename=filename_from_url(url),
                installer_type=WINGET_TYPE_MAP.get(str(inst.get("InstallerType", "")).lower(), "exe"),
                sha256=(inst.get("InstallerSha256") or "").lower() or None,
                install_args=switches.get("Silent"),   # replaces the type defaults
                extra_args=switches.get("Custom"),      # appended
                product_code=inst.get("ProductCode"),
                architecture=str(inst.get("Architecture", "")).lower() or None,
                scope=str(inst.get("Scope", "")).lower() or None,
                release_notes_url=inst.get("ReleaseNotesUrl"),
                order=order,
            ))
        return out

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        return self.resolve_all(ctx)[0]
