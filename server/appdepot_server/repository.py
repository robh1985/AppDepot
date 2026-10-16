"""On-disk repository layout.

::

    <root>/
      <app_id>/
        <version>/
          installer/<installer file>          <- what clients install
          intune/<app_id>_<version>.intunewin <- upload to Intune
          intune/<app_id>_<version>.intune.txt   install/uninstall commands etc.
          intune/<app_id>_<version>.detect.ps1   custom detection script
          metadata.json                       <- copy of the DB record

Clients reach the same tree through the SMB share (``unc_root``) or over
HTTP at ``<public_url>/files/<app_id>/<version>/...``.
"""

from __future__ import annotations

import json
import re
import shutil
from pathlib import Path, PurePosixPath
from urllib.parse import quote

from .config import Config

_SAFE = re.compile(r"[^A-Za-z0-9._+\-]")


def safe_segment(value: str) -> str:
    cleaned = _SAFE.sub("_", value).strip(".")
    return cleaned or "_"


class Repository:
    def __init__(self, config: Config):
        self.config = config
        self.root = config.repo_root
        self.root.mkdir(parents=True, exist_ok=True)
        self.tmp = self.root / ".tmp"
        self.tmp.mkdir(exist_ok=True)

    # ---- paths ---------------------------------------------------------------
    def version_rel(self, app_id: str, version: str) -> PurePosixPath:
        return PurePosixPath(safe_segment(app_id), safe_segment(version))

    def abs(self, rel: str | PurePosixPath) -> Path:
        path = (self.root / str(rel)).resolve()
        if self.root.resolve() not in path.parents and path != self.root.resolve():
            raise ValueError("Path escapes the repository root")
        return path

    def unc(self, rel: str | PurePosixPath | None) -> str | None:
        if rel is None or not self.config.unc_root:
            return None
        return self.config.unc_root + "\\" + str(rel).replace("/", "\\")

    def http(self, rel: str | PurePosixPath | None) -> str | None:
        if rel is None:
            return None
        return f"{self.config.public_url}/files/{quote(str(rel))}"

    # ---- operations ----------------------------------------------------------
    def store_installer(self, app_id: str, version: str, temp_file: Path, filename: str) -> PurePosixPath:
        rel = self.version_rel(app_id, version) / "installer" / safe_segment(filename)
        target = self.abs(rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(temp_file), target)
        return rel

    def write_metadata(self, app_id: str, version: str, data: dict) -> None:
        target = self.abs(self.version_rel(app_id, version) / "metadata.json")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(data, indent=2, default=str), encoding="utf-8")

    def delete_version(self, app_id: str, version: str) -> None:
        path = self.abs(self.version_rel(app_id, version))
        if path.exists():
            shutil.rmtree(path)

    def cleanup_tmp(self) -> None:
        for item in self.tmp.iterdir():
            if item.is_dir():
                shutil.rmtree(item, ignore_errors=True)
            else:
                item.unlink(missing_ok=True)
