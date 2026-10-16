# AppDepot server

The repository server: finds new application versions on the internet, stores the last
versions of each application, packages them for Intune and serves the catalog to clients.

See the [main README](../README.md) and [docs/server.md](../docs/server.md).

```
pip install .
appdepot-server --config appdepot.yaml serve
```
