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

    An existing release is added to, not recreated: artifacts it does not have yet
    are appended, and ones it already carries under the same name are replaced by the
    freshly built file. That makes re-running a release after a rebuild safe, and
    keeps the attachments in agreement with the SHA256SUMS.txt uploaded beside them.
    -NoReplace turns a name collision back into an error.

    -BinariesOnly ships just the installers: no docker build, no docker login, no
    image push, and the release upload is implied. It takes the target list to
    build (win, linux-appimage, linux-flatpak — comma-separated) and that list
    overrides -Targets. The Linux targets need a Linux host or WSL: on Windows,
    add -UseWsl and build-release.ps1 hands them to a WSL distro.

    -WinInWsl and -KeepInWsl are forwarded to build-release.ps1 and together keep
    the unsigned .exe off NTFS entirely: it is built in the distro and, because
    -KeepInWsl skips the copy back, it is still there at upload time. This script
    then reads dist/wsl-artifacts.json and runs the curl upload *inside* the distro
    for those files, so the endpoint agent never sees a write it can quarantine.
    The token reaches the distro through WSLENV, not through the command line.

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
    ./scripts/publish.ps1 -Tag v1.1.0 -PublishRelease -WinInWsl -KeepInWsl
    Full release with every installer built in WSL and uploaded from there — no
    unsigned binary is ever written to a Windows filesystem.

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

    # Forwarded to build-release.ps1. "linux" is shorthand for both Linux bundles;
    # "win" is NSIS + portable, and win-nsis / win-portable are those two on their
    # own (only the NSIS one needs Wine when built in WSL).
    [ValidateSet("win", "win-nsis", "win-portable", "linux", "linux-appimage", "linux-flatpak")]
    [string[]]$Targets = @("win", "linux"),
    [switch]$SkipVendor,

    # Forwarded to build-release.ps1: build the Linux targets in a WSL distro
    # instead of warning that Windows cannot produce them.
    [switch]$UseWsl,
    [string]$WslDistro,

    # Forwarded to build-release.ps1: build the Windows targets in WSL too, and
    # leave what WSL built inside the distro. With -KeepInWsl the upload below runs
    # in the distro instead of on Windows, so the .exe never reaches NTFS.
    [switch]$WinInWsl,
    [switch]$KeepInWsl,

    # Reuse the installers already in dist/ instead of re-running the build. For
    # retrying a failed upload without paying for the build again.
    [switch]$NoBinaryBuild,

    # Ship only the installers: no docker build, login or push. Implies
    # -PublishRelease, since building alone is what build-release.ps1 already does.
    # Takes the target list to build (comma-separated), which overrides -Targets:
    #   -BinariesOnly win,linux-appimage
    [ValidateSet("win", "win-nsis", "win-portable", "linux-appimage", "linux-flatpak")]
    [string[]]$BinariesOnly,

    # Attach the installers to the Gitea release for $Tag, creating the release if
    # it is missing.
    [switch]$PublishRelease,

    # owner/repo holding the release. Defaults to $Owner/$Repo.
    [string]$ReleaseRepo,

    # Gitea base URL for the API. Defaults to https://<Registry>.
    [string]$ApiBase,

    # Fail instead of replacing an attachment that already exists under the same
    # name. The default is to replace, because re-running a release for the same tag
    # after a rebuild is the normal case and the new file is the one that matches
    # SHA256SUMS.txt.
    [switch]$NoReplace,

    # Deprecated: replacing is now the default, so this does nothing. Kept so
    # existing commands and scripts do not start failing on an unknown parameter.
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

function ConvertTo-BashScript {
    <#
        Strip CR. This file is stored with CRLF line endings, so a multi-line
        here-string handed to bash arrives with a \r on every line and bash reads it
        as part of the last token — `set: - : invalid option`, and paths that end in
        a literal \r. Single-line commands never show it.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Script)
    return $Script -replace "`r", ""
}

<#
    And the companion trap: `set -e` plus an explicit `exit 0` under `bash -lc` yields
    1, because a login shell sources ~/.bash_logout on exit and Ubuntu's ends in a
    `[ -x /usr/bin/clear_console ] && ...` that fails with no tty, which errexit then
    promotes to the shell's status. -l has to stay (node from nvm/fnm lives on the
    login PATH), so the scripts below set only `-u` and check what matters explicitly.
#>

