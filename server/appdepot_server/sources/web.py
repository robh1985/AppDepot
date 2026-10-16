"""Web page, JSON API and fixed-URL sources.

``web`` - scrape a download page with regular expressions::

    source:
      type: web
      url: https://www.7-zip.org/download.html
      version_regex: 'Download 7-Zip (?P<version>[\\d.]+)'
      # either a regex for the link (group 'url' or 1, relative links allowed) ...
      url_regex: 'href="(?P<url>a/7z\\d+-x64\\.msi)"'
      # ... or a template using {version}, {version_nodots}, {major}, {minor} ...
      download_url: https://www.7-zip.org/a/7z{version_nodots}-x64.msi

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
      version_from: msi          # msi | filename | redirect
      version_regex: '(\\d+(?:\\.\\d+)+)'   # for filename / redirect

With ``version_from: msi`` the file is downloaded and the version read from
the MSI. The ETag/Last-Modified headers are remembered so unchanged files are
not downloaded again on the next check.
"""

from __future__ import annotations

import re
from urllib.parse import urljoin

from ..versioning import max_version
from .base import (
    ReleaseInfo,
    Source,
    SourceContext,
    clean_version,
    filename_from_url,
    json_path,
    regex_first,
    render_template,
)


class WebSource(Source):
    type_name = "web"
    required = ("url", "version_regex")

    @classmethod
    def validate(cls, config):
        super().validate(config)
        if not (config.get("url_regex") or config.get("download_url")):
            raise ValueError("'web' source requires url_regex or download_url")

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        resp = ctx.client.get(self.config["url"])
        resp.raise_for_status()
        page = resp.text
        rx = re.compile(self.config["version_regex"])
        found = []
        for m in rx.finditer(page):
            found.append(m.group("version") if "version" in m.groupdict()
                         else (m.group(1) if m.groups() else m.group(0)))
        version = max_version(found)
        if not version:
            raise LookupError(f"version_regex did not match {self.config['url']}")
        if self.config.get("download_url"):
            url = render_template(self.config["download_url"], version)
        else:
            pattern = render_template(self.config["url_regex"], version) \
                if "{version" in self.config["url_regex"] else self.config["url_regex"]
            link = regex_first(pattern, page, group="url")
            if not link:
                raise LookupError("url_regex did not match the download page")
            url = urljoin(str(resp.url), link.replace("&amp;", "&"))
        return ReleaseInfo(version=version, url=url, filename=self.config.get("filename") or filename_from_url(url))


class JsonSource(Source):
    type_name = "json"
    required = ("url", "version_path")

    @classmethod
    def validate(cls, config):
        super().validate(config)
        if not (config.get("url_path") or config.get("download_url")):
            raise ValueError("'json' source requires url_path or download_url")

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        resp = ctx.client.get(self.config["url"], headers={"Accept": "application/json"})
        resp.raise_for_status()
        data = resp.json()
        version = clean_version(json_path(data, self.config["version_path"]), self.config)
        if self.config.get("url_path"):
            url = str(json_path(data, self.config["url_path"]))
        else:
            url = render_template(self.config["download_url"], version)
        sha = None
        if self.config.get("sha256_path"):
            sha = str(json_path(data, self.config["sha256_path"])).lower()
        return ReleaseInfo(version=version, url=url, sha256=sha,
                           filename=self.config.get("filename") or filename_from_url(url))


class UrlSource(Source):
    type_name = "url"
    required = ("url",)

    @classmethod
    def validate(cls, config):
        super().validate(config)
        if config.get("version_from", "msi") not in ("msi", "filename", "redirect"):
            raise ValueError("version_from must be msi, filename or redirect")

    def resolve(self, ctx: SourceContext) -> ReleaseInfo:
        url = self.config["url"]
        mode = self.config.get("version_from", "msi")
        head = ctx.client.head(url)
        if head.status_code >= 400:  # some CDNs reject HEAD
            head = None
        final_url = str(head.url) if head is not None else url
        filename = self.config.get("filename") or filename_from_url(final_url)

        state = {}
        if head is not None:
            state = {k: head.headers.get(k) for k in ("etag", "last-modified", "content-length")
                     if head.headers.get(k)}

        if mode == "msi":
            unchanged = bool(state) and state == ctx.state.get("http")
            return ReleaseInfo(version=None, url=url, filename=filename,
                               state={"http": state}, unchanged=unchanged)

        text = final_url if mode == "redirect" else filename
        pattern = self.config.get("version_regex") or r"(\d+(?:\.\d+)+)"
        version = regex_first(pattern, text)
        if not version:
            raise LookupError(f"Could not read a version from '{text}'")
        return ReleaseInfo(version=clean_version(version, {}), url=final_url, filename=filename,
                           state={"http": state})
