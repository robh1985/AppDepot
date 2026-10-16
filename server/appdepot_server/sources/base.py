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
    sha512: str | None = None
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
    # Filled in by the updater when candidates from several sources are compared
    source_index: int = 0
    source_type: str = ""
    order: int = 0                 # preference order within its source
    downloaded: Any = None         # (path, sha256, size, final_url, cd_filename) once fetched
    inspected: Any = None          # packages.FileInfo once the file has been examined
    # How to read the version from the downloaded file when version is None:
    # {"text_regex": ...} searches MSI texts; "fallback" is used when nothing is found
    version_rule: dict[str, Any] = field(default_factory=dict)


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
        for key in ("version_regex", "url_regex", "asset_pattern", "tag_regex", "sha256_regex"):
            for value in as_list(config.get(key)):
                try:
                    re.compile(value)
                except re.error as exc:
                    raise ValueError(f"{key} is not a valid regex: {exc}") from exc

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:  # pragma: no cover - abstract
        raise NotImplementedError

    def resolve_all(self, ctx: SourceContext) -> list[ReleaseInfo]:
        """Every installer this source offers for its latest version, best first.

        The updater compares the candidates of all sources and picks the preferred
        installer type (MSI by default). Sources offering a single file return one item.
        """
        return [self.resolve(ctx)]


def make_client(sources_cfg: dict[str, Any]) -> httpx.Client:
    return httpx.Client(
        follow_redirects=True,
        timeout=httpx.Timeout(float(sources_cfg.get("timeout") or 600), connect=30.0),
        headers={"User-Agent": sources_cfg.get("user_agent") or "AppDepot/1.0"},
        proxy=sources_cfg.get("proxy") or None,
        verify=sources_cfg.get("verify_tls", True),
    )


def render_template(template: str, version: str, extra: dict[str, str] | None = None) -> str:
    """Fill {version}, {version_nodots}, {major}... Other braces (e.g. regex {0,40}) are left alone."""
    values = version_parts(version)
    if extra:
        values.update(extra)
    return re.sub(r"\{(\w+)\}", lambda m: str(values[m.group(1)]) if m.group(1) in values else m.group(0),
                  template)


def regex_first(pattern: str, text: str, group: str = "version") -> str | None:
    m = re.search(pattern, text)
    if not m:
        return None
    if group in m.groupdict():
        return m.group(group)
    return m.group(1) if m.groups() else m.group(0)


_PATH_TOKEN = re.compile(r"\[\?([^\]]+)\]|\[max:([^\]]+)\]|\[(-?\d+)\]|([^.\[\]]+)")


def _matches(item: Any, condition: str) -> bool:
    """``key=value`` (``&`` combines conditions); values compare as text or numbers."""
    for cond in condition.split("&"):
        key, _, want = cond.partition("=")
        value = item.get(key.strip()) if isinstance(item, dict) else None
        want = want.strip()
        if value is None:
            return False
        if str(value).lower() == want.lower():
            continue
        try:
            if float(value) == float(want):
                continue
        except (TypeError, ValueError):
            pass
        return False
    return True


def json_path(data: Any, path: str) -> Any:
    """Small JSON path language.

    ``a.b[0].c`` / ``a.b.0.c``  index into objects and lists (``[-1]`` = last)
    ``list[?Key=Value]``         keep list items whose Key equals Value (``&`` for several)
    ``list[max:Key]``            the item whose Key is the highest version
    """
    from ..versioning import version_key

    cur = data
    for flt, mx, idx, name in _PATH_TOKEN.findall(path):
        if flt:
            if not isinstance(cur, list):
                raise KeyError(path)
            cur = [item for item in cur if _matches(item, flt)]
        elif mx:
            items = [i for i in (cur or []) if isinstance(i, dict) and i.get(mx) is not None]
            if not items:
                raise KeyError(path)
            cur = max(items, key=lambda i: version_key(str(i[mx])))
        elif idx:
            if not isinstance(cur, list):
                raise KeyError(path)
            cur = cur[int(idx)]
        elif isinstance(cur, list) and name.lstrip("-").isdigit():
            cur = cur[int(name)]
        elif isinstance(cur, dict):
            cur = cur[name]
        else:
            raise KeyError(path)
    return cur


def type_from_filename(name: str | None) -> str | None:
    ext = (name or "").lower().rsplit(".", 1)[-1] if "." in (name or "") else ""
    return {"msi": "msi", "msp": "msp", "msix": "msix", "msixbundle": "msix", "appx": "appx",
            "appxbundle": "appx"}.get(ext)


def as_list(value: Any) -> list:
    if value is None:
        return []
    return list(value) if isinstance(value, (list, tuple)) else [value]


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
