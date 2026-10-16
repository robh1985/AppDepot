"""Installer preference: MSI is chosen across all sources before any fallback."""

import sqlite3

from appdepot_server.db import Database

from .conftest import write_manifest
from .msi_fixture import build_msi

EXE = b"MZ Nullsoft fake installer " + b"x" * 2000


def msi(version: str) -> bytes:
    return build_msi({"ProductCode": "{AAAAAAAA-1111-2222-3333-444444444444}", "ProductVersion": version,
                      "ProductName": "Contoso Tool", "Manufacturer": "Contoso", "ALLUSERS": "1"})


def page(web, version):
    web.add(r"vendor\.example/download$", f"<p>Version {version}</p>")


def stored(ctx, app_id):
    with ctx.db.session() as s:
        return {v.version: (v.installer_type, v.source_type) for v in ctx.db.get_app(s, app_id).versions
                if v.status == "available"}


def events(ctx, app_id):
    from appdepot_server.db import Event
    from sqlalchemy import select
    with ctx.db.session() as s:
        return [e.message for e in s.scalars(select(Event).where(Event.app_id == app_id))]


def test_msi_from_second_source_beats_exe_from_first(ctx, web):
    page(web, "2.0")
    web.add(r"vendor\.example/tool-2\.0\.exe$", EXE)
    web.add(r"mirror\.example/api$", {"latest": "2.0"})
    web.add(r"mirror\.example/tool-2\.0\.msi$", msi("2.0"))
    write_manifest(ctx, {"id": "Contoso.Tool", "name": "Contoso Tool", "sources": [
        {"type": "web", "url": "https://vendor.example/download", "version_regex": r"Version (?P<version>[\d.]+)",
         "download_url": "https://vendor.example/tool-{version}.exe"},
        {"type": "json", "url": "https://mirror.example/api", "version_path": "latest",
         "download_url": "https://mirror.example/tool-{version}.msi"},
    ]})
    ctx.sync()
    r = ctx.updater.check_app("Contoso.Tool")
    assert r.status == "updated", r.message
    assert stored(ctx, "Contoso.Tool") == {"2.0": ("msi", "json")}
    assert any("Selected MSI from json (source 2 of 2)" in m for m in events(ctx, "Contoso.Tool"))
    # Nothing from the EXE source was downloaded
    assert not any("tool-2.0.exe" in str(q.url) and q.method == "GET" for q in web.requests)


def test_falls_back_to_exe_when_msi_download_missing(ctx, web):
    page(web, "3.1")
    web.add(r"vendor\.example/tool-3\.1\.exe$", EXE)          # the .msi URL returns 404
    write_manifest(ctx, {"id": "Contoso.Tool", "name": "Contoso Tool", "installer": {"type": "nullsoft"},
                         "source": {"type": "web", "url": "https://vendor.example/download",
                                    "version_regex": r"Version (?P<version>[\d.]+)",
                                    "download_url": ["https://vendor.example/tool-{version}.msi",
                                                     "https://vendor.example/tool-{version}.exe"]}})
    ctx.sync()
    r = ctx.updater.check_app("Contoso.Tool")
    assert r.status == "updated", r.message
    assert stored(ctx, "Contoso.Tool") == {"3.1": ("nullsoft", "web")}
    msgs = events(ctx, "Contoso.Tool")
    assert any("Download failed, trying next candidate" in m for m in msgs)
    assert any("The MSI for version 3.1 could not be downloaded; using nullsoft" in m for m in msgs)


def test_stored_exe_is_replaced_when_an_msi_appears(ctx, web):
    page(web, "4.0")
    web.add(r"vendor\.example/tool-4\.0\.exe$", EXE)
    write_manifest(ctx, {"id": "Contoso.Tool", "name": "Contoso Tool", "installer": {"type": "nullsoft"},
                         "source": {"type": "web", "url": "https://vendor.example/download",
                                    "version_regex": r"Version (?P<version>[\d.]+)",
                                    "download_url": ["https://vendor.example/tool-{version}.msi",
                                                     "https://vendor.example/tool-{version}.exe"]}})
    ctx.sync()
    assert ctx.updater.check_app("Contoso.Tool").status == "updated"
    assert stored(ctx, "Contoso.Tool") == {"4.0": ("nullsoft", "web")}

    web.add(r"vendor\.example/tool-4\.0\.msi$", msi("4.0"))    # vendor now publishes an MSI
    r = ctx.updater.check_app("Contoso.Tool")
    assert r.status == "updated", r.message
    assert stored(ctx, "Contoso.Tool") == {"4.0": ("msi", "web")}
    assert any("Replacing the stored nullsoft installer of 4.0 with the preferred msi" in m
               for m in events(ctx, "Contoso.Tool"))
    # and a third check is a no-op
    assert ctx.updater.check_app("Contoso.Tool").status == "up_to_date"


