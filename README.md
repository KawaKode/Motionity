# Motionity

This is a fork of the original project aiming to fix issues and add features.

## Running it

```bash
npm run vendor   # downloads the third-party libraries into src/vendor/
npm start        # http://127.0.0.1:8080
```

Three packaged distributions are available — desktop (Windows `.exe`, Linux
AppImage and Flatpak), a Docker image, and a bare-metal install. Build
instructions for all of them are in [PACKAGING.md](PACKAGING.md).

```bash
npm run dev            # desktop app from source
npm run dist:win       # Windows installer + portable exe
npm run dist:linux     # AppImage + Flatpak
npm run docker:build   # container image
```

## Releasing

```powershell
./scripts/build-release.ps1                 # installers + SHA256SUMS.txt in dist/
./scripts/publish.ps1 -PublishRelease       # + image push and Gitea release upload
```

`build-release.ps1` needs no credentials. `publish.ps1` needs a Gitea token with
package read/write (image push) and `write:repository` (release upload), read
from `$env:GITEA_TOKEN` or prompted for. `-BinariesOnly -NoBinaryBuild` retries a
failed upload without rebuilding.

One rule applies to every target: browsers expose WebCodecs (the fast exporter)
and IndexedDB (project saving) only in a secure context. `http://localhost`
qualifies; a plain-HTTP LAN address does not. Serve it over TLS anywhere else.
