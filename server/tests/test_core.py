import base64
import io
import zipfile
from pathlib import Path

import pytest

from appdepot_server.installers import build_commands, guess_installer_type, split_command
from appdepot_server.intunewin import create_intunewin_native, read_intunewin
from appdepot_server.manifest import ManifestError, validate_manifest
from appdepot_server.msi import decode_stream_name
from appdepot_server.versioning import compare_versions, is_newer, max_version, sort_versions, version_parts


# ---------------------------------------------------------------- versioning
@pytest.mark.parametrize("a,b,expected", [
    ("1.0", "1.0.0", 0),
    ("24.08", "24.8", 0),
    ("1.10", "1.9", 1),
    ("2.0", "10.0", -1),
    ("1.0-rc1", "1.0", -1),
    ("1.0-beta", "1.0-rc", -1),
    ("v3.1", "3.1", 0),
    ("131.0.3", "131.0", 1),
    ("2.47.0.windows.2", "2.47.0.windows.1", 1),
    ("8.7.1", "8.7.1", 0),
])
def test_compare_versions(a, b, expected):
    assert compare_versions(a, b) == expected


def test_version_helpers():
    assert max_version(["1.9", "1.10", "1.2"]) == "1.10"
    assert sort_versions(["1", "3", "2"]) == ["3", "2", "1"]
    assert is_newer("2.0", None)
    assert not is_newer("1.0", "1.0.0")
    p = version_parts("24.08.1")
    assert p["version_nodots"] == "24081" and p["major"] == "24" and p["minor"] == "08"


# ---------------------------------------------------------------- installers
def test_msi_commands():
    c = build_commands(filename="app.msi", installer_type="msi", product_code="{ABC}",
                       extra_args="ALLUSERS=1")
    assert c.install_command == 'msiexec.exe /i "app.msi" /qn /norestart ALLUSERS=1'
    assert c.install_executable == "msiexec.exe"
    assert c.uninstall_command == "msiexec.exe /x {ABC} /qn /norestart"


def test_nsis_commands_use_registry_uninstall():
    c = build_commands(filename="setup.exe", installer_type="nullsoft", display_name_regex="^Tool")
    assert c.install_command == '"setup.exe" /S'
    assert c.install_executable == "setup.exe" and c.install_arguments == "/S"
    assert c.uninstall_executable == "powershell.exe"
    assert "'^Tool'" in c.uninstall_command and "'/S'" in c.uninstall_command
    assert len(c.uninstall_command) < 1024  # Intune command line limit


def test_custom_args_and_uninstall_override():
    c = build_commands(filename="x.exe", installer_type="inno", install_args="/SILENT",
                       uninstall_command='"C:\\Program Files\\X\\unins000.exe" /SILENT',
                       display_name_regex="^X")
    assert c.install_command == '"x.exe" /SILENT'
    assert c.uninstall_executable == "C:\\Program Files\\X\\unins000.exe"
    assert c.uninstall_arguments == "/SILENT"


def test_split_command():
    assert split_command('"C:\\a b\\x.exe" /S') == ("C:\\a b\\x.exe", "/S")
    assert split_command("msiexec.exe /x {A} /qn") == ("msiexec.exe", "/x {A} /qn")


def test_guess_installer_type(tmp_path):
    f = tmp_path / "a.exe"
    f.write_bytes(b"MZ....Inno Setup Setup Data....")
    assert guess_installer_type(f) == "inno"
    f.write_bytes(b"MZ....Nullsoft Install System")
    assert guess_installer_type(f) == "nullsoft"
    assert guess_installer_type(tmp_path / "b.msi") == "msi"