function Get-WslArtifactManifest {
    <#
        build-release.ps1 -KeepInWsl writes dist/wsl-artifacts.json for the artifacts
        it deliberately did not copy onto NTFS. It removes the file whenever a build
        leaves nothing behind, so its presence means "these files are in the distro";
        the tag is still checked, because a -NoBinaryBuild run for a different tag
        would otherwise upload the previous release's binaries under the new one.
    #>
    param([Parameter(Mandatory)][string]$DistDir, [Parameter(Mandatory)][string]$Tag)

    $path = Join-Path $DistDir "wsl-artifacts.json"
    if (-not (Test-Path $path)) { return $null }

    $manifest = Get-Content $path -Raw | ConvertFrom-Json
    if (-not $manifest.files -or -not @($manifest.files).Count) { return $null }
    if ($manifest.tag -ne $Tag) {
        throw "$path was written for tag '$($manifest.tag)', not '$Tag' — those artifacts belong to another release. Rebuild, or delete the file if it is stale."
    }
    if (-not $manifest.distro -or -not $manifest.stageDir) {
        throw "$path is missing the distro or stageDir field — delete it and rebuild."
    }
    return $manifest
}

function Invoke-WithWslEnv {
    <#
        Run a script block with $Name exported into WSL through WSLENV.

        WSLENV is the only way to hand a value to a WSL process without putting it in
        an argument list, and an argument list is exactly where a token must not be:
        wsl.exe's own command line is readable from the Windows process table. The
        previous WSLENV is restored rather than overwritten, because a distro may
        rely on entries somebody else put there (PATH translation flags in
        particular are positional and easy to break).
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    $previousValue  = [Environment]::GetEnvironmentVariable($Name, "Process")
    $previousWslEnv = $env:WSLENV
    [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
    $env:WSLENV = if ($previousWslEnv) { "$previousWslEnv`:$Name" } else { $Name }
    try {
        & $Body
    }
    finally {
        [Environment]::SetEnvironmentVariable($Name, $previousValue, "Process")
        if ($null -eq $previousWslEnv) {
            Remove-Item Env:\WSLENV -ErrorAction SilentlyContinue
        }
        else {
            $env:WSLENV = $previousWslEnv
        }
    }
}

function Test-WslArtifacts {
    <#
        Every file the manifest names must still be in the staging directory. Without
        this the first missing one surfaces as a curl error about an unreadable
        upload part, halfway through a release.
    #>
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][string[]]$Names
    )

    $script = @'
set -u
cd "$1" || { echo "staging directory $1 is gone" >&2; exit 1; }
shift
missing=0
for f in "$@"; do
    [ -f "$f" ] || { echo "$f" >&2; missing=1; }
done
exit $missing
'@
    & wsl.exe -d $Distro -e bash -lc (ConvertTo-BashScript $script) "motionity-publish" $StageDir @Names 2>&1 |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        throw "artifacts named in dist/wsl-artifacts.json are missing from ${StageDir} in '$Distro' (listed above) — rebuild with -WinInWsl -KeepInWsl, or drop -NoBinaryBuild."
    }
}

function Get-WslArtifactMtime {
    <#
        Oldest mtime among the staged artifacts, as a local DateTime, so the
        -NoBinaryBuild staleness check works on WSL-resident files too.
    #>
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][string[]]$Names
    )

    $script = @'
set -u
cd "$1" || exit 1
shift
stat -c %Y -- "$@" | sort -n | head -n 1
'@
    $out = (& wsl.exe -d $Distro -e bash -lc (ConvertTo-BashScript $script) "motionity-publish" $StageDir @Names)
    $epoch = (@($out) -join "").Replace("`0", "").Trim()
    if ($LASTEXITCODE -ne 0 -or $epoch -notmatch '^\d+$') { return $null }
    return [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$epoch).LocalDateTime
}

function Send-ReleaseAssetFromWsl {
    <#
        Upload one staged file as a release attachment, with curl running inside the
        distro. Same Gitea endpoint and the same --config indirection for the token as
        Send-ReleaseAsset; the only reason for a second implementation is that the
        file must not be copied to NTFS to be read.

        The config file is written by bash from $GITEA_UPLOAD_TOKEN (arriving via
        WSLENV) rather than interpolated into the command string, so the token is in
        neither wsl.exe's arguments nor the distro's process table. mktemp creates it
        0600, and the trap removes it even if curl dies.
    #>
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uri
    )

    # fail-with-body needs curl 7.76+ (Ubuntu 22.04 ships 7.81); the Windows path
    # above already assumes it, so the two behave the same on an HTTP error.
    $script = @'
