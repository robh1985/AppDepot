import hashlib

from fastapi.testclient import TestClient
from sqlalchemy import select

from appdepot_server.api import create_app
from appdepot_server.db import Application, AppVersion
from appdepot_server.intunewin import read_intunewin

from .conftest import WEB_APP, publish_web_version, write_manifest


def setup_app(ctx, **overrides):
    manifest = {**WEB_APP, **overrides}
    write_manifest(ctx, manifest)
    res = ctx.sync()
    assert res["errors"] == []
    return manifest["id"]


def test_full_update_cycle(ctx, web):
    app_id = setup_app(ctx)
    payload = publish_web_version(web, "1.0.0")

    r = ctx.updater.check_app(app_id)
    assert r.status == "updated", r.message
    assert r.version == "1.0.0"

    with ctx.db.session() as s:
        app = ctx.db.get_app(s, app_id)
        assert app.latest_version == "1.0.0"
        assert app.last_check_status == "updated"
        v = app.versions[0]
        assert v.is_latest and v.status == "available"
        assert v.sha256 == hashlib.sha256(payload).hexdigest()
        assert v.unc_path == r"\\depot\AppDepot\Contoso.Tool\1.0.0\installer\tool-1.0.0.exe"
        assert v.install_command == '"tool-1.0.0.exe" /S'
        assert v.intune_status == "ok", v.intune_error
        root = ctx.repo.root
        assert (root / v.relative_path).read_bytes() == payload
        pkg = root / v.intunewin_relative_path
        info = (root / v.intune_info_relative_path).read_text()
        detect = (root / v.intune_detection_relative_path).read_text(encoding="utf-8-sig")
        assert (root / "Contoso.Tool" / "1.0.0" / "metadata.json").exists()

    xml, _ = read_intunewin(pkg)
    assert "<SetupFile>tool-1.0.0.exe</SetupFile>" in xml
    assert '"tool-1.0.0.exe" /S' in info and "Uninstall command" in info
    assert "$RequiredVersion = '1.0.0'" in detect

    # Same version again -> up to date, no new download
    assert ctx.updater.check_app(app_id).status == "up_to_date"


def test_retention_keeps_last_three(ctx, web):
    app_id = setup_app(ctx)
    for ver in ["1.0", "1.1", "1.2", "1.10"]:
        publish_web_version(web, ver)
        assert ctx.updater.check_app(app_id).status == "updated"

    with ctx.db.session() as s:
        app = ctx.db.get_app(s, app_id)
        available = sorted(v.version for v in app.versions if v.status == "available")
        purged = [v.version for v in app.versions if v.status == "purged"]
        assert available == ["1.1", "1.10", "1.2"]
        assert purged == ["1.0"]
        assert app.latest_version == "1.10"
    assert not (ctx.repo.root / "Contoso.Tool" / "1.0").exists()
    assert (ctx.repo.root / "Contoso.Tool" / "1.10").exists()


def test_per_app_retention_override(ctx, web):
    app_id = setup_app(ctx, retain_versions=1)
    for ver in ["1.0", "2.0"]:
        publish_web_version(web, ver)
        ctx.updater.check_app(app_id)
    with ctx.db.session() as s:
        app = ctx.db.get_app(s, app_id)
        assert [v.version for v in app.versions if v.status == "available"] == ["2.0"]


def test_failure_is_recorded(ctx, web):
    app_id = setup_app(ctx)
    web.add(r"contoso\.example/download$", "<p>nothing here</p>")
    r = ctx.updater.check_app(app_id)
    assert r.status == "failed"
    with ctx.db.session() as s:
        app = ctx.db.get_app(s, app_id)
        assert app.last_check_status == "failed"
        assert "version_regex did not match" in app.last_error


def test_hash_mismatch_rejected(ctx, web, monkeypatch):
    from appdepot_server.sources.web import WebSource
    from appdepot_server.sources.base import ReleaseInfo

    app_id = setup_app(ctx)
    publish_web_version(web, "3.0")
    monkeypatch.setattr(WebSource, "resolve", lambda self, c: ReleaseInfo(
        version="3.0", url="https://contoso.example/files/tool-3.0.exe", sha256="00" * 32))
    r = ctx.updater.check_app(app_id)
    assert r.status == "failed" and "SHA-256 mismatch" in r.message
    assert not list((ctx.repo.root / ".tmp").iterdir())


