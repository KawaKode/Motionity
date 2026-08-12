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

.EXAMPLE
    ./scripts/build-release.ps1
    Build every target at v<package.json version>.

.EXAMPLE
    ./scripts/build-release.ps1 -Targets win -Tag v1.1.0
    Windows installers only, named v1.1.0.

.EXAMPLE
    ./scripts/build-release.ps1 -SkipVendor -SkipDeps
    Reuse src/vendor/ and node_modules as they are — the fast rebuild.
#>
[CmdletBinding()]
param(
    # Platforms to package. "win" is NSIS + portable, "linux" is AppImage + Flatpak.
    [ValidateSet("win", "linux")]
    [string[]]$Targets = @("win", "linux"),

    # Version used in the artifact names. Defaults to v<package.json version>,
    # because electron-builder stamps that same version into the app itself — a
    # git-describe tag here would disagree with what the installed app reports.
    [string]$Tag,

    # Skip `npm run vendor` (the ~20 MB third-party download into src/vendor/).
    [switch]$SkipVendor,

    # Skip the npm install even when node_modules is missing.
    [switch]$SkipDeps,

    # Remove dist/ before building.
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Args)
    Write-Host "  > $Exe $($Args -join ' ')" -ForegroundColor DarkGray
    & $Exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($Args -join ' ')' failed with exit code $LASTEXITCODE."
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

    # electron-builder produces AppImage and Flatpak with Linux-only tooling
    # (appimagetool, flatpak-builder). Warned rather than blocked: the same script
    # runs under pwsh on a Linux box or in WSL, which is where that target belongs.
    if ($Targets -contains "linux" -and $env:OS -eq "Windows_NT") {
        Write-Warning "the linux target needs a Linux host or WSL — electron-builder cannot produce AppImage or Flatpak on Windows (PACKAGING.md has the WSL setup)."
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

    foreach ($target in $Targets) {
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
            "linux" {
                $builderArgs = @(
                    "--linux", "AppImage", "flatpak", "--publish", "never",
                    "-c.appImage.artifactName=$(Get-ArtifactName "$prefix-linux-x86_64")",
                    "-c.flatpak.artifactName=$(Get-ArtifactName "$prefix-linux-x86_64")"
                )
            }
        }

        Invoke-Checked $builder $builderArgs
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
