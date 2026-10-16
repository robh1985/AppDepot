"""Adding applications: winget search, manifest generation, preview, save and remove."""

import sqlite3

import pytest
import yaml
from fastapi.testclient import TestClient

from appdepot_server import onboarding
from appdepot_server.api import create_app
from appdepot_server.onboarding import detection_regex, guess_category, search_index_db

from .conftest import WEB_APP, publish_web_version, write_manifest
from .msi_fixture import build_msi

ADMIN = {"X-Api-Key": "secret"}
GH = r"api\.github\.com/repos/microsoft/winget-pkgs/contents/manifests/c/Contoso/Viewer$"
RAW = r"raw\.githubusercontent\.com/microsoft/winget-pkgs/master/manifests/c/Contoso/Viewer/3\.2\.1/"


@pytest.fixture
def winget(web, monkeypatch):
    """A fake winget package Contoso.Viewer 3.2.1 with an x64 MSI and EXE."""
    monkeypatch.setattr(onboarding, "make_client", web.client)
    web.add(GH, [{"name": "3.1.0", "type": "dir"}, {"name": "3.2.1", "type": "dir"}])
    web.add(RAW + r"Contoso\.Viewer\.yaml$", "PackageIdentifier: Contoso.Viewer\nPackageVersion: 3.2.1\n"
                                              "DefaultLocale: en-US\nManifestType: version\n")
    web.add(RAW + r"Contoso\.Viewer\.locale\.en-US\.yaml$", """
PackageIdentifier: Contoso.Viewer
PackageVersion: 3.2.1
PackageLocale: en-US
Publisher: Contoso Ltd
PackageName: Contoso PDF Viewer
PackageUrl: https://contoso.example/viewer
License: Freeware
ShortDescription: Fast PDF document viewer.
Tags: [pdf, viewer, document]
""")
    web.add(RAW + r"Contoso\.Viewer\.installer\.yaml$", """
PackageIdentifier: Contoso.Viewer
PackageVersion: 3.2.1
AppsAndFeaturesEntries:
- DisplayName: Contoso PDF Viewer 3.2.1 (x64)
Installers:
- Architecture: x64
  InstallerType: nullsoft
  InstallerUrl: https://dl.contoso.example/viewer-3.2.1-x64.exe
- Architecture: x64
  InstallerType: wix
  InstallerUrl: https://dl.contoso.example/viewer-3.2.1-x64.msi
""")
    web.add(r"dl\.contoso\.example/viewer-3\.2\.1-x64\.msi$",
            build_msi({"ProductCode": "{B0B0B0B0-1111-2222-3333-444444444444}", "ProductVersion": "3.2.1",
                       "ProductName": "Contoso PDF Viewer", "ALLUSERS": "1"}))
    return web


# --------------------------------------------------------------------------- helpers
@pytest.mark.parametrize("display,expected", [
    ("7-Zip 24.08 (x64)", r"^7\-Zip"),
    ("Contoso PDF Viewer 3.2.1 (x64)", r"^Contoso\ PDF\ Viewer"),
    ("Google Chrome", r"^Google\ Chrome"),
    ("Notepad++ (64-bit x64)", r"^Notepad\+\+\ \(64\-bit\ x64\)"),
    ("VLC media player", r"^VLC\ media\ player"),
])
def test_detection_regex(display, expected):
    assert detection_regex(display) == expected


def test_guess_category():
    assert guess_category("Firefox", "A free web browser") == "Browsers"
    assert guess_category("Viewer", "Fast PDF document viewer") == "Office"
    assert guess_category("Thing", "", tags=["ssh"]) == "Networking"
    assert guess_category("Thing", "does stuff") == "Utilities"


