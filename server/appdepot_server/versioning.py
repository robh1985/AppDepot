"""Version comparison that copes with the many version formats vendors use.

``packaging.version`` rejects strings like ``24.08``, ``1.2.3b``, ``2024-10-01``
or ``v3.1-rc2``, so AppDepot uses its own tolerant comparison:

* the string is split into numeric and alphabetic tokens;
* numbers compare numerically (``24.08`` == ``24.8``);
* trailing zero components of each numeric run are ignored
  (``1.0`` == ``1.0.0``, ``1.0-rc1`` == ``1-rc1``);
* alphabetic tokens (``beta``, ``rc``) sort *before* the release they qualify,
  so ``1.0-rc1 < 1.0``.

The same algorithm is implemented in the PowerShell client
(``Compare-DepotVersion``) so both sides agree on what "newer" means.
"""

from __future__ import annotations

import functools
import re

_TOKEN = re.compile(r"\d+|[A-Za-z]+")

# Tuple tags: alpha tokens < end-of-version < numbers
_ALPHA, _END, _NUM = 0, 1, 2


def version_key(version: str | None) -> tuple:
    if not version:
        return ((_END, 0, ""),)
    v = version.strip()
    if v[:1] in ("v", "V") and v[1:2].isdigit():
        v = v[1:]
    tokens: list[tuple[int, int, str]] = []
    run_start = 0  # index where the current run of numeric tokens began

    def trim_run() -> None:
        # Drop trailing zeros of a numeric run (keep at least one number)
        while len(tokens) - run_start > 1 and tokens[-1] == (_NUM, 0, ""):
            tokens.pop()

    for tok in _TOKEN.findall(v):
        if tok.isdigit():
            tokens.append((_NUM, int(tok), ""))
        else:
            trim_run()
            tokens.append((_ALPHA, 0, tok.lower()))
            run_start = len(tokens)
    trim_run()
    tokens.append((_END, 0, ""))
    return tuple(tokens)


def compare_versions(a: str | None, b: str | None) -> int:
    """Return -1, 0 or 1 like a classic comparator."""
    ka, kb = version_key(a), version_key(b)
    return (ka > kb) - (ka < kb)


def is_newer(candidate: str | None, current: str | None) -> bool:
    if not current:
        return bool(candidate)
    return compare_versions(candidate, current) > 0


def sort_versions(versions, reverse: bool = True, key=lambda v: v):
    return sorted(versions, key=lambda item: version_key(key(item)), reverse=reverse)


def max_version(versions):
    versions = [v for v in versions if v]
    if not versions:
        return None
    return max(versions, key=version_key)


cmp_key = functools.cmp_to_key(compare_versions)


def version_parts(version: str) -> dict[str, str]:
    """Split a version into template variables for download URL templates."""
    nums = re.findall(r"\d+", version or "")
    parts = {
        "version": version,
        "version_nodots": (version or "").replace(".", ""),
        "version_underscore": (version or "").replace(".", "_"),
        "version_dashes": (version or "").replace(".", "-"),
        "major": nums[0] if len(nums) > 0 else "",
        "minor": nums[1] if len(nums) > 1 else "",
        "patch": nums[2] if len(nums) > 2 else "",
        "build": nums[3] if len(nums) > 3 else "",
    }
    parts["major_minor"] = ".".join(n for n in (parts["major"], parts["minor"]) if n)
    return parts
