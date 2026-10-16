import json
import re

import httpx
import pytest
import yaml

from appdepot_server import updater as updater_module
from appdepot_server.config import Config, DEFAULTS, _merge
from appdepot_server.context import build_context


class FakeWeb:
    """In-memory internet: map URL regexes to responses."""

    def __init__(self):
        self.routes: list[tuple[re.Pattern, object]] = []
        self.requests: list[httpx.Request] = []

    def add(self, pattern: str, body=b"", status=200, headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            headers = {"content-type": "application/json", **(headers or {})}
        elif isinstance(body, str):
            body = body.encode()
        self.routes.insert(0, (re.compile(pattern), (status, body, headers or {})))

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        for rx, (status, body, headers) in self.routes:
            if rx.search(str(request.url)):
                return httpx.Response(status, content=body if request.method != "HEAD" else b"",
                                      headers=headers)
        return httpx.Response(404, content=b"not found")

    def client(self, *_args, **_kwargs) -> httpx.Client:
        return httpx.Client(transport=httpx.MockTransport(self.handler), follow_redirects=True)


@pytest.fixture
def web(monkeypatch):
    fake = FakeWeb()
    monkeypatch.setattr(updater_module, "make_client", fake.client)
    return fake


@pytest.fixture
def ctx(tmp_path):
    manifests = tmp_path / "manifests"
    manifests.mkdir()
    data = _merge(DEFAULTS, {
        "server": {"public_url": "http://depot:8080", "api_key": "secret"},
        "repository": {"root": str(tmp_path / "repo"), "unc_root": r"\\depot\AppDepot", "retain_versions": 3},
        "database": {"url": f"sqlite:///{tmp_path / 'test.db'}"},
        "manifests_dir": str(manifests),
        "schedule": {"max_concurrent": 2},
    })
    c = build_context(Config(data=data))
    yield c
    c.scheduler.shutdown()


def write_manifest(ctx, manifest: dict) -> None:
    path = ctx.config.manifests_dir / f"{manifest['id']}.yaml"
    path.write_text(yaml.safe_dump(manifest), encoding="utf-8")


WEB_APP = {
    "id": "Contoso.Tool",
    "name": "Contoso Tool",
    "publisher": "Contoso",
    "category": "Utilities",
    "source": {
        "type": "web",
        "url": "https://contoso.example/download",
        "version_regex": r"Version (?P<version>[\d.]+)",
        "download_url": "https://contoso.example/files/tool-{version}.exe",
    },
    "installer": {"type": "nullsoft"},
    "detection": {"display_name": "^Contoso Tool"},
}


def publish_web_version(web: FakeWeb, version: str, payload: bytes | None = None) -> bytes:
    payload = payload or (b"MZ fake installer Nullsoft " + version.encode() * 100)
    web.add(r"contoso\.example/download$", f"<h1>Contoso Tool</h1><p>Version {version}</p>")
    web.add(rf"contoso\.example/files/tool-{re.escape(version)}\.exe$", payload)
    return payload