def test_newer_version_wins_over_older_msi(ctx, web):
    page(web, "5.1")
    web.add(r"vendor\.example/tool-5\.1\.exe$", EXE)
    web.add(r"mirror\.example/api$", {"latest": "5.0"})
    web.add(r"mirror\.example/tool-5\.0\.msi$", msi("5.0"))
    write_manifest(ctx, {"id": "Contoso.Tool", "name": "Contoso Tool", "installer": {"type": "nullsoft"},
                         "sources": [
        {"type": "json", "url": "https://mirror.example/api", "version_path": "latest",
         "download_url": "https://mirror.example/tool-{version}.msi"},
        {"type": "web", "url": "https://vendor.example/download", "version_regex": r"Version (?P<version>[\d.]+)",
         "download_url": "https://vendor.example/tool-{version}.exe"},
    ]})
    ctx.sync()
    assert ctx.updater.check_app("Contoso.Tool").status == "updated"
    assert stored(ctx, "Contoso.Tool") == {"5.1": ("nullsoft", "web")}


def test_failing_source_does_not_block_others(ctx, web):
    web.add(r"mirror\.example/tool-6\.0\.msi$", msi("6.0"))
    web.add(r"mirror\.example/api$", {"latest": "6.0"})
    write_manifest(ctx, {"id": "Contoso.Tool", "name": "Contoso Tool", "sources": [
        {"type": "web", "url": "https://broken.example/download", "version_regex": r"Version ([\d.]+)",
         "download_url": "https://broken.example/x.exe"},
        {"type": "json", "url": "https://mirror.example/api", "version_path": "latest",
         "download_url": "https://mirror.example/tool-{version}.msi"},
    ]})
    ctx.sync()
    r = ctx.updater.check_app("Contoso.Tool")
    assert r.status == "updated", r.message
    assert any("Source failed: source 1 (web)" in m for m in events(ctx, "Contoso.Tool"))


def test_per_app_preference_overrides_default(ctx, web):
    page(web, "7.0")
    web.add(r"vendor\.example/tool-7\.0\.exe$", EXE)
    web.add(r"vendor\.example/tool-7\.0\.msi$", msi("7.0"))
    write_manifest(ctx, {"id": "Contoso.Tool", "name": "Contoso Tool",
                         "installer": {"type": "nullsoft", "preferred_types": ["nullsoft", "msi"]},
                         "source": {"type": "web", "url": "https://vendor.example/download",
                                    "version_regex": r"Version (?P<version>[\d.]+)",
                                    "download_url": ["https://vendor.example/tool-{version}.msi",
                                                     "https://vendor.example/tool-{version}.exe"]}})
    ctx.sync()
    ctx.updater.check_app("Contoso.Tool")
    assert stored(ctx, "Contoso.Tool") == {"7.0": ("nullsoft", "web")}


def test_winget_offers_all_types_for_best_architecture():
    import yaml
    from appdepot_server.sources.winget import WingetSource
    manifest = yaml.safe_load("""
PackageVersion: '1.0'
Installers:
- {Architecture: x86, InstallerType: wix, InstallerUrl: https://x/app-x86.msi}
- {Architecture: x64, InstallerType: nullsoft, InstallerUrl: https://x/app-x64.exe}
- {Architecture: x64, InstallerType: wix, InstallerUrl: https://x/app-x64.msi}
- {Architecture: x64, InstallerType: exe, Scope: user, InstallerUrl: https://x/user.exe}
- {Architecture: x64, InstallerType: zip, InstallerUrl: https://x/app.zip}
""")
    src = WingetSource({"package": "a.b"})
    urls = [c["InstallerUrl"] for c in src.installer_candidates(manifest)]
    # x64 exists, so the x86 MSI is not offered; the per-user EXE and the ZIP are dropped
    assert urls == ["https://x/app-x64.exe", "https://x/app-x64.msi"]


def test_migration_adds_new_columns(tmp_path):
    db_path = tmp_path / "old.db"
    con = sqlite3.connect(db_path)
    con.execute("CREATE TABLE app_versions (id INTEGER PRIMARY KEY, version VARCHAR(100))")
    con.commit()
    con.close()
    db = Database(f"sqlite:///{db_path}")
    db.create_all()
    cols = {r[1] for r in sqlite3.connect(db_path).execute("PRAGMA table_info(app_versions)")}
    assert {"source_type", "sha256", "intune_status"} <= cols
