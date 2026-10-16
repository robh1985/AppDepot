"""Web page, JSON API and fixed-URL sources.

``web`` - scrape a download page with regular expressions::

    source:
      type: web
      url: https://www.7-zip.org/download.html
      version_regex: 'Download 7-Zip (?P<version>[\\d.]+)'
      # either a regex for the link (group 'url' or 1, relative links allowed) ...
      url_regex: 'href="(?P<url>a/7z\\d+-x64\\.msi)"'
      # ... or a template using {version}, {version_nodots}, {major}, {minor} ...
      # A list of templates is allowed: every URL is a candidate and the preferred
      # installer type (MSI) that actually exists wins.
      download_url:
        - https://www.7-zip.org/a/7z{version_nodots}-x64.msi
        - https://www.7-zip.org/a/7z{version_nodots}-x64.exe

``json`` - query a JSON API::

    source:
      type: json
      url: https://product-details.mozilla.org/1.0/firefox_versions.json
      version_path: LATEST_FIREFOX_VERSION
      download_url: https://download-installer.cdn.mozilla.net/pub/firefox/releases/{version}/win64/en-US/Firefox%20Setup%20{version}.msi
      # or url_path: data.downloads[0].url

``url`` - a fixed "always latest" download link::

    source:
      type: url
      url: https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi
      version_from: file         # file | filename | redirect | fixed
      version_regex: '(\\d+(?:\\.\\d+)+)'   # for filename / redirect (or text inside an MSI)

With ``version_from: file`` (alias ``msi``) the file is downloaded and its version
read from it: MSI ProductVersion, MSIX manifest or EXE version resource. With a
``version_regex`` the MSI's property values and summary information are
searched instead (Chrome's MSI ProductVersion is not the Chrome version), and
``version_api: {url, path}`` gives a fallback. ``fixed`` uses ``version``
(final releases that never change). The ETag/Last-Modified headers are
remembered so unchanged files are not downloaded again on the next check.

Common options: ``headers`` (dict) and ``browser: true`` (send browser-like
headers). ``web``: ``strip_html``, ``version_format`` ('{g1}.{g2}' or named
groups), ``sha256_regex`` (``{version}``/``{filename}`` placeholders),
``version_from: file`` (links whose version is only in the file). ``json``:
``text_path`` + ``url_regex`` (links inside an HTML field), ``sha256_path``,
``sha512_path``. JSON paths support ``[?Key=Value]`` filters and ``[max:Key]``.
"""

from __future__ import annotations

import html
import re
from urllib.parse import urljoin

from ..versioning import max_version
from .adobe import BROWSER_HEADERS
from .base import (
    ReleaseInfo,
    as_list,
    type_from_filename,
    Source,
    SourceContext,
    clean_version,
    filename_from_url,
    json_path,
    regex_first,
    render_template,
)


def candidates_for(version: str | None, urls: list[str], cfg: dict) -> list[ReleaseInfo]:
    single = len(urls) == 1
    out = []
    for order, url in enumerate(urls):
        filename = (cfg.get("filename") if single else None) or filename_from_url(url)
        if "." not in filename:   # e.g. go.microsoft.com/fwlink/?linkid=...: name it after the download
            filename = None
        out.append(ReleaseInfo(version=version, url=url, filename=filename,
                               installer_type=type_from_filename(filename), order=order))
    return out


