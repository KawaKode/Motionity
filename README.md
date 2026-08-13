# Motionity
### Demo available here : [motionity.kawa.zip](https://motionity.kawa.zip/)
Web-based motion graphics editor with keyframing, masking, filters and text animations.

This is a fork of the original [Motionity](https://github.com/alyssaxuu/motionity) by [@alyssaxuu](https://github.com/alyssaxuu), with bug fixes and enhancements.

## Quick Start

**Web (localhost only):**
```bash
npm install
npm run vendor
npm start  # http://127.0.0.1:8080
```

**Desktop:**
```bash
npm install
npm run vendor
npm run dev  # Electron app
```

**Docker:**
```bash
npm run docker:build
npm run docker:run  # http://localhost:8080
```

Full build instructions (Windows installers, Linux AppImage/Flatpak) in [PACKAGING.md](PACKAGING.md).

## Notes

- `ffmpeg.wasm` is vendored; `npm install` + `npm run vendor` are required
- WebCodecs and IndexedDB only work in secure context (`http://localhost` OK, plain HTTP over LAN is not)
- Serve over TLS for remote access
