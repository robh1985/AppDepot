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

import fnmatch
import json
import logging
import os
import re
import shutil
import struct
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
    file_version: str | None = None        # MSIX manifest or EXE version resource
    texts: list[str] = field(default_factory=list)   # MSI property values + summary information

    @property
    def msi_version(self) -> str | None:
        return (self.msi_info or {}).get("ProductVersion")

    @property
    def version(self) -> str | None:
        """Version carried by the file itself: MSI ProductVersion, MSIX manifest, EXE resource."""
        return self.msi_version or self.file_version

    def find_text_version(self, pattern: str) -> str | None:
        """Highest match of a regex in the MSI's texts (e.g. Chrome's real version)."""
        from .versioning import max_version
        found = []
        for text in self.texts:
            for m in re.finditer(pattern, text or ""):
                found.append(m.group("version") if "version" in m.groupdict()
                             else (m.group(1) if m.groups() else m.group(0)))
        return max_version(found)


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
    """setup_file: a file name, a relative path, or a wildcard pattern such as '*.msi'."""
    if setup_file and ("/" in setup_file or "\\" in setup_file):
        p = extract_dir / setup_file.replace("\\", "/")
        if p.is_file():
            return p
        raise ValueError(f"'{setup_file}' was not found in the archive")
    files = sorted((p for p in extract_dir.rglob("*") if p.is_file()), key=lambda p: (len(p.parts), str(p)))
    if setup_file:
        for p in files:
            if p.name.lower() == setup_file.lower() or fnmatch.fnmatch(p.name.lower(), setup_file.lower()):
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


def pe_version(path: Path) -> str | None:
    """FileVersion from an EXE's VS_FIXEDFILEINFO block (no Windows APIs needed)."""
    signature = b"\xbd\x04\xef\xfe"
    chunk_size, overlap = 4 * 1024 * 1024, 64
    try:
        with open(path, "rb") as fh:
            offset, tail = 0, b""
            while True:
                chunk = fh.read(chunk_size)
                if not chunk:
                    return None
                data = tail + chunk
                pos = data.find(signature)
                while pos != -1:
                    block = data[pos:pos + 52]
                    if len(block) < 20:
                        fh.seek(offset - len(tail) + pos)
                        block = fh.read(52)
                    _, struc, ms, ls = struct.unpack("<IIII", block[:16])
                    if struc in (0x00010000, 0x00000000) and (ms or ls):
                        return f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}"
                    pos = data.find(signature, pos + 4)
                tail = data[-overlap:]
                offset += len(chunk)
    except OSError:
        return None


def msix_version(path: Path) -> str | None:
    """Identity Version from an .msix/.appx (AppxManifest.xml) or a bundle's manifest."""
    try:
        with zipfile.ZipFile(path) as zf:
            names = {n.lower(): n for n in zf.namelist()}
            for candidate in ("appxmanifest.xml", "appxmetadata/appxbundlemanifest.xml"):
                if candidate in names:
                    xml = zf.read(names[candidate]).decode("utf-8", "replace")
                    m = re.search(r"<Identity\b[^>]*\bVersion=\"([\d.]+)\"", xml)
                    if m:
                        return m.group(1)
    except (OSError, zipfile.BadZipFile):
        return None
    return None


def msi_texts(path: Path) -> list[str]:
    """MSI property values (except ProductVersion) and summary title/subject/keywords/comments."""
    from .msi import read_msi_properties
    texts = []
    try:
        texts += [v for k, v in read_msi_properties(path).items() if k != "ProductVersion" and v]
    except Exception:  # noqa: BLE001
        pass
    try:
        with olefile.OleFileIO(str(path)) as ole:
            meta = ole.get_metadata()
        for attr in ("title", "subject", "keywords", "comments"):
            value = getattr(meta, attr, None)
            if isinstance(value, bytes):
                value = value.decode("latin-1", "replace")
            if value:
                texts.append(value)
    except Exception:  # noqa: BLE001
        pass
    return texts


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
        info = FileInfo(installer_type=itype, setup_path=str(PurePosixPath(*setup.relative_to(extract_dir).parts)),
                        setup_name=setup.name, setup_dir=setup.parent, msi_info=msi_info)
        if setup.suffix.lower() == ".msi":
            info.texts = msi_texts(setup)
        elif not msi_info and setup.suffix.lower() == ".exe":
            info.file_version = pe_version(setup)
        return info

    itype = _resolve_type(path, declared_type, candidate_type)
    info = FileInfo(installer_type=itype)
    if itype in ("msi", "wix") or path.suffix.lower() == ".msi":
        info.msi_info = _msi(path)
        info.texts = msi_texts(path)
    elif itype == "msp":
        info.target_product_codes = msp_targets(path)
    elif itype in ("msix", "appx"):
        info.file_version = msix_version(path)
    elif path.suffix.lower() == ".exe":
        info.file_version = pe_version(path)
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


SIGNATURE_SCRIPT = (
    "$ErrorActionPreference = 'Stop'; "
    "Import-Module Microsoft.PowerShell.Security; "
    "$s = Get-AuthenticodeSignature -LiteralPath $env:APPDEPOT_SIGFILE; "
    "[Console]::Out.Write((ConvertTo-Json -Compress -InputObject @{ "
    "Status = [string]$s.Status; Subject = [string]$s.SignerCertificate.Subject; "
    "Message = [string]$s.StatusMessage }))"
)


def _powershell() -> str | None:
    """Windows PowerShell 5.1 (always present on Windows Server), then PowerShell 7."""
    system_ps = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    if system_ps.exists():
        return str(system_ps)
    return shutil.which("powershell.exe") or shutil.which("pwsh.exe")


def verify_signature(path: Path, signer: str) -> tuple[bool | None, str]:
    """(True/False, detail) on Windows; (None, reason) where it cannot be checked.

    False means the file is unsigned, tampered with or signed by someone else, and the
    download is rejected. None means the check itself could not run; the download is
    kept and the reason logged.
    """
    if os.name != "nt":
        return None, "signature not verified (only possible on a Windows server)"
    ps = _powershell()
    if not ps:
        return None, "signature not verified (PowerShell not found)"
    # A PSModulePath inherited from PowerShell 7 makes Windows PowerShell load the wrong
    # Microsoft.PowerShell.Security module, so Get-AuthenticodeSignature fails. Start clean.
    env = {k: v for k, v in os.environ.items() if k.upper() != "PSMODULEPATH"}
    env["APPDEPOT_SIGFILE"] = str(path)
    try:
        proc = subprocess.run([ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
                               SIGNATURE_SCRIPT], capture_output=True, text=True, timeout=300, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"signature not verified: PowerShell could not run ({exc})"
    out = (proc.stdout or "").strip().lstrip("\ufeff")
    try:
        data = json.loads(out[out.find("{"):]) if "{" in out else {}
    except ValueError:
        data = {}
    status, subject = data.get("Status") or "", data.get("Subject") or ""
    if not status:
        err = " ".join((proc.stderr or proc.stdout or "no output").split())[:300]
        log.warning("Authenticode check of %s did not run (exit %s): %s", path.name, proc.returncode, err)
        return None, f"signature not verified: the check did not run ({err})"
    ok = status == "Valid" and re.search(signer, subject, re.IGNORECASE) is not None
    detail = f"status {status}, signer {subject or 'none'}"
    if status != "Valid" and data.get("Message"):
        detail += f" - {data['Message']}"
    return ok, detail
