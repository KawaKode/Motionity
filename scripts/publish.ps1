#requires -Version 5.1
<#
.SYNOPSIS
    Build the Motionity container image + desktop installers; push the image to the
    Gitea registry and attach the installers to a Gitea release.

.DESCRIPTION
    Builds the Docker image from the repo Dockerfile, tags it for the Gitea
    registry (git.azuze.fr by default), logs in, and pushes one or more tags.

    It also builds the desktop installers (scripts/build-release.ps1) from the same
    commit, so both carry the same -Tag. Installers cannot live in a container
    registry, so -PublishRelease attaches them to the Gitea release for that tag
    instead (creating the release if it does not exist).

    -BinariesOnly ships just the installers: no docker build, no docker login, no
    image push, and the release upload is implied. It takes the target list to
    build (win, linux-appimage, linux-flatpak — comma-separated) and that list
    overrides -Targets. The Linux targets need a Linux host or WSL: on Windows,
    add -UseWsl and build-release.ps1 hands them to a WSL distro.

    Credentials are read, in order of precedence:
      1. -Username / -Password parameters
      2. $env:GITEA_USER / $env:GITEA_TOKEN
      3. Interactive prompt (token is read as a SecureString)

    Use a Gitea access token (Settings -> Applications) as the password, not your
    account password. The image push needs package read/write scope; the release
    upload needs repository write scope (`write:repository`).

.EXAMPLE
    ./scripts/publish.ps1
    Build and push :latest plus v<package.json version>; build installers locally.

.EXAMPLE
    ./scripts/publish.ps1 -Tag v1.1.0 -PublishRelease
    Full release: push the image and attach every dist/ installer to release v1.1.0.

.EXAMPLE
    ./scripts/publish.ps1 -BinariesOnly win -Tag v1.1.0
    Windows installers only — build them and attach them to release v1.1.0. Docker
    is never invoked, so this works with Docker Desktop stopped.

.EXAMPLE
    ./scripts/publish.ps1 -BinariesOnly win,linux-appimage -Tag v1.1.0
    Windows installers plus the Linux AppImage (no Flatpak), attached to v1.1.0.

.EXAMPLE
    ./scripts/publish.ps1 -Tag v1.1.0 -PublishRelease -UseWsl
    Full release from Windows: image push, .exe installers built natively, AppImage
    and Flatpak built in WSL, everything attached to release v1.1.0.

.EXAMPLE
    ./scripts/publish.ps1 -BinariesOnly win -NoBinaryBuild -Tag v1.1.0
    Retry a failed upload: attach the installers already in dist/ without rebuilding
    (the target list is required syntactically but ignored — every dist/ installer
    for the tag is uploaded regardless).

.EXAMPLE
    ./scripts/publish.ps1 -NoBinaries
    Container only — no installer build, so no Node toolchain needed.

.EXAMPLE
    $env:GITEA_USER = "kawa"; $env:GITEA_TOKEN = "xxxx"; ./scripts/publish.ps1 -SkipLogin:$false
