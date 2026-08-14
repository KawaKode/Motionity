#requires -Version 5.1
<#
.SYNOPSIS
    Build the Motionity desktop installers with electron-builder.

.DESCRIPTION
    Produces, in dist/:

      motionity-<tag>-win-x64-setup.exe        NSIS installer
      motionity-<tag>-win-x64-portable.exe     portable exe
      motionity-<tag>-linux-x86_64.AppImage    AppImage
      motionity-<tag>-linux-x86_64.flatpak     Flatpak bundle
      SHA256SUMS.txt

    The PowerShell equivalent of `npm run dist:win` / `npm run dist:linux`, with
    two differences that matter for a release:

      * every artifact name carries the tag, so publish.ps1 can glob exactly this
        tag's files and never ship a stale one from an earlier build;
      * NSIS and portable get distinct names. package.json's global artifactName
        (`${productName}-${version}-${arch}.${ext}`) resolves to the same file for
        both, so one silently overwrites the other.

    The vendor step runs first: index.html references only src/vendor/, which is
    gitignored, so a package built without it ships an app whose every script tag
    404s.

    Windows builds the .exe targets; AppImage and Flatpak need a Linux host or
    WSL (see PACKAGING.md).

    -UseWsl makes that split automatic: the .exe targets run on Windows, and the
    Linux ones are handed to a WSL distro over /mnt/c, against this same worktree.
    The npm install, the vendor step and the icon all happen once on the Windows
    side and the WSL build reads them through the mount, so the artifacts still
    land in dist/ and the checksum step below sees every one of them.

    -WinInWsl sends the .exe targets to that distro as well. The reason to want
    that is not portability: a locked-down Windows machine's endpoint agent takes an
    exclusive lock on the freshly written unsigned Motionity.exe and the 7-Zip step
    that packs the installer payload then cannot read it (PACKAGING.md has the
    error). Building in the distro's ext4 filesystem is not visible to that agent.
    Signing is the one thing lost, and these builds are unsigned either way — the
    WSL build passes win.signExecutable=false, because the signtool.exe path runs
    under Wine and there is no certificate for it to use.

    What each Windows target needs on the Linux side:

      win-portable  nothing. electron-builder's NSIS bundle ships a native Linux
                    makensis, and rcedit was replaced by the resedit JS package, so
                    the icon and version strings are written without Wine.
      win-nsis      Wine, with 32-bit support, unavoidably. NSIS builds its
                    uninstaller by *executing* the installer stub it has just linked
                    (NsisTarget's computeScriptAndSignUninstaller) because the
                    installer then embeds that uninstaller as a file
                    (templates/nsis/include/installer.nsh: `File "/oname=..."
                    "${UNINSTALLER_OUT_FILE}"`). There is no flag to skip it, and the
                    stub is PE32/i386, so a 64-bit-only Wine cannot run it either.
                    Assert-WslWine checks for a usable one before building.

                    Do NOT reach for toolsets.wine=1.0.1 here. That bundle exists and
                    downloads cleanly, but the Linux build of it is unusable: it ships
                    lib/wine/x86_64-unix only, with no *-windows PE builtin directory
                    and no syswow64, so wine dies with
                      wine: failed to load .../x86_64-unix/ntdll.dll error c0000135
                    after the app has already been packaged. The distro's own wine is
                    the working path.

    "win" is both, in one packaging pass. -Targets win-portable is the way to get a
    usable .exe out of a machine where you cannot apt-install anything.

    -KeepInWsl goes further and never copies the WSL-built artifacts back: they
    stay in the staging directory, and dist/ gets only SHA256SUMS.txt plus
    wsl-artifacts.json naming them. Use it when the agent quarantines the finished
    unsigned .exe on write, not just during the build — publish.ps1 reads that
    manifest and uploads those files to Gitea from inside the distro, so the .exe
    never lands on NTFS at all.

.EXAMPLE
    ./scripts/build-release.ps1
    Build every target at v<package.json version>.

.EXAMPLE
    ./scripts/build-release.ps1 -UseWsl
    Same, with AppImage and Flatpak built in the first non-docker WSL distro.

.EXAMPLE
    ./scripts/build-release.ps1 -Targets win -Tag v1.1.0
    Windows installers only, named v1.1.0.

.EXAMPLE
    ./scripts/build-release.ps1 -Targets win,linux-appimage
    Windows installers plus the Linux AppImage — no Flatpak.

.EXAMPLE
    ./scripts/build-release.ps1 -Targets linux -UseWsl -WslDistro Ubuntu-24.04
    Both Linux bundles, in a named distro.

.EXAMPLE
    ./scripts/build-release.ps1 -WinInWsl
    Every target built in WSL, artifacts copied back into dist/. Nothing unsigned
    is written to NTFS while the build runs.

.EXAMPLE
    ./scripts/build-release.ps1 -WinInWsl -KeepInWsl
    Same, but the artifacts stay in the distro. dist/ gets SHA256SUMS.txt and
    wsl-artifacts.json; publish.ps1 uploads from there.

.EXAMPLE
    ./scripts/build-release.ps1 -Targets win-portable -WinInWsl -KeepInWsl
    The portable .exe only, built and left in WSL. Needs no Wine and no root in the
    distro, and writes nothing to NTFS.

.EXAMPLE
    ./scripts/build-release.ps1 -SkipVendor -SkipDeps
    Reuse src/vendor/ and node_modules as they are — the fast rebuild.
#>
[CmdletBinding()]
param(
    # Platforms to package. "win" is NSIS + portable in one pass, and "win-nsis" /
    # "win-portable" are those two separately — worth having because only the NSIS
    # one needs Wine when built in WSL. "linux-appimage" and "linux-flatpak" are the
    # two Linux bundles, and "linux" is shorthand for both.
    [ValidateSet("win", "win-nsis", "win-portable", "linux", "linux-appimage", "linux-flatpak")]
    [string[]]$Targets = @("win", "linux"),

    # Version used in the artifact names. Defaults to v<package.json version>,
    # because electron-builder stamps that same version into the app itself — a
    # git-describe tag here would disagree with what the installed app reports.
    [string]$Tag,

    # Skip `npm run vendor` (the ~20 MB third-party download into src/vendor/).
    [switch]$SkipVendor,

    # Skip the npm install even when node_modules is missing.
    [switch]$SkipDeps,

    # Build the Linux targets inside WSL instead of warning that they cannot be
    # built on Windows. Ignored on a Linux host, where they build natively.
    [switch]$UseWsl,

    # WSL distro to build in. Defaults to the first installed one that is not
    # docker-desktop.
    [string]$WslDistro,

    # Send the "win" target to WSL too. Implies -UseWsl. Nothing unsigned is then
    # written to NTFS during the build, which is what the endpoint agent reacts to.
    [switch]$WinInWsl,

    # Leave the WSL-built artifacts in the distro instead of copying them into
    # dist/. dist/ still gets SHA256SUMS.txt and wsl-artifacts.json.
    [switch]$KeepInWsl,

    # Remove dist/ before building.
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    # NB: the param is $CmdArgs, not $Args. $Args is an automatic variable in
    # PowerShell; a param of that name never binds the passed array (it stays the
    # function's own empty $args), so `& $Exe @Args` would run the exe with no
    # arguments — e.g. bare `npm`, which just prints usage and exits 1.
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$CmdArgs)
    Write-Host "  > $Exe $($CmdArgs -join ' ')" -ForegroundColor DarkGray
    & $Exe @CmdArgs
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($CmdArgs -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Get-ArtifactName {
    <#
        electron-builder rejects an artifactName that has no ${ext} macro, and
        PowerShell would read `${ext}` inside a double-quoted string as a variable,
        so the macro is appended from a single-quoted literal.
    #>
    param([Parameter(Mandatory)][string]$Stem)
    return $Stem + '.${ext}'
}

# --- WSL plumbing -------------------------------------------------------------

function ConvertTo-BashScript {
    <#
        Strip CR. This file is stored with CRLF line endings, so a multi-line
        here-string handed to bash arrives with a \r on every line and bash treats it
        as part of the last token:

          set: - : invalid option
          cd: $'/home/kawa/.cache/motionity-build\r': No such file or directory

        Single-line commands are unaffected, which is exactly why this is easy to
        miss until a script gains a second line.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Script)
    return $Script -replace "`r", ""
}

<#
    A second trap in the same area, worth stating once: never combine `set -e` with an
    explicit `exit 0` under `bash -lc`.

      wsl -d Ubuntu -e bash -lc 'set -e; exit 0'   -> 1
      wsl -d Ubuntu -e bash -lc 'exit 0'           -> 0

    A login shell sources ~/.bash_logout on the way out, and Ubuntu's default one ends
    in `[ -x /usr/bin/clear_console ] && /usr/bin/clear_console -q`, which fails with
    no tty attached. With errexit set, that failure becomes the shell's exit status,
    and a script that did its job reports failure. -l is not negotiable (node from nvm
    or fnm is only on the login PATH), so the scripts below use `set -u` and check the
    commands that matter by hand.
#>

function Invoke-Wsl {
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$Command)
    Write-Host "  > wsl -d $Distro -- $Command" -ForegroundColor DarkGray
    # bash -lc, so PATH matches an interactive shell: node installed through nvm
    # or fnm is not on the default non-login PATH.
    & wsl.exe -d $Distro -e bash -lc (ConvertTo-BashScript $Command)
    if ($LASTEXITCODE -ne 0) {
        throw "the WSL build in '$Distro' failed with exit code $LASTEXITCODE."
    }
}

