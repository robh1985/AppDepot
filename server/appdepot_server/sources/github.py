"""GitHub Releases source.

    source:
      type: github
      repo: notepad-plus-plus/notepad-plus-plus
      asset_pattern: 'npp\\.[\\d.]+\\.Installer\\.x64\\.exe$'
      include_prerelease: false      # optional
      version_regex: '(\\d+(?:\\.\\d+)+)'  # optional, applied to the tag name
"""

from __future__ import annotations

import re

from .base import ReleaseInfo, Source, SourceContext, clean_version

API = "https://api.github.com/repos/"


class GitHubSource(Source):
    type_name = "github"
    required = ("repo", "asset_pattern")

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        headers = {"Accept": "application/vnd.github+json"}
        if ctx.github_token:
            headers["Authorization"] = f"Bearer {ctx.github_token}"
        repo = self.config["repo"]
        if self.config.get("include_prerelease"):
            resp = ctx.client.get(f"{API}{repo}/releases?per_page=20", headers=headers)
            resp.raise_for_status()
            releases = [r for r in resp.json() if not r.get("draft")]
        else:
            resp = ctx.client.get(f"{API}{repo}/releases/latest", headers=headers)
            resp.raise_for_status()
            releases = [resp.json()]

        pattern = re.compile(self.config["asset_pattern"], re.IGNORECASE)
        for rel in releases:
            for asset in rel.get("assets", []):
                if pattern.search(asset["name"]):
                    digest = asset.get("digest") or ""
                    return ReleaseInfo(
                        version=clean_version(rel.get("tag_name") or rel.get("name"), self.config),
                        url=asset["browser_download_url"],
                        filename=asset["name"],
                        sha256=digest[7:].lower() if digest.startswith("sha256:") else None,
                        release_notes_url=rel.get("html_url"),
                    )
        raise LookupError(f"No release asset in {repo} matches '{self.config['asset_pattern']}'")