#>
[CmdletBinding()]
param(
    # Registry host (Gitea instance).
    [string]$Registry = "git.azuze.fr",

    # Owner / organisation that holds the package and the repo.
    [string]$Owner = "kawa",

    # Image name.
    [string]$Image = "motionity",

    # Repository name holding the releases. The image and the repo are not named
    # the same here (motionity vs Motionity), so this is separate from -Image.
    [string]$Repo = "Motionity",

    # Primary tag. Defaults to v<package.json version>.
    [string]$Tag,

    # Also push :latest. On by default.
    [switch]$NoLatest,

    # Registry username. Falls back to $env:GITEA_USER then a prompt.
    [string]$Username,

    # Registry token/password. Falls back to $env:GITEA_TOKEN then a prompt.
    [string]$Password,

    # Ship the image without the 18.5 MB asm.js ffmpeg build: "0" makes MP4/GIF
    # export fetch it from archive.org on first use instead of working offline.
    # The Dockerfile declares this ARG; it has no ARG VERSION.
    [ValidateSet("0", "1")]
    [string]$WithFfmpeg = "1",

    # Skip the image build and only push existing local tags.
    [switch]$NoBuild,

    # Skip docker login (assume already authenticated).
    [switch]$SkipLogin,

    # Skip building the desktop installers.
    [switch]$NoBinaries,

    # Forwarded to build-release.ps1. "linux" is shorthand for both Linux bundles.
    [ValidateSet("win", "linux", "linux-appimage", "linux-flatpak")]
    [string[]]$Targets = @("win", "linux"),
    [switch]$SkipVendor,

    # Forwarded to build-release.ps1: build the Linux targets in a WSL distro
    # instead of warning that Windows cannot produce them.
    [switch]$UseWsl,
    [string]$WslDistro,

    # Reuse the installers already in dist/ instead of re-running the build. For
    # retrying a failed upload without paying for the build again.
    [switch]$NoBinaryBuild,

    # Ship only the installers: no docker build, login or push. Implies
    # -PublishRelease, since building alone is what build-release.ps1 already does.
    # Takes the target list to build (comma-separated), which overrides -Targets:
    #   -BinariesOnly win,linux-appimage
    [ValidateSet("win", "linux-appimage", "linux-flatpak")]
    [string[]]$BinariesOnly,

    # Attach the installers to the Gitea release for $Tag, creating the release if
    # it is missing.
    [switch]$PublishRelease,

    # owner/repo holding the release. Defaults to $Owner/$Repo.
    [string]$ReleaseRepo,

    # Gitea base URL for the API. Defaults to https://<Registry>.
    [string]$ApiBase,

    # Replace release attachments that already exist under the same name.
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    # $CmdArgs, not $Args: $Args is a PowerShell automatic variable and never
    # binds the passed array, so `& $Exe @Args` would run the exe bare.
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$CmdArgs)
    Write-Host "  > $Exe $($CmdArgs -join ' ')" -ForegroundColor DarkGray
    & $Exe @CmdArgs
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($CmdArgs -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Resolve-Token {
    <#
        The token for both the registry push and the release API: parameter, then
        env, then an interactive SecureString prompt. Read once and reused, so a
        run that does both does not prompt twice.
    #>
    param([string]$Provided, [Parameter(Mandatory)][string]$Purpose)

    if ($Provided) { return $Provided }
    if ($env:GITEA_TOKEN) { return $env:GITEA_TOKEN }
    $secure = Read-Host "Gitea token ($Purpose)" -AsSecureString
    return [System.Net.NetworkCredential]::new("", $secure).Password
}

function Invoke-GiteaApi {
    <#
        JSON call against the Gitea API. Returns $null on 404 instead of throwing,
        because "does this release exist yet?" is a 404 in the normal case and
        Invoke-RestMethod treats any 4xx as terminating.
    #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        $Body
    )

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = @{ Authorization = "token $Token"; Accept = "application/json" }
    }
    if ($null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 5)
        $params.ContentType = "application/json"
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 404) { return $null }
        if ($status -eq 401) {
            throw "Gitea API $Method $Uri returned 401 — the token was rejected. Check GITEA_TOKEN (a registry-only token works for docker push but not for the API)."
        }
        if ($status -eq 403) {
            throw "Gitea API $Method $Uri returned 403 — the token is valid but lacks repository write scope (write:repository)."
        }
        throw "Gitea API $Method $Uri failed: $($_.Exception.Message)"
    }
}

