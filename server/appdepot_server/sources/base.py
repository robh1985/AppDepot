"""Common source plumbing."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, ClassVar
from urllib.parse import unquote, urlparse

import httpx

from ..versioning import version_parts


@dataclass
class ReleaseInfo:
    """What a source found on the internet."""

    version: str | None          # None = determine from the downloaded file (MSI)
    url: str
    filename: str | None = None
    installer_type: str | None = None
    sha256: str | None = None
    install_args: str | None = None        # silent switches published by the source
    extra_args: str | None = None          # additional switches appended to the above
    product_code: str | None = None
    architecture: str | None = None
    scope: str | None = None
    release_notes_url: str | None = None
    headers: dict[str, str] = field(default_factory=dict)
    # Opaque state stored on the application (e.g. ETag) to skip unchanged downloads
    state: dict[str, Any] = field(default_factory=dict)
    unchanged: bool = False


@dataclass
class SourceContext:
    client: httpx.Client
    github_token: str | None = None
    state: dict[str, Any] = field(default_factory=dict)


class Source:
    type_name: ClassVar[str] = ""
    required: ClassVar[tuple[str, ...]] = ()

    def __init__(self, config: dict[str, Any]):
        self.config = config

    @classmethod
    def validate(cls, config: dict[str, Any]) -> None:
        missing = [k for k in cls.required if not config.get(k)]
        if missing:
            raise ValueError(f"'{cls.type_name}' source requires: {', '.join(missing)}")
        for key in ("version_regex", "url_regex", "asset_pattern"):
            if config.get(key):
                try:
                    re.compile(config[key])
                except re.error as exc:
                    raise ValueError(f"{key} is not a valid regex: {exc}") from exc

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:  # pragma: no cover - abstract
        raise NotImplementedError


def make_client(sources_cfg: dict[str, Any]) -> httpx.Client:
    return httpx.Client(
        follow_redirects=True,
        timeout=httpx.Timeout(float(sources_cfg.get("timeout") or 600), connect=30.0),
        headers={"User-Agent": sources_cfg.get("user_agent") or "AppDepot/1.0"},
        proxy=sources_cfg.get("proxy") or None,
        verify=sources_cfg.get("verify_tls", True),
    )


def render_template(template: str, version: str, extra: dict[str, str] | None = None) -> str:
    values = version_parts(version)
    if extra:
        values.update(extra)
    return template.format(**values)


def regex_first(pattern: str, text: str, group: str = "version") -> str | None:
    m = re.search(pattern, text)
    if not m:
        return None
    if group in m.groupdict():
        return m.group(group)
    return m.group(1) if m.groups() else m.group(0)


def json_path(data: Any, path: str) -> Any:
    """Tiny JSON path: ``a.b[0].c`` or ``a.b.0.c``. ``[-1]`` selects the last element."""
    cur = data
    for part in re.findall(r"[^.\[\]]+", path):
        if isinstance(cur, list):
            cur = cur[int(part)]
        elif isinstance(cur, dict):
            cur = cur[part]
        else:
            raise KeyError(path)
    return cur


def filename_from_url(url: str) -> str:
    name = unquote(urlparse(url).path.rstrip("/").rsplit("/", 1)[-1])
    return name or "installer.bin"


def clean_version(raw: str | None, cfg: dict[str, Any]) -> str | None:
    if raw is None:
        return None
    raw = str(raw).strip()
    if cfg.get("version_regex"):
        found = regex_first(cfg["version_regex"], raw)
        if found:
            raw = found
    if raw[:1] in ("v", "V") and raw[1:2].isdigit():
        raw = raw[1:]
    return raw
