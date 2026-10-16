"""Adobe Acrobat and Acrobat Reader (DC, Continuous track).

Ported from the Adobe sync script method:

* **Latest version** - Adobe's Reader products service (``rdc.adobe.io``, fast
  JSON). Fallback: the Acrobat release notes index on www.adobe.com (which also
  lists earlier releases).
* **Updates** - the cumulative ``.msp`` patch for the release, downloaded from
  ``ardownload3.adobe.com`` or ``ardownload2.adobe.com`` using Adobe's file
  naming (``AcroRdrDCx64Upd<digits>_MUI.msp``, ``AcrobatDCx64Upd<digits>.msp``...).
* **Full installers** - Reader's offline installer
  (``AcroRdrDCx64<digits>_MUI.exe``; for out-of-cycle releases without one, the
  previous releases are tried) and Acrobat Pro's installer zip from
  ``trials.adobe.com`` (version read from AcroPro.msi inside it).

    source:
      type: adobe
      product: reader          # reader | acrobat
      package: update          # update (.msp patch) | installer (full installer)
      architecture: x64        # x64 | x86
      language: MUI            # Reader only: MUI (multi-language) | en_US
"""

from __future__ import annotations

import re
from typing import Any

from ..versioning import sort_versions
from .base import ReleaseInfo, Source, SourceContext

PRODUCTS_API = ("https://rdc.adobe.io/reader/products?lang=mui&site=enterprise&os=Windows%2011"
                "&api_key=dc-get-adobereader-cdn")
INDEX_URL = "https://www.adobe.com/devnet-docs/acrobatetk/tools/ReleaseNotesDC/index.html"
HOSTS = ("ardownload3.adobe.com", "ardownload2.adobe.com")
DOWNLOAD_URL = "https://{host}/pub/adobe/{folder}/win/AcrobatDC/{digits}/{name}"
TRIALS = {
    "x64": "https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_x64_WWMUI.zip",
    "x86": "https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_WWMUI.zip",
}
# www.adobe.com's bot protection drops requests that do not look like a browser
BROWSER_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
                  "Chrome/128.0.0.0 Safari/537.36 Edg/128.0.0.0",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}
VERSION_RE = re.compile(r"^\d{2}\.\d{3}\.\d{5}$")
INDEX_RE = re.compile(r'(?is)<a\s[^>]*href="([^"]*continuous/[^"#]+\.html)[^"]*"[^>]*>\s*(\d{2}\.\d{3}\.\d{5})\b')
FALLBACK_RELEASES = 4   # how many earlier releases to try for a full Reader installer


def file_name(product: str, package: str, arch: str, language: str, digits: str) -> str:
    x64 = "x64" if arch == "x64" else ""
    if package == "update":
        if product == "acrobat":
            return f"AcrobatDC{x64}Upd{digits}.msp"
        return f"AcroRdrDC{x64}Upd{digits}{'_MUI' if language == 'MUI' else ''}.msp"
    return f"AcroRdrDC{x64}{digits}_{language}.exe"


def folder(product: str, arch: str) -> str:
    return "reader" if product == "reader" and arch == "x86" else "acrobat"


class AdobeSource(Source):
    type_name = "adobe"
    required = ("product",)

    @classmethod
    def validate(cls, config: dict[str, Any]) -> None:
        super().validate(config)
        checks = {"product": ("reader", "acrobat"), "package": ("update", "installer"),
                  "architecture": ("x64", "x86"), "language": ("MUI", "en_US")}
        defaults = {"package": "update", "architecture": "x64", "language": "MUI"}
        for key, allowed in checks.items():
            value = config.get(key, defaults.get(key))
            if value not in allowed:
                raise ValueError(f"'adobe' source: {key} must be one of {', '.join(allowed)}")

    @property
    def product(self) -> str:
        return self.config["product"]

    @property
    def package(self) -> str:
        return self.config.get("package", "update")

    @property
    def arch(self) -> str:
        return self.config.get("architecture", "x64")

    @property
    def language(self) -> str:
        return self.config.get("language", "MUI")

    # -- versions ------------------------------------------------------------------
    def releases(self, ctx: SourceContext, history: bool = False) -> list[tuple[str, str | None]]:
        """[(version, release notes url)], newest first."""
        found: dict[str, str | None] = {}
        errors = []
        try:
            resp = ctx.client.get(PRODUCTS_API, headers=BROWSER_HEADERS, timeout=60)
            resp.raise_for_status()
            products = resp.json().get("products") or {}
            for item in (products.get("reader") or []) + (products.get("dcPro") or []):
                v = str((item or {}).get("version", ""))
                if VERSION_RE.match(v):
                    found.setdefault(v, None)
        except Exception as exc:  # noqa: BLE001
            errors.append(f"products service: {exc}")

        if history or not found:
            try:
                resp = ctx.client.get(INDEX_URL, headers=BROWSER_HEADERS, timeout=45)
                resp.raise_for_status()
                for m in INDEX_RE.finditer(resp.text):
                    found[m.group(2)] = str(resp.url.join(m.group(1)))
            except Exception as exc:  # noqa: BLE001
                errors.append(f"release notes index: {exc}")

        if not found:
            raise LookupError("Adobe version sources failed: " + "; ".join(errors))
        return [(v, found[v]) for v in sort_versions(found)]

    # -- candidates ----------------------------------------------------------------
    def resolve_all(self, ctx: SourceContext) -> list[ReleaseInfo]:
        if self.product == "acrobat" and self.package == "installer":
            return [self._acrobat_installer(ctx)]

        reader_installer = self.package == "installer"
        releases = self.releases(ctx, history=reader_installer)
        releases = releases[:1 + (FALLBACK_RELEASES if reader_installer else 0)]
        out: list[ReleaseInfo] = []
        for version, notes in releases:
            digits = version.replace(".", "")
            name = file_name(self.product, self.package, self.arch, self.language, digits)
            for host in HOSTS:
                out.append(ReleaseInfo(
                    version=version,
                    url=DOWNLOAD_URL.format(host=host, folder=folder(self.product, self.arch), digits=digits,
                                            name=name),
                    filename=name,
                    installer_type="msp" if self.package == "update" else "exe",
                    architecture=self.arch,
                    release_notes_url=notes,
                    order=len(out),
                ))
        return out

    def _acrobat_installer(self, ctx: SourceContext) -> ReleaseInfo:
        url = TRIALS[self.arch]
        stamp = {}
        try:
            head = ctx.client.head(url, headers=BROWSER_HEADERS, timeout=60)
            if head.status_code < 400:
                stamp = {k: head.headers.get(k) for k in ("etag", "last-modified", "content-length")
                         if head.headers.get(k)}
        except Exception:  # noqa: BLE001 - fall back to downloading
            pass
        unchanged = bool(stamp) and stamp == ctx.state.get("http")
        # The version is read from AcroPro.msi inside the zip after downloading
        return ReleaseInfo(version=None, url=url, filename=url.rsplit("/", 1)[-1], architecture=self.arch,
                           state={"http": stamp}, unchanged=unchanged)


class ManualSource(Source):
    """Applications whose installers are uploaded by an administrator."""

    type_name = "manual"

    def resolve_all(self, ctx: SourceContext) -> list[ReleaseInfo]:
        return []

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:  # pragma: no cover - never called
        raise LookupError("Manual applications are not downloaded; upload new versions instead")
