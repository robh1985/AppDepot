# REST API

Base URL: `http://<server>:8080/api/v1`. Interactive documentation (OpenAPI/Swagger) is served
at `http://<server>:8080/docs`.

Read endpoints are open to the network. Endpoints marked **admin** need the `X-Api-Key` header
(or, if no key is configured, a request from the server itself).

## Catalog

| Method & path | Description |
|---|---|
| `GET /health` | Server version, application count, UNC root, running checks |
| `GET /apps?search=&category=&include_empty=false` | Catalog (apps with at least one stored version unless `include_empty`) |
| `GET /apps/{id}` | Application details incl. `source`, `next_check`, `version_details`, `manifest` |
| `GET /apps/{id}/versions?include_purged=false` | Stored versions, newest first |
| `GET /apps/{id}/versions/{version\|latest}` | One version (everything needed to install it) |
| `POST /updates` | Body `{"installed":[{"id":"7zip.7zip","version":"24.07"}]}` → which have updates |
| `GET /categories` | Category names |
| `GET /events?app_id=&level=&limit=100` | Event log, newest first |
| `GET /schedule` | Global schedule and all scheduled jobs with next run time |
| `GET /files/{path}` | Download a repository file (installer, `.intunewin`, sheet, detection script) |

### Version object

```json
{
  "app_id": "Mozilla.Firefox",
  "version": "131.0.3",
  "status": "available",
  "is_latest": true,
  "filename": "Firefox_Setup_131.0.3.msi",
  "installer_type": "msi",
  "architecture": "x64",
  "scope": "machine",
  "sha256": "5e1c…",
  "size_bytes": 64352256,
  "downloaded_at": "2026-10-16T03:00:12Z",
  "source_url": "https://download-installer.cdn.mozilla.net/…",
  "product_code": "{1294A4C5-…}",
  "location": {
    "relative": "Mozilla.Firefox/131.0.3/installer/Firefox_Setup_131.0.3.msi",
    "unc": "\\\\appdepot\\AppDepot\\Mozilla.Firefox\\131.0.3\\installer\\Firefox_Setup_131.0.3.msi",
    "http": "http://appdepot:8080/files/Mozilla.Firefox/131.0.3/installer/Firefox_Setup_131.0.3.msi"
  },
  "install":   {"executable": "msiexec.exe", "arguments": "/i \"Firefox_Setup_131.0.3.msi\" /qn /norestart …", "command": "msiexec.exe /i …"},
  "uninstall": {"executable": "msiexec.exe", "arguments": "/x {1294A4C5-…} /qn /norestart", "command": "msiexec.exe /x …"},
  "success_exit_codes": [0, 1641, 1707, 3010],
  "reboot_exit_codes": [3010, 1641],
  "source_type": "winget",
  "upgrade_behavior": "install",
  "intune": {
    "status": "ok", "error": null,
    "package": {"unc": "…\\intune\\Mozilla.Firefox_131.0.3.intunewin", "http": "…"},
    "info": {"unc": "…\\intune\\Mozilla.Firefox_131.0.3.intune.txt", "http": "…"},
    "detection_script": {"unc": "…\\intune\\Mozilla.Firefox_131.0.3.detect.ps1", "http": "…"}
  }
}
```

## Administration (admin)

| Method & path | Description |
|---|---|
| `POST /apps?replace=false&check=false` | Add an application. Body: manifest as JSON (same schema as YAML). Writes the manifest file; `409` if it exists unless `replace=true`; `check=true` downloads it now |
| `POST /apps/yaml?replace=&check=` | Same, with a YAML manifest as the raw body |
| `POST /apps/preview` | Preview a manifest (JSON body): newest version, every candidate installer, `msi_available`, the selected installer and why. Nothing is saved or downloaded |
| `POST /apps/preview/yaml` | Same for a YAML body |
| `POST /apps/{id}/preview` | Preview an application already in the repository |
| `GET /winget/search?q=&limit=25` | Search the winget catalog; each result has `in_repository` |
| `GET /winget/packages/{wingetId}?category=&architecture=x64` | Generate a manifest from winget, with `info` (installer types, `msi_available`) and `preview` |
| `GET /templates/{type}` | Manifest template: winget, github, web, json, url, multi |
| `DELETE /apps/{id}?delete_files=false` | Remove an application (optionally its files). The manifest file is renamed to `*.removed` |
| `POST /apps/{id}/check?force=false&wait=false` | Check now; `wait=true` returns the result |
| `POST /check` | Body `{"app_ids": [...] or null, "force": false}` — queue checks |
| `PUT /schedule` | Body `{"schedule": "0 3 * * *"}` — global schedule |
| `PUT /apps/{id}/schedule` | Body `{"schedule": "0 */6 * * *" \| "manual" \| null}` |
| `POST /apps/{id}/versions/{version}/repackage` | Rebuild Intune package and commands |
| `DELETE /apps/{id}/versions/{version}` | Delete a stored version |
| `POST /manifests/sync` | Reload manifests from disk |

```powershell
Invoke-RestMethod http://appdepot:8080/api/v1/apps/Google.Chrome/check?wait=true -Method Post `
    -Headers @{ 'X-Api-Key' = $key }
```

```bash
curl -X PUT http://appdepot:8080/api/v1/schedule -H "X-Api-Key: $KEY" \
     -H 'Content-Type: application/json' -d '{"schedule":"0 2 * * *"}'
```
