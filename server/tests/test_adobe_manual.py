"""Adobe Acrobat/Reader source, archives, MSP patches and manually uploaded applications."""

import io
import zipfile

import yaml
from fastapi.testclient import TestClient

from appdepot_server.api import create_app
from appdepot_server.intunewin import read_intunewin
from appdepot_server.onboarding import save_application

from .conftest import write_manifest
from .msi_fixture import build_msi

ADMIN = {"X-Api-Key": "secret"}
PRODUCTS = r"rdc\.adobe\.io/reader/products"
INDEX = r"www\.adobe\.com/devnet-docs/acrobatetk/tools/ReleaseNotesDC/index\.html$"
DETECT = {"display_name": "^Adobe Acrobat", "key_pattern": r"^\{AC76BA86-"}


def products(web, *versions):
    web.add(PRODUCTS, {"products": {"reader": [{"displayName": "Reader", "version": v} for v in versions],
                                    "dcPro": []}})


def stored(ctx, app_id):
    with ctx.db.session() as s:
        app = ctx.db.get_app(s, app_id)
        return {v.version: v for v in app.versions if v.status == "available"}


def events(ctx, app_id):
    from sqlalchemy import select
    from appdepot_server.db import Event
    with ctx.db.session() as s:
        return [e.message for e in s.scalars(select(Event).where(Event.app_id == app_id))]


# --------------------------------------------------------------------------- MSP updates
def test_reader_update_patch(ctx, web):
    products(web, "26.002.21931", "25.001.20531")
    # ardownload3 is unavailable, ardownload2 has the file
    web.add(r"ardownload2\.adobe\.com/pub/adobe/acrobat/win/AcrobatDC/2600221931/AcroRdrDCx64Upd2600221931_MUI\.msp$",
            b"MSP-PATCH" * 1000)
    write_manifest(ctx, {"id": "Adobe.Reader.Update", "name": "Adobe Acrobat Reader (64-bit) - update",
                         "source": {"type": "adobe", "product": "reader", "package": "update",
                                    "architecture": "x64", "language": "MUI"},
                         "installer": {"type": "msp", "signer": "Adobe"}, "detection": DETECT})
    ctx.sync()
    r = ctx.updater.check_app("Adobe.Reader.Update")
    assert r.status == "updated", r.message
    v = stored(ctx, "Adobe.Reader.Update")["26.002.21931"]
    assert v.installer_type == "msp"
    assert v.install_command == 'msiexec.exe /p "AcroRdrDCx64Upd2600221931_MUI.msp" /qn /norestart'
    assert v.uninstall_command is None
    assert "ardownload2" in v.source_url
    info = (ctx.repo.root / v.intune_info_relative_path).read_text()
    assert "a patch cannot be removed on its own" in info
    detect = (ctx.repo.root / v.intune_detection_relative_path).read_text(encoding="utf-8-sig")
    assert "$KeyPattern = '^\\{AC76BA86-'" in detect
    msgs = events(ctx, "Adobe.Reader.Update")
    assert any("Download failed, trying next candidate" in m for m in msgs)       # ardownload3 404
    assert any("signature not verified" in m for m in msgs)                       # non-Windows test host
    assert ctx.updater.check_app("Adobe.Reader.Update").status == "up_to_date"


def test_acrobat_update_file_name_and_index_fallback(ctx, web):
    web.add(PRODUCTS, b"", status=503)                          # products service down
    web.add(INDEX, '<a href="continuous/dccontinuousmar2026.html#x">26.001.21345 Planned update</a>'
                   '<a href="continuous/dccontinuousjan2026.html">25.001.20999 Planned update</a>')
    web.add(r"ardownload3\.adobe\.com/pub/adobe/acrobat/win/AcrobatDC/2600121345/AcrobatDCx64Upd2600121345\.msp$",
            b"MSP" * 500)
    write_manifest(ctx, {"id": "Adobe.Pro.Update", "name": "Acrobat Pro update",
                         "source": {"type": "adobe", "product": "acrobat"}, "detection": DETECT})
    ctx.sync()
    r = ctx.updater.check_app("Adobe.Pro.Update")
    assert r.status == "updated" and r.version == "26.001.21345", r.message
    assert stored(ctx, "Adobe.Pro.Update")["26.001.21345"].release_notes_url.endswith("dccontinuousmar2026.html")


