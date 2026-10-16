"""Inspect downloaded or uploaded installer files.

* ZIP archives (e.g. Adobe's Acrobat installer) are extracted and the setup file
  is located (``installer.setup_file``). The folder that contains it is what
  Intune packages and clients run.
* MSI files - including an MSI next to a setup.exe in an archive - give the
  version, ProductCode and UpgradeCode.
* MSP patches list the products they apply to (summary information "Template").
* Authenticode signatures can be checked against an expected signer
  (``installer.signer``). This uses Windows' own verification, so it only runs
  on a Windows server; elsewhere it is reported as "not verified".
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
import zipfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

import olefile

from .installers import guess_installer_type
from .msi import msi_summary

log = logging.getLogger("appdepot.packages")
GUID_RE = re.compile(r"^\{[0-9A-F-]{36}\}$")


@dataclass
class FileInfo:
    installer_type: str
    setup_path: str | None = None          # path of the setup file inside the archive (posix)
    setup_name: str | None = None          # file name used in install commands
    setup_dir: Path | None = None          # extracted folder containing the setup file
    msi_info: dict | None = None
    target_product_codes: list[str] = field(default_factory=list)

    @property
    def msi_version(self) -> str | None:
        return (self.msi_info or {}).get("ProductVersion")


def is_archive(path: Path) -> bool:
    return path.suffix.lower() == ".zip" and zipfile.is_zipfile(path)


def safe_extract(archive: Path, target: Path) -> Path:
    target.mkdir(parents=True, exist_ok=True)
    root = target.resolve()
    with zipfile.ZipFile(archive) as zf:
        for member in zf.infolist():
            dest = (target / member.filename).resolve()
            if root not in dest.parents and dest != root:
                raise ValueError(f"Unsafe path in archive: {member.filename}")
        zf.extractall(target)
    return target


def find_setup(extract_dir: Path, setup_file: str | None) -> Path:
    if setup_file and ("/" in setup_file or "\\" in setup_file):
        p = extract_dir / setup_file.replace("\\", "/")
        if p.is_file():
            return p
        raise ValueError(f"'{setup_file}' was not found in the archive")
    files = sorted((p for p in extract_dir.rglob("*") if p.is_file()), key=lambda p: (len(p.parts), str(p)))
    if setup_file:
        for p in files:
            if p.name.lower() == setup_file.lower():
                return p
        raise ValueError(f"'{setup_file}' was not found in the archive")
    for pattern in ("setup.exe", "*.msi", "*.exe"):
        matches = [p for p in files if p.match(pattern)]
        if len(matches) >= 1:
            return matches[0]
    raise ValueError("No setup file found in the archive; set installer.setup_file")


def msp_targets(path: Path) -> list[str]:
    """ProductCodes an .msp patch applies to."""
    try:
        with olefile.OleFileIO(str(path)) as ole:
            template = ole.get_metadata().template
    except Exception as exc:  # noqa: BLE001
        log.warning("Could not read patch information from %s: %s", path.name, exc)
        return []
    if isinstance(template, bytes):
        template = template.decode("latin-1", "replace")
    return [t.strip().upper() for t in (template or "").split(";") if GUID_RE.match(t.strip().upper())]


def _msi(path: Path) -> dict | None:
    try:
        return msi_summary(path)
    except Exception as exc:  # noqa: BLE001
        log.warning("Could not read MSI properties of %s: %s", path.name, exc)
        return None


def inspect_file(path: Path, *, setup_file: str | None = None, declared_type: str | None = None,
                 candidate_type: str | None = None, extract_to: Path | None = None) -> FileInfo:
    """Work out installer type, setup file and MSI/patch details of a file."""
    if is_archive(path) and (setup_file or declared_type != "zip"):
        extract_dir = safe_extract(path, extract_to or path.parent / (path.stem + "_extracted"))
        setup = find_setup(extract_dir, setup_file)
        itype = _resolve_type(setup, declared_type, None)
        msi_info = _msi(setup) if setup.suffix.lower() == ".msi" else None
        if msi_info is None:   # e.g. setup.exe next to AcroPro.msi
            for m in sorted(setup.parent.glob("*.msi")):
                msi_info = _msi(m)
                if msi_info:
                    break
        return FileInfo(installer_type=itype, setup_path=str(PurePosixPath(*setup.relative_to(extract_dir).parts)),
                        setup_name=setup.name, setup_dir=setup.parent, msi_info=msi_info)

    itype = _resolve_type(path, declared_type, candidate_type)
    info = FileInfo(installer_type=itype)
    if itype in ("msi", "wix") or path.suffix.lower() == ".msi":
        info.msi_info = _msi(path)
    elif itype == "msp":
        info.target_product_codes = msp_targets(path)
    return info


def _resolve_type(path: Path, declared: str | None, candidate: str | None) -> str:
    ext = path.suffix.lower()
    if ext == ".msi":
        return "wix" if candidate == "wix" else "msi"
    if ext == ".msp":
        return "msp"
    if ext in (".msix", ".msixbundle"):
        return "msix"
    if ext in (".appx", ".appxbundle"):
        return "appx"
    if candidate and candidate != "exe":
        return candidate
    if declared and declared not in ("msi", "wix", "msp", "msix", "appx"):
        return declared
    return guess_installer_type(path)


def verify_signature(path: Path, signer: str) -> tuple[bool | None, str]:
    """(True/False, detail) on Windows; (None, reason) where it cannot be checked."""
    if os.name != "nt":
        return None, "signature not verified (only possible on a Windows server)"
    ps = shutil.which("powershell.exe") or shutil.which("pwsh.exe")
    if not ps:
        return None, "signature not verified (PowerShell not found)"
    script = ("$s = Get-AuthenticodeSignature -LiteralPath $env:APPDEPOT_SIGFILE; "
              "[pscustomobject]@{Status=[string]$s.Status; Subject=[string]$s.SignerCertificate.Subject} "
              "| ConvertTo-Json -Compress")
    try:
        proc = subprocess.run([ps, "-NoProfile", "-NonInteractive", "-Command", script], capture_output=True,
                              text=True, timeout=300, env={**os.environ, "APPDEPOT_SIGFILE": str(path)})
        data = json.loads(proc.stdout.strip() or "{}")
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return None, f"signature check could not run: {exc}"
    status, subject = data.get("Status", ""), data.get("Subject", "")
    ok = status == "Valid" and re.search(signer, subject or "", re.IGNORECASE) is not None
    return ok, f"status {status or 'unknown'}, signer {subject or 'none'}"
