# Packaging Motionity

Three distribution targets share one source tree (`src/`, a plain static app):

| Target | Output | Build host |
| --- | --- | --- |
| Desktop | `Motionity Setup 1.0.0.exe`, `Motionity-1.0.0-x64.AppImage`, `.flatpak` | Windows for `.exe`, Linux (or WSL2) for AppImage/Flatpak |
| Container | `motionity:latest`, ~86 MB on disk / ~57 MB pulled | any Docker host |
| Bare metal | `src/` behind Node, nginx or Caddy | any |

## 0. One prerequisite for every target: vendor the assets

```bash
npm install          # only needed for the desktop builds
npm run vendor       # ~20 MB, writes src/vendor/ (gitignored)
```

`index.html` used to pull jQuery, fabric.js, lottie, pickr, selection-js, the
WebFont loader and Inter from five different CDNs. `scripts/vendor.mjs`
downloads all of them plus the 18.5 MB asm.js ffmpeg build into `src/vendor/`
and the app now references only those local copies. Without this step the page
loads but every script tag 404s.

The Docker build runs the vendor step inside the image, so it is the one target
where you can skip it locally.

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

**AppImage: yes.** electron-builder produces the squashfs itself, so no FUSE is
needed at build time. To *run* the result inside WSL you need `libfuse2`
(or `./Motionity-1.0.0-x64.AppImage --appimage-extract-and-run`), and WSLg on
Windows 11 gives you the GUI.

**Flatpak: technically yes, practically annoying.** `flatpak-builder` runs under
WSL2 (the kernel has the user namespaces and `/dev/fuse` that bubblewrap needs),
but you must install the runtimes by hand first and there is no
`xdg-desktop-portal` to fall back on. If it fights you, build it in a Linux
container instead — it is the same command with fewer moving parts.

**`.exe`: no.** Build it on the Windows side. Cross-building NSIS from Linux
needs Wine and rules out signing.

This machine currently has no WSL distro other than `docker-desktop`, so the
Linux targets have not been run here. Setup, from PowerShell:

```powershell
wsl --install -d Ubuntu
```

Then inside Ubuntu:

```bash
sudo apt update
sudo apt install -y nodejs npm libfuse2            # AppImage
sudo apt install -y flatpak flatpak-builder elfutils  # Flatpak
flatpak remote-add --if-not-exists --user flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub \
  org.freedesktop.Platform//23.08 \
  org.freedesktop.Sdk//23.08 \
  org.electronjs.Electron2.BaseApp//23.08

cd /mnt/c/Users/<you>/git\ azuze/motionity-2
npm install
npm run dist:linux
```

Note that building on `/mnt/c` is slow. Copying the tree into the WSL
filesystem (`~/motionity`) is several times faster.

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
# -18.5 MB: MP4/GIF export fetches ffmpeg from archive.org on first use
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