def test_api(ctx, web):
    app_id = setup_app(ctx)
    publish_web_version(web, "1.0")
    ctx.updater.check_app(app_id)
    publish_web_version(web, "1.1")
    ctx.updater.check_app(app_id)

    client = TestClient(create_app(ctx, start_scheduler=False))
    apps = client.get("/api/v1/apps").json()
    assert [a["id"] for a in apps] == ["Contoso.Tool"]
    assert apps[0]["versions"] == ["1.1", "1.0"]
    assert apps[0]["detection"]["display_name"] == "^Contoso Tool"

    assert client.get("/api/v1/apps", params={"search": "nomatch"}).json() == []

    latest = client.get("/api/v1/apps/contoso.tool/versions/latest").json()
    assert latest["version"] == "1.1"
    assert latest["location"]["unc"].startswith("\\\\depot\\AppDepot\\")
    assert latest["location"]["http"] == "http://depot:8080/files/Contoso.Tool/1.1/installer/tool-1.1.exe"
    assert latest["install"]["arguments"] == "/S"
    assert latest["intune"]["status"] == "ok"

    f = client.get("/files/Contoso.Tool/1.1/installer/tool-1.1.exe")
    assert f.status_code == 200 and f.content.startswith(b"MZ")
    assert client.get("/files/../test.db").status_code == 404

    upd = client.post("/api/v1/updates", json={"installed": [{"id": "Contoso.Tool", "version": "1.0"}]}).json()
    assert upd[0]["update_available"] is True and upd[0]["latest_version"] == "1.1"

    # admin endpoints need the key
    assert client.put("/api/v1/schedule", json={"schedule": "0 4 * * *"}).status_code == 401
    hdr = {"X-Api-Key": "secret"}
    assert client.put("/api/v1/schedule", json={"schedule": "bad"}, headers=hdr).status_code == 422
    r = client.put("/api/v1/schedule", json={"schedule": "0 4 * * *"}, headers=hdr)
    assert r.status_code == 200 and r.json()["global"] == "0 4 * * *"
    r = client.put(f"/api/v1/apps/{app_id}/schedule", json={"schedule": "*/30 * * * *"}, headers=hdr)
    assert r.status_code == 200
    jobs = {j["id"] for j in client.get("/api/v1/schedule").json()["jobs"]}
    assert jobs == {"global", "app:Contoso.Tool"}

    r = client.post(f"/api/v1/apps/{app_id}/check", params={"wait": True}, headers=hdr)
    assert r.json()["status"] == "up_to_date"

    events = client.get("/api/v1/events", params={"app_id": app_id}).json()
    assert any(e["event"] == "update" for e in events)

    assert client.get("/").status_code == 200

    # add an app through the API
    new = {**WEB_APP, "id": "Contoso.Other", "name": "Other"}
    assert client.post("/api/v1/apps", json=new, headers=hdr).status_code == 201
    bad = {**WEB_APP, "id": "x y"}
    assert client.post("/api/v1/apps", json=bad, headers=hdr).status_code == 422


def test_schedule_override_survives_manifest_sync(ctx):
    app_id = setup_app(ctx)
    ctx.scheduler.set_app_schedule(app_id, "manual")
    write_manifest(ctx, {**WEB_APP, "description": "changed"})
    ctx.sync()
    with ctx.db.session() as s:
        app = ctx.db.get_app(s, app_id)
        assert app.description == "changed"
        assert app.effective_schedule == "manual"
    assert ctx.updater.enabled_app_ids(only_global_schedule=True) == []


def test_url_source_reads_version_from_msi(ctx, web):
    from .msi_fixture import build_msi

    msi = build_msi({"ProductCode": "{0F0F0F0F-1111-2222-3333-444444444444}", "ProductVersion": "7.2.1",
                     "ProductName": "Contoso Agent", "Manufacturer": "Contoso", "UpgradeCode": "{U}",
                     "ALLUSERS": "1"})
    web.add(r"contoso\.example/agent\.msi$", msi, headers={"etag": '"abc"'})
    write_manifest(ctx, {"id": "Contoso.Agent", "name": "Contoso Agent",
                         "source": {"type": "url", "url": "https://contoso.example/agent.msi",
                                    "version_from": "msi"}})
    ctx.sync()

    r = ctx.updater.check_app("Contoso.Agent")
    assert (r.status, r.version) == ("updated", "7.2.1"), r.message
    with ctx.db.session() as s:
        v = ctx.db.get_app(s, "Contoso.Agent").versions[0]
        assert v.installer_type == "msi"
        assert v.install_command == 'msiexec.exe /i "agent.msi" /qn /norestart'
        assert v.uninstall_command == "msiexec.exe /x {0F0F0F0F-1111-2222-3333-444444444444} /qn /norestart"
        pkg = ctx.repo.root / v.intunewin_relative_path
        info = (ctx.repo.root / v.intune_info_relative_path).read_text()
    xml, _ = read_intunewin(pkg)
    assert "<MsiProductCode>{0F0F0F0F-1111-2222-3333-444444444444}</MsiProductCode>" in xml
    assert "<Name>Contoso Agent</Name>" in xml
    assert "MSI product code" in info

    # Same ETag on the next check -> nothing downloaded
    gets_before = sum(1 for q in web.requests if q.method == "GET")
    assert ctx.updater.check_app("Contoso.Agent").status == "up_to_date"
    assert sum(1 for q in web.requests if q.method == "GET") == gets_before


def test_global_run_skips_apps_with_own_schedule(ctx, web):
    setup_app(ctx)
    write_manifest(ctx, {**WEB_APP, "id": "Contoso.Hourly", "name": "Hourly", "schedule": "0 * * * *"})
    ctx.sync()
    publish_web_version(web, "1.0")

    ctx.scheduler._run_global()

    with ctx.db.session() as s:
        assert ctx.db.get_app(s, "Contoso.Tool").latest_version == "1.0"
        assert ctx.db.get_app(s, "Contoso.Hourly").last_checked_at is None
    jobs = {j["id"] for j in ctx.scheduler.jobs()}
    assert jobs == {"global", "app:Contoso.Hourly"}
