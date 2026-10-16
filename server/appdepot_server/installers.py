"""Installer technologies: detection, silent switches and command lines.

Commands are generated in two forms:

* ``executable`` + ``arguments`` - used by the AppDepot client, which runs the
  installer from its download cache.
* a single ``command`` string - the exact text to paste into the Intune
  "Install command" / "Uninstall command" fields. The installer is referenced by
  file name only because Intune runs commands from the extracted content folder.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

# type -> (install args, uninstall args used with the registry UninstallString)
INSTALLER_TYPES: dict[str, dict[str, str]] = {
    "msi": {"install": "/qn /norestart", "uninstall": "/qn /norestart",
            "label": "Windows Installer (MSI)"},
    "wix": {"install": "/qn /norestart", "uninstall": "/qn /norestart",
            "label": "WiX MSI"},
    "msp": {"install": "/qn /norestart", "uninstall": "", "label": "Windows Installer patch (MSP)"},
    "nullsoft": {"install": "/S", "uninstall": "/S", "label": "Nullsoft (NSIS)"},
    "inno": {"install": "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /ALLUSERS",
             "uninstall": "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART",
             "label": "Inno Setup"},
    "burn": {"install": "/quiet /norestart", "uninstall": "/uninstall /quiet /norestart",
             "label": "WiX Burn bundle"},
    "exe": {"install": "", "uninstall": "", "label": "Custom EXE"},
    "msix": {"install": "", "uninstall": "", "label": "MSIX / AppX"},
    "appx": {"install": "", "uninstall": "", "label": "MSIX / AppX"},
}

MSI_TYPES = {"msi", "wix"}
APPX_TYPES = {"msix", "appx"}

# Success codes Intune / the client treat as success
DEFAULT_RETURN_CODES = [
    (0, "Success"),
    (1707, "Success"),
    (3010, "Soft reboot"),
    (1641, "Hard reboot"),
    (1618, "Retry (another installation is in progress)"),
]

_EXT_TYPES = {".msi": "msi", ".msp": "msp", ".msix": "msix", ".msixbundle": "msix", ".appx": "appx",
              ".appxbundle": "appx"}


def guess_installer_type(path: Path) -> str:
    """Best-effort identification of the installer technology of a file."""
    ext = path.suffix.lower()
    if ext in _EXT_TYPES:
        return _EXT_TYPES[ext]
    if ext != ".exe":
        return "exe"
    try:
        size = path.stat().st_size
        with open(path, "rb") as fh:
            head = fh.read(4 * 1024 * 1024)
            if size > 8 * 1024 * 1024:
                fh.seek(max(0, size - 2 * 1024 * 1024))
                head += fh.read()
    except OSError:
        return "exe"
    if b"Nullsoft" in head or b"NSIS Error" in head:
        return "nullsoft"
    if b"Inno Setup" in head or b"InnoSetupLdrWindow" in head:
        return "inno"
    if b".wixburn" in head:
        return "burn"
    return "exe"


def _q(value: str) -> str:
    return f'"{value}"'


@dataclass
class CommandSet:
    install_executable: str
    install_arguments: str
    install_command: str
    uninstall_executable: str | None
    uninstall_arguments: str | None
    uninstall_command: str | None


def _join(*parts: str | None) -> str:
    return " ".join(p.strip() for p in parts if p and p.strip())


def build_commands(
    *,
    filename: str,
    installer_type: str,
    install_args: str | None = None,
    extra_args: str | None = None,
    product_code: str | None = None,
    uninstall_command: str | None = None,
    uninstall_args: str | None = None,
    display_name_regex: str | None = None,
    version: str | None = None,
    key_pattern: str | None = None,
    exclude: str | None = None,
    appx_name: str | None = None,
) -> CommandSet:
    """Build the silent install and uninstall command lines for an installer.

    ``install_args`` replaces the default silent switches for the installer
    type; ``extra_args`` is appended to them (e.g. MSI properties).
    """
    itype = installer_type if installer_type in INSTALLER_TYPES else "exe"
    defaults = INSTALLER_TYPES[itype]
    args = install_args if install_args is not None else defaults["install"]
    args = _join(args, extra_args)

    if itype in MSI_TYPES or itype == "msp":
        inst_exe = "msiexec.exe"
        inst_args = _join("/p" if itype == "msp" else "/i", _q(filename), args)
        inst_cmd = _join("msiexec.exe", inst_args)
    elif itype in APPX_TYPES:
        inst_exe = "powershell.exe"
        inst_args = ("-NoProfile -ExecutionPolicy Bypass -Command "
                     f"\"Add-AppxProvisionedPackage -Online -PackagePath '{filename}' -SkipLicense\"")
        inst_cmd = _join(inst_exe, inst_args)
    else:
        inst_exe = filename
        inst_args = args
        inst_cmd = _join(_q(filename), args)

    # ---- uninstall ------------------------------------------------------------
    tokens = {"product_code": product_code or "", "version": version or "", "filename": filename}
    un_exe = un_args = un_cmd = None
    if uninstall_command:
        un_cmd = uninstall_command.format(**tokens)
        un_exe, un_args = split_command(un_cmd)
    elif itype == "msp":
        pass   # a patch is removed by uninstalling (or repairing) the product it updates
    elif itype in MSI_TYPES and product_code:
        un_exe = "msiexec.exe"
        un_args = _join("/x", product_code, uninstall_args or defaults["uninstall"])
        un_cmd = _join(un_exe, un_args)
    elif itype in APPX_TYPES:
        pkg = appx_name or ((display_name_regex or "").strip("^$") or "*")
        un_exe = "powershell.exe"
        un_args = ("-NoProfile -ExecutionPolicy Bypass -Command "
                   f"\"Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like '{pkg}*' | "
                   "Remove-AppxProvisionedPackage -Online -AllUsers; "
                   f"Get-AppxPackage -AllUsers -Name '{pkg}*' | Remove-AppxPackage -AllUsers\"")
        un_cmd = _join(un_exe, un_args)
    elif display_name_regex:
        # Look up the uninstaller in the registry at run time; works for any
        # installer that registers itself in Programs and Features.
        silent = uninstall_args if uninstall_args is not None else defaults["uninstall"]
        un_exe = "powershell.exe"
        un_args = "-NoProfile -ExecutionPolicy Bypass -Command \"" + registry_uninstall_script(
            display_name_regex, silent, key_pattern, exclude) + "\""
        un_cmd = _join(un_exe, un_args)

    return CommandSet(inst_exe, inst_args, inst_cmd, un_exe, un_args, un_cmd)


def registry_uninstall_script(display_name_regex: str, silent_args: str, key_pattern: str | None = None,
                              exclude: str | None = None) -> str:
    """Compact PowerShell (no double quotes) that finds and runs an uninstaller."""
    rx = display_name_regex.replace("'", "''")
    sa = silent_args.replace("'", "''")
    key_filter = f" -and $_.PSChildName -match '{key_pattern.replace(chr(39), chr(39) * 2)}'" if key_pattern else ""
    if exclude:
        key_filter += f" -and $_.DisplayName -notmatch '{exclude.replace(chr(39), chr(39) * 2)}'"
    return (
        "$k='HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',"
        "'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*';"
        f"$a=Get-ItemProperty $k -EA 0|?{{$_.DisplayName -match '{rx}'{key_filter}}}|select -First 1;"
        "if(!$a){exit 0};"
        "if($a.UninstallString -match 'msiexec'){$p=Start-Process msiexec.exe "
        "-ArgumentList ('/x '+$a.PSChildName+' /qn /norestart') -Wait -PassThru}"
        "else{$u=$a.UninstallString;if($u -match '^\\W*(.+?\\.exe)'){"
        f"$p=Start-Process $matches[1] -ArgumentList '{sa}' -Wait -PassThru}}}};"
        "exit $p.ExitCode"
    )


def split_command(cmd: str) -> tuple[str, str]:
    """Split ``"C:\\path\\app.exe" /S`` into executable and arguments."""
    cmd = cmd.strip()
    m = re.match(r'^"([^"]+)"\s*(.*)$', cmd)
    if m:
        return m.group(1), m.group(2)
    m = re.match(r"^(\S+?\.(?:exe|cmd|bat|com))\b\s*(.*)$", cmd, re.IGNORECASE)
    if m:
        return m.group(1), m.group(2)
    exe, _, rest = cmd.partition(" ")
    return exe, rest
