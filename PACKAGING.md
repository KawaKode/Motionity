# Packaging Motionity

Three distribution targets share one source tree (`src/`, a plain static app):

| Target | Output | Build host |
| --- | --- | --- |
| Desktop | `Motionity Setup 1.0.0.exe`, `Motionity-1.0.0-x64.AppImage`, `.flatpak` | Linux or WSL2 builds all of them; Windows builds only the `.exe` targets |
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

npm run dist:linux:wsl          # from Windows: Linux bundles, built in WSL
npm run dist:win:wsl            # from Windows: .exe targets, built and left in WSL
npm run dist:win:wsl:portable   # same, portable only (needs no Wine in the distro)
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

1. **Build the Windows targets in WSL**, where the agent cannot see the files at
   all — `npm run dist:win:wsl`, covered in [its own section](#can-the-exe-be-built-in-wsl-too)
   below. Needs no admin rights on the Windows side.
2. Exclude the repository's `dist/` directory in the endpoint protection agent.
3. Build on a machine or CI runner without that agent.
4. Ship `dist/win-unpacked/` — `electron-builder --win dir` is unaffected.

The same agent can also quarantine the *finished* unsigned `.exe` on write, not
just lock it during the build. That is what `-KeepInWsl` is for: the artifact
stays in the distro and is uploaded to the release from there, so it never
crosses onto NTFS.

### Running `npm run dev` from a VS Code terminal

VS Code exports `ELECTRON_RUN_AS_NODE=1`, which turns the `electron` binary into
plain Node and leaves the `electron` module empty. `main.js` detects this and
prints a message. Fix it in the shell:

```bash
env -u ELECTRON_RUN_AS_NODE npm run dev     # bash
$env:ELECTRON_RUN_AS_NODE=$null; npm run dev  # PowerShell
```

### Is WSL enough for AppImage and Flatpak?

Yes, and `build-release.ps1 -UseWsl` does it for you from Windows (`-WinInWsl`
moves the `.exe` targets there too — see [below](#can-the-exe-be-built-in-wsl-too)):

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
- `-UseWsl` delegates only `linux-appimage` and `linux-flatpak`; add `-WinInWsl`
  to send `win` / `win-nsis` / `win-portable` as well. On a Linux host, or with no
  target selected for WSL, both warn and change nothing;
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

**`.exe`: yes** — see the next section. It is opt-in (`-WinInWsl`) because Windows
builds those targets natively too; the reason to move them is the endpoint agent
described above, not portability.

One-time distro setup, from PowerShell:

```powershell
wsl --install -d Ubuntu
```

Then inside Ubuntu:

```bash
sudo apt update
sudo apt install -y nodejs npm libfuse2               # AppImage (libfuse2 only to run it)
sudo apt install -y flatpak flatpak-builder elfutils  # Flatpak
sudo dpkg --add-architecture i386 && sudo apt update  # only for the NSIS .exe (see below)
sudo apt install -y wine                              #   "     "
flatpak remote-add --if-not-exists --user flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub \
  org.freedesktop.Platform//23.08 \
  org.freedesktop.Sdk//23.08 \
  org.electronjs.Electron2.BaseApp//23.08
```

### Can the `.exe` be built in WSL too?

Yes, and it is the way out of the "Access denied" failure above, since nothing
unsigned is written to a Windows filesystem.

```powershell
npm run dist:win:wsl                # NSIS + portable, built and left in WSL — build only
npm run dist:win:wsl:portable       # portable only — no Wine, no sudo needed
npm run release:binaries:wsl        # same .exe targets, then uploaded to the Gitea release
npm run release:wsl                 # everything incl. Linux + the container image push

./scripts/build-release.ps1 -WinInWsl              # copy the .exe back into dist/
./scripts/build-release.ps1 -WinInWsl -KeepInWsl   # leave it in the distro
```

Verified on this machine (`Ubuntu`, WSL2 kernel 6.18): a 138 MB portable
`motionity-v2.0.2-win-x64-portable.exe`, `PE32 executable for MS Windows (GUI),
Nullsoft Installer self-extracting archive`, with the icon and version resources
applied, byte-identical whether read in the distro or after the copy back into
`dist/`. The NSIS installer needs the wine setup below and has not been built this
way yet.

**What each Windows target needs on the Linux side.**

| Target | Wine? | Why |
| --- | --- | --- |
| `-Targets win-portable` | no | electron-builder's NSIS bundle ships a native Linux `makensis`, and the exe's icon and version strings are written by the `resedit` JS package, not by `rcedit.exe`. |
| `-Targets win-nsis` | **yes, 32-bit capable** | NSIS builds its uninstaller by *executing* the installer stub it has just linked, so a Windows PE has to run. |
| `-Targets win` | yes | Both of the above in one packaging pass. |

**Why the NSIS target cannot avoid Wine.** electron-builder links the installer
once with `BUILD_UNINSTALLER` defined, runs it to produce `uninstaller.exe`, then
links the real installer, which *embeds that file*:
`templates/nsis/include/installer.nsh` does
`File "/oname=${UNINSTALL_FILENAME}" "${UNINSTALLER_OUT_FILE}"`. There is no
option to skip the first pass. The stub it executes is **PE32/i386** even for an
x64 app, so a 64-bit-only Wine is not enough either:

```bash
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install -y wine
```

`build-release.ps1` probes for a usable wine before packaging (missing or broken
wine is an error; a wine with no `i386-windows` directory is a warning), because
the failure otherwise arrives ~200 MB into the build naming ntdll rather than the
missing package.

**Do not use `toolsets.wine=1.0.1` for this.** electron-builder can download its
own Wine 11 bundle instead of using the distro's, which looks like it would avoid
the apt install, and it does download and verify cleanly. Its Linux build is
unusable: `lib/wine/x86_64-unix/` only, with no `*-windows` PE builtin directory
and no `syswow64`, so it fails after the app is already packaged with

```
wine: failed to load .../wine-11.0-linux-x86_64-*/lib/wine/x86_64-unix/ntdll.dll error c0000135
0024:err:environ:run_wineboot failed to start wineboot 1
```

`c0000135` is `STATUS_DLL_NOT_FOUND`. Leaving `toolsets.wine` unset is what makes
electron-builder use the distro's `wine` on Linux, which is the working path. If
that bundle was already downloaded, `rm -rf ~/.cache/electron-builder/wine@1.0.1`
reclaims it.

If you cannot install anything in the distro, `-Targets win-portable` is a
complete answer: a single self-contained `.exe`, no installer, no Wine, no root.

**Why the build also passes `win.signExecutable=false`.** With no certificate
configured, electron-builder still walks the signing path, and on Linux that
path shells out to `signtool.exe` under Wine *before* discovering there is
nothing to sign — `spawn wine ENOENT`, build over. `signExecutable: false` skips
signing while still applying the icon and version metadata.
(`signAndEditExecutable: false` would drop those too, which is not wanted.) Both
overrides are passed on the command line for the WSL build only, so a native
Windows build behaves exactly as before. These releases are unsigned either way.

**Uploading straight from the distro.** With `-KeepInWsl`, `build-release.ps1`
writes `dist/wsl-artifacts.json` naming the distro, the staging directory and the
files it deliberately did not copy back. `publish.ps1` reads it and runs the
`curl` upload *inside* the distro for those files. The Gitea token reaches WSL
through `WSLENV` and is written to a `mktemp` config file by bash — it is in
neither `wsl.exe`'s arguments nor the distro's process table. `SHA256SUMS.txt`
still covers every artifact, hashes for the staged ones coming from `sha256sum`
in the distro; it is text, so nothing objects to it landing in `dist/`.

Two things to know when writing more of this plumbing:

- These `.ps1` files are stored with **CRLF**, so a multi-line here-string handed
  to `bash -lc` arrives with a `\r` on every line (`set: - : invalid option`,
  `cd: $'/path\r': No such file or directory`). `ConvertTo-BashScript` strips it.
- Never combine `set -e` with an explicit `exit 0` under `bash -lc`. A login
  shell sources `~/.bash_logout`, Ubuntu's ends in a `clear_console` test that
  fails with no tty, and errexit promotes that to the shell's exit status:
  `wsl -e bash -lc 'set -e; exit 0'` returns **1**. `-l` has to stay, because
  node from nvm or fnm is only on the login `PATH`.

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
