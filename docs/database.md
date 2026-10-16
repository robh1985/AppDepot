# Database schema

Created automatically on first start (SQLAlchemy). Columns added by newer AppDepot versions are
added to an existing database automatically at startup. Every change the server makes — a check,
download, packaging step, purge, schedule or manifest change — updates these tables.

## `applications` — one row per application

| Column | Purpose |
|---|---|
| `app_id`, `name`, `publisher`, `description`, `homepage`, `license`, `category`, `tags` | Catalog information |
| `source_type`, `source_config` | Where new versions are found (manifest `source`; `multi` + a list for `sources`) |
| `preferred_types` | Per-app installer preference (`NULL` = server default, MSI first) |
| `extra` | Further installer options: `setup_file`, `signer`, `update_with` |
| `source_state` | Source bookkeeping, e.g. last ETag for `url` sources |
| `installer_type`, `install_args`, `uninstall_command`, `uninstall_args`, `architecture`, `scope`, `upgrade_behavior`, `success_exit_codes` | Silent install settings from the manifest |
| `detection` | Display-name / publisher regex and product code for clients |
| `schedule` | Schedule from the manifest (`NULL` = global, `manual`, or cron) |
| `schedule_override` | Schedule set through API/CLI; wins over `schedule` |
| `retain_versions`, `enabled` | Per-app retention and on/off |
| **`latest_version`** | Latest version available in the repository |
| `last_checked_at`, `last_updated_at`, `last_check_status`, `last_error` | Result of the most recent check |
| `manifest_path`, `manifest_hash`, `created_at`, `updated_at` | Housekeeping |

## `app_versions` — one row per downloaded version

| Column | Purpose |
|---|---|
| `application_id`, **`version`**, `status` (`available` / `purged`), `is_latest` | Available versions (purged rows keep history) |
| `filename`, `setup_path`, `relative_path`, `local_path`, **`unc_path`** | **Location** of the installer (server path and domain share path) |
| `sha256`, `size_bytes`, `source_url`, `source_type`, `release_notes_url` | Integrity and provenance (which source supplied the file) |
| `installer_type`, `architecture`, `scope` | Installer technology |
| `install_executable`, `install_arguments`, **`install_command`** | **Silent install** information |
| `uninstall_executable`, `uninstall_arguments`, `uninstall_command` | Silent uninstall |
| `source_silent_args`, `source_custom_args` | Switches published by the source (winget) |
| `product_code`, `upgrade_code`, `msi_info` | MSI properties; for patches `msi_info.TargetProductCodes` |
| `intunewin_relative_path`, `intune_info_relative_path`, `intune_detection_relative_path`, `intune_status`, `intune_error` | Intune artefacts |
| **`downloaded_at`**, `purged_at` | **Download date** and removal date |

## `events` — audit log

`timestamp`, `app_id`, `version`, `level` (`info`/`error`), `event` (`check`, `download`,
`update`, `package`, `purge`, `schedule`, `manifest`, `server`, `error`), `message`, `details` (JSON).

## `settings`

Key/value store: `global_schedule`, `schedule_revision` (signals schedule changes to a running
server).

## Example queries

```sql
-- Latest version and share path of every application
SELECT a.app_id, a.latest_version, v.unc_path, v.install_command, v.downloaded_at
FROM applications a JOIN app_versions v ON v.application_id = a.id AND v.is_latest;

-- Applications whose last check failed
SELECT app_id, last_checked_at, last_error FROM applications WHERE last_check_status = 'failed';

-- Everything downloaded in the last 7 days
SELECT a.app_id, v.version, v.downloaded_at FROM app_versions v
JOIN applications a ON a.id = v.application_id
WHERE v.downloaded_at > datetime('now', '-7 days') ORDER BY v.downloaded_at DESC;
```
