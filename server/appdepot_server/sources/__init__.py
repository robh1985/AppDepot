"""Version sources: where AppDepot looks for new releases on the internet."""

from .base import ReleaseInfo, Source, SourceContext, make_client
from .github import GitHubSource
from .web import JsonSource, UrlSource, WebSource
from .winget import WingetSource

SOURCE_TYPES: dict[str, type[Source]] = {
    cls.type_name: cls for cls in (WingetSource, GitHubSource, WebSource, JsonSource, UrlSource)
}


def get_source(source_type: str, config: dict) -> Source:
    try:
        return SOURCE_TYPES[source_type](config)
    except KeyError:
        raise ValueError(f"Unknown source type '{source_type}'") from None


__all__ = ["ReleaseInfo", "Source", "SourceContext", "SOURCE_TYPES", "get_source", "make_client"]