function Send-ReleaseAsset {
    <#
        Upload one file as a release attachment.

        curl.exe rather than Invoke-RestMethod -Form: -Form needs PowerShell 6+,
        and hand-rolling a multipart body in 5.1 means loading the whole binary
        into a string — these installers are 80-200 MB. The token goes in a
        --config file, never in the argument list, so it stays out of the process
        table and the shell history.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Path
    )

    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if (-not $curl) { $curl = (Get-Command curl -ErrorAction SilentlyContinue).Source }
    if (-not $curl) { throw "curl not found — needed to upload release attachments." }

    $configFile = [System.IO.Path]::GetTempFileName()
    try {
        # curl --config syntax: one option per line, `name = "value"`, and a value
        # may not span lines. Only the header belongs here — everything else goes
        # on the command line, where a stray escape can't silently split a line.
        Set-Content -Path $configFile -Encoding ASCII -Value @(
            "header = `"Authorization: token $Token`"",
            "silent",
            "show-error",
            "fail-with-body"
        )
        Write-Host "  > curl --config <temp> -F attachment=@$(Split-Path -Leaf $Path) `"$Uri`"" -ForegroundColor DarkGray
        # Single-quoted: the \n is curl's own escape in -w, not PowerShell's.
        & $curl "--config" $configFile `
            "--write-out" '  http %{http_code}, %{size_upload} bytes uploaded\n' `
            "-F" "attachment=@$Path" $Uri
        if ($LASTEXITCODE -ne 0) { throw "upload of '$Path' failed (curl exit $LASTEXITCODE)." }
    }
    finally {
        Remove-Item -Force $configFile -ErrorAction SilentlyContinue
    }
}

function Publish-BinaryRelease {
    <#
        Attach the installers to the release for $Tag, creating that release if it
        does not exist yet. Re-uploading the same file name is a delete + upload,
        which needs -Force: overwriting an asset someone may already have linked is
        not something to do silently.
    #>
    param(
        [Parameter(Mandatory)][string]$ApiRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string[]]$Artifacts,
        [switch]$Force
    )

    $releasesUri = "$ApiRoot/repos/$RepoPath/releases"
    $release = Invoke-GiteaApi -Method GET -Uri "$releasesUri/tags/$Tag" -Token $Token

    if (-not $release) {
        Write-Host "  creating release $Tag in $RepoPath..." -ForegroundColor DarkGray
        $release = Invoke-GiteaApi -Method POST -Uri $releasesUri -Token $Token -Body @{
            tag_name = $Tag
            name     = "Motionity $Tag"
            body     = "Desktop installers — Windows NSIS + portable, Linux AppImage + Flatpak — with SHA256SUMS.txt. Container image: ${Registry}/${Owner}/${Image}:$Tag"
            draft    = $false
        }
        if (-not $release) { throw "could not create release $Tag in $RepoPath (does the repo exist?)." }
    }
    else {
        Write-Host "  reusing release $Tag (id $($release.id))" -ForegroundColor DarkGray
    }

    foreach ($path in $Artifacts) {
        $name     = Split-Path -Leaf $path
        $existing = $release.assets | Where-Object { $_.name -eq $name }
        if ($existing) {
            if (-not $Force) {
                throw "release $Tag already has an attachment named '$name' — pass -Force to replace it."
            }
            Write-Host "  replacing existing attachment '$name'..." -ForegroundColor DarkGray
            Invoke-GiteaApi -Method DELETE -Token $Token `
                -Uri "$releasesUri/$($release.id)/assets/$($existing.id)" | Out-Null
        }
        $encoded = [System.Uri]::EscapeDataString($name)
        Send-ReleaseAsset -Token $Token -Path $path `
            -Uri "$releasesUri/$($release.id)/assets?name=$encoded"
    }

    return "$ApiRoot/repos/$RepoPath/releases/tags/$Tag"
}

