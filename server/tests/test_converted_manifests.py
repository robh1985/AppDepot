"""The manifests converted from SyncScripts/*.ps1, run against realistic fake vendor responses.

Each test loads the real file from server/manifests, so the shipped configuration (paths,
regexes, templates) is what is exercised.
"""

import hashlib
import io
import shutil
import struct
import zipfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from appdepot_server.api import create_app
from appdepot_server.packages import pe_version

from .msi_fixture import build_msi

MANIFESTS = Path(__file__).resolve().parents[1] / "manifests"


def use(ctx, app_id):
    shutil.copy(MANIFESTS / f"{app_id}.yaml", ctx.config.manifests_dir / f"{app_id}.yaml")
    res = ctx.sync()
    assert not res["errors"], res["errors"]


def check(ctx, app_id):
    r = ctx.updater.check_app(app_id)
    assert r.status == "updated", r.message
    with ctx.db.session() as s:
        app = ctx.db.get_app(s, app_id)
        return r, next(v for v in app.versions if v.is_latest)


def msi(version, product_code="{11111111-2222-3333-4444-555555555555}", **extra):
    return build_msi({"ProductCode": product_code, "ProductVersion": version, "ProductName": "App",
                      "ALLUSERS": "1", **extra})


def exe_with_version(version: str) -> bytes:
    a, b, c, d = (int(x) for x in version.split("."))
    fixed = struct.pack("<IIII", 0xFEEF04BD, 0x00010000, (a << 16) | b, (c << 16) | d) + b"\0" * 36
    return b"MZ" + b"\0" * 5000 + b"VS_VERSION_INFO\0" + fixed + b"\0" * 100


# --------------------------------------------------------------------------- Edge (JSON filters)
def test_edge_release_feed(ctx, web):
    body = b"MSI-EDGE" * 100
    sha = hashlib.sha256(body).hexdigest().upper()
    web.add(r"edgeupdates\.microsoft\.com/api/products", [
        {"Product": "Beta", "Releases": [{"Platform": "Windows", "Architecture": "x64", "ProductVersion": "999.0",
                                          "Artifacts": [{"ArtifactName": "msi", "Location": "https://x/beta.msi"}]}]},
        {"Product": "Stable", "Releases": [
            {"Platform": "Windows", "Architecture": "x64", "ProductVersion": "141.0.3537.57",
             "Artifacts": [{"ArtifactName": "msi", "Location": "https://msedge.example/old.msi", "Hash": "00"}]},
            {"Platform": "Windows", "Architecture": "x64", "ProductVersion": "141.0.3537.71",
             "Artifacts": [{"ArtifactName": "cab", "Location": "https://x/a.cab"},
                           {"ArtifactName": "msi", "Location": "https://msedge.example/MicrosoftEdgeEnterpriseX64.msi",
                            "Hash": sha, "HashAlgorithm": "SHA256"}]},
            {"Platform": "Windows", "Architecture": "x86", "ProductVersion": "141.0.3537.99", "Artifacts": []},
            {"Platform": "MacOS", "Architecture": "universal", "ProductVersion": "150.0", "Artifacts": []}]}])
    web.add(r"msedge\.example/MicrosoftEdgeEnterpriseX64\.msi$", body)
    use(ctx, "Microsoft.Edge")
    r, v = check(ctx, "Microsoft.Edge")
    assert v.version == "141.0.3537.71" and v.sha256 == sha.lower()


# --------------------------------------------------------------------------- Chrome (MSI text version)
def test_chrome_version_from_msi_text(ctx, web):
    # The MSI ProductVersion (here 77.x) is not the Chrome version; a property holds the real one
    web.add(r"dl\.google\.com/.+standaloneenterprise64\.msi$",
            msi("77.68.23417", ChromeVersion="Google Chrome 141.0.7390.108 Enterprise"), headers={"etag": '"c1"'})
    web.add(r"versionhistory\.googleapis\.com", {"releases": [{"version": "141.0.7390.66", "fraction": 1}]})
    use(ctx, "Google.Chrome")
    _, v = check(ctx, "Google.Chrome")
    assert v.version == "141.0.7390.108"