# --------------------------------------------------------------------------- full installers
def test_reader_installer_falls_back_to_previous_release(ctx, web):
    products(web, "26.002.21931")
    web.add(INDEX, '<a href="continuous/a.html">26.002.21931 Out of cycle</a>'
                   '<a href="continuous/b.html">25.001.20531 Planned update</a>')
    # No full installer for the out-of-cycle release; the previous one exists
    web.add(r"ardownload3\.adobe\.com/pub/adobe/acrobat/win/AcrobatDC/2500120531/AcroRdrDCx64_?2500120531_MUI\.exe$",
            b"MZ Adobe Reader installer" * 300)
    write_manifest(ctx, {"id": "Adobe.Reader", "name": "Adobe Acrobat Reader (64-bit)",
                         "source": {"type": "adobe", "product": "reader", "package": "installer"},
                         "installer": {"type": "exe", "install_args": "/sAll /rs /msi EULA_ACCEPT=YES",
                                       "update_with": "Adobe.Reader.Update"},
                         "detection": DETECT})
    ctx.sync()
    r = ctx.updater.check_app("Adobe.Reader")
    assert r.status == "updated" and r.version == "25.001.20531", r.message
    v = stored(ctx, "Adobe.Reader")["25.001.20531"]
    assert v.filename == "AcroRdrDCx642500120531_MUI.exe"
    assert v.install_command == '"AcroRdrDCx642500120531_MUI.exe" /sAll /rs /msi EULA_ACCEPT=YES'
    # next check: still no file for 26.002 -> up to date, not failed
    r = ctx.updater.check_app("Adobe.Reader")
    assert r.status == "up_to_date" and "newer files unavailable" in r.message

    client = TestClient(create_app(ctx, start_scheduler=False))
    app = client.get("/api/v1/apps/Adobe.Reader").json()
    assert app["update_with"] == "Adobe.Reader.Update" and app["is_patch"] is False
    assert app["detection"]["key_pattern"] == r"^\{AC76BA86-"


def _acrobat_zip(version: str) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("Adobe Acrobat/setup.exe", b"MZ Adobe setup")
        zf.writestr("Adobe Acrobat/AcroPro.msi", build_msi({
            "ProductCode": "{AC76BA86-1033-FFFF-7760-BC15014EA700}", "ProductVersion": version,
            "ProductName": "Adobe Acrobat (64-bit)", "ALLUSERS": "1"}))
        zf.writestr("Adobe Acrobat/Transforms/1033.mst", b"mst")
    return buf.getvalue()


def test_acrobat_installer_zip(ctx, web):
    web.add(r"trials\.adobe\.com/.+/Acrobat_DC_Web_x64_WWMUI\.zip$", _acrobat_zip("24.001.20604"),
            headers={"etag": '"zip-1"'})
    write_manifest(ctx, {"id": "Adobe.Pro", "name": "Adobe Acrobat Pro (64-bit)",
                         "source": {"type": "adobe", "product": "acrobat", "package": "installer"},
                         "installer": {"type": "exe", "setup_file": "setup.exe",
                                       "install_args": "/sAll /rs /rps /msi EULA_ACCEPT=YES"},
                         "detection": DETECT})
    ctx.sync()
    r = ctx.updater.check_app("Adobe.Pro")
    assert r.status == "updated" and r.version == "24.001.20604", r.message
    v = stored(ctx, "Adobe.Pro")["24.001.20604"]
    assert v.filename == "Acrobat_DC_Web_x64_WWMUI.zip"
    assert v.setup_path == "Adobe Acrobat/setup.exe"
    assert v.install_command == '"setup.exe" /sAll /rs /rps /msi EULA_ACCEPT=YES'
    assert v.product_code == "{AC76BA86-1033-FFFF-7760-BC15014EA700}"
    xml, content = read_intunewin(ctx.repo.root / v.intunewin_relative_path)
    assert "<SetupFile>setup.exe</SetupFile>" in xml
    with zipfile.ZipFile(io.BytesIO(content)) as inner:
        assert {"setup.exe", "AcroPro.msi", "Transforms/1033.mst"} <= set(inner.namelist())
    # unchanged ETag -> no new download
    gets = sum(1 for q in web.requests if q.method == "GET" and q.url.path.endswith(".zip"))
    assert ctx.updater.check_app("Adobe.Pro").status == "up_to_date"
    assert sum(1 for q in web.requests if q.method == "GET" and q.url.path.endswith(".zip")) == gets
    # repackaging re-extracts the archive
    assert ctx.updater.repackage("Adobe.Pro", "24.001.20604")["intune_status"] == "ok"


