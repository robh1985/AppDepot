"""Adding the bundled application catalog (server/manifests) to an installation."""

from pathlib import Path

from fastapi.testclient import TestClient

from appdepot_server import cli
from appdepot_server.api import create_app
from appdepot_server.onboarding import add_catalog, bundled_manifest_dir

BUNDLED = sorted(bundled_manifest_dir().glob("*.yaml"))


def test_bundled_folder_is_found():
    assert len(BUNDLED) >= 53
    assert (bundled_manifest_dir() / "7zip.7zip.yaml").exists()


def test_adds_every_bundled_app(ctx):
    res = add_catalog(ctx.config, ctx.db)
    assert res["errors"] == []
    assert len(res["added"]) == len(BUNDLED)
    assert len(list(ctx.config.manifests_dir.glob("*.yaml"))) == len(BUNDLED)
    with ctx.db.session() as s:
        app = ctx.db.get_app(s, "Microsoft.VCRedist.2015+.x64")
        assert app is not None and app.manifest_path.startswith(str(ctx.config.manifests_dir.resolve()))
    # running it again changes nothing, and a normal sync agrees
    again = add_catalog(ctx.config, ctx.db)
    assert again["added"] == [] and len(again["unchanged"]) == len(BUNDLED)
    assert ctx.sync()["errors"] == []


def test_local_changes_and_removals_are_respected(ctx):
    add_catalog(ctx.config, ctx.db, ids=["7zip.7zip", "VideoLAN.VLC", "PuTTY.PuTTY"])
    mdir = ctx.config.manifests_dir
    edited = mdir / "7zip.7zip.yaml"
    edited.write_text(edited.read_text(encoding="utf-8").replace("name: 7-Zip", "name: 7-Zip (ours)"),
                      encoding="utf-8")
    (mdir / "VideoLAN.VLC.yaml").rename(mdir / "VideoLAN.VLC.yaml.removed")

    res = add_catalog(ctx.config, ctx.db)
    assert "7zip.7zip" in res["kept"] and "VideoLAN.VLC" in res["skipped_removed"]
    assert "PuTTY.PuTTY" in res["unchanged"]
    assert "(ours)" in edited.read_text(encoding="utf-8")

    res = add_catalog(ctx.config, ctx.db, overwrite=True, dry_run=True)
    assert "7zip.7zip" in res["updated"] and "(ours)" in edited.read_text(encoding="utf-8")

    res = add_catalog(ctx.config, ctx.db, overwrite=True)
    assert "7zip.7zip" in res["updated"]
    assert "(ours)" not in edited.read_text(encoding="utf-8")
    assert "(ours)" in (mdir / "7zip.7zip.yaml.bak").read_text(encoding="utf-8")

    # naming a removed application brings it back
    res = add_catalog(ctx.config, ctx.db, ids=["VideoLAN.VLC", "No.Such.App"])
    assert res["added"] == ["VideoLAN.VLC"] and res["errors"] == ["No.Such.App: not in " + str(bundled_manifest_dir())]
    assert not (mdir / "VideoLAN.VLC.yaml.removed").exists()


def test_api_requires_key_and_imports(ctx):
    client = TestClient(create_app(ctx), base_url="http://appdepot.example")
    body = {"app_ids": ["PuTTY.PuTTY", "Adobe.CreativeCloud"]}
    assert client.post("/api/v1/catalog/bundled", json=body).status_code in (401, 403)
    r = client.post("/api/v1/catalog/bundled", json=body, headers={"X-Api-Key": "secret"})
    assert r.status_code == 200, r.text
    assert sorted(r.json()["added"]) == ["Adobe.CreativeCloud", "PuTTY.PuTTY"]
    apps = client.get("/api/v1/apps", params={"include_empty": True}).json()
    assert {"PuTTY.PuTTY", "Adobe.CreativeCloud"} <= {a["id"] for a in apps}


def test_cli_dry_run(ctx, capsys, monkeypatch, tmp_path):
    monkeypatch.setattr(cli, "build_context", lambda config: ctx)
    monkeypatch.setattr(cli, "setup_logging", lambda config: None)
    monkeypatch.setattr(cli, "load_config", lambda path: ctx.config)
    assert cli.main(["app", "add-catalog", "--dry-run"]) == 0
    out = capsys.readouterr().out
    assert f"Added ({len(BUNDLED)})" in out and "Dry run" in out
    assert not list(Path(ctx.config.manifests_dir).glob("*.yaml"))


def test_api_check_queues_downloadable_apps_only(ctx, monkeypatch):
    queued = []
    monkeypatch.setattr(ctx.scheduler, "run_in_background", lambda ids, **kw: queued.extend(ids))
    client = TestClient(create_app(ctx), base_url="http://appdepot.example")
    r = client.post("/api/v1/catalog/bundled", headers={"X-Api-Key": "secret"},
                    json={"app_ids": ["Zoom.Zoom", "Adobe.CreativeCloud"], "check": True})
    assert r.status_code == 200, r.text
    assert r.json()["queued"] == ["Zoom.Zoom"] == queued      # manual apps are uploaded, not downloaded
