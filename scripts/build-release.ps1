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
    WSL (see PACKAGING.md). Nothing here cross-builds.

    -UseWsl makes that split automatic: the .exe targets run on Windows, and the
    Linux ones are handed to a WSL distro over /mnt/c, against this same worktree.
    The npm install, the vendor step and the icon all happen once on the Windows
    side and the WSL build reads them through the mount, so the artifacts still
    land in dist/ and the checksum step below sees every one of them.

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
    ./scripts/build-release.ps1 -SkipVendor -SkipDeps
    Reuse src/vendor/ and node_modules as they are — the fast rebuild.
#>
[CmdletBinding()]
param(
    # Platforms to package. "win" is NSIS + portable; "linux-appimage" and
    # "linux-flatpak" are the two Linux bundles, and "linux" is shorthand for both.
    [ValidateSet("win", "linux", "linux-appimage", "linux-flatpak")]
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

function Invoke-Wsl {
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$Command)
    Write-Host "  > wsl -d $Distro -- $Command" -ForegroundColor DarkGray
    # bash -lc, so PATH matches an interactive shell: node installed through nvm
    # or fnm is not on the default non-login PATH.
    & wsl.exe -d $Distro -e bash -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "the WSL build in '$Distro' failed with exit code $LASTEXITCODE."
    }
}

function Test-WslCommand {
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$Command)
    & wsl.exe -d $Distro -e bash -lc $Command *> $null
    return ($LASTEXITCODE -eq 0)
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

    # AppImage needs nothing else: electron-builder downloads its own appimage
    # tooling and writes the squashfs itself. libfuse2 is only needed to *run* the
    # result, which is not this script's job.
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

    # Expand "linux" to its two concrete bundles and drop duplicates, so the rest
    # of the script only ever deals with win / linux-appimage / linux-flatpak.
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
    $onWindows  = ($env:OS -eq "Windows_NT")
    $wslTargets = @($resolvedTargets | Where-Object { $_ -like "linux-*" })
    $useWslHere = $onWindows -and $UseWsl -and [bool]$wslTargets.Count

    if ($onWindows -and $wslTargets.Count -and -not $UseWsl) {
        Write-Warning "the Linux targets need a Linux host or WSL — electron-builder cannot produce AppImage or Flatpak on Windows. Add -UseWsl to build them in a WSL distro (PACKAGING.md has the setup)."
    }
    if ($UseWsl -and -not $onWindows) {
        Write-Warning "-UseWsl ignored: this is already a Linux host, so the Linux targets build natively."
    }
    if ($UseWsl -and $onWindows -and -not $wslTargets.Count) {
        Write-Warning "-UseWsl ignored: no Linux target was requested (-Targets $($Targets -join ', '))."
    }

    $wslRepo  = $null
    $wslStage = $null
    if ($useWslHere) {
        $WslDistro = Get-WslDistro -Requested $WslDistro
        $wslRepo   = Get-WslPath -Distro $WslDistro -WindowsPath $repoRoot
        $wslStage  = Get-WslStageDir -Distro $WslDistro
        Write-Host "Linux targets go to WSL" -ForegroundColor Cyan
        Write-Host "  distro  : $WslDistro"
        Write-Host "  worktree: $wslRepo"
        Write-Host "  staging : $wslStage (copied back into dist/)"
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

        if ($useWslHere -and $target -like "linux-*") {
            # `node cli.js` rather than node_modules/.bin/electron-builder: the
            # extensionless shim npm writes on Windows is a sh script, and whether
            # it is executable across the mount depends on the drvfs options.
            #
            # The output goes to the distro's filesystem (see Get-WslStageDir) and
            # the bundles are copied back afterwards. `cp -f`, never `cp -p`:
            # preserving modes means chmod, which is the EPERM this avoids.
            #
            # The rm clears this tag's previous bundles from the staging directory,
            # so the copy back cannot pick up an artifact from an earlier build that
            # electron-builder did not overwrite this time round.
            $quotedArgs = @($builderArgs | ForEach-Object { ConvertTo-BashArg $_ }) -join " "
            $stage      = ConvertTo-BashArg $wslStage
            $wslCommand = "cd $(ConvertTo-BashArg $wslRepo)" +
                          " && mkdir -p $stage" +
                          " && rm -f $stage/$prefix-*" +
                          " && USE_HARD_LINKS=false node node_modules/electron-builder/cli.js $quotedArgs $(ConvertTo-BashArg "-c.directories.output=$wslStage")" +
                          " && cp -f $stage/$prefix-* $(ConvertTo-BashArg "$wslRepo/dist")/"
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
    if (-not $built.Count) {
        throw "electron-builder reported success but no $prefix-* artifact landed in $distDir."
    }

    # --- Checksums ------------------------------------------------------------
    Write-Host "Writing checksums..." -ForegroundColor Cyan
    $sumsPath = Join-Path $distDir "SHA256SUMS.txt"
    $lines = foreach ($f in $built) {
        "$((Get-FileHash -Algorithm SHA256 $f.FullName).Hash.ToLower())  $($f.Name)"
    }
    # ASCII with LF: a BOM or CRLF makes `sha256sum -c` reject the first line.
    [System.IO.File]::WriteAllText($sumsPath, ($lines -join "`n") + "`n", [System.Text.ASCIIEncoding]::new())
    Write-Host ""

    Write-Host "Done. Built:" -ForegroundColor Green
    foreach ($f in $built) {
        Write-Host "  $($f.FullName) ($([math]::Round($f.Length / 1MB, 1)) MB)" -ForegroundColor Green
    }
    Write-Host "  $sumsPath" -ForegroundColor Green
}
finally {
    Pop-Location
}