def test_archive_without_setup_file_is_rejected(ctx, web):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("readme.txt", "no installer here")
    web.add(r"vendor\.example/tool-1\.0\.zip$", buf.getvalue())
    write_manifest(ctx, {"id": "Contoso.Zip", "name": "Zip",
                         "source": {"type": "url", "url": "https://vendor.example/tool-1.0.zip",
                                    "version_from": "filename"},
                         "installer": {"setup_file": "setup.exe", "type": "inno"}})
    ctx.sync()
    r = ctx.updater.check_app("Contoso.Zip")
    assert r.status == "failed" and "setup.exe' was not found in the archive" in r.message


# --------------------------------------------------------------------------- manual applications
MANUAL = {"id": "Contoso.LOB", "name": "Contoso LOB", "publisher": "Contoso", "category": "Business",
          "source": {"type": "manual"}, "installer": {"type": "inno"}}


def test_manual_application_import(ctx, tmp_path):
    save_application(ctx.config, ctx.db, MANUAL)
    assert ctx.updater.check_app("Contoso.LOB").status == "skipped"
    assert "Contoso.LOB" not in ctx.updater.enabled_app_ids()

    exe = tmp_path / "LOB-Setup.exe"
    exe.write_bytes(b"MZ Inno Setup " + b"z" * 100)
    try:
        ctx.updater.import_installer("Contoso.LOB", exe)
        raise AssertionError("expected a version error")
    except ValueError as exc:
        assert "version is required" in str(exc)

    r = ctx.updater.import_installer("Contoso.LOB", exe, version="1.4.0")
    assert r.status == "updated"
    v = stored(ctx, "Contoso.LOB")["1.4.0"]
    assert v.installer_type == "inno" and v.source_type == "manual"
    assert v.install_command.startswith('"LOB-Setup.exe" /VERYSILENT')
    assert v.intune_status == "ok"

    msi = tmp_path / "lob.msi"
    msi.write_bytes(build_msi({"ProductCode": "{C0C0C0C0-1111-2222-3333-444444444444}",
                               "ProductVersion": "1.5.0", "ProductName": "Contoso LOB", "ALLUSERS": "1"}))
    r = ctx.updater.import_installer("Contoso.LOB", msi)          # version read from the MSI
    assert r.version == "1.5.0"
    assert stored(ctx, "Contoso.LOB")["1.5.0"].installer_type == "msi"   # file type wins over manifest
    try:
        ctx.updater.import_installer("Contoso.LOB", msi)
        raise AssertionError("expected duplicate error")
    except ValueError as exc:
        assert "already in the repository" in str(exc)
    assert ctx.updater.import_installer("Contoso.LOB", msi, replace=True).status == "updated"


