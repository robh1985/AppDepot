"""``appdepot-server`` command line.

    appdepot-server serve                      run API + scheduler
    appdepot-server sync                       load manifests into the database
    appdepot-server check [APP_ID ...] [--force]
    appdepot-server list
    appdepot-server versions APP_ID
    appdepot-server schedule show
    appdepot-server schedule global "0 3 * * *"
    appdepot-server schedule app APP_ID "0 */6 * * *" | manual | global
    appdepot-server repackage APP_ID VERSION
    appdepot-server purge APP_ID               apply retention now
    appdepot-server events [--app APP_ID] [--limit 50]
    appdepot-server validate FILE ...          validate manifest files
    appdepot-server verify-package FILE        verify an .intunewin file

  Adding applications (see docs/adding-applications.md):
    appdepot-server app create APP_ID --name NAME [--type msi] [--args ...] [--installer FILE --version V]
    appdepot-server app import APP_ID FILE [--version V] [--replace]      upload an installer
    appdepot-server app search QUERY            search the winget catalog
    appdepot-server app add WINGET_ID [--category C] [--arch x64] [--check] [--yes]
    appdepot-server app add --file MANIFEST.yaml [--check]
    appdepot-server app test (WINGET_ID | --file F | --id APP_ID)   preview, nothing saved
    appdepot-server app template TYPE           print a manifest template
    appdepot-server app remove APP_ID [--delete-files] [--yes]
    appdepot-server app add-catalog [APP_ID ...] [--overwrite] [--check] [--dry-run] [--from DIR]
                                                add the applications that ship with AppDepot
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from sqlalchemy import select

from . import __version__
from .config import load_config
from .context import build_context, setup_logging
from .db import Application, Event
from .versioning import sort_versions


def _table(rows: list[list[str]], headers: list[str]) -> str:
    widths = [max(len(str(x)) for x in col) for col in zip(headers, *rows)] if rows else [len(h) for h in headers]
    line = "  ".join(h.ljust(w) for h, w in zip(headers, widths))
    out = [line, "  ".join("-" * w for w in widths)]
    out += ["  ".join(str(c).ljust(w) for c, w in zip(r, widths)) for r in rows]
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="appdepot-server", description="AppDepot repository server")
    p.add_argument("--config", "-c", help="Path to appdepot.yaml (default: $APPDEPOT_CONFIG or ./appdepot.yaml)")
    p.add_argument("--version", action="version", version=f"AppDepot server {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("serve", help="Run the API server and scheduler")
    sp.add_argument("--host")
    sp.add_argument("--port", type=int)
    sp.add_argument("--no-sync", action="store_true", help="Do not sync manifests on startup")

    sub.add_parser("sync", help="Load manifests into the database")

    sp = sub.add_parser("check", help="Check for updates now (all enabled apps if none given)")
    sp.add_argument("app_ids", nargs="*")
    sp.add_argument("--force", action="store_true", help="Re-download even if the version exists")

    sub.add_parser("list", help="List applications")

    sp = sub.add_parser("versions", help="List stored versions of an application")
    sp.add_argument("app_id")
    sp.add_argument("--all", action="store_true", help="Include purged versions")

    sp = sub.add_parser("schedule", help="Show or change schedules")
    ssub = sp.add_subparsers(dest="action", required=True)
    ssub.add_parser("show")
    g = ssub.add_parser("global")
    g.add_argument("cron")
    a = ssub.add_parser("app")
    a.add_argument("app_id")
    a.add_argument("cron", help="Cron expression, 'manual' or 'global'")

    sp = sub.add_parser("repackage", help="Rebuild the Intune package and commands for a version")
    sp.add_argument("app_id")
    sp.add_argument("version")

    sp = sub.add_parser("purge", help="Apply version retention now")
    sp.add_argument("app_id", nargs="?")

    sp = sub.add_parser("events", help="Show the event log")
    sp.add_argument("--app")
    sp.add_argument("--limit", type=int, default=50)

    sp = sub.add_parser("validate", help="Validate manifest files")
    sp.add_argument("files", nargs="+")

    sp = sub.add_parser("verify-package", help="Verify the encryption/integrity of an .intunewin file")
    sp.add_argument("file")

    sp = sub.add_parser("app", help="Add, test and remove applications")
    asub = sp.add_subparsers(dest="action", required=True)
    a = asub.add_parser("search", help="Search the winget catalog")
    a.add_argument("query", nargs="+")
    a.add_argument("--limit", type=int, default=25)
    a = asub.add_parser("add", help="Add an application from winget or a manifest file")
    a.add_argument("winget_id", nargs="?")
    a.add_argument("--file", help="Manifest YAML file")
    a.add_argument("--category")
    a.add_argument("--arch", default="x64", choices=["x64", "x86", "arm64"])
    a.add_argument("--check", action="store_true", help="Download the application now")
    a.add_argument("--replace", action="store_true", help="Overwrite an existing application")
    a.add_argument("--yes", "-y", action="store_true", help="Do not ask for confirmation")
    a = asub.add_parser("test", help="Preview what would be downloaded (nothing is saved)")
    a.add_argument("winget_id", nargs="?")
    a.add_argument("--file")
    a.add_argument("--id", dest="app_id", help="An application already in the repository")
    a = asub.add_parser("template", help="Print a manifest template")
    a.add_argument("type", choices=["winget", "github", "web", "json", "url", "multi", "adobe", "manual"])
    a = asub.add_parser("create", help="Create a manual application (installers are uploaded)")
    a.add_argument("app_id")
    a.add_argument("--name", required=True)
    a.add_argument("--publisher")
    a.add_argument("--category")
    a.add_argument("--description")
    a.add_argument("--homepage")
    a.add_argument("--type", dest="installer_type", help="msi, inno, nullsoft, burn, exe, msix ...")
    a.add_argument("--args", dest="install_args", help="Silent install arguments (required for type exe)")
    a.add_argument("--uninstall", dest="uninstall_command", help="Silent uninstall command")
    a.add_argument("--setup-file", help="For .zip installers: the file to run inside the archive")
    a.add_argument("--detect", dest="display_name", help="Regex for the Programs and Features name")
    a.add_argument("--installer", help="Upload this installer as the first version")
    a.add_argument("--version", dest="version", help="Version of --installer (read from MSI files if omitted)")
    a = asub.add_parser("import", help="Add an installer file as a version of an application")
    a.add_argument("app_id")
    a.add_argument("file")
    a.add_argument("--version", dest="version", help="Version (read from MSI files if omitted)")
    a.add_argument("--replace", action="store_true", help="Replace the version if it exists")
    a = asub.add_parser("add-catalog", help="Add the applications that ship with AppDepot (server/manifests)")
    a.add_argument("ids", nargs="*", metavar="APP_ID", help="Only these applications (default: all)")
    a.add_argument("--from", dest="source_dir", help="Take the manifests from this folder instead")
    a.add_argument("--overwrite", action="store_true",
                   help="Replace installed manifests that differ (the old file is kept as .bak)")
    a.add_argument("--check", action="store_true", help="Download the added applications now")
    a.add_argument("--dry-run", action="store_true", help="Only show what would change")
    a = asub.add_parser("remove", help="Remove an application")
    a.add_argument("app_id")
    a.add_argument("--delete-files", action="store_true")
    a.add_argument("--yes", "-y", action="store_true")

    args = p.parse_args(argv)

    if args.cmd == "app" and args.action == "template":
        from .onboarding import TEMPLATES
        print(TEMPLATES[args.type], end="")
        return 0

    if args.cmd == "validate":
        from .manifest import load_manifest_file
        ok = True
        for f in args.files:
            try:
                m = load_manifest_file(Path(f))
                print(f"OK     {f} ({m['id']})")
            except Exception as exc:  # noqa: BLE001
                ok = False
                print(f"ERROR  {exc}")
        return 0 if ok else 1

    if args.cmd == "verify-package":
        from .intunewin import read_intunewin
        xml, content = read_intunewin(Path(args.file))
        print(xml)
        print(f"OK - MAC and SHA-256 digest verified, {len(content):,} bytes of content")
        return 0

    config = load_config(args.config)
    setup_logging(config)
    ctx = build_context(config)

    if args.cmd == "serve":
        import uvicorn
        from .api import create_app

        if not args.no_sync:
            res = ctx.sync()
            for err in res["errors"]:
                print(f"Manifest error: {err}", file=sys.stderr)
        srv = config.section("server")
        uvicorn.run(create_app(ctx), host=args.host or srv["host"], port=args.port or int(srv["port"]),
                    log_level=str(config.section("logging").get("level", "info")).lower())
        return 0

    if args.cmd == "sync":
        res = ctx.sync()
        print(json.dumps(res, indent=2))
        return 1 if res["errors"] else 0

    if args.cmd == "check":
        ids = args.app_ids or ctx.updater.enabled_app_ids()
        results = ctx.updater.check_many(ids, force=args.force)
        print(_table([[r.app_id, r.status, r.version or "", r.message[:80]] for r in results],
                     ["Application", "Status", "Version", "Message"]))
        return 1 if any(r.status == "failed" for r in results) else 0

    if args.cmd == "list":
        with ctx.db.session() as s:
            apps = s.scalars(select(Application).order_by(Application.app_id)).all()
            rows = [[a.app_id, a.name, a.latest_version or "-", a.source_type,
                     a.effective_schedule or "global", a.last_check_status or "-",
                     "yes" if a.enabled else "no"] for a in apps]
        print(_table(rows, ["Id", "Name", "Latest", "Source", "Schedule", "Last check", "Enabled"]))
        return 0

    if args.cmd == "versions":
        with ctx.db.session() as s:
            app = ctx.db.get_app(s, args.app_id)
            if app is None:
                print(f"Unknown application {args.app_id}", file=sys.stderr)
                return 1
            vs = [v for v in app.versions if args.all or v.status == "available"]
            rows = [[v.version, v.status, "*" if v.is_latest else "", v.filename, v.installer_type,
                     f"{v.size_bytes / 1048576:.1f} MB", f"{v.downloaded_at:%Y-%m-%d %H:%M}",
                     v.intune_status or "-"] for v in sort_versions(vs, key=lambda v: v.version)]
        print(_table(rows, ["Version", "Status", "Latest", "File", "Type", "Size", "Downloaded", "Intune"]))
        return 0

    if args.cmd == "schedule":
        if args.action == "global":
            ctx.scheduler.set_global_schedule(args.cron)
        elif args.action == "app":
            ctx.scheduler.set_app_schedule(args.app_id, args.cron)
        else:
            ctx.scheduler.reload()
        print(f"Global schedule: {ctx.scheduler.global_schedule}")
        with ctx.db.session() as s:
            for a in s.scalars(select(Application).order_by(Application.app_id)):
                if a.effective_schedule:
                    print(f"  {a.app_id}: {a.effective_schedule}")
        print("A running server applies schedule changes within a minute.")
        return 0

    if args.cmd == "repackage":
        print(json.dumps(ctx.updater.repackage(args.app_id, args.version), indent=2))
        return 0

    if args.cmd == "purge":
        ids = [args.app_id] if args.app_id else ctx.updater.enabled_app_ids()
        for aid in ids:
            purged = ctx.updater.apply_retention(aid)
            if purged:
                print(f"{aid}: purged {', '.join(purged)}")
        return 0

    if args.cmd == "app":
        return _app_command(ctx, args)

    if args.cmd == "events":
        with ctx.db.session() as s:
            q = select(Event).order_by(Event.id.desc()).limit(args.limit)
            if args.app:
                q = q.where(Event.app_id == args.app)
            for e in reversed(list(s.scalars(q))):
                print(f"{e.timestamp:%Y-%m-%d %H:%M:%S}  {e.level:<5}  {e.event:<9} "
                      f"{(e.app_id or ''):<28} {e.message}")
        return 0

    return 1


def _print_preview(pv: dict) -> None:
    print(f"\n{pv['id']}: latest version {pv['latest_version'] or '?'}")
    print(f"  {pv['note']}")
    print(f"  MSI available: {'yes' if pv['msi_available'] else 'no'}")
    if pv["candidates"]:
        print(_table([[("*" if i == 0 else ""), c["version"] or "?", c["type"], f"{c['source']} #{c['source_index']}",
                       (c["filename"] or "")[:60]] for i, c in enumerate(pv["candidates"])],
                     ["", "Version", "Type", "Source", "File"]))
    for e in pv["errors"]:
        print(f"  ! {e}")


def _confirm(question: str, assume_yes: bool) -> bool:
    if assume_yes:
        return True
    return input(f"{question} [y/N] ").strip().lower() in ("y", "yes")


def _app_command(ctx, args) -> int:
    import yaml

    from .manifest import ManifestError, export_manifest, load_manifest_file
    from .onboarding import (
        OnboardingError,
        WingetCatalog,
        manifest_from_winget,
        preview,
        remove_application,
        save_application,
    )

    try:
        if args.action == "search":
            results = WingetCatalog(ctx.config).search(" ".join(args.query), args.limit)
            with ctx.db.session() as s:
                known = {a.lower() for a in s.scalars(select(Application.app_id))}
            print(_table([[r["id"], r.get("name") or "", r.get("version") or "",
                           "yes" if r["id"].lower() in known else ""] for r in results],
                         ["Winget id", "Name", "Version", "In repository"]))
            print("\nAdd one with: appdepot-server app add <Winget id>")
            return 0

        if args.action in ("add", "test"):
            info = None
            if getattr(args, "app_id", None):
                with ctx.db.session() as s:
                    app = ctx.db.get_app(s, args.app_id)
                    if app is None:
                        print(f"Unknown application {args.app_id}", file=sys.stderr)
                        return 1
                    manifest = export_manifest(app)
            elif args.file:
                manifest = load_manifest_file(Path(args.file))
            elif args.winget_id:
                manifest, info = manifest_from_winget(ctx.config, args.winget_id,
                                                      getattr(args, "category", None),
                                                      getattr(args, "arch", "x64"))
            else:
                print("Give a winget id, --file or --id", file=sys.stderr)
                return 2
            if args.action == "add" and args.category:
                manifest["category"] = args.category
            pv = preview(ctx.config, manifest)
            if info:
                print(f"winget installers for {manifest['source']['architecture']}: "
                      f"{', '.join(info['installer_types']) or 'none'}")
                if info["msi_other_architecture"]:
                    print("  note: winget has an MSI only for another architecture")
            _print_preview(pv)
            if args.action == "test":
                print("\nManifest:\n" + yaml.safe_dump(manifest, sort_keys=False, allow_unicode=True))
                return 0 if pv["ok"] else 1
            print("\n" + yaml.safe_dump(manifest, sort_keys=False, allow_unicode=True))
            if not pv["ok"]:
                print("Warning: no installer could be found with this manifest.")
            if not _confirm(f"Add {manifest['id']} to the repository?", args.yes):
                return 1
            result = save_application(ctx.config, ctx.db, manifest, replace=args.replace,
                                      added_by="appdepot-server app add")
            ctx.scheduler.bump_revision()
            print(f"Added {result['id']} -> {result['manifest_path']}")
            if args.check:
                r = ctx.updater.check_app(result["id"])
                print(f"{r.status}: {r.version or ''} {r.message}")
                return 1 if r.status == "failed" else 0
            print(f"Download it now with: appdepot-server check {result['id']}")
            return 0

        if args.action == "create":
            installer = {k: v for k, v in {"type": args.installer_type, "install_args": args.install_args,
                                           "uninstall_command": args.uninstall_command,
                                           "setup_file": args.setup_file}.items() if v}
            manifest = {k: v for k, v in {
                "id": args.app_id, "name": args.name, "publisher": args.publisher,
                "category": args.category, "description": args.description, "homepage": args.homepage,
                "source": {"type": "manual"}, "installer": installer or None,
                "detection": {"display_name": args.display_name} if args.display_name else None,
            }.items() if v}
            result = save_application(ctx.config, ctx.db, manifest, added_by="appdepot-server app create")
            ctx.scheduler.bump_revision()
            print(f"Created {result['id']} -> {result['manifest_path']}")
            if args.installer:
                r = ctx.updater.import_installer(result["id"], Path(args.installer), version=args.version,
                                                 source_label="import")
                print(f"{r.status}: {r.version} {r.message}")
            return 0

        if args.action == "add-catalog":
            from .onboarding import add_catalog
            res = add_catalog(ctx.config, ctx.db, source_dir=Path(args.source_dir) if args.source_dir else None,
                              ids=args.ids or None, overwrite=args.overwrite, dry_run=args.dry_run)
            labels = {"added": "Added", "updated": "Updated (old file saved as .bak)", "unchanged": "Already up to date",
                      "kept": "Kept your version (differs; use --overwrite to replace)",
                      "skipped_removed": "Skipped, removed earlier (name it to add it back)", "errors": "Errors"}
            for key, label in labels.items():
                if res[key]:
                    print(f"{label} ({len(res[key])}):")
                    for item in res[key]:
                        print(f"  {item}")
            if args.dry_run:
                print("Dry run - nothing was changed.")
                return 0
            ctx.scheduler.bump_revision()
            changed = res["added"] + res["updated"]
            if args.check and changed:
                enabled = set(ctx.updater.enabled_app_ids())
                todo = [i for i in changed if i in enabled]
                results = ctx.updater.check_many(todo)
                print(_table([[r.app_id, r.status, r.version or "", r.message[:80]] for r in results],
                             ["Application", "Status", "Version", "Message"]))
            elif changed:
                print("Download them now with: appdepot-server check   (or wait for the schedule)")
            return 1 if res["errors"] else 0

        if args.action == "import":
            r = ctx.updater.import_installer(args.app_id, Path(args.file), version=args.version,
                                             replace=args.replace, source_label="import")
            print(f"{r.status}: {r.version} {r.message}")
            return 0

        if args.action == "remove":
            if not _confirm(f"Remove {args.app_id}{' and delete its files' if args.delete_files else ''}?",
                            args.yes):
                return 1
            result = remove_application(ctx.db, ctx.repo, args.app_id, args.delete_files)
            ctx.scheduler.bump_revision()
            print(f"Removed {result['id']}" + (f"; manifest retired to {result['manifest_retired_to']}"
                                              if result["manifest_retired_to"] else ""))
            return 0
    except (OnboardingError, ManifestError, KeyError, ValueError, FileNotFoundError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