set -u
command -v curl >/dev/null 2>&1 || { echo "curl is not installed in this WSL distro: sudo apt install -y curl" >&2; exit 127; }
[ -n "${GITEA_UPLOAD_TOKEN:-}" ] || { echo "GITEA_UPLOAD_TOKEN did not reach the distro — is WSLENV being overwritten?" >&2; exit 2; }
cfg=$(mktemp) || { echo "could not create a temp file for the curl config" >&2; exit 1; }
trap 'rm -f "$cfg"' EXIT
printf 'header = "Authorization: token %s"\nsilent\nshow-error\nfail-with-body\n' "$GITEA_UPLOAD_TOKEN" > "$cfg" || exit 1
cd "$1" || exit 1
# Last command on purpose: curl's status is the script's status.
curl --config "$cfg" --write-out '  http %{http_code}, %{size_upload} bytes uploaded\n' -F "attachment=@$2" "$3"
'@
    Write-Host "  > [$Distro] curl --config <temp> -F attachment=@$Name `"$Uri`"" -ForegroundColor DarkGray
    & wsl.exe -d $Distro -e bash -lc (ConvertTo-BashScript $script) "motionity-publish" $StageDir $Name $Uri
    if ($LASTEXITCODE -ne 0) {
        throw "upload of '$StageDir/$Name' from '$Distro' failed (exit $LASTEXITCODE)."
    }
}

function Get-ReleaseBody {
    <#
        The markdown shown on the Gitea release page: how to run each artifact.

        A literal here-string, because an expandable one treats ``` as backtick
        escapes and the third one would swallow the newline as a line continuation.
        The two placeholders are substituted afterwards instead, and the content sits
        at column 0 because four leading spaces would make markdown read it as code.
    #>
    param([Parameter(Mandatory)][string]$Tag)

    $body = @'
## Linux

### AppImage

Make it executable: `chmod +x motionity-%TAG%-linux-x86_64.AppImage`, then launch it (needs `libfuse2` installed).

### Flatpak

```
flatpak install ./motionity-%TAG%-linux-x86_64.flatpak
```

## Windows

Launch the installer or the portable version directly. A SmartScreen warning may appear, as the binary is not signed.

## Docker

Recommended: `docker-compose.yml`

```yaml
services:
  motionity:
    image: %IMAGE%:%TAG%
    ports:
      - 8080:8080
    restart: unless-stopped
```
'@

    return $body.Replace("%IMAGE%", "$Registry/$Owner/$Image").Replace("%TAG%", $Tag)
}