def test_api_upload(ctx):
    client = TestClient(create_app(ctx, start_scheduler=False))
    assert client.post("/api/v1/apps", json=MANUAL, headers=ADMIN).status_code == 201
    body = b"MZ Inno Setup " + b"q" * 5000
    r = client.post("/api/v1/apps/Contoso.LOB/versions", params={"filename": "LOB-Setup.exe", "version": "2.0"},
                    content=body, headers=ADMIN | {"Content-Type": "application/octet-stream"})
    assert r.status_code == 201, r.text
    assert r.json()["version"] == "2.0"
    assert client.post("/api/v1/apps/Contoso.LOB/versions", params={"filename": "x.exe", "version": "2.0"},
                       content=body, headers=ADMIN).status_code == 409
    assert client.post("/api/v1/apps/Contoso.LOB/versions", params={"filename": "x.exe"},
                       content=body, headers=ADMIN).status_code == 422          # no version
    assert client.post("/api/v1/apps/Contoso.LOB/versions", params={"filename": "x.exe", "version": "3"},
                       content=body).status_code == 401
    app = client.get("/api/v1/apps/Contoso.LOB").json()
    assert app["manual"] is True and app["versions"] == ["2.0"]
    f = client.get("/files/Contoso.LOB/2.0/installer/LOB-Setup.exe")
    assert f.status_code == 200 and f.content == body
    manifest = yaml.safe_load((ctx.config.manifests_dir / "Contoso.LOB.yaml").read_text())
    assert manifest["source"] == {"type": "manual"}


def test_manual_cannot_mix_with_other_sources():
    import pytest
    from appdepot_server.manifest import ManifestError, validate_manifest
    with pytest.raises(ManifestError, match="manual"):
        validate_manifest({"id": "a.b", "name": "x", "sources": [{"type": "manual"},
                                                                {"type": "winget", "package": "a.b"}]})


def test_cli_create_and_import(ctx, tmp_path, monkeypatch):
    from appdepot_server import cli
    msi = tmp_path / "tool.msi"
    msi.write_bytes(build_msi({"ProductCode": "{D0D0D0D0-1111-2222-3333-444444444444}", "ProductVersion": "3.1",
                               "ProductName": "Tool", "ALLUSERS": "1"}))
    monkeypatch.setattr(cli, "build_context", lambda config: ctx)
    monkeypatch.setattr(cli, "load_config", lambda path: ctx.config)
    assert cli.main(["app", "create", "Contoso.CliTool", "--name", "CLI Tool", "--category", "Utilities",
                     "--installer", str(msi)]) == 0
    assert "3.1" in stored(ctx, "Contoso.CliTool")
    exe = tmp_path / "tool-3.2.exe"
    exe.write_bytes(b"MZ Nullsoft")
    assert cli.main(["app", "import", "Contoso.CliTool", str(exe), "--version", "3.2"]) == 0
    assert stored(ctx, "Contoso.CliTool")["3.2"].installer_type == "nullsoft"


def test_patch_target_product_codes_reach_clients(ctx, web):
    from .msi_fixture import build_msp
    reader_x64 = "{AC76BA86-1033-FF00-7760-BC15014EA700}"
    products(web, "26.002.21931")
    web.add(r"ardownload3\.adobe\.com/.+/AcroRdrDCx64Upd2600221931_MUI\.msp$", build_msp([reader_x64]))
    write_manifest(ctx, {"id": "Adobe.Reader.Update", "name": "Reader update",
                         "source": {"type": "adobe", "product": "reader"},
                         "installer": {"type": "msp"}, "detection": DETECT})
    ctx.sync()
    assert ctx.updater.check_app("Adobe.Reader.Update").status == "updated"
    v = stored(ctx, "Adobe.Reader.Update")["26.002.21931"]
    assert v.msi_info["TargetProductCodes"] == [reader_x64]
    assert reader_x64 in (ctx.repo.root / v.intune_info_relative_path).read_text()   # Intune sheet lists it
    client = TestClient(create_app(ctx, start_scheduler=False))
    app = client.get("/api/v1/apps/Adobe.Reader.Update").json()
    assert app["is_patch"] is True
    assert app["detection"]["product_codes"] == [reader_x64]
    assert app["detection"]["match_codes_only"] is True
    assert client.get("/api/v1/apps/Adobe.Reader.Update/versions/latest").json()["target_product_codes"] == [reader_x64]