def test_chrome_version_api_fallback(ctx, web):
    web.add(r"dl\.google\.com/.+standaloneenterprise64\.msi$", msi("77.68.23417"), headers={"etag": '"c2"'})
    web.add(r"versionhistory\.googleapis\.com", {"releases": [
        {"version": "141.0.7390.122", "fraction": 0.25},          # not fully rolled out
        {"version": "141.0.7390.108", "fraction": 1},
        {"version": "141.0.7390.66", "fraction": 1}]})
    use(ctx, "Google.Chrome")
    _, v = check(ctx, "Google.Chrome")
    assert v.version == "141.0.7390.108"


# --------------------------------------------------------------------------- Teams (MSIX)
def test_teams_msix(ctx, web):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("AppxManifest.xml", '<Package><Identity Name="MSTeams" Publisher="CN=Microsoft" '
                                        'Version="25275.2601.4002.2815" ProcessorArchitecture="x64"/></Package>')
    web.add(r"go\.microsoft\.com/fwlink/\?linkid=2196106", buf.getvalue(), headers={"etag": '"t1"'})
    use(ctx, "Microsoft.Teams")
    _, v = check(ctx, "Microsoft.Teams")
    assert v.version == "25275.2601.4002.2815" and v.installer_type == "msix"
    assert "Add-AppxProvisionedPackage" in v.install_command and "MSTeams-x64.msix" in v.install_command
    assert "Remove-AppxProvisionedPackage" in v.uninstall_command and "MSTeams" in v.uninstall_command
    detect = (ctx.repo.root / v.intune_detection_relative_path).read_text(encoding="utf-8-sig")
    assert "$AppxName = 'MSTeams'" in detect
    app = TestClient(create_app(ctx, start_scheduler=False)).get("/api/v1/apps/Microsoft.Teams").json()
    assert app["detection"]["appx_name"] == "MSTeams"


# --------------------------------------------------------------------------- VC++ (EXE version, fixed)
def test_pe_version_reader(tmp_path):
    f = tmp_path / "vc_redist.x64.exe"
    f.write_bytes(exe_with_version("14.44.35211.0"))
    assert pe_version(f) == "14.44.35211.0"


def test_vcredist_v14_and_fixed(ctx, web):
    web.add(r"aka\.ms/vc14/vc_redist\.x64\.exe$", exe_with_version("14.44.35211.0"))
    web.add(r"download\.microsoft\.com/.+VSU_4/vcredist_x64\.exe$", b"MZ old vcredist 2012")
    use(ctx, "Microsoft.VCRedist.2015+.x64")
    use(ctx, "Microsoft.VCRedist.2012.x64")
    _, v = check(ctx, "Microsoft.VCRedist.2015+.x64")
    assert v.version == "14.44.35211.0" and v.install_command.endswith("/install /quiet /norestart")
    _, v = check(ctx, "Microsoft.VCRedist.2012.x64")
    assert v.version == "11.0.61030.0"
    assert ctx.updater.check_app("Microsoft.VCRedist.2012.x64").status == "up_to_date"


# --------------------------------------------------------------------------- .NET (SHA-512)
def test_dotnet_desktop_runtime_sha512(ctx, web):
    body = b"MZ windowsdesktop runtime" * 50
    def feed(hash_):
        return {"releases": [{"release-version": "8.0.21", "windowsdesktop": {"version": "8.0.21", "files": [
            {"name": "windowsdesktop-runtime-win-x86.exe", "rid": "win-x86", "url": "https://dn.example/x86.exe", "hash": "0"},
            {"name": "windowsdesktop-runtime-win-x64.exe", "rid": "win-x64",
             "url": "https://dn.example/windowsdesktop-runtime-8.0.21-win-x64.exe", "hash": hash_}]}}]}
    web.add(r"builds\.dotnet\.microsoft\.com/dotnet/release-metadata/8\.0/releases\.json$", feed("ab" * 64))
    web.add(r"dn\.example/windowsdesktop-runtime-8\.0\.21-win-x64\.exe$", body)
    use(ctx, "Microsoft.DotNet.DesktopRuntime.8")
    r = ctx.updater.check_app("Microsoft.DotNet.DesktopRuntime.8")
    assert r.status == "failed" and "SHA-512 mismatch" in r.message
    web.add(r"builds\.dotnet\.microsoft\.com/dotnet/release-metadata/8\.0/releases\.json$",
            feed(hashlib.sha512(body).hexdigest()))
    _, v = check(ctx, "Microsoft.DotNet.DesktopRuntime.8")
    assert v.version == "8.0.21" and v.installer_type == "burn"