# Resolve repo root (parent of this script's folder) so the script works from anywhere.
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    # --- Mode resolution ------------------------------------------------------
    # -BinariesOnly is a target list, so its mere presence (a non-empty array) is
    # what selects the mode.
    $binariesOnlyMode = $BinariesOnly.Count -gt 0
    if ($binariesOnlyMode -and $NoBinaries) {
        throw "-BinariesOnly and -NoBinaries cancel each other out — pick one."
    }
    if ($NoBinaryBuild -and $NoBinaries) {
        throw "-NoBinaryBuild reuses the build that -NoBinaries skips entirely — pick one."
    }
    if ($binariesOnlyMode) {
        # Nothing to build, log into or push on the container side, and uploading
        # is the whole point (build-release.ps1 alone covers "just build them").
        $NoBuild        = $true
        $SkipLogin      = $true
        $PublishRelease = $true
        # The targets named on -BinariesOnly are what to build.
        $Targets        = $BinariesOnly
    }
    $pushImage = -not $binariesOnlyMode

    if (-not $ReleaseRepo) { $ReleaseRepo = "$Owner/$Repo" }
    if (-not $ApiBase)     { $ApiBase = "https://$Registry" }
    $apiRoot = "$($ApiBase.TrimEnd('/'))/api/v1"

    # --- Tag resolution -------------------------------------------------------
    # Same default as build-release.ps1, so the image tag, the installer names and
    # the version the app reports in its own window all agree.
    if (-not $Tag) {
        $pkg = Get-Content (Join-Path $repoRoot "package.json") -Raw | ConvertFrom-Json
        $Tag = "v$($pkg.version)"
    }
    # A published tag nobody can check out again is worth naming out loud. The tag
    # comes from package.json rather than git describe, so the dirty state has to
    # be asked for separately.
    $dirty = $false
    try { $dirty = [bool](git status --porcelain 2>$null) } catch { }
    if ($dirty -or $Tag -like "*-dirty") {
        Write-Warning "the worktree is dirty — the artifacts published as '$Tag' won't match any commit. Commit first."
    }

    $base = "$Registry/$Owner/$Image"
    $tags = @("$base`:$Tag")
    if (-not $NoLatest -and $Tag -ne "latest") { $tags += "$base`:latest" }

    Write-Host "Motionity publish" -ForegroundColor Cyan
    Write-Host "  registry : $Registry"
    if ($pushImage) {
        Write-Host "  image    : $base"
        Write-Host "  tags     : $($tags -join ', ')"
        Write-Host "  ffmpeg   : $(if ($WithFfmpeg -eq '1') { 'bundled' } else { 'fetched at run time (WITH_FFMPEG=0)' })"
    }
    else {
        Write-Host "  image    : skipped (-BinariesOnly)"
    }
    Write-Host "  binaries : $(if ($NoBinaries) { 'skipped' } elseif ($NoBinaryBuild) { 'dist/ (reused, not rebuilt)' } else { $Targets -join ', ' })"
    Write-Host "  release  : $(if ($PublishRelease) { "$ReleaseRepo @ $Tag" } else { 'not uploaded' })"
    Write-Host ""

    # PowerShell 5.1 still defaults to TLS 1.0 on some hosts, which every current
    # Gitea rejects — the API call would fail with an opaque connection error.
    if ($PublishRelease -and [Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    # --- Build ----------------------------------------------------------------
    if (-not $NoBuild) {
        Write-Host "Building image..." -ForegroundColor Cyan
        # The Dockerfile has no ARG VERSION — the image is a static file server and
        # carries no version string of its own, so the tag is the only marker.
        $buildArgs = @("build") + @("--build-arg", "WITH_FFMPEG=$WithFfmpeg")
        foreach ($t in $tags) { $buildArgs += @("-t", $t) }
        $buildArgs += "."
        Invoke-Checked docker $buildArgs
        Write-Host ""
    }

    # --- Release artifacts ----------------------------------------------------
    # Built before the push so a failing build doesn't leave a pushed image with
    # no matching installers for the same tag.
    $artifacts = @()
    if (-not $NoBinaries) {
        $distDir = Join-Path $repoRoot "dist"

        if ($NoBinaryBuild) {
            Write-Host "Reusing existing build..." -ForegroundColor Cyan
            if (-not (Test-Path $distDir)) {
                throw "-NoBinaryBuild was set but $distDir does not exist — build first (drop the flag, or run scripts/build-release.ps1)."
            }

            # Uploading an installer older than the code it claims to be is the one
            # way this flag can quietly go wrong, so say so rather than assume.
            $oldest = (Get-ChildItem $distDir -Filter "motionity-$Tag-*" -File |
                Sort-Object LastWriteTime | Select-Object -First 1)
            if (-not $oldest) {
                throw "no installers matching motionity-$Tag-* in $distDir — what is on disk was built under a different tag. Drop -NoBinaryBuild."
            }
            # src/ is the app: every extension the packaged tree actually serves,
            # plus the packaging scripts themselves.
            $newer = Get-ChildItem $repoRoot -Recurse -Include *.js, *.cjs, *.mjs, *.html, *.css, *.json -File |
                Where-Object {
                    $_.FullName -notlike "$distDir*" -and
                    $_.FullName -notlike "*\node_modules\*" -and
                    $_.FullName -notlike "*/node_modules/*" -and
                    $_.LastWriteTime -gt $oldest.LastWriteTime
                }
            if ($newer) {
                Write-Warning "$($oldest.Name) predates $($newer.Count) source file(s) — the installers may not contain your latest changes (newest: $(($newer | Sort-Object LastWriteTime -Descending)[0].Name))."
            }
        }
        else {
            Write-Host "Building desktop installers..." -ForegroundColor Cyan
            # build-release.ps1 throws on any failure and $ErrorActionPreference=Stop
            # propagates it, so there is nothing to test an exit code against —
            # `& script.ps1` leaves $LASTEXITCODE untouched, and with -NoBuild no
            # docker command has reset it, so checking it would rethrow whatever the
            # caller's shell last failed at.
            # -WslDistro is only passed when set: build-release.ps1 treats an empty
            # string as "not requested" either way, but splatting nothing keeps the
            # -WhatIf/-Verbose trace readable.
            $buildParams = @{
                Tag        = $Tag
                Targets    = $Targets
                SkipVendor = $SkipVendor
                UseWsl     = $UseWsl
            }
            if ($WslDistro) { $buildParams["WslDistro"] = $WslDistro }
            & (Join-Path $PSScriptRoot "build-release.ps1") @buildParams
        }

        $artifacts = @(Get-ChildItem $distDir -Filter "motionity-$Tag-*" -File | ForEach-Object FullName)
        if (-not $artifacts.Count) { throw "no installers for $Tag found in $distDir." }
        $sums = Join-Path $distDir "SHA256SUMS.txt"
        if (Test-Path $sums) { $artifacts += $sums }
        Write-Host ""
    }

    # --- Login ----------------------------------------------------------------
    if (-not $SkipLogin) {
        if (-not $Username) { $Username = $env:GITEA_USER }
        if (-not $Username) { $Username = Read-Host "Gitea username for $Registry" }

        $Password = Resolve-Token -Provided $Password -Purpose "registry push as $Username"

        Write-Host "Logging in to $Registry as $Username..." -ForegroundColor Cyan
        # Pass the token via stdin so it never lands in process args or history.
        $Password | docker login $Registry --username $Username --password-stdin
        if ($LASTEXITCODE -ne 0) { throw "docker login failed (exit $LASTEXITCODE)." }
        Write-Host ""
    }

    # --- Push -----------------------------------------------------------------
    if ($pushImage) {
        Write-Host "Pushing image..." -ForegroundColor Cyan
        foreach ($t in $tags) { Invoke-Checked docker @("push", $t) }
        Write-Host ""
    }

    # --- Release attachments --------------------------------------------------
    $releaseUrl = $null
    if ($PublishRelease) {
        if (-not $artifacts.Count) {
            throw "-PublishRelease has nothing to upload (was -NoBinaries set?)."
        }
        Write-Host "Uploading artifacts to release $Tag..." -ForegroundColor Cyan
        $Password   = Resolve-Token -Provided $Password -Purpose "release upload to $ReleaseRepo"
        $releaseUrl = Publish-BinaryRelease -ApiRoot $apiRoot -RepoPath $ReleaseRepo -Tag $Tag `
            -Token $Password -Artifacts $artifacts -Force:$Force
        Write-Host ""
    }

    Write-Host "Done." -ForegroundColor Green
    if ($pushImage) {
        Write-Host "Pushed:" -ForegroundColor Green
        foreach ($t in $tags) { Write-Host "  $t" -ForegroundColor Green }
    }
    if ($artifacts.Count) {
        $where = if ($PublishRelease) { "attached to release $Tag" } else { "built locally — attach to a release manually" }
        Write-Host "Artifacts ($where):" -ForegroundColor Green
        foreach ($a in $artifacts) { Write-Host "  $a" -ForegroundColor Green }
        if ($releaseUrl) { Write-Host "  $ApiBase/$ReleaseRepo/releases/tag/$Tag" -ForegroundColor Green }
    }
}
finally {
    Pop-Location
}
