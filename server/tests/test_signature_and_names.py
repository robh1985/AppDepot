"""Authenticode signer checks and naming of downloads whose URL has no usable extension."""

import io
import json
import subprocess
import zipfile

from appdepot_server import packages

from .conftest import write_manifest
from .msi_fixture import build_msi


def _fake_run(stdout="", stderr="", code=0, seen=None):
    def run(cmd, **kwargs):
        if seen is not None:
            seen.update(kwargs["env"])
        return subprocess.CompletedProcess(cmd, code, stdout, stderr)
    return run


def _windows(monkeypatch, run):
    monkeypatch.setattr(packages.os, "name", "nt")
    monkeypatch.setattr(packages, "_powershell", lambda: r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe")
    monkeypatch.setattr(packages.subprocess, "run", run)


def test_valid_signature_from_expected_signer(monkeypatch, tmp_path):
    seen = {}
    monkeypatch.setenv("PSModulePath", r"C:\Program Files\PowerShell\7\Modules")
    _windows(monkeypatch, _fake_run('\ufeff{"Status":"Valid","Subject":"CN=Zoom Communications, Inc., O=Zoom"}',
                                    seen=seen))
    ok, detail = packages.verify_signature(tmp_path / "z.msi", "Zoom Communications")
    assert ok is True and "Zoom" in detail
    assert not any(k.upper() == "PSMODULEPATH" for k in seen)      # PowerShell 7 paths are not inherited
    assert seen["APPDEPOT_SIGFILE"].endswith("z.msi")


def test_wrong_signer_or_bad_signature_is_rejected(monkeypatch, tmp_path):
    _windows(monkeypatch, _fake_run('{"Status":"Valid","Subject":"CN=Someone Else"}'))
    assert packages.verify_signature(tmp_path / "a.exe", "Zoom")[0] is False
    _windows(monkeypatch, _fake_run('{"Status":"HashMismatch","Subject":"CN=Zoom","Message":"The hash does not match"}'))
    ok, detail = packages.verify_signature(tmp_path / "a.exe", "Zoom")
    assert ok is False and "HashMismatch" in detail and "hash does not match" in detail
    _windows(monkeypatch, _fake_run('{"Status":"NotSigned","Subject":""}'))
    assert packages.verify_signature(tmp_path / "a.exe", "Zoom")[0] is False


def test_check_that_cannot_run_does_not_reject(monkeypatch, tmp_path):
    err = "Get-AuthenticodeSignature : The module 'Microsoft.PowerShell.Security' could not be loaded."
    _windows(monkeypatch, _fake_run("", err, 1))
    ok, detail = packages.verify_signature(tmp_path / "a.msi", "Zoom")
    assert ok is None and "could not be loaded" in detail


def test_unverifiable_signature_keeps_download(ctx, web, monkeypatch):
    monkeypatch.setattr("appdepot_server.updater.verify_signature",
                        lambda path, signer: (None, "signature not verified: the check did not run (x)"))
    web.add(r"vendor\.example/app\.msi$", build_msi({"ProductCode": "{11111111-2222-3333-4444-555555555555}",
                                                     "ProductVersion": "2.0.0", "ProductName": "App"}))
    write_manifest(ctx, {"id": "Contoso.Signed", "name": "App",
                         "source": {"type": "url", "url": "https://vendor.example/app.msi", "version_from": "file"},
                         "installer": {"type": "msi", "signer": "Contoso"}})
    ctx.sync()
    r = ctx.updater.check_app("Contoso.Signed")
    assert r.status == "updated" and r.version == "2.0.0", r.message


def test_zip_behind_a_non_installer_name(ctx, web):
    """Mimecast: https://...netsuite.com/core/media/media.nl?id=...&_xt=.zip with the MSI inside."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("Mimecast for Outlook 7.10.1.133 (32 bit).msi", build_msi({
            "ProductCode": "{22222222-2222-3333-4444-555555555555}", "ProductVersion": "7.10.1.133",
            "ProductName": "Mimecast for Outlook", "ALLUSERS": "1"}))
    web.add(r"kb\.example/article\.json$", json.dumps({"article": {"body":
            '<h3>Mimecast for Outlook</h3><table><tr><td>'
            '<a href="https://601905.app.netsuite.example/core/media/media.nl?id=1&amp;c=2&amp;_xt=.zip">32-bit</a>'
            '</td></tr></table>'}}))
    web.add(r"netsuite\.example/core/media/media\.nl", buf.getvalue())
    write_manifest(ctx, {"id": "Mimecast.Test", "name": "Mimecast for Outlook",
                         "source": {"type": "json", "url": "https://kb.example/article.json",
                                    "text_path": "article.body",
                                    "url_regex": r'(?is)>\s*Mimecast for Outlook\s*</h\d>(?:(?!</tr>).)*?'
                                                 r'<a\s[^>]*href="(?P<url>[^"]+)"[^>]*>\s*32-bit\s*</a>',
                                    "version_from": "file"},
                         "installer": {"type": "msi", "setup_file": "*.msi"}})
    ctx.sync()
    r = ctx.updater.check_app("Mimecast.Test")
    assert r.status == "updated" and r.version == "7.10.1.133", r.message
