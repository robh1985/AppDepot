"""GitHub Releases source.

    source:
      type: github
      repo: notepad-plus-plus/notepad-plus-plus
      asset_pattern: 'npp\\.[\\d.]+\\.Installer\\.x64\\.(msi|exe)$'   # may match several files;
                                                              # the MSI is preferred
      include_prerelease: false      # optional
      tag_regex: '^Audacity-3\\.'     # optional: only releases whose tag matches (a "track")
      version_regex: '(\\d+(?:\\.\\d+)+)'  # optional, applied to the tag name
"""

from __future__ import annotations

import re

from .base import ReleaseInfo, Source, SourceContext, clean_version, type_from_filename

API = "https://api.github.com/repos/"


class GitHubSource(Source):
    type_name = "github"
    required = ("repo", "asset_pattern")

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        return self.resolve_all(ctx)[0]

    def resolve_all(self, ctx: SourceContext) -> list[ReleaseInfo]:
        headers = {"Accept": "application/vnd.github+json"}
        if ctx.github_token:
            headers["Authorization"] = f"Bearer {ctx.github_token}"
        repo = self.config["repo"]
        tag_rx = re.compile(self.config["tag_regex"]) if self.config.get("tag_regex") else None
        if self.config.get("include_prerelease") or tag_rx:
            resp = ctx.client.get(f"{API}{repo}/releases?per_page=100", headers=headers)
            resp.raise_for_status()
            releases = [r for r in resp.json() if not r.get("draft")
                        and (self.config.get("include_prerelease") or not r.get("prerelease"))
                        and (tag_rx is None or tag_rx.search(r.get("tag_name") or ""))]
        else:
            resp = ctx.client.get(f"{API}{repo}/releases/latest", headers=headers)
            resp.raise_for_status()
            releases = [resp.json()]

        pattern = re.compile(self.config["asset_pattern"], re.IGNORECASE)
        for rel in releases:
            found = []
            for asset in rel.get("assets", []):
                if pattern.search(asset["name"]):
                    digest = asset.get("digest") or ""
                    found.append(ReleaseInfo(
                        version=clean_version(rel.get("tag_name") or rel.get("name"), self.config),
                        url=asset["browser_download_url"],
                        filename=asset["name"],
                        installer_type=type_from_filename(asset["name"]),
                        sha256=digest[7:].lower() if digest.startswith("sha256:") else None,
                        release_notes_url=rel.get("html_url"),
                        order=len(found),
                    ))
            if found:
                return found
        raise LookupError(f"No release asset in {repo} matches '{self.config['asset_pattern']}'")
