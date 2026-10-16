import httpx
import pytest

from appdepot_server.sources import SourceContext, get_source

from .conftest import FakeWeb

WINGET_INSTALLER = """
PackageIdentifier: 7zip.7zip
PackageVersion: 24.08
InstallerType: exe
InstallerSwitches:
  Silent: /S
Installers:
- Architecture: x86
  InstallerUrl: https://www.7-zip.org/a/7z2408.exe
  InstallerSha256: AAAA
- Architecture: x64
  InstallerUrl: https://www.7-zip.org/a/7z2408-x64.exe
  InstallerSha256: BBBB
- Architecture: x64
  InstallerType: msi
  InstallerUrl: https://www.7-zip.org/a/7z2408-x64.msi
  InstallerSha256: CCCC
  ProductCode: '{23170F69-40C1-2702-2408-000001000000}'
  InstallerSwitches:
    Custom: ALLUSERS=1
ManifestType: installer
"""


def ctx_for(web: FakeWeb, state=None) -> SourceContext:
    return SourceContext(client=web.client(), state=state or {})


def test_winget_selects_preferred_installer():
    web = FakeWeb()
    web.add(r"api\.github\.com/repos/microsoft/winget-pkgs/contents/manifests/7/7zip/7zip$", [
        {"name": "23.01", "type": "dir"}, {"name": "24.08", "type": "dir"},
        {"name": "24.07", "type": "dir"}, {"name": "Beta", "type": "dir"},
    ])
    web.add(r"raw\.githubusercontent\.com/.+/7zip/7zip/24\.08/7zip\.7zip\.installer\.yaml$", WINGET_INSTALLER)
    src = get_source("winget", {"type": "winget", "package": "7zip.7zip", "installer_type": "msi"})
    r = src.resolve(ctx_for(web))
    assert r.version == "24.08"
    assert r.url.endswith("7z2408-x64.msi")
    assert r.installer_type == "msi"
    assert r.sha256 == "cccc"
    assert r.product_code.startswith("{23170F69")
    assert r.install_args == "/S" and r.extra_args == "ALLUSERS=1"

    src = get_source("winget", {"type": "winget", "package": "7zip.7zip", "installer_type": "exe"})
    assert src.resolve(ctx_for(web)).url.endswith("7z2408-x64.exe")


def test_github_source():
    web = FakeWeb()
    web.add(r"api\.github\.com/repos/git-for-windows/git/releases/latest$", {
        "tag_name": "v2.47.0.windows.2", "html_url": "https://github.com/x",
        "assets": [{"name": "Git-2.47.0.2-32-bit.exe", "browser_download_url": "https://g/32.exe"},
                   {"name": "Git-2.47.0.2-64-bit.exe", "browser_download_url": "https://g/64.exe",
                    "digest": "sha256:ABCDEF"}]})
    src = get_source("github", {"type": "github", "repo": "git-for-windows/git",
                                "asset_pattern": r"^Git-[\d.]+-64-bit\.exe$",
                                "version_regex": r"^v?(\d+\.\d+\.\d+)"})
    r = src.resolve(ctx_for(web))
    assert (r.version, r.url, r.sha256) == ("2.47.0", "https://g/64.exe", "abcdef")


def test_web_source_with_url_regex_picks_highest_version():
    web = FakeWeb()
    web.add(r"example\.com/dl$", '<a href="files/app-1.2.msi">Version 1.2</a> old: Version 1.10 '
                                 '<a href="files/app-1.10.msi">x</a>')
    src = get_source("web", {"type": "web", "url": "https://example.com/dl",
                             "version_regex": r"Version (?P<version>[\d.]+)",
                             "url_regex": r'href="(?P<url>files/app-{version}\.msi)"'})
    r = src.resolve(ctx_for(web))
    assert r.version == "1.10"
    assert r.url == "https://example.com/files/app-1.10.msi"


def test_json_source():
    web = FakeWeb()
    web.add(r"product-details", {"LATEST_FIREFOX_VERSION": "131.0.3"})
    src = get_source("json", {"type": "json", "url": "https://product-details/x.json",
                              "version_path": "LATEST_FIREFOX_VERSION",
                              "download_url": "https://dl/{version}/Firefox%20Setup%20{version}.msi"})
    r = src.resolve(ctx_for(web))
    assert r.version == "131.0.3"
    assert r.filename == "Firefox Setup 131.0.3.msi"


def test_url_source_uses_etag_to_skip_downloads():
    web = FakeWeb()
    web.add(r"vendor\.example/latest\.msi$", b"", headers={"etag": '"v1"'})
    src = get_source("url", {"type": "url", "url": "https://vendor.example/latest.msi"})
    first = src.resolve(ctx_for(web))
    assert first.version is None and not first.unchanged
    second = src.resolve(ctx_for(web, state=first.state))
    assert second.unchanged


def test_url_source_version_from_redirect():
    def handler(request: httpx.Request):
        if request.url.path == "/latest":
            return httpx.Response(302, headers={"location": "https://cdn.example/app-5.4.3-x64.exe"})
        return httpx.Response(200)

    client = httpx.Client(transport=httpx.MockTransport(handler), follow_redirects=True)
    src = get_source("url", {"type": "url", "url": "https://vendor.example/latest", "version_from": "redirect"})
    r = src.resolve(SourceContext(client=client))
    assert r.version == "5.4.3" and r.filename == "app-5.4.3-x64.exe"


def test_validation_errors():
    with pytest.raises(ValueError):
        get_source("web", {}).validate({"type": "web", "url": "x", "version_regex": "("})