# --------------------------------------------------------------------------- OpenVPN (strip_html + format + sha)
def test_openvpn_release_notes(ctx, web):
    body = b"MSI-OPENVPN" * 100
    sha = hashlib.sha256(body).hexdigest()
    web.add(r"openvpn\.net/connect-docs/windows-release-notes\.html$",
            "<h2>Release notes</h2><h3>3.8.1 <span>(4904)</span></h3><p>Windows 10 build 19045 (1234)</p>"
            "<h3>3.9.0&nbsp;(5008)</h3><table><tr><td>openvpn-connect-3.9.0.5008_signed.msi</td>"
            f"<td><code>{sha}</code></td></tr></table>")
    web.add(r"packages\.openvpn\.net/connect/v3/openvpn-connect-3\.9\.0\.5008_signed\.msi$", body)
    use(ctx, "OpenVPNTechnologies.OpenVPNConnect")
    r, v = check(ctx, "OpenVPNTechnologies.OpenVPNConnect")
    assert v.version == "3.9.0.5008" and v.sha256 == sha          # winget source unavailable here


# --------------------------------------------------------------------------- PuTTY (sha256sums)
def test_putty_sha256sums(ctx, web):
    body = b"MSI-PUTTY" * 100
    sha = hashlib.sha256(body).hexdigest()
    web.add(r"the\.earth\.li/~sgtatham/putty/latest/sha256sums$",
            f"{'1' * 64}  w32/putty-0.83-installer.msi\n{sha}  w64/putty-64bit-0.83-installer.msi\n")
    web.add(r"the\.earth\.li/~sgtatham/putty/0\.83/w64/putty-64bit-0\.83-installer\.msi$", body)
    use(ctx, "PuTTY.PuTTY")
    _, v = check(ctx, "PuTTY.PuTTY")
    assert v.version == "0.83" and v.sha256 == sha


# --------------------------------------------------------------------------- ODBC (link from page, version from MSI)
def test_odbc_driver_link_and_msi_version(ctx, web):
    web.add(r"raw\.githubusercontent\.com/MicrosoftDocs/sql-docs/.+download-odbc-driver-for-sql-server\.md$",
            "- [Download Microsoft ODBC Driver 18 for SQL Server (x64)](https://go.microsoft.com/fwlink/?linkid=2280794)\n"
            "- [Download Microsoft ODBC Driver 17 for SQL Server (x64)](https://go.microsoft.com/fwlink/?linkid=2266640)\n")
    web.add(r"go\.microsoft\.com/fwlink/\?linkid=2266640$", msi("17.10.6.1"))
    web.add(r"go\.microsoft\.com/fwlink/\?linkid=2280794$", msi("18.5.1.1"))
    use(ctx, "Microsoft.msodbcsql.17")
    _, v = check(ctx, "Microsoft.msodbcsql.17")
    assert v.version == "17.10.6.1" and "IACCEPTMSODBCSQLLICENSETERMS=YES" in v.install_command
    sheet = (ctx.repo.root / v.intune_info_relative_path).read_text()
    assert "Microsoft.VCRedist.2015+.x64" in sheet                       # dependency for Intune
    gets = sum(1 for q in web.requests if q.method == "GET" and "linkid=2266640" in str(q.url))
    assert ctx.updater.check_app("Microsoft.msodbcsql.17").status == "up_to_date"
    assert sum(1 for q in web.requests if q.method == "GET" and "linkid=2266640" in str(q.url)) == gets
    app = TestClient(create_app(ctx, start_scheduler=False)).get("/api/v1/apps/Microsoft.msodbcsql.17").json()
    assert app["requires"] == ["Microsoft.VCRedist.2015+.x64"]


