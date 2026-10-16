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

    args = p.parse_args(argv)

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


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
