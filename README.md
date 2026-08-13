<div align="center">

<img src="src/assets/logo.svg" alt="Motionity" width="72">

# Motionity

**Web-based motion graphics editor** — keyframing, masking, filters, text animations.
A free alternative to After Effects and Canva, running entirely in the browser.

### ▶ [Try the live demo — motionity.kawa.zip](https://motionity.kawa.zip/)

[![Demo](https://img.shields.io/badge/demo-motionity.kawa.zip-6c5ce7?style=flat-square)](https://motionity.kawa.zip/)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Downloads](https://img.shields.io/badge/downloads-releases-2ea44f?style=flat-square)](https://git.azuze.fr/kawa/Motionity/releases)

---

Created by **[Alyssa X](https://github.com/alyssaxuu)** · maintained by **Kawa**

Fork of the original [Motionity](https://github.com/alyssaxuu/motionity), with bug fixes,
vendored (offline-capable) assets, desktop builds and a hardened container image.

</div>

---

## How to run

### Docker (recommended for self-hosting)

```bash
docker compose up -d          # http://localhost:8080
```

Or without compose:

```bash
docker run --rm -p 8080:8080 git.azuze.fr/kawa/motionity:latest
```

Build the image yourself:

```bash
docker build -t motionity:latest .        # ~86 MB on disk
docker build --build-arg WITH_FFMPEG=0 .  # -23 MB, no MP4/GIF export
```

Runtime is [static-web-server](https://github.com/static-web-server/static-web-server) on Alpine — no Node, no shell, runs as UID 65534, `read_only` filesystem.

### Windows app

Grab the installer or the portable build from **[Releases](https://git.azuze.fr/kawa/Motionity/releases)**:

| File | What it is |
| --- | --- |
| `Motionity Setup <ver>.exe` | NSIS installer, per-user, choosable install dir |
| `Motionity-<ver>-x64.exe` | Portable, no install |

Build from source (on Windows):

```bash
npm install
npm run dist:win              # -> dist/
```

### Linux app

From **[Releases](https://git.azuze.fr/kawa/Motionity/releases)**: `Motionity-<ver>-x86_64.AppImage` or the `.flatpak`.

```bash
chmod +x Motionity-*.AppImage && ./Motionity-*.AppImage   # needs libfuse2
flatpak install ./Motionity-*.flatpak                      # or this
```

Build from source (on Linux or WSL2):

```bash
npm install
npm run dist:appimage         # AppImage only
npm run dist:flatpak          # Flatpak only
npm run dist:linux            # both
```

### From source — web

```bash
npm install
npm run vendor                # downloads third-party assets into src/vendor/ (~24 MB)
npm start                     # http://127.0.0.1:8080
```

```bash
HOST=0.0.0.0 PORT=3000 npm start     # bind elsewhere
```

### From source — desktop

```bash
npm install
npm run vendor
npm run dev                   # Electron
```

> In a VS Code terminal, `ELECTRON_RUN_AS_NODE=1` breaks this. Unset it:
> `$env:ELECTRON_RUN_AS_NODE=$null; npm run dev`

### Two things to know

- **`npm run vendor` is mandatory** for every non-Docker target. Without it the page loads but every script 404s. The Docker build runs it inside the image.
- **Secure context required.** WebCodecs (fast export) and IndexedDB (project saving) only exist on `http://localhost` or HTTPS. Over plain HTTP on a LAN address they silently disappear: export falls back to slow real-time capture, projects stop saving. Anything beyond localhost needs TLS — `deploy/Caddyfile` is the shortest path.

Full packaging details, WSL notes and troubleshooting: **[PACKAGING.md](PACKAGING.md)**.

---

## Dependencies

Everything is vendored at build time — no CDN is contacted at runtime.

### Editor core

| Library | Role |
| --- | --- |
| [Fabric.js](https://github.com/fabricjs/fabric.js) | canvas object model, selection, transforms |
| [anime.js](https://github.com/juliangarnier/anime) | keyframe animation engine |
| [lottie-web](https://github.com/airbnb/lottie-web) | Lottie / Bodymovin playback |
| [ffmpeg.wasm](https://github.com/ffmpegwasm/ffmpeg.wasm) | MP4 / GIF export (single-threaded [core](https://github.com/ffmpegwasm/ffmpeg.wasm-core)) |
| [webm-writer-js](https://github.com/thenickdude/webm-writer-js) | WEBM muxing for the WebCodecs exporter |

### UI

| Library | Role |
| --- | --- |
| [jQuery](https://github.com/jquery/jquery) | DOM plumbing |
| [Pickr](https://github.com/simonwep/pickr) | color picker |
| [Selection.js](https://github.com/simonwep/selection) | timeline box-selection |
| [Sortable](https://github.com/SortableJS/Sortable) | layer reordering |
| [jquery-nice-select](https://github.com/hernansartorio/jquery-nice-select) | styled `<select>` |
| range-slider | timeline / property sliders (vendored, no upstream banner) |
| [Localbase](https://github.com/dannyconnell/localbase) | IndexedDB project storage |
| [webfontloader](https://github.com/typekit/webfontloader) | Google Fonts loading |
| [Inter](https://github.com/rsms/inter) | UI typeface |

### Build & runtime

| Package | Role |
| --- | --- |
| [Electron](https://github.com/electron/electron) | desktop shell |
| [electron-builder](https://github.com/electron-userland/electron-builder) | NSIS / AppImage / Flatpak packaging |
| [static-web-server](https://github.com/static-web-server/static-web-server) | container HTTP server |

`scripts/server.cjs` (the `npm start` server) has zero dependencies — Node 18+ builtins only.

### Still online by design

[Google Fonts](https://fonts.google.com/) (font picker), [Pixabay](https://pixabay.com/) (image/video/audio search), [Unsplash](https://unsplash.com/) (empty-state samples). All three degrade quietly when offline; the editor itself starts and exports without a network.

---

## License

[MIT](LICENSE) — same as upstream.