function Test-WslCommand {
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$Command)
    & wsl.exe -d $Distro -e bash -lc $Command *> $null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-WslCapture {
    <#
        Like Invoke-Wsl, but returns the distro's stdout instead of echoing the
        command. For the small queries (a path, a checksum listing) whose output is
        the point and whose command line is noise.

        Positional arguments go to bash as $1..$n; $0 is a label. Passing them this
        way rather than interpolating into $Command keeps quoting out of it.
    #>
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$ScriptArgs = @()
    )
    # 2>&1: stderr is merged in so a failure can be reported with what the distro
    # actually said. Callers filter the lines they want, so the noise is harmless.
    $out = @(& wsl.exe -d $Distro -e bash -lc (ConvertTo-BashScript $Command) "motionity-build" @ScriptArgs 2>&1 |
        ForEach-Object { $_.ToString().Replace("`0", "") })
    if ($LASTEXITCODE -ne 0) {
        throw "a query in WSL distro '$Distro' failed with exit code ${LASTEXITCODE}: $($out -join ' | ')"
    }
    return $out
}

function ConvertTo-BashArg {
    <#
        Single quotes, always. The artifactName arguments carry a literal ${ext}
        for electron-builder to expand, and bash would expand it to nothing first
        inside double quotes; the repo path has a space in it.
    #>
    param([Parameter(Mandatory)][string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Get-WslDistro {
    <#
        docker-desktop is excluded on purpose. It is Docker Desktop's own LinuxKit
        VM: no apt, no user home to install the flatpak runtimes into — and it is
        usually the *default* distro, so picking blind would land there.
    #>
    param([string]$Requested)

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "-UseWsl needs wsl.exe on PATH. Install a distro with 'wsl --install -d Ubuntu' (PACKAGING.md has the rest of the setup)."
    }

    # wsl.exe writes its own listings as UTF-16LE, which PowerShell 5.1 reads back
    # as NUL-interleaved text. WSL_UTF8 fixes it at the source; the -replace is the
    # fallback for WSL older than 0.64.
    $previousUtf8 = $env:WSL_UTF8
    $env:WSL_UTF8 = "1"
    try     { $listed = (& wsl.exe --list --quiet) -join "`n" }
    finally { $env:WSL_UTF8 = $previousUtf8 }

    $distros = @(($listed -replace "`0", "") -split "`r?`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($Requested) {
        if ($distros -notcontains $Requested) {
            throw "WSL distro '$Requested' is not installed. Installed: $($distros -join ', ')."
        }
        return $Requested
    }

    $usable = @($distros | Where-Object { $_ -notlike "docker-desktop*" })
    if (-not $usable.Count) {
        throw "no WSL distro that can build here (installed: $($distros -join ', ')). Run 'wsl --install -d Ubuntu', then the package setup in PACKAGING.md."
    }
    return $usable[0]
}

function Get-WslPath {
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$WindowsPath)
    # -e wslpath rather than a shell: the backslashes and the space in the repo
    # path then reach wslpath as one literal argv entry, unquoted and unmangled.
    $out = (& wsl.exe -d $Distro -e wslpath -a -u $WindowsPath)
    $path = (@($out) -join "").Replace("`0", "").Trim()
    if ($LASTEXITCODE -ne 0 -or -not $path) {
        throw "wslpath failed in '$Distro' for '$WindowsPath' — is the Windows drive mounted in that distro?"
    }
    return $path
}

function Get-WslStageDir {
    <#
        Where the Linux build actually happens. It cannot be dist/ on /mnt/c:
        electron-builder chmods every file it unpacks out of the Electron zip, and
        drvfs answers chmod with EPERM unless /mnt/c was mounted with the metadata
        option — a global change to the distro needing sudo and a wsl --shutdown.

          ⨯ EPERM: operation not permitted, chmod '.../linux-unpacked.tmp/locales/de.pak'

        Staging in the distro's own filesystem and copying the finished bundles back
        needs none of that, and is faster besides. Reading src/ over the mount is
        still fine — nothing chmods the input.
    #>
    param([Parameter(Mandatory)][string]$Distro)
    # printf, not echo: no trailing newline to trim off the path.
    $out  = (& wsl.exe -d $Distro -e bash -lc 'printf %s "${XDG_CACHE_HOME:-$HOME/.cache}/motionity-build"')
    $path = (@($out) -join "").Replace("`0", "").Trim()
    if ($LASTEXITCODE -ne 0 -or $path -notlike "/*") {
        throw "could not resolve a staging directory in '$Distro' (got '$path')."
    }
    return $path
}

function Assert-WslWine {
    <#
        The NSIS target needs a wine in the distro that can run a 32-bit PE, because
        the installer stub it has to execute is PE32/i386 even for an x64 app. Checked
        up front: without it the build dies after packaging ~200 MB, with an error
        that names ntdll rather than the missing package.

        The i386 check is a warning, not an error. The directory list below covers the
        usual layouts but cannot cover every distro or a hand-built wine, and a false
        negative must not block a build that would have worked.
    #>
    param([Parameter(Mandatory)][string]$Distro)

    $probe = @'
set -u
command -v wine >/dev/null 2>&1 || exit 10
wine --version >/dev/null 2>&1 || exit 11
for d in /usr/lib/wine /usr/lib64/wine /usr/lib/x86_64-linux-gnu/wine /usr/local/lib/wine /opt/wine*/lib/wine; do
    [ -d "$d/i386-windows" ] && exit 0
done
exit 12
'@
    & wsl.exe -d $Distro -e bash -lc (ConvertTo-BashScript $probe) "motionity-build" *> $null
    $code = $LASTEXITCODE

    $installHint = @"
Inside the distro (the i386 architecture is what provides the 32-bit loader):
  sudo dpkg --add-architecture i386
  sudo apt update
  sudo apt install -y wine
Or skip NSIS entirely — the portable .exe runs no PE, so it needs neither Wine nor root:
  ./scripts/build-release.ps1 -Targets win-portable -WinInWsl -KeepInWsl
"@

    switch ($code) {
        10 { throw "no wine in WSL distro '$Distro', and the NSIS uninstaller cannot be built without one.`n$installHint" }
        11 { throw "wine is installed in '$Distro' but will not run ('wine --version' failed). A broken or partial install cannot build the NSIS uninstaller.`n$installHint" }
        12 { Write-Warning "wine in '$Distro' looks 64-bit only (no i386-windows directory found). The NSIS installer stub is PE32/i386, so the build will likely fail at 'building target=nsis'. If it does:`n$installHint" }
    }
}

function Assert-WslBuildEnv {
    <#
        Fail before the build rather than during it. electron-builder's own error
        for a missing flatpak ref is a bare flatpak-builder exit code that names
        neither the ref nor the remote.
    #>
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string[]]$WslTargets,
        [Parameter(Mandatory)]$Pkg
    )

    if (-not (Test-WslCommand $Distro 'command -v node')) {
        throw "no node in WSL distro '$Distro'. Inside it: sudo apt update && sudo apt install -y nodejs npm"
    }

    # NSIS links the installer and then *runs* it with BUILD_UNINSTALLER defined to
    # get the uninstaller out, so building it on Linux means executing a Windows PE.
    if (@($WslTargets | Where-Object { $_ -eq "win" -or $_ -eq "win-nsis" }).Count) {
        Assert-WslWine -Distro $Distro
    }

    # AppImage and the Windows targets need nothing else: electron-builder downloads
    # its own appimage tooling and writes the squashfs itself, and it downloads the
    # NSIS bundle whose makensis is a native Linux binary. libfuse2 is only needed to
    # *run* an AppImage, which is not this script's job.
    if ($WslTargets -notcontains "linux-flatpak") { return }

    if (-not (Test-WslCommand $Distro 'command -v flatpak-builder')) {
        throw "no flatpak-builder in WSL distro '$Distro'. Inside it: sudo apt install -y flatpak flatpak-builder elfutils"
    }

    $runtimeVersion = $Pkg.build.flatpak.runtimeVersion
    $baseVersion    = $Pkg.build.flatpak.baseVersion
    if (-not $runtimeVersion) { $runtimeVersion = "23.08" }
    if (-not $baseVersion)    { $baseVersion    = $runtimeVersion }

    $refs = @(
        "org.freedesktop.Platform//$runtimeVersion",
        "org.freedesktop.Sdk//$runtimeVersion",
        "org.electronjs.Electron2.BaseApp//$baseVersion"
    )
    $missing = @($refs | Where-Object { -not (Test-WslCommand $Distro "flatpak info $_") })
    if ($missing.Count) {
        throw @"
flatpak refs missing in '$Distro': $($missing -join ', ')
Inside the distro:
  flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak install --user -y flathub $($refs -join ' ')
"@
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    $pkg = Get-Content (Join-Path $repoRoot "package.json") -Raw | ConvertFrom-Json

    if (-not $Tag) { $Tag = "v$($pkg.version)" }
    if ($Tag.TrimStart("v") -ne $pkg.version) {
        Write-Warning "-Tag '$Tag' does not match package.json version '$($pkg.version)'. electron-builder stamps package.json into the app, so the file names and the app's own About version would disagree — bump package.json first."
    }

    $prefix  = "motionity-$Tag"
    $distDir = Join-Path $repoRoot "dist"

    Write-Host "Motionity release build" -ForegroundColor Cyan
    Write-Host "  tag     : $Tag"
    Write-Host "  targets : $($Targets -join ', ')"
    Write-Host "  output  : $distDir"
    Write-Host ""

    # Expand "linux" to its two concrete bundles and drop duplicates. "win" is left
    # alone rather than expanded the same way: electron-builder builds nsis and
    # portable from one packaging pass, and splitting it would unpack Electron twice.
    $resolvedTargets = @()
    foreach ($t in $Targets) {
        if ($t -eq "linux") { $resolvedTargets += "linux-appimage", "linux-flatpak" }
        else                { $resolvedTargets += $t }
    }
    $resolvedTargets = @($resolvedTargets | Select-Object -Unique)

    # electron-builder produces AppImage and Flatpak with Linux-only tooling (its
    # downloaded appimage bundle, and flatpak-builder). -UseWsl hands those two
    # targets to a WSL distro; without it they stay a warning rather than an error,
    # because the other right answer is running this whole script under pwsh on a
    # Linux box, where they build natively.
    #
    # -WinInWsl adds "win" to that set. Not because Windows cannot build it, but
    # because a locked-down Windows machine's endpoint agent interferes with the
    # unsigned .exe while the installer is being packed (see the header).
    $onWindows  = ($env:OS -eq "Windows_NT")
    $wantWsl    = $UseWsl -or $WinInWsl
    $wslTargets = @($resolvedTargets | Where-Object { $_ -like "linux-*" -or ($WinInWsl -and $_ -like "win*") })
    $useWslHere = $onWindows -and $wantWsl -and [bool]$wslTargets.Count

    $linuxTargets = @($resolvedTargets | Where-Object { $_ -like "linux-*" })
    if ($onWindows -and $linuxTargets.Count -and -not $wantWsl) {
        Write-Warning "the Linux targets need a Linux host or WSL — electron-builder cannot produce AppImage or Flatpak on Windows. Add -UseWsl to build them in a WSL distro (PACKAGING.md has the setup)."
    }
    if ($wantWsl -and -not $onWindows) {
        Write-Warning "-UseWsl/-WinInWsl ignored: this is already a Linux host, so every target builds natively."
    }
    if ($wantWsl -and $onWindows -and -not $wslTargets.Count) {
        Write-Warning "-UseWsl ignored: no target was selected for WSL (-Targets $($Targets -join ', ')). Add -WinInWsl to send the Windows targets there too."
    }
    if ($KeepInWsl -and -not $useWslHere) {
        Write-Warning "-KeepInWsl ignored: nothing is being built in WSL."
    }

    $wslRepo  = $null
    $wslStage = $null
    if ($useWslHere) {
        $WslDistro = Get-WslDistro -Requested $WslDistro
        $wslRepo   = Get-WslPath -Distro $WslDistro -WindowsPath $repoRoot
        $wslStage  = Get-WslStageDir -Distro $WslDistro
        Write-Host "Targets going to WSL: $($wslTargets -join ', ')" -ForegroundColor Cyan
        Write-Host "  distro  : $WslDistro"
        Write-Host "  worktree: $wslRepo"
        Write-Host "  staging : $wslStage$(if ($KeepInWsl) { ' (left there — -KeepInWsl)' } else { ' (copied back into dist/)' })"
        Assert-WslBuildEnv -Distro $WslDistro -WslTargets $wslTargets -Pkg $pkg
        Write-Host ""
    }

    if ($Clean) {
        Write-Host "Cleaning dist/..." -ForegroundColor Cyan
        if (Test-Path $distDir) { Remove-Item -Recurse -Force $distDir }
    }
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null

    # --- Dependencies ---------------------------------------------------------
    # Only when node_modules is absent: `npm ci` deletes the tree and re-extracts
    # ~250 MB of Electron every time, which turns a 2-minute rebuild into a
    # 10-minute one for no gain.
    if (-not $SkipDeps -and -not (Test-Path (Join-Path $repoRoot "node_modules"))) {
        Write-Host "Installing dependencies..." -ForegroundColor Cyan
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            throw "npm not found — install Node 18+, or pass -SkipDeps if node_modules is provided some other way."
        }
        Invoke-Checked npm @("ci", "--no-audit", "--no-fund")
        Write-Host ""
    }

    # --- Vendored assets ------------------------------------------------------
    # index.html points only at src/vendor/, which is gitignored, so this has to
    # run before electron-builder copies src/ into the package — not after.
    if (-not $SkipVendor) {
        Write-Host "Vendoring third-party assets..." -ForegroundColor Cyan
        Invoke-Checked node @("scripts/vendor.mjs")
        Write-Host ""
    }

    # A missing src/vendor/ yields an installer that opens to a blank editor and
    # only fails at run time, so check one file that must be there.
    $vendorProbe = Join-Path $repoRoot "src/vendor/fabric.min.js"
    if (-not (Test-Path $vendorProbe)) {
        throw "src/vendor/fabric.min.js is missing — the package would ship an app whose scripts all 404. Run without -SkipVendor."
    }

    # --- Icon -----------------------------------------------------------------
    # build/icon.png is gitignored and generated; electron-builder derives the
    # Windows .ico and the Linux icon set from it and fails without it.
    Write-Host "Rendering icon..." -ForegroundColor Cyan
    Invoke-Checked node @("scripts/make-icon.cjs")
    Write-Host ""

    # --- Package --------------------------------------------------------------
    # The local binary rather than npx: npx renamed --no-install to --no in npm 10,
    # and a version-dependent flag inside a release script is a trap.
    $builder = Join-Path $repoRoot "node_modules/.bin/electron-builder.cmd"
    if (-not (Test-Path $builder)) {
        $builder = Join-Path $repoRoot "node_modules/.bin/electron-builder"
    }
    if (-not (Test-Path $builder)) {
        throw 'electron-builder not found in node_modules — run "npm ci" (or drop -SkipDeps).'
    }

    # Clear this tag's previous bundles from the staging directory once, before the
    # loop — not per target. Per target, the glob would delete the artifacts an
    # earlier target had just staged, which only went unnoticed while every target
    # copied its output back immediately.
    if ($useWslHere) {
        Invoke-Wsl -Distro $WslDistro -Command (
            "mkdir -p $(ConvertTo-BashArg $wslStage) && rm -f $(ConvertTo-BashArg $wslStage)/$prefix-*")
    }

    foreach ($target in $resolvedTargets) {
        Write-Host "Packaging $target..." -ForegroundColor Cyan

        # --publish never: electron-builder otherwise tries to upload to whatever
        # provider it infers from the repo URL as soon as the tag looks like a
        # release. Publishing is publish.ps1's job, against Gitea.
        switch ($target) {
            "win" {
                $builderArgs = @(
                    "--win", "--publish", "never",
                    "-c.nsis.artifactName=$(Get-ArtifactName "$prefix-win-x64-setup")",
                    "-c.portable.artifactName=$(Get-ArtifactName "$prefix-win-x64-portable")"
                )
            }
            "win-nsis" {
                $builderArgs = @(
                    "--win", "nsis", "--publish", "never",
                    "-c.nsis.artifactName=$(Get-ArtifactName "$prefix-win-x64-setup")"
                )
            }
            "win-portable" {
                $builderArgs = @(
                    "--win", "portable", "--publish", "never",
                    "-c.portable.artifactName=$(Get-ArtifactName "$prefix-win-x64-portable")"
                )
            }
            "linux-appimage" {
                $builderArgs = @(
                    "--linux", "AppImage", "--publish", "never",
                    "-c.appImage.artifactName=$(Get-ArtifactName "$prefix-linux-x86_64")"
                )
            }
            "linux-flatpak" {
                $builderArgs = @(
                    "--linux", "flatpak", "--publish", "never",
                    "-c.flatpak.artifactName=$(Get-ArtifactName "$prefix-linux-x86_64")"
                )
            }
        }

        # Two overrides that only apply to a Windows target built on Linux:
        #
        #   signExecutable=false  electron-builder still walks the signing path with no
        #                         certificate configured, and on Linux that path shells
        #                         out to signtool.exe under Wine before it discovers
        #                         there is nothing to sign — `spawn wine ENOENT`, build
        #                         over. false skips signing while still applying the
        #                         icon and version strings (signAndEditExecutable=false
        #                         would drop those too, which is not what is wanted).
        # toolsets.wine is deliberately NOT set: leaving it unset is what makes
        # electron-builder use the distro's own `wine` on Linux, and the 1.0.1 bundle
        # it would otherwise download is unusable there (see the header).
        #
        # Passed here rather than put in package.json so a native Windows build keeps
        # behaving exactly as it did.
        if ($useWslHere -and $wslTargets -contains $target -and $target -like "win*") {
            $builderArgs += "-c.win.signExecutable=false"
        }

        if ($useWslHere -and $wslTargets -contains $target) {
            # `node cli.js` rather than node_modules/.bin/electron-builder: the
            # extensionless shim npm writes on Windows is a sh script, and whether
            # it is executable across the mount depends on the drvfs options.
            #
            # The output goes to the distro's filesystem (see Get-WslStageDir) and
            # the bundles are copied back afterwards. `cp -f`, never `cp -p`:
            # preserving modes means chmod, which is the EPERM this avoids.
            #
            # With -KeepInWsl there is no copy back at all: the point is that no
            # unsigned .exe is ever written to NTFS, and a `cp` into dist/ is exactly
            # the write the endpoint agent would quarantine.
            $quotedArgs = @($builderArgs | ForEach-Object { ConvertTo-BashArg $_ }) -join " "
            $stage      = ConvertTo-BashArg $wslStage
            $wslCommand = "cd $(ConvertTo-BashArg $wslRepo)" +
                          " && USE_HARD_LINKS=false node node_modules/electron-builder/cli.js $quotedArgs $(ConvertTo-BashArg "-c.directories.output=$wslStage")"
            if (-not $KeepInWsl) {
                $wslCommand += " && cp -f $stage/$prefix-* $(ConvertTo-BashArg "$wslRepo/dist")/"
            }
            Invoke-Wsl -Distro $WslDistro -Command $wslCommand
        }
        else {
            Invoke-Checked $builder $builderArgs
        }
        Write-Host ""
    }

    # electron-builder drops auto-update metadata and the NSIS payload beside the
    # installers. publish.ps1 uploads everything matching the tag prefix, so clear
    # them out here instead of attaching 80 MB of intermediates to the release.
    Get-ChildItem $distDir -File | Where-Object {
        $_.Name -like "*.blockmap" -or $_.Name -like "latest*.yml" -or
        $_.Name -like "*.nsis.7z" -or $_.Name -eq "builder-debug.yml"
    } | Remove-Item -Force

    $built = @(Get-ChildItem $distDir -Filter "$prefix-*" -File | Sort-Object Name)

    # --- Artifacts left in the distro ------------------------------------------
    # With -KeepInWsl the bundles never crossed the mount, so their names and hashes
    # have to come from the distro. The same intermediates are cleared there first:
    # `<installer>.exe.blockmap` matches the $prefix-* glob too, and would otherwise
    # be listed as a release artifact.
    $manifestPath = Join-Path $distDir "wsl-artifacts.json"
    $stagedLines  = @()
    if ($useWslHere -and $KeepInWsl) {
        $listScript = @'
set -u
cd "$1" || { echo "staging directory $1 is gone" >&2; exit 1; }
rm -f ./*.blockmap ./*.nsis.7z ./latest*.yml ./builder-debug.yml
shopt -s nullglob
files=("$2"-*)
if [ ${#files[@]} -gt 0 ]; then sha256sum "${files[@]}"; fi
'@
        $stagedLines = @(Invoke-WslCapture -Distro $WslDistro -Command $listScript `
            -ScriptArgs @($wslStage, $prefix) | Where-Object { $_ -match '^[0-9a-f]{64}\s\s\S' })
    }
    $stagedNames = @($stagedLines | ForEach-Object { ($_ -split '\s\s', 2)[1] } | Sort-Object)

    # A name built in WSL this run wins over a same-named file sitting in dist/ from
    # an earlier native build. That leftover is stale by definition, and it is also
    # the likeliest file on the machine to be locked or quarantined — which is the
    # whole reason for building in the distro.
    if ($stagedNames.Count) {
        $shadowed = @($built | Where-Object { $stagedNames -contains $_.Name })
        if ($shadowed.Count) {
            Write-Warning "ignoring $($shadowed.Count) stale file(s) in dist/ superseded by this run's WSL build: $(($shadowed | ForEach-Object Name) -join ', '). Delete them (or pass -Clean) to keep dist/ honest."
            $built = @($built | Where-Object { $stagedNames -notcontains $_.Name })
        }
    }

    if (-not $built.Count -and -not $stagedNames.Count) {
        throw "electron-builder reported success but no $prefix-* artifact landed in $(if ($KeepInWsl) { "$distDir or $wslStage" } else { $distDir })."
    }

    # publish.ps1 globs dist/ for what to upload, so the files that stayed behind
    # need an explicit hand-off. A stale manifest from a previous -KeepInWsl run
    # would make it upload artifacts this build did not produce, so it is removed
    # whenever this run left nothing in the distro.
    if ($stagedNames.Count) {
        $manifest = [ordered]@{
            tag      = $Tag
            distro   = $WslDistro
            stageDir = $wslStage
            files    = @($stagedNames)
        }
        [System.IO.File]::WriteAllText($manifestPath,
            ($manifest | ConvertTo-Json -Depth 3), [System.Text.UTF8Encoding]::new($false))
    }
    elseif (Test-Path $manifestPath) {
        Remove-Item -Force $manifestPath
    }

    # --- Checksums ------------------------------------------------------------
    Write-Host "Writing checksums..." -ForegroundColor Cyan
    $sumsPath = Join-Path $distDir "SHA256SUMS.txt"
    # sha256sum's own output format is already `<hash>  <name>`, so the lines from the
    # distro go in verbatim and the two sets sort together by file name.
    $lines = @(
        @(foreach ($f in $built) {
            try {
                "$((Get-FileHash -Algorithm SHA256 $f.FullName).Hash.ToLower())  $($f.Name)"
            }
            catch {
                # An artifact in dist/ that cannot even be read is the endpoint agent
                # again, and hashing is not the step to paper over it: publish.ps1
                # would try to upload the same unreadable file next.
                throw "cannot read $($f.FullName) to hash it ($($_.Exception.Message.Trim())). On a machine whose security agent locks unsigned executables, build with -WinInWsl -KeepInWsl and delete the leftovers in dist/ (or pass -Clean)."
            }
        }) + $stagedLines
    ) | Sort-Object { ($_ -split '\s\s', 2)[1] }
    # ASCII with LF: a BOM or CRLF makes `sha256sum -c` reject the first line.
    [System.IO.File]::WriteAllText($sumsPath, ($lines -join "`n") + "`n", [System.Text.ASCIIEncoding]::new())
    Write-Host ""

    Write-Host "Done. Built:" -ForegroundColor Green
    foreach ($f in $built) {
        Write-Host "  $($f.FullName) ($([math]::Round($f.Length / 1MB, 1)) MB)" -ForegroundColor Green
    }
    if ($stagedNames.Count) {
        Write-Host "  in WSL ($WslDistro), not copied to NTFS:" -ForegroundColor Green
        foreach ($n in $stagedNames) {
            Write-Host "    $wslStage/$n" -ForegroundColor Green
        }
        Write-Host "    reachable from Windows as \\wsl.localhost\$WslDistro$(($wslStage -replace '/', '\'))\" -ForegroundColor DarkGray
        Write-Host "    publish.ps1 uploads these from inside the distro (dist/wsl-artifacts.json)" -ForegroundColor DarkGray
    }
    Write-Host "  $sumsPath" -ForegroundColor Green
}
finally {
    Pop-Location
}
