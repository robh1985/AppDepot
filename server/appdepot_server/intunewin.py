"""Create ``.intunewin`` packages for Microsoft Intune Win32 apps.

Two packagers are available:

``native`` (default)
    A pure-Python implementation of the format produced by Microsoft's
    *Win32 Content Prep Tool* (IntuneWinAppUtil.exe). Works on any OS.

``official``
    Runs IntuneWinAppUtil.exe (Windows only), for organisations that prefer the
    Microsoft tool.

Format
------
An ``.intunewin`` file is a ZIP archive containing::

    IntuneWinPackage/Contents/IntunePackage.intunewin   (encrypted payload)
    IntuneWinPackage/Metadata/Detection.xml             (metadata + keys)

The payload is a ZIP of the source folder, encrypted with AES-256-CBC
(PKCS7 padding) and authenticated with HMAC-SHA256. The encrypted file is laid
out as ``HMAC(32) || IV(16) || ciphertext`` where the HMAC covers
``IV || ciphertext``. Keys, IV, MAC and the SHA-256 of the unencrypted ZIP are
stored base64-encoded in Detection.xml; Intune uses them to decrypt the
content on the device.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

TOOL_VERSION = "1.8.6.0"
CHUNK = 1024 * 1024


class IntuneWinError(RuntimeError):
    pass


def _zip_folder(source: Path, target: Path) -> None:
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
        for path in sorted(source.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(source).as_posix())


def _encrypt_file(src: Path, dst: Path) -> dict[str, str]:
    enc_key, mac_key, iv = os.urandom(32), os.urandom(32), os.urandom(16)
    encryptor = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).encryptor()
    padder = padding.PKCS7(128).padder()
    mac = hmac.new(mac_key, digestmod=hashlib.sha256)
    digest = hashlib.sha256()

    with open(src, "rb") as fin, open(dst, "wb") as fout:
        fout.write(b"\0" * 32)  # placeholder for the HMAC
        fout.write(iv)
        mac.update(iv)
        while chunk := fin.read(CHUNK):
            digest.update(chunk)
            out = encryptor.update(padder.update(chunk))
            mac.update(out)
            fout.write(out)
        out = encryptor.update(padder.finalize()) + encryptor.finalize()
        mac.update(out)
        fout.write(out)
        mac_bytes = mac.digest()
        fout.seek(0)
        fout.write(mac_bytes)

    b64 = lambda b: base64.b64encode(b).decode("ascii")  # noqa: E731
    return {
        "EncryptionKey": b64(enc_key),
        "MacKey": b64(mac_key),
        "InitializationVector": b64(iv),
        "Mac": b64(mac_bytes),
        "ProfileIdentifier": "ProfileVersion1",
        "FileDigest": b64(digest.digest()),
        "FileDigestAlgorithm": "SHA256",
    }


def _bool(v: bool) -> str:
    return "true" if v else "false"


def build_detection_xml(*, name: str, setup_file: str, unencrypted_size: int,
                        encryption: dict[str, str], msi_info: dict | None = None) -> str:
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<ApplicationInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" '
        f'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ToolVersion="{TOOL_VERSION}">',
        f"  <Name>{escape(name)}</Name>",
        f"  <UnencryptedContentSize>{unencrypted_size}</UnencryptedContentSize>",
        "  <FileName>IntunePackage.intunewin</FileName>",
        f"  <SetupFile>{escape(setup_file)}</SetupFile>",
        "  <EncryptionInfo>",
    ]
    for key in ("EncryptionKey", "MacKey", "InitializationVector", "Mac",
                "ProfileIdentifier", "FileDigest", "FileDigestAlgorithm"):
        lines.append(f"    <{key}>{escape(encryption[key])}</{key}>")
    lines.append("  </EncryptionInfo>")
    if msi_info and msi_info.get("ProductCode"):
        machine = str(msi_info.get("ALLUSERS") or "1") == "1"
        lines += [
            "  <MsiInfo>",
            f"    <MsiProductCode>{escape(msi_info['ProductCode'])}</MsiProductCode>",
            f"    <MsiProductVersion>{escape(msi_info.get('ProductVersion') or '')}</MsiProductVersion>",
            f"    <MsiPackageCode>{escape(msi_info.get('PackageCode') or '')}</MsiPackageCode>",
            f"    <MsiUpgradeCode>{escape(msi_info.get('UpgradeCode') or '')}</MsiUpgradeCode>",
            f"    <MsiExecutionContext>{'System' if machine else 'Any'}</MsiExecutionContext>",
            "    <MsiRequiresLogon>false</MsiRequiresLogon>",
            "    <MsiRequiresReboot>false</MsiRequiresReboot>",
            f"    <MsiIsMachineInstall>{_bool(machine)}</MsiIsMachineInstall>",
            f"    <MsiIsUserInstall>{_bool(not machine)}</MsiIsUserInstall>",
            "    <MsiIncludesServices>false</MsiIncludesServices>",
            "    <MsiIncludesODBCDataSource>false</MsiIncludesODBCDataSource>",
            "    <MsiContainsSystemRegistryKeys>false</MsiContainsSystemRegistryKeys>",
            "    <MsiContainsSystemFolders>false</MsiContainsSystemFolders>",
            "  </MsiInfo>",
        ]
    lines.append("</ApplicationInfo>")
    return "\r\n".join(lines) + "\r\n"


def create_intunewin_native(source_folder: Path, setup_file: str, output_file: Path,
                            msi_info: dict | None = None) -> Path:
    source_folder = Path(source_folder)
    if not (source_folder / setup_file).is_file():
        raise IntuneWinError(f"Setup file {setup_file} not found in {source_folder}")
    output_file = Path(output_file)
    output_file.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="intunewin-", dir=output_file.parent) as tmp:
        tmp = Path(tmp)
        content_zip = tmp / "content.zip"
        encrypted = tmp / "IntunePackage.intunewin"
        _zip_folder(source_folder, content_zip)
        encryption = _encrypt_file(content_zip, encrypted)
        name = (msi_info or {}).get("ProductName") or setup_file
        xml = build_detection_xml(name=name, setup_file=setup_file,
                                  unencrypted_size=content_zip.stat().st_size,
                                  encryption=encryption, msi_info=msi_info)
        partial = tmp / "package.intunewin"
        # The outer archive is stored without compression, like the official tool.
        with zipfile.ZipFile(partial, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as zf:
            zf.write(encrypted, "IntuneWinPackage/Contents/IntunePackage.intunewin")
            zf.writestr("IntuneWinPackage/Metadata/Detection.xml", xml.encode("utf-8"))
        shutil.move(str(partial), output_file)
    return output_file


def create_intunewin_official(tool: Path, source_folder: Path, setup_file: str,
                              output_file: Path) -> Path:
    if not tool or not Path(tool).is_file():
        raise IntuneWinError(f"IntuneWinAppUtil.exe not found at {tool}")
    output_file = Path(output_file)
    with tempfile.TemporaryDirectory(prefix="intunewin-", dir=output_file.parent) as tmp:
        cmd = [str(tool), "-c", str(source_folder), "-s", setup_file, "-o", tmp, "-q"]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        produced = Path(tmp) / (Path(setup_file).stem + ".intunewin")
        if proc.returncode != 0 or not produced.exists():
            raise IntuneWinError(f"IntuneWinAppUtil failed ({proc.returncode}): {proc.stdout[-2000:]}")
        shutil.move(str(produced), output_file)
    return output_file


def read_intunewin(package: Path) -> tuple[str, bytes]:
    """Return (Detection.xml, decrypted content zip bytes). Verifies MAC + digest.

    Used by tests and ``appdepot-server verify-package``.
    """
    import xml.etree.ElementTree as ET

    with zipfile.ZipFile(package) as zf:
        xml = zf.read("IntuneWinPackage/Metadata/Detection.xml").decode("utf-8")
        blob = zf.read("IntuneWinPackage/Contents/IntunePackage.intunewin")
    root = ET.fromstring(xml)
    info = {child.tag: child.text for child in root.find("EncryptionInfo")}
    key = base64.b64decode(info["EncryptionKey"])
    mac_key = base64.b64decode(info["MacKey"])
    mac, iv, ciphertext = blob[:32], blob[32:48], blob[48:]
    expected = hmac.new(mac_key, iv + ciphertext, hashlib.sha256).digest()
    if not hmac.compare_digest(mac, expected) or base64.b64encode(mac).decode() != info["Mac"]:
        raise IntuneWinError("HMAC verification failed")
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    unpadder = padding.PKCS7(128).unpadder()
    plain = unpadder.update(decryptor.update(ciphertext) + decryptor.finalize()) + unpadder.finalize()
    if base64.b64encode(hashlib.sha256(plain).digest()).decode() != info["FileDigest"]:
        raise IntuneWinError("File digest mismatch")
    return xml, plain