def request_headers(cfg: dict) -> dict[str, str]:
    headers = dict(cfg.get("headers") or {})
    if cfg.get("browser"):   # some vendor sites reject requests that don't look like a browser
        headers.setdefault("User-Agent", BROWSER_UA)
        headers.setdefault("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        headers.setdefault("Accept-Language", "en-US,en;q=0.9")
    return headers


def strip_html(text: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", text)))


def version_from_match(m: re.Match, cfg: dict) -> str:
    groups = {k: v for k, v in m.groupdict().items() if v is not None}
    if cfg.get("version_format"):
        positional = {f"g{i}": g for i, g in enumerate(m.groups(), start=1) if g is not None}
        return cfg["version_format"].format(**positional, **groups)
    if "version" in groups:
        return groups["version"]
    return m.group(1) if m.groups() else m.group(0)


def links_from(text: str, base_url: str, patterns: list[str], version: str | None) -> list[str]:
    urls: list[str] = []
    for rx_text in patterns:
        pattern = render_template(rx_text, version) if version and "{version" in rx_text else rx_text
        for m in re.finditer(pattern, text):
            link = m.group("url") if "url" in m.groupdict() else (m.group(1) if m.groups() else m.group(0))
            full = urljoin(base_url, html.unescape(link))
            if full not in urls:
                urls.append(full)
    return urls


def apply_sha256_regex(found: list[ReleaseInfo], cfg: dict, texts: list[str]) -> None:
    """sha256_regex may use {version}... and {filename} (escaped) placeholders."""
    if not cfg.get("sha256_regex"):
        return
    for c in found:
        pattern = cfg["sha256_regex"].replace("{filename}", re.escape(c.filename or ""))
        if c.version and "{version" in pattern:
            pattern = render_template(pattern, c.version)
        for text in texts:
            sha = regex_first(pattern, text, group="sha")
            if sha and re.fullmatch(r"[0-9A-Fa-f]{64}", sha):
                c.sha256 = sha.lower()
                break


def from_file(found: list[ReleaseInfo], ctx: SourceContext) -> list[ReleaseInfo]:
    """Candidates whose version is read from the downloaded file. A link that has not changed
    since the last check reuses the version found then, so nothing is downloaded again."""
    for c in found:
        c.version = None
        c.state = {"url": c.url}
        c.unchanged = ctx.state.get("url") == c.url and bool(ctx.state.get("version"))
    return found


class WebSource(Source):
    type_name = "web"
    required = ("url",)

    @classmethod
    def validate(cls, config):
        super().validate(config)
        if not (config.get("url_regex") or config.get("download_url")):
            raise ValueError("'web' source requires url_regex or download_url")
        if config.get("version_from", "page") not in ("page", "file"):
            raise ValueError("version_from must be page or file")
        if config.get("version_from", "page") == "page" and not config.get("version_regex"):
            raise ValueError("'web' source requires version_regex (or version_from: file)")

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        return self.resolve_all(ctx)[0]

    def resolve_all(self, ctx: SourceContext) -> list[ReleaseInfo]:
        cfg = self.config
        resp = ctx.client.get(cfg["url"], headers=request_headers(cfg))
        resp.raise_for_status()
        page = resp.text
        text = strip_html(page) if cfg.get("strip_html") else page

        version = None
        if cfg.get("version_from", "page") == "page":
            found_versions = [version_from_match(m, cfg) for m in re.finditer(cfg["version_regex"], text)]
            version = max_version(found_versions)
            if not version:
                raise LookupError(f"version_regex did not match {cfg['url']}")
            version = clean_version(version, {})

        if cfg.get("download_url"):
            if version is None and any("{" in t for t in as_list(cfg["download_url"])):
                raise ValueError("download_url templates need a version from the page")
            urls = [render_template(t, version) if version else t for t in as_list(cfg["download_url"])]
        else:
            urls = links_from(page, str(resp.url), as_list(cfg["url_regex"]), version)
            if not urls:
                raise LookupError("url_regex did not match the download page")
        found = candidates_for(version, urls, cfg)
        apply_sha256_regex(found, cfg, [text, page])
        return from_file(found, ctx) if version is None else found


class JsonSource(Source):
    type_name = "json"
    required = ("url",)

    @classmethod
    def validate(cls, config):
        super().validate(config)
        if not (config.get("url_path") or config.get("download_url") or config.get("url_regex")):
            raise ValueError("'json' source requires url_path, download_url or url_regex")
        if not config.get("version_path") and config.get("version_from") != "file":
            raise ValueError("'json' source requires version_path (or version_from: file)")

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        return self.resolve_all(ctx)[0]

    def resolve_all(self, ctx: SourceContext) -> list[ReleaseInfo]:
        cfg = self.config
        resp = ctx.client.get(cfg["url"], headers={"Accept": "application/json", **request_headers(cfg)})
        resp.raise_for_status()
        data = resp.json()
        version = None
        if cfg.get("version_path"):
            version = clean_version(json_path(data, cfg["version_path"]), cfg)

        if cfg.get("url_path"):
            urls = []
            for path in as_list(cfg["url_path"]):
                try:
                    urls.append(str(json_path(data, path)))
                except (KeyError, IndexError, ValueError):
                    continue
            if not urls:
                raise LookupError("url_path not found in the JSON response")
        elif cfg.get("url_regex"):
            # e.g. a help-center article whose HTML body is a JSON field (text_path)
            text = str(json_path(data, cfg["text_path"])) if cfg.get("text_path") else resp.text
            urls = links_from(text, str(resp.url), as_list(cfg["url_regex"]), version)
            if not urls:
                raise LookupError("url_regex did not match the JSON text")
        else:
            urls = [render_template(t, version) for t in as_list(cfg["download_url"])]

        found = candidates_for(version, urls, cfg)
        if len(urls) == 1:
            if cfg.get("sha256_path"):
                found[0].sha256 = str(json_path(data, cfg["sha256_path"])).lower()
            if cfg.get("sha512_path"):
                found[0].sha512 = str(json_path(data, cfg["sha512_path"])).lower()
        return from_file(found, ctx) if version is None else found


class UrlSource(Source):
    type_name = "url"
    required = ("url",)
    MODES = ("file", "msi", "filename", "redirect", "fixed")

    @classmethod
    def validate(cls, config):
        super().validate(config)
        mode = config.get("version_from", "file")
        if mode not in cls.MODES:
            raise ValueError(f"version_from must be one of {', '.join(cls.MODES)}")
        if mode == "fixed" and not config.get("version"):
            raise ValueError("version_from: fixed requires version")

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        cfg = self.config
        url = cfg["url"]
        mode = cfg.get("version_from", "file")
        headers = request_headers(cfg)
        head = ctx.client.head(url, headers=headers)
        if head.status_code >= 400:  # some CDNs reject HEAD
            head = None
        final_url = str(head.url) if head is not None else url
        filename = cfg.get("filename") or filename_from_url(final_url)

        state = {}
        if head is not None:
            state = {k: head.headers.get(k) for k in ("etag", "last-modified", "content-length")
                     if head.headers.get(k)}

        if mode == "fixed":
            return ReleaseInfo(version=str(cfg["version"]), url=url, filename=filename, state={"http": state})

        if mode in ("file", "msi"):
            # Version read from the file after downloading: MSI ProductVersion, MSIX manifest,
            # EXE version resource - or, with version_regex, the first match in the MSI's texts.
            rule = {}
            if cfg.get("version_regex"):
                rule["text_regex"] = cfg["version_regex"]
            if cfg.get("version_api"):
                try:
                    api = cfg["version_api"]
                    resp = ctx.client.get(api["url"], headers=request_headers(api))
                    resp.raise_for_status()
                    rule["fallback"] = str(json_path(resp.json(), api["path"]))
                except Exception:  # noqa: BLE001 - only a fallback
                    pass
            unchanged = bool(state) and state == ctx.state.get("http")
            return ReleaseInfo(version=None, url=url, filename=filename, state={"http": state},
                               unchanged=unchanged, version_rule=rule)

        text = final_url if mode == "redirect" else filename
        pattern = cfg.get("version_regex") or r"(\d+(?:\.\d+)+)"
        version = regex_first(pattern, text)
        if not version:
            raise LookupError(f"Could not read a version from '{text}'")
        return ReleaseInfo(version=clean_version(version, {}), url=final_url, filename=filename,
                           state={"http": state})


BROWSER_UA = BROWSER_HEADERS["User-Agent"]
