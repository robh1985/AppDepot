"""Server configuration.

Configuration is read from a YAML file (``appdepot.yaml``). The path is taken
from the ``APPDEPOT_CONFIG`` environment variable or the ``--config`` command
line option. Every setting has a default so a minimal file only needs the
repository paths.
"""

from __future__ import annotations

import copy
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

DEFAULTS: dict[str, Any] = {
    "server": {
        "host": "0.0.0.0",
        "port": 8080,
        # URL clients use to reach this server. Used to build HTTP download links.
        "public_url": "http://localhost:8080",
        # Key required for administrative API calls (X-Api-Key header).
        "api_key": None,
    },
    "repository": {
        # Local path on the server where installers are stored.
        "root": "./repository",
        # UNC path clients use to reach ``root`` over SMB, e.g. \\depot01\AppDepot
        "unc_root": None,
        # Number of versions kept per application.
        "retain_versions": 3,
    },
    "database": {
        "url": "sqlite:///./appdepot.db",
    },
    "schedule": {
        # Global cron expression (minute hour day month weekday).
        "global": "0 3 * * *",
        "timezone": None,  # None = server local time
        "max_concurrent": 2,
        "run_on_startup": False,
    },
    "sources": {
        "github_token": None,
        "user_agent": "AppDepot/1.0 (+https://github.com/)",
        "proxy": None,
        "timeout": 600,
        "verify_tls": True,
    },
    "installers": {
        # Installer types in order of preference, applied across all sources of an app.
        "preferred_types": ["msi", "wix", "msp", "msix", "appx", "burn", "inno", "nullsoft", "exe"],
    },
    "intune": {
        "enabled": True,
        # native = built-in packager (any OS); official = IntuneWinAppUtil.exe (Windows)
        "packager": "native",
        "intunewinapputil_path": None,
    },
    "manifests_dir": "./manifests",
    "logging": {
        "level": "INFO",
        "file": None,
    },
}


def _merge(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    for key, value in (override or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


@dataclass
class Config:
    data: dict = field(default_factory=lambda: copy.deepcopy(DEFAULTS))
    path: Path | None = None

    # -- convenience accessors -------------------------------------------------
    def section(self, name: str) -> dict:
        return self.data.get(name, {})

    def _resolve(self, value: str) -> Path:
        p = Path(value)
        if not p.is_absolute() and self.path is not None:
            p = self.path.parent / p
        return p

    @property
    def repo_root(self) -> Path:
        return self._resolve(self.data["repository"]["root"])

    @property
    def unc_root(self) -> str | None:
        unc = self.data["repository"].get("unc_root")
        return unc.rstrip("\\/") if unc else None

    @property
    def retain_versions(self) -> int:
        return max(1, int(self.data["repository"].get("retain_versions", 3)))

    @property
    def manifests_dir(self) -> Path:
        return self._resolve(self.data["manifests_dir"])

    @property
    def database_url(self) -> str:
        url = self.data["database"]["url"]
        # Resolve relative sqlite paths against the config file location.
        prefix = "sqlite:///"
        if url.startswith(prefix) and not url.startswith(prefix + "/") and self.path:
            rel = url[len(prefix):]
            if not (len(rel) > 1 and rel[1] == ":"):  # not a Windows drive path
                url = prefix + str(self._resolve(rel))
        return url

    @property
    def preferred_types(self) -> list[str]:
        return [str(t).lower() for t in self.data.get("installers", {}).get("preferred_types") or []] \
            or list(DEFAULTS["installers"]["preferred_types"])

    @property
    def public_url(self) -> str:
        return self.data["server"]["public_url"].rstrip("/")

    @property
    def api_key(self) -> str | None:
        return self.data["server"].get("api_key") or os.environ.get("APPDEPOT_API_KEY")


def load_config(path: str | os.PathLike | None = None) -> Config:
    path = path or os.environ.get("APPDEPOT_CONFIG")
    if path is None:
        default = Path("appdepot.yaml")
        path = default if default.exists() else None
    if path is None:
        return Config()
    p = Path(path).resolve()
    with open(p, "r", encoding="utf-8") as fh:
        raw = yaml.safe_load(fh) or {}
    return Config(data=_merge(DEFAULTS, raw), path=p)