function Publish-BinaryRelease {
    <#
        Attach the installers to the release for $Tag, creating that release if it
        does not exist yet. An existing release is added to, never recreated.

        A file name the release already carries is replaced: Gitea does not treat
        attachment names as unique, so uploading over one without removing it first
        leaves two assets with the same name and no way for anyone to tell which is
        which. Replacing is the default because the alternative is a release whose
        binaries disagree with its own SHA256SUMS.txt after a rebuild; -NoReplace
        restores the strict behaviour.

        Delete-then-upload, in that order, for the same reason — which does mean a
        failed upload leaves the old asset gone. Recover with -NoBinaryBuild, which
        re-attaches from dist/ (or from the distro) without rebuilding.
    #>
    param(
        [Parameter(Mandatory)][string]$ApiRoot,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Token,
        # Windows-side files, uploaded by curl.exe.
        [string[]]$Artifacts = @(),
        # Files still in a WSL staging directory, uploaded by curl inside the distro.
        [string[]]$WslArtifacts = @(),
        [string]$WslDistro,
        [string]$WslStageDir,
        [switch]$NoReplace
    )

    $releasesUri = "$ApiRoot/repos/$RepoPath/releases"
    $release = Invoke-GiteaApi -Method GET -Uri "$releasesUri/tags/$Tag" -Token $Token

    if (-not $release) {
        Write-Host "  creating release $Tag in $RepoPath..." -ForegroundColor DarkGray
        $release = Invoke-GiteaApi -Method POST -Uri $releasesUri -Token $Token -Body @{
            tag_name = $Tag
            name     = "Motionity $Tag"
            body     = (Get-ReleaseBody -Tag $Tag)
            draft    = $false
        }
        if (-not $release) { throw "could not create release $Tag in $RepoPath (does the repo exist?)." }
    }
    else {
        Write-Host "  reusing release $Tag (id $($release.id))" -ForegroundColor DarkGray
    }

    # One list so the asset-already-exists handling is written once: only the final
    # transfer differs between a file on NTFS and one left in the distro.
    $uploads = @()
    foreach ($path in $Artifacts)    { $uploads += @{ Name = (Split-Path -Leaf $path); Path = $path; InWsl = $false } }
    foreach ($name in $WslArtifacts) { $uploads += @{ Name = $name;                    Path = $null; InWsl = $true } }

    foreach ($upload in $uploads) {
        $name = $upload.Name
        # @() because a release can already hold several assets under one name — an
        # earlier run that uploaded without deleting, or a partial retry. Unwrapped,
        # $existing.id would be an array and the DELETE would go to a malformed URL.
        $existing = @($release.assets | Where-Object { $_.name -eq $name })
        if ($existing.Count) {
            if ($NoReplace) {
                throw "release $Tag already has an attachment named '$name', and -NoReplace was passed. Drop it to replace the file, or upload under a different tag."
            }
            foreach ($asset in $existing) {
                Write-Host "  replacing attachment '$name' (asset $($asset.id))..." -ForegroundColor DarkGray
                Invoke-GiteaApi -Method DELETE -Token $Token `
                    -Uri "$releasesUri/$($release.id)/assets/$($asset.id)" | Out-Null
            }
        }
        else {
            Write-Host "  adding attachment '$name'..." -ForegroundColor DarkGray
        }
        $encoded  = [System.Uri]::EscapeDataString($name)
        $assetUri = "$releasesUri/$($release.id)/assets?name=$encoded"
        if ($upload.InWsl) {
            Send-ReleaseAssetFromWsl -Distro $WslDistro -StageDir $WslStageDir -Name $name -Uri $assetUri
        }
        else {
            Send-ReleaseAsset -Token $Token -Path $upload.Path -Uri $assetUri
        }
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
    if ($Force) {
        Write-Warning "-Force is deprecated and ignored: replacing an attachment that already exists is now the default. -NoReplace is the opt-out."
    }
    if ($Force -and $NoReplace) {
        throw "-Force and -NoReplace ask for opposite things — drop -Force, it is already the default."
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
    Write-Host "  binaries : $(if ($NoBinaries) { 'skipped' } elseif ($NoBinaryBuild) { 'dist/ (reused, not rebuilt)' } else { $Targets -join ', ' })$(if ($WinInWsl) { ' (all in WSL)' } elseif ($UseWsl) { ' (Linux ones in WSL)' })$(if ($KeepInWsl) { ', uploaded from the distro' })"
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
    $artifacts       = @()
    $wslArtifacts    = @()
    $wslUploadDistro = $null
    $wslStageDir     = $null
    if (-not $NoBinaries) {
        $distDir = Join-Path $repoRoot "dist"

        if ($NoBinaryBuild) {
            Write-Host "Reusing existing build..." -ForegroundColor Cyan
            if (-not (Test-Path $distDir)) {
                throw "-NoBinaryBuild was set but $distDir does not exist — build first (drop the flag, or run scripts/build-release.ps1)."
            }

            # Uploading an installer older than the code it claims to be is the one
            # way this flag can quietly go wrong, so say so rather than assume. The
            # artifacts a -KeepInWsl build left in the distro count as present here:
            # dist/ can legitimately hold nothing but SHA256SUMS.txt.
            $manifest = Get-WslArtifactManifest -DistDir $distDir -Tag $Tag
            $oldest = (Get-ChildItem $distDir -Filter "motionity-$Tag-*" -File |
                Sort-Object LastWriteTime | Select-Object -First 1)
            $oldestName = if ($oldest) { $oldest.Name } else { $null }
            $oldestTime = if ($oldest) { $oldest.LastWriteTime } else { $null }

            if ($manifest) {
                Write-Host "  $(@($manifest.files).Count) artifact(s) staged in '$($manifest.distro)':$($manifest.stageDir)" -ForegroundColor DarkGray
                Test-WslArtifacts -Distro $manifest.distro -StageDir $manifest.stageDir -Names @($manifest.files)
                $wslTime = Get-WslArtifactMtime -Distro $manifest.distro -StageDir $manifest.stageDir -Names @($manifest.files)
                if ($wslTime -and (-not $oldestTime -or $wslTime -lt $oldestTime)) {
                    $oldestTime = $wslTime
                    $oldestName = @($manifest.files)[0]
                }
            }
            if (-not $oldestTime) {
                throw "no installers matching motionity-$Tag-* in $distDir and no dist/wsl-artifacts.json for $Tag — what is on disk was built under a different tag. Drop -NoBinaryBuild."
            }

            # src/ is the app: every extension the packaged tree actually serves,
            # plus the packaging scripts themselves.
            $newer = Get-ChildItem $repoRoot -Recurse -Include *.js, *.cjs, *.mjs, *.html, *.css, *.json -File |
                Where-Object {
                    $_.FullName -notlike "$distDir*" -and
                    $_.FullName -notlike "*\node_modules\*" -and
                    $_.FullName -notlike "*/node_modules/*" -and
                    $_.LastWriteTime -gt $oldestTime
                }
            if ($newer) {
                Write-Warning "$oldestName predates $($newer.Count) source file(s) — the installers may not contain your latest changes (newest: $(($newer | Sort-Object LastWriteTime -Descending)[0].Name))."
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
                WinInWsl   = $WinInWsl
                KeepInWsl  = $KeepInWsl
            }
            if ($WslDistro) { $buildParams["WslDistro"] = $WslDistro }
            & (Join-Path $PSScriptRoot "build-release.ps1") @buildParams

            $manifest = Get-WslArtifactManifest -DistDir $distDir -Tag $Tag
            if ($manifest) {
                Test-WslArtifacts -Distro $manifest.distro -StageDir $manifest.stageDir -Names @($manifest.files)
            }
        }

        if ($manifest) {
            $wslArtifacts    = @($manifest.files)
            $wslUploadDistro = $manifest.distro
            $wslStageDir     = $manifest.stageDir
        }

        # A name that exists both in dist/ and in the distro is the WSL build's, and
        # the dist/ copy is a leftover from an earlier native build — uploading both
        # would collide on the release's asset names anyway.
        $artifacts = @(Get-ChildItem $distDir -Filter "motionity-$Tag-*" -File |
            Where-Object { $wslArtifacts -notcontains $_.Name } | ForEach-Object FullName)
        if (-not $artifacts.Count -and -not $wslArtifacts.Count) {
            throw "no installers for $Tag found in $distDir."
        }
        # SHA256SUMS.txt covers both sets and is written on the Windows side either
        # way — it is text, so nothing objects to it landing in dist/.
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
        if (-not $artifacts.Count -and -not $wslArtifacts.Count) {
            throw "-PublishRelease has nothing to upload (was -NoBinaries set?)."
        }
        Write-Host "Uploading artifacts to release $Tag..." -ForegroundColor Cyan
        $Password = Resolve-Token -Provided $Password -Purpose "release upload to $ReleaseRepo"

        $publishArgs = @{
            ApiRoot   = $apiRoot
            RepoPath  = $ReleaseRepo
            Tag       = $Tag
            Token     = $Password
            Artifacts = $artifacts
            NoReplace = $NoReplace
        }
        if ($wslArtifacts.Count) {
            $publishArgs["WslArtifacts"] = $wslArtifacts
            $publishArgs["WslDistro"]    = $wslUploadDistro
            $publishArgs["WslStageDir"]  = $wslStageDir
            # The token is exported for the whole upload rather than per file: WSLENV
            # is process-wide state, and setting and restoring it around every
            # attachment is more windows in which a concurrent wsl.exe sees it.
            $releaseUrl = Invoke-WithWslEnv -Name "GITEA_UPLOAD_TOKEN" -Value $Password -Body {
                Publish-BinaryRelease @publishArgs
            }
        }
        else {
            $releaseUrl = Publish-BinaryRelease @publishArgs
        }
        Write-Host ""
    }

    Write-Host "Done." -ForegroundColor Green
    if ($pushImage) {
        Write-Host "Pushed:" -ForegroundColor Green
        foreach ($t in $tags) { Write-Host "  $t" -ForegroundColor Green }
    }
    if ($artifacts.Count -or $wslArtifacts.Count) {
        $where = if ($PublishRelease) { "attached to release $Tag" } else { "built locally — attach to a release manually" }
        Write-Host "Artifacts ($where):" -ForegroundColor Green
        foreach ($a in $artifacts) { Write-Host "  $a" -ForegroundColor Green }
        foreach ($a in $wslArtifacts) {
            Write-Host "  [$wslUploadDistro] $wslStageDir/$a" -ForegroundColor Green
        }
        if ($releaseUrl) { Write-Host "  $ApiBase/$ReleaseRepo/releases/tag/$Tag" -ForegroundColor Green }
    }
}
finally {
    Pop-Location
}