# ---------------------------------------------------------------- intunewin
def test_intunewin_roundtrip(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    (src / "setup.exe").write_bytes(b"installer-bytes" * 5000)
    out = create_intunewin_native(src, "setup.exe", tmp_path / "out" / "pkg.intunewin")

    with zipfile.ZipFile(out) as zf:
        names = zf.namelist()
        assert names == ["IntuneWinPackage/Contents/IntunePackage.intunewin",
                         "IntuneWinPackage/Metadata/Detection.xml"]
        assert all(i.compress_type == zipfile.ZIP_STORED for i in zf.infolist())

    xml, content = read_intunewin(out)
    assert "<SetupFile>setup.exe</SetupFile>" in xml
    assert "<ProfileIdentifier>ProfileVersion1</ProfileIdentifier>" in xml
    with zipfile.ZipFile(io.BytesIO(content)) as inner:
        assert inner.read("setup.exe") == b"installer-bytes" * 5000
    # Keys are 256 bit, IV 128 bit
    import re
    key = re.search(r"<EncryptionKey>(.+?)</EncryptionKey>", xml).group(1)
    iv = re.search(r"<InitializationVector>(.+?)</InitializationVector>", xml).group(1)
    assert len(base64.b64decode(key)) == 32 and len(base64.b64decode(iv)) == 16


def test_intunewin_msi_info(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    (src / "app.msi").write_bytes(b"x")
    out = create_intunewin_native(src, "app.msi", tmp_path / "p.intunewin",
                                  msi_info={"ProductCode": "{1}", "ProductVersion": "1.0",
                                            "ProductName": "App", "ALLUSERS": "1"})
    xml, _ = read_intunewin(out)
    assert "<MsiProductCode>{1}</MsiProductCode>" in xml
    assert "<MsiExecutionContext>System</MsiExecutionContext>" in xml
    assert "<Name>App</Name>" in xml


# ---------------------------------------------------------------- msi / manifests
def test_msi_stream_name_decoding():
    from .msi_fixture import encode_table_name
    assert decode_stream_name(encode_table_name("Property")) == "!Property"
    assert decode_stream_name(encode_table_name("_StringPool")) == "!_StringPool"


def test_read_msi_properties(tmp_path):
    from appdepot_server.msi import msi_summary
    from .msi_fixture import build_msi
    props = {"ProductCode": "{11111111-2222-3333-4444-555555555555}", "ProductVersion": "5.4.3",
             "ProductName": "Contoso Tool", "Manufacturer": "Contoso \u00e9", "UpgradeCode": "{AAAA}",
             "ALLUSERS": "1"}
    f = tmp_path / "x.msi"
    f.write_bytes(build_msi(props))
    assert msi_summary(f) == props


def test_manifest_validation():
    ok = validate_manifest({"id": "Notepad++.Notepad++", "name": "Notepad++",
                            "source": {"type": "winget", "package": "Notepad++.Notepad++"}})
    assert ok["id"] == "Notepad++.Notepad++"
    with pytest.raises(ManifestError, match="source"):
        validate_manifest({"id": "a.b", "name": "x", "source": {"type": "nope"}})
    with pytest.raises(ManifestError, match="schedule"):
        validate_manifest({"id": "a.b", "name": "x", "schedule": "not a cron",
                           "source": {"type": "winget", "package": "a.b"}})
    with pytest.raises(ManifestError, match="install_args"):
        validate_manifest({"id": "a.b", "name": "x", "installer": {"type": "exe"},
                           "source": {"type": "winget", "package": "a.b"}})


def test_example_manifests_are_valid():
    from appdepot_server.manifest import load_manifest_file
    files = sorted((Path(__file__).parent.parent / "manifests").glob("*.yaml"))
    assert files
    for f in files:
        load_manifest_file(f)


def test_shared_version_cases():
    """The same cases are checked by the PowerShell client tests (Compare-DepotVersion)."""
    import json
    cases = json.loads((Path(__file__).parents[2] / "tests" / "version-cases.json").read_text())
    assert len(cases) > 300
    for c in cases:
        assert compare_versions(c["a"], c["b"]) == c["expected"], c
