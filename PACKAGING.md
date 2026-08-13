# Packaging Motionity

Three distribution targets share one source tree (`src/`, a plain static app):

| Target | Output | Build host |
| --- | --- | --- |
| Desktop | `Motionity Setup 1.0.0.exe`, `Motionity-1.0.0-x64.AppImage`, `.flatpak` | Windows for `.exe`, Linux (or WSL2) for AppImage/Flatpak |
| Container | `motionity:latest`, ~86 MB on disk / ~57 MB pulled | any Docker host |
| Bare metal | `src/` behind Node, nginx or Caddy | any |

## 0. One prerequisite for every target: vendor the assets

```bash
npm install          # now required for every target, not just the desktop ones
npm run vendor       # ~24 MB, writes src/vendor/ (gitignored)
```

`index.html` used to pull jQuery, fabric.js, lottie, pickr, selection-js, the
WebFont loader and Inter from five different CDNs. `scripts/vendor.mjs`
downloads all of them into `src/vendor/` and the app now references only those
local copies. Without this step the page loads but every script tag 404s.

ffmpeg.wasm is handled differently: `vendor.mjs` **copies** it out of
`node_modules` instead of downloading it, which is why `npm install` is now a
prerequisite everywhere. `package-lock.json` pins those packages by integrity
hash, so the bytes that reach the image are the bytes npm verified. The asm.js
build this replaced was fetched from a public archive.org mirror with no
integrity check of any kind — a changed object there would have executed in the
page unnoticed.

Two consequences worth knowing:

- `@ffmpeg/core-st` is the **single-threaded** core, chosen deliberately. The
  default `@ffmpeg/core` is built with pthreads and needs `SharedArrayBuffer`,
  which requires COOP/COEP cross-origin isolation, which would break the
  Pixabay, Unsplash and Google Fonts requests the editor makes.
- The two `@ffmpeg/*` packages are `dependencies`, not `devDependencies`, so the
  Docker vendor stage can `npm ci --omit=dev` without pulling in electron. That
  makes electron-builder want to bundle them into the asar too, so `build.files`
  excludes `node_modules/**` outright — the packaged app requires nothing but
  `electron` and node builtins, and the copies it loads live in
  `src/vendor/ffmpeg/`.

The Docker build runs `npm ci` and the vendor step inside the image, so it is
the one target where you can skip both locally.

## 1. Desktop — Electron

`electron/main.js` starts the same static server the bare-metal target uses, on
`127.0.0.1` with a random port, and points the window at it.

**This is deliberate, do not "simplify" it to `loadFile()`.** Chromium exposes
WebCodecs (`VideoEncoder`, the fast exporter in `src/js/render.js`) and
IndexedDB (project storage via localbase) only in a secure context. `file://`
is not one; a loopback HTTP origin is. Load the app from `file://` and export
silently falls back to real-time `MediaRecorder` capture and projects stop
saving.

```bash
npm run dev            # run the desktop app from source

npm run dist:win       # NSIS installer + portable .exe -> dist/
npm run dist:appimage  # .AppImage -> dist/
npm run dist:flatpak   # .flatpak  -> dist/
npm run dist:linux     # both Linux targets
```

Each `dist:*` script re-runs `vendor` and regenerates `build/icon.png`
(`scripts/make-icon.cjs` rasterises the logo geometry with zlib only — no
ImageMagick, no sharp).

### Why `desktopName` is `app.motionity.desktop.desktop`

The doubled suffix is correct, do not trim it. Electron reads the **root-level**
`desktopName` from `package.json` and derives the Wayland `app_id` / X11
`WM_CLASS` from it with the `.desktop` suffix stripped, so the value has to be
the desktop *file name*, not the app id. Flatpak in turn installs the entry as
`<appId>.desktop` and nothing can rename it — with `appId`
`app.motionity.desktop`, the file is `app.motionity.desktop.desktop`.

`linux.syncDesktopName: true` makes electron-builder use the same base name for
the AppImage's embedded entry and write a matching `StartupWMClass`. Without the
pair, the build warns