# --------------------------------------------------------------------------- Mimecast (link in JSON HTML + zip)
def test_mimecast_link_from_help_center(ctx, web):
    body = ('<h2>Mimecast Security Agent</h2><table><tr><td><a href="https://wrong.example/x.zip">32-bit</a></td></tr></table>'
            '<h3>Mimecast for Outlook</h3><table><tr><td><a href="https://mc.example/mfo-x64.zip">64-bit</a> '
            '<a href="https://mc.example/mfo-x86.zip?a=1&amp;b=2">32-bit</a></td></tr></table>')
    web.add(r"mimecastsupport\.zendesk\.com/api/v2/help_center/.+\.json$", {"article": {"body": body}})
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("Mimecast for outlook 7.10.1.133 (32 Bit).msi", msi("7.10.1.133"))
        zf.writestr("readme.txt", "x")
    web.add(r"mc\.example/mfo-x86\.zip\?a=1&b=2$", buf.getvalue())
    use(ctx, "Mimecast.MimecastForOutlook")
    _, v = check(ctx, "Mimecast.MimecastForOutlook")
    assert v.version == "7.10.1.133"
    assert v.setup_path == "Mimecast for outlook 7.10.1.133 (32 Bit).msi"
    assert v.install_command == 'msiexec.exe /i "Mimecast for outlook 7.10.1.133 (32 Bit).msi" /qn /norestart'


# --------------------------------------------------------------------------- Audacity tracks
@pytest.mark.parametrize("app_id,expected,asset", [
    ("Audacity.Audacity.4", "4.0.1", "audacity-win-4.0.1-x86_64.msi"),
    ("Audacity.Audacity.3", "3.7.5", "audacity-win-3.7.5-64bit.exe"),
])
def test_audacity_tracks(ctx, web, app_id, expected, asset):
    def rel(tag, *assets, pre=False):
        return {"tag_name": tag, "prerelease": pre, "draft": False, "html_url": "h",
                "assets": [{"name": a, "browser_download_url": f"https://gh.example/{a}"} for a in assets]}
    web.add(r"api\.github\.com/repos/audacity/audacity/releases\?per_page=100$", [
        rel("Audacity-4.1.0-beta", "audacity-win-4.1.0-x86_64.msi", pre=True),
        rel("Audacity-4.0.1", "audacity-win-4.0.1-x86_64.msi", "audacity-win-4.0.1-arm64.msi"),
        rel("Audacity-3.7.5", "audacity-win-3.7.5-64bit.exe", "audacity-win-3.7.5-32bit.exe"),
        rel("Audacity-3.7.4", "audacity-win-3.7.4-64bit.exe")])
    web.add(r"gh\.example/audacity-win-4\.0\.1-x86_64\.msi$", msi("4.0.1"))
    web.add(r"gh\.example/audacity-win-3\.7\.5-64bit\.exe$", b"MZ Inno Setup")
    use(ctx, app_id)
    _, v = check(ctx, app_id)
    assert v.version == expected and v.filename == asset


# --------------------------------------------------------------------------- Zoom, exclusions
def test_zoom_redirect_and_exclusions(ctx, web, monkeypatch):
    import httpx

    def handler(request: httpx.Request):
        if request.url.host == "zoom.us":
            return httpx.Response(302, headers={"location": "https://cdn.zoom.us/prod/6.6.2.12345/x64/ZoomInstallerFull.msi"})
        return httpx.Response(200, content=b"" if request.method == "HEAD" else msi("6.6.12345"))

    from appdepot_server import updater as updater_module
    monkeypatch.setattr(updater_module, "make_client",
                        lambda *a, **k: httpx.Client(transport=httpx.MockTransport(handler), follow_redirects=True))
    use(ctx, "Zoom.Zoom")
    _, v = check(ctx, "Zoom.Zoom")
    assert v.version == "6.6.2.12345" and v.filename == "ZoomInstallerFull.msi"
    detect = (ctx.repo.root / v.intune_detection_relative_path).read_text(encoding="utf-8-sig")
    assert "$Exclude = 'Outlook|Rooms" in detect
    app = TestClient(create_app(ctx, start_scheduler=False)).get("/api/v1/apps/Zoom.Zoom").json()
    assert app["detection"]["exclude"].startswith("Outlook|Rooms")


def test_all_converted_manifests_load(ctx):
    for f in MANIFESTS.glob("*.yaml"):
        shutil.copy(f, ctx.config.manifests_dir / f.name)
    res = ctx.sync()
    assert not res["errors"] and len(res["added_or_updated"]) == len(list(MANIFESTS.glob("*.yaml")))
