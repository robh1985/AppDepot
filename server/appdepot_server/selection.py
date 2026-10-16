"""Choose the installer to download from the candidates of all sources.

Rules (see docs/manifest-reference.md, "Installer preference"):

1. Every source of an application is queried; a failing source does not stop
   the others.
2. Only candidates for the **newest version** found by any source are
   considered first.
3. Among those, the installer type earliest in the preference list wins
   (default: MSI first). Ties go to the source listed first, then to the
   source's own order.
4. Older versions are kept at the end of the list as a last resort, so the
   updater can fall back when every download of the newest version fails.
"""

from __future__ import annotations

from typing import Any

from .sources import ReleaseInfo, SourceContext, get_source
from .sources.base import type_from_filename
from .versioning import compare_versions, version_key

DEFAULT_PREFERRED_TYPES = ["msi", "wix", "msp", "msix", "appx", "burn", "inno", "nullsoft", "exe"]
MSI_FAMILY = {"msi", "wix"}


def candidate_type(c: ReleaseInfo) -> str:
    return c.installer_type or type_from_filename(c.filename) or type_from_filename(c.url) or "exe"


def type_rank(itype: str, preferred: list[str]) -> int:
    if itype in preferred:
        return preferred.index(itype)
    # Unlisted exe-based technologies rank with generic exe; anything else last.
    return preferred.index("exe") if "exe" in preferred else len(preferred)


def apply_declared_type(candidates: list[ReleaseInfo], declared: str | None) -> None:
    """Let a manifest's installer.type label generic .exe candidates (e.g. as 'inno')."""
    if not declared or declared in MSI_FAMILY or declared in ("msix", "appx"):
        return
    for c in candidates:
        if c.installer_type in (None, "exe") and not type_from_filename(c.filename or c.url):
            c.installer_type = declared


def gather(sources: list[dict[str, Any]], client, github_token: str | None,
           state: dict[str, Any]) -> tuple[list[ReleaseInfo], list[str]]:
    """Query every source. Returns (candidates, error messages)."""
    candidates: list[ReleaseInfo] = []
    errors: list[str] = []
    for idx, cfg in enumerate(sources):
        ctx = SourceContext(client=client, github_token=github_token, state=dict(state.get(str(idx)) or {}))
        try:
            found = get_source(cfg["type"], cfg).resolve_all(ctx)
        except Exception as exc:  # noqa: BLE001 - one bad source must not hide the others
            errors.append(f"source {idx + 1} ({cfg['type']}): {exc}")
            continue
        for c in found:
            c.source_index = idx
            c.source_type = cfg["type"]
            # A url source that saw an unchanged file reports the version it had last time
            if c.version is None and c.unchanged and ctx.state.get("version"):
                c.version = ctx.state["version"]
        candidates.extend(found)
    return candidates, errors


def rank(candidates: list[ReleaseInfo], preferred: list[str]) -> list[ReleaseInfo]:
    """Order candidates best first. Candidates without a version are ignored."""
    def key(c: ReleaseInfo) -> tuple:
        # Newest version first (negated version key sorts descending), then type, source, order.
        return (_Desc(version_key(c.version)), type_rank(candidate_type(c), preferred),
                c.source_index, c.order)

    return sorted((c for c in candidates if c.version), key=key)


class _Desc:
    """Wraps a sortable value so that it sorts in descending order."""

    __slots__ = ("v",)

    def __init__(self, v):
        self.v = v

    def __lt__(self, other):
        return self.v > other.v

    def __eq__(self, other):
        return self.v == other.v


def describe(c: ReleaseInfo) -> dict[str, Any]:
    return {"version": c.version, "type": candidate_type(c), "source": c.source_type,
            "source_index": c.source_index + 1, "url": c.url, "filename": c.filename,
            "architecture": c.architecture}


def selection_note(chosen: ReleaseInfo, candidates: list[ReleaseInfo], source_count: int) -> str:
    itype = candidate_type(chosen)
    where = f"{chosen.source_type} (source {chosen.source_index + 1} of {source_count})"
    if itype in MSI_FAMILY:
        return f"Selected MSI from {where}"
    if itype == "msp":
        return f"Selected MSP update patch from {where}"
    same_version = sorted({candidate_type(c) for c in candidates
                           if c.version and compare_versions(c.version, chosen.version) == 0})
    if MSI_FAMILY & set(same_version):
        return (f"The MSI for version {chosen.version} could not be downloaded; "
                f"using {itype} from {where}")
    return (f"No MSI available for version {chosen.version} from {source_count} source(s) "
            f"(found: {', '.join(same_version) or itype}); using {itype} from {where}")