```
electron uses desktopName as app_id / WM_CLASS for window association.
  reason=desktopName is not set in package.json
```

and the running window is not linked to its launcher entry: GNOME shows a
generic icon and a second, unpinnable dock item instead of the installed app.
Changing `appId` means changing `desktopName` in step with it.

### If the NSIS step fails with "Access denied" on `Motionity.exe`

On a locked-down Windows machine the security agent can take an exclusive lock
on the freshly written 214 MB unsigned `dist/win-unpacked/Motionity.exe`, and
the 7-Zip step that builds the installer payload then cannot read it. The
symptom is a build that produces `dist/win-unpacked/` correctly and dies right
after "Archive size":

```
.\Motionity.exe : Accès refusé.
WARNING: Cannot open 2 files
```

The ACL is intact (the owner still has FullControl), so this is a filter
driver, not a permissions problem. Fixes, in order of preference:

1. Exclude the repository's `dist/` directory in the endpoint protection agent.
2. Build on a machine or CI runner without that agent.
3. Ship `dist/win-unpacked/` — `electron-builder --win dir` is unaffected.

### Running `npm run dev` from a VS Code terminal

VS Code exports `ELECTRON_RUN_AS_NODE=1`, which turns the `electron` binary into
plain Node and leaves the `electron` module empty. `main.js` detects this and
prints a message. Fix it in the shell:

```bash
env -u ELECTRON_RUN_AS_NODE npm run dev     # bash
$env:ELECTRON_RUN_AS_NODE=$null; npm run dev  # PowerShell
```

### Is WSL enough for AppImage and Flatpak?

Yes, and `build-release.ps1 -UseWsl` does it for you from Windows:

```powershell
./scripts/build-release.ps1 -UseWsl                       # .exe on Windows, Linux bundles in WSL
./scripts/build-release.ps1 -Targets linux -UseWsl        # Linux bundles only
./scripts/publish.ps1 -Tag v2.0.1 -PublishRelease -UseWsl # same, then attach to the Gitea release
```

Both bundles have been built this way on this machine (`Ubuntu`, WSL2 kernel
6.18): a 172 MB AppImage and a 133 MB Flatpak, checksums verified with
`sha256sum -c`. Under the hood:

- the `npm ci`, `vendor` and icon steps run **once on the Windows side**, and the
  WSL build reads them back through `/mnt/c` — one worktree, no second checkout;
- only `linux-appimage` and `linux-flatpak` are delegated. `-UseWsl` on a Linux
  host, or with no Linux target, warns and changes nothing;
- the distro is the first installed one that is not `docker-desktop`, override
  with `-WslDistro`. `docker-desktop` is skipped deliberately: it is Docker's own
  LinuxKit VM, with no apt and no home to install the flatpak runtimes into, and
  it is usually the *default* distro, so a blind `wsl --` lands there;
- missing tooling fails **before** the build with the apt or `flatpak install`
  line to run, because electron-builder's own error for an absent flatpak ref is
  a bare exit code naming neither the ref nor the remote.

**Why the build stages in `~/.cache/motionity-build` and not in `dist/`.**
electron-builder chmods every file it unpacks from the Electron zip, and `/mnt/c`
is mounted without the `metadata` option, so chmod is refused:

```
⨯ EPERM: operation not permitted, chmod '.../dist/linux-unpacked.tmp/locales/de.pak'
```

The alternative fix is `options = "metadata"` under `[automount]` in
`/etc/wsl.conf` plus a `wsl --shutdown` — a global, sudo-and-reboot change to the
distro. Building into ext4 and copying the two finished bundles back into `dist/`
needs neither, and is faster anyway. Reading `src/` over the mount is fine;
nothing chmods the input. The copy back is `cp -f`, never `cp -p` — preserving
modes means chmod, which is the EPERM being avoided.

**AppImage** needs no extra tooling: electron-builder downloads its own appimage
bundle and writes the squashfs itself, no FUSE at build time. To *run* the result
inside WSL you need `libfuse2` (or
`./motionity-*.AppImage --appimage-extract-and-run`); WSLg gives you the GUI.