def _v1_index(path):
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE ids(id TEXT); CREATE TABLE names(name TEXT); CREATE TABLE versions(version TEXT);
        CREATE TABLE monikers(moniker TEXT);
        CREATE TABLE manifest(id INT, name INT, moniker INT, version INT, channel INT, pathpart INT);
        INSERT INTO ids(rowid, id) VALUES (1,'Google.Chrome'),(2,'Mozilla.Firefox'),(3,'Google.Chrome.Beta');
        INSERT INTO names(rowid, name) VALUES (1,'Google Chrome'),(2,'Mozilla Firefox'),(3,'Google Chrome Beta');
        INSERT INTO versions(rowid, version) VALUES (1,'129.0.1'),(2,'130.0.2'),(3,'131.0');
        INSERT INTO monikers(rowid, moniker) VALUES (1,'chrome'),(2,'firefox');
        INSERT INTO manifest VALUES (1,1,1,1,0,0),(1,1,1,2,0,0),(2,2,2,3,0,0),(3,3,NULL,3,0,0);
    """)
    con.commit()
    con.close()


def test_search_index_v1(tmp_path):
    db = tmp_path / "index.db"
    _v1_index(db)
    found = {r["id"]: r["version"] for r in search_index_db(db, "chrome")}
    assert found == {"Google.Chrome": "130.0.2", "Google.Chrome.Beta": "131.0"}
    assert [r["id"] for r in search_index_db(db, "firefox")] == ["Mozilla.Firefox"]


def test_search_index_v2(tmp_path):
    db = tmp_path / "index.db"
    con = sqlite3.connect(db)
    con.executescript("""CREATE TABLE packages(id TEXT, name TEXT, moniker TEXT, latest_version TEXT);
                         INSERT INTO packages VALUES ('VideoLAN.VLC','VLC media player','vlc','3.0.21');""")
    con.commit()
    con.close()
    assert search_index_db(db, "vlc") == [{"id": "VideoLAN.VLC", "name": "VLC media player", "version": "3.0.21"}]


def test_catalog_ranks_exact_matches_first(ctx, tmp_path, monkeypatch):
    db = tmp_path / "index.db"
    _v1_index(db)
    monkeypatch.setattr(onboarding.WingetCatalog, "_index_path", lambda self: db)
    ids = [r["id"] for r in onboarding.WingetCatalog(ctx.config).search("google chrome")]
    assert ids[0] == "Google.Chrome"


# --------------------------------------------------------------------------- manifest + preview
def test_manifest_from_winget(ctx, winget):
    manifest, info = onboarding.manifest_from_winget(ctx.config, "Contoso.Viewer")
    assert manifest["name"] == "Contoso PDF Viewer"
    assert manifest["publisher"] == "Contoso Ltd"
    assert manifest["category"] == "Office"
    assert manifest["homepage"] == "https://contoso.example/viewer"
    assert manifest["source"] == {"type": "winget", "package": "Contoso.Viewer", "architecture": "x64"}
    assert manifest["detection"]["display_name"] == r"^Contoso\ PDF\ Viewer"
    assert info["winget_version"] == "3.2.1"
    assert info["msi_available"] is True
    assert set(info["installer_types"]) == {"wix", "nullsoft"}


def test_preview_selects_msi(ctx, winget):
    manifest, _ = onboarding.manifest_from_winget(ctx.config, "Contoso.Viewer")
    pv = onboarding.preview(ctx.config, manifest)
    assert pv["ok"] and pv["msi_available"]
    assert pv["selected"]["type"] == "wix" and pv["selected"]["filename"].endswith(".msi")
    assert pv["latest_version"] == "3.2.1"
    assert "Selected MSI" in pv["note"]
    assert not any(q.method == "GET" and q.url.path.endswith((".msi", ".exe")) for q in winget.requests)


def test_unknown_winget_package(ctx, web, monkeypatch):
    monkeypatch.setattr(onboarding, "make_client", web.client)
    with pytest.raises(onboarding.OnboardingError, match="not found"):
        onboarding.manifest_from_winget(ctx.config, "Nobody.Nothing")


# --------------------------------------------------------------------------- API
def test_api_add_from_winget_end_to_end(ctx, winget):
    client = TestClient(create_app(ctx, start_scheduler=False))
    r = client.get("/api/v1/winget/packages/Contoso.Viewer", headers=ADMIN)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["preview"]["msi_available"] and not body["in_repository"]

    manifest = body["manifest"] | {"category": "Office"}
    r = client.post("/api/v1/apps", json=manifest, headers=ADMIN)
    assert r.status_code == 201, r.text
    path = ctx.config.manifests_dir / "Contoso.Viewer.yaml"
    assert r.json()["manifest_path"] == str(path.resolve())
    assert yaml.safe_load(path.read_text())["source"]["package"] == "Contoso.Viewer"

    # duplicate -> 409, replace -> ok
    assert client.post("/api/v1/apps", json=manifest, headers=ADMIN).status_code == 409
    assert client.post("/api/v1/apps", json=manifest | {"description": "x"}, params={"replace": True},
                       headers=ADMIN).status_code == 201

    # the saved application downloads the MSI
    res = ctx.updater.check_app("Contoso.Viewer")
    assert res.status == "updated", res.message
    v = client.get("/api/v1/apps/Contoso.Viewer/versions/latest").json()
    assert v["installer_type"] == "wix" and v["install"]["executable"] == "msiexec.exe"

    # a sync of the manifests folder changes nothing
    assert "Contoso.Viewer" in ctx.sync()["unchanged"]


def test_api_add_yaml_and_remove(ctx, web):
    client = TestClient(create_app(ctx, start_scheduler=False))
    text = yaml.safe_dump({**WEB_APP, "id": "Contoso.Yaml", "name": "Yaml App"})
    r = client.post("/api/v1/apps/yaml", content=text, headers=ADMIN | {"Content-Type": "application/yaml"})
    assert r.status_code == 201, r.text
    assert client.post("/api/v1/apps/yaml", content="- not a mapping", headers=ADMIN).status_code == 422
    assert client.post("/api/v1/apps", json={"id": "bad id"}, headers=ADMIN).status_code == 422

    r = client.delete("/api/v1/apps/Contoso.Yaml", headers=ADMIN)
    assert r.status_code == 200
    assert r.json()["manifest_retired_to"].endswith("Contoso.Yaml.yaml.removed")
    ctx.sync()
    assert client.get("/api/v1/apps/Contoso.Yaml").status_code == 404   # not re-added by sync


def test_api_preview_existing_and_templates(ctx, web):
    write_manifest(ctx, WEB_APP)
    ctx.sync()
    publish_web_version(web, "9.9")
    client = TestClient(create_app(ctx, start_scheduler=False))
    pv = client.post("/api/v1/apps/Contoso.Tool/preview", headers=ADMIN).json()
    assert pv["latest_version"] == "9.9" and pv["msi_available"] is False
    assert "No MSI available" in pv["note"]
    t = client.get("/api/v1/templates/multi", headers=ADMIN).json()
    assert "sources:" in t["yaml"]
    assert client.get("/api/v1/winget/search", params={"q": "chrome"}).status_code == 401


def test_api_winget_search(ctx, tmp_path, monkeypatch):
    db = tmp_path / "index.db"
    _v1_index(db)
    monkeypatch.setattr(onboarding.WingetCatalog, "_index_path", lambda self: db)
    write_manifest(ctx, {**WEB_APP, "id": "Mozilla.Firefox", "name": "Firefox"})
    ctx.sync()
    client = TestClient(create_app(ctx, start_scheduler=False))
    res = client.get("/api/v1/winget/search", params={"q": "firefox"}, headers=ADMIN).json()
    assert res == [{"id": "Mozilla.Firefox", "name": "Mozilla Firefox", "version": "131.0", "in_repository": True}]


def test_search_unavailable_gives_helpful_error(ctx, monkeypatch):
    def boom(self):
        raise onboarding.OnboardingError("offline")
    monkeypatch.setattr(onboarding.WingetCatalog, "_index_path", boom)
    with pytest.raises(onboarding.OnboardingError, match="exact winget id"):
        onboarding.WingetCatalog(ctx.config).search("chrome")


def test_preview_ignores_installers_that_do_not_exist(ctx, web):
    web.add(r"vendor\.example/download$", "<p>Version 5.0.1</p>")
    web.add(r"vendor\.example/tool-5\.0\.1\.exe$", b"MZ Inno Setup")     # the .msi guess is a 404
    manifest = {"id": "Contoso.Tool", "name": "Contoso Tool", "installer": {"type": "inno"},
                "source": {"type": "web", "url": "https://vendor.example/download",
                           "version_regex": r"Version (?P<version>[\d.]+)",
                           "download_url": ["https://vendor.example/tool-{version}.msi",
                                            "https://vendor.example/tool-{version}.exe"]}}
    pv = onboarding.preview(ctx.config, manifest)
    assert pv["selected"]["type"] == "inno" and pv["msi_available"] is False
    assert any("not available: https://vendor.example/tool-5.0.1.msi" in e for e in pv["errors"])
    assert not any(q.method == "GET" and q.url.path.endswith(".exe") for q in web.requests)