**Flatpak** needs `flatpak-builder` and the runtimes installed by hand — the
WSL2 kernel has the user namespaces and `/dev/fuse` that bubblewrap wants, but
there is no `xdg-desktop-portal` to fall back on.

**`.exe`: no.** Build it on the Windows side. Cross-building NSIS from Linux
needs Wine and rules out signing.

One-time distro setup, from PowerShell:

```powershell
wsl --install -d Ubuntu
```

Then inside Ubuntu:

```bash
sudo apt update
sudo apt install -y nodejs npm libfuse2               # AppImage (libfuse2 only to run it)
sudo apt install -y flatpak flatpak-builder elfutils  # Flatpak
flatpak remote-add --if-not-exists --user flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub \
  org.freedesktop.Platform//23.08 \
  org.freedesktop.Sdk//23.08 \
  org.electronjs.Electron2.BaseApp//23.08
```

Those three refs must match `build.flatpak.runtimeVersion` / `baseVersion` in
`package.json`; `build-release.ps1` reads them from there when it checks.

To build inside the distro directly instead — no `-UseWsl`, and faster still,
since `src/` is read locally too:

```bash
git clone <repo> ~/motionity && cd ~/motionity
npm ci && npm run dist:linux
```

`wsl.exe` writes its own listings as UTF-16LE, which PowerShell 5.1 renders as
NUL-interleaved text — `wsl -l -v` can look like it has one distro when it has
two. `$env:WSL_UTF8 = "1"` fixes it.

## 2. Docker

```bash
docker build -t motionity:latest .
docker run --rm -p 8080:8080 motionity:latest
# or: docker compose up --build
```

The runtime image is `static-web-server` (Rust) on Alpine — 9 MB of base image,
no Node, no shell tooling, running as UID 65534. Everything above that is the
app itself: 46 MB of bundled stock media plus 20 MB of vendored libraries.

Two knobs if the size matters more than offline completeness:

```bash
# -23 MB: MP4/GIF export reports itself unavailable (WEBM export is unaffected).
# There is no runtime download to fall back on any more, by design.
docker build --build-arg WITH_FFMPEG=0 -t motionity:slim .

# -33 MB: drop the bundled royalty-free music library (removes the Audio panel
# presets; uploads still work). Add to .dockerignore:
#   src/assets/audio
```

## 3. Bare metal

```bash
npm run vendor
npm start                       # http://127.0.0.1:8080
HOST=0.0.0.0 PORT=3000 npm start
```

`scripts/server.cjs` is dependency-free: correct MIME types, byte ranges (the
audio and video panels seek), no directory listings, path-traversal guard. Node
18+.

For a real install, `deploy/` has a systemd unit plus nginx and Caddy configs
that serve `src/` directly, no Node process involved:

```bash
sudo cp -r . /opt/motionity
sudo cp deploy/motionity.service /etc/systemd/system/
sudo systemctl enable --now motionity
```

## The secure-context rule, once more

Both the container and the bare-metal targets serve plain HTTP. That is fine on
`http://localhost`, which browsers treat as secure. It is **not** fine on a LAN
address or a domain: `VideoEncoder` disappears (export falls back to slow
real-time capture) and IndexedDB is blocked (projects stop saving), with no
error message beyond a console warning.

Anything beyond localhost needs TLS. `deploy/Caddyfile` is the shortest path —
it obtains the certificate itself.

## What still needs the internet

Vendoring makes the editor start and export offline. Three features remain
online by design, and degrade quietly rather than breaking:

1. **Google Fonts** — the font picker loads families through `WebFont.load`,
   and `src/js/init.js` lists them from the Google Fonts API. Offline, text
   falls back to a system font. Only Inter (the UI font) is bundled.
2. **Pixabay** — the Images, Videos and Audio browsers search Pixabay live.
3. **Unsplash** — sample images on the empty-state screen.

MP4 and GIF export used to be a fourth: the encoder came from archive.org at
conversion time. It is now vendored, so export works fully offline.
