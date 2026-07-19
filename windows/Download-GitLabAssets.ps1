<#
.SYNOPSIS
  Download every GitLab package / Docker image needed for an OFFLINE upgrade
  from 16.1 to the latest release, and assemble a self-contained "bundle"
  folder you copy to each air-gapped Ubuntu server.

.DESCRIPTION
  Runs on an ONLINE Windows machine. Reads the required upgrade "stops" from
  config\upgrade-path.conf and, for each one, downloads:
    * the Omnibus .deb package (for the deb-installed server), and/or
    * the Docker image, saved as a .tar (for the Docker server).
  It also copies the Linux-side scripts and writes a manifest (bundle.conf) plus
  SHA256SUMS so the server can verify integrity after transfer.

.PARAMETER Edition       ce (default) or ee.
.PARAMETER Codename      Ubuntu codename for the .deb server: jammy (22.04, default) or focal (20.04).
.PARAMETER CurrentVersion  Exact running version(s), e.g. 16.1.8. Included so ROLLBACK is possible. Repeatable.
.PARAMETER TargetVersion   Stop after this version (default: last entry in the path file).
.PARAMETER FromVersion     Only download stops greater than this (default: download the whole path).
.PARAMETER OutDir        Bundle output directory (default: ..\gitlab-offline-bundle).
.PARAMETER Deb           Download .deb packages. If neither -Deb nor -Docker is given, BOTH are done.
.PARAMETER Docker        Download + save Docker images (requires Docker Desktop running).
.PARAMETER Validate      Do NOT download; only HEAD/manifest-check that every asset exists. Run this FIRST.
.PARAMETER SkipScripts   Do not copy the Linux scripts into the bundle.

.EXAMPLE
  # 1) Confirm every version in the path really exists before a big download:
  .\Download-GitLabAssets.ps1 -CurrentVersion 16.1.8 -Validate

.EXAMPLE
  # 2) Download BOTH deb (jammy) and docker images + rollback baseline:
  .\Download-GitLabAssets.ps1 -Codename jammy -CurrentVersion 16.1.8

.EXAMPLE
  # Only the docker server's images:
  .\Download-GitLabAssets.ps1 -Docker -CurrentVersion 16.1.6
#>
[CmdletBinding()]
param(
  [string]$Config = "$PSScriptRoot\..\config\upgrade-path.conf",
  [ValidateSet('ce','ee')][string]$Edition = 'ce',
  [ValidateSet('jammy','focal')][string]$Codename = 'jammy',
  [string[]]$CurrentVersion = @(),
  [string]$TargetVersion = '',
  [string]$FromVersion = '',
  [string]$OutDir = "$PSScriptRoot\..\gitlab-offline-bundle",
  [switch]$Deb,
  [switch]$Docker,
  [switch]$Validate,
  [switch]$SkipScripts
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

if (-not $Deb -and -not $Docker) { $Deb = $true; $Docker = $true }

function Info($m){ Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# ---- read upgrade path -------------------------------------------------------
if (-not (Test-Path $Config)) { Fail "Upgrade-path file not found: $Config" }
$versions = Get-Content $Config |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -and -not $_.StartsWith('#') }

if (-not $versions) { Fail "No versions found in $Config" }
if (-not $TargetVersion) { $TargetVersion = $versions[-1] }

# filter by From/Target
$plan = @()
foreach ($v in $versions) {
  if ($FromVersion   -and ([version]$v -le [version]$FromVersion))   { continue }
  if ($TargetVersion -and ([version]$v -gt [version]$TargetVersion)) { continue }
  $plan += $v
}
# Full download set = rollback baselines (current versions) + the path stops.
$downloadSet = @()
$downloadSet += $CurrentVersion
$downloadSet += $plan
$downloadSet = $downloadSet | Where-Object { $_ } | Select-Object -Unique

Info "Edition        : $Edition"
Info "Deb codename   : $Codename"
Info "Target version : $TargetVersion"
Info "Path stops     : $($plan -join ', ')"
if ($CurrentVersion) { Info "Rollback base  : $($CurrentVersion -join ', ')" }
$assetKinds = @(); if ($Deb) { $assetKinds += 'deb' }; if ($Docker) { $assetKinds += 'docker' }
Info "Assets         : $($assetKinds -join ' + ')"
Info "Bundle dir     : $OutDir"
Write-Host ""

# ---- prepare dirs ------------------------------------------------------------
if (-not $Validate) {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  # Resolve to an ABSOLUTE path now: later code substrings FullName against it.
  $OutDir = (Resolve-Path $OutDir).Path
}
$debDir    = Join-Path $OutDir "assets\deb\$Codename"
$dockerDir = Join-Path $OutDir "assets\docker"
if (-not $Validate) {
  if ($Deb)    { New-Item -ItemType Directory -Force -Path $debDir    | Out-Null }
  if ($Docker) { New-Item -ItemType Directory -Force -Path $dockerDir | Out-Null }
}

# ---- helpers -----------------------------------------------------------------
function Deb-Url($ver){
  $file = "gitlab-${Edition}_${ver}-${Edition}.0_amd64.deb"
  $url  = "https://packages.gitlab.com/gitlab/gitlab-${Edition}/packages/ubuntu/${Codename}/${file}/download.deb"
  return @{ File = $file; Url = $url }
}
function Image-Ref($ver){ "gitlab/gitlab-${Edition}:${ver}-${Edition}.0" }
function Image-Tar($ver){ "gitlab-${Edition}-${ver}-${Edition}.0.tar" }

function Test-Deb($ver){
  $d = Deb-Url $ver
  try {
    $r = Invoke-WebRequest -Uri $d.Url -Method Head -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 60
    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { return $true }
  } catch {}
  # Fallback: some CDNs reject HEAD on the redirect target; fetch just 1 byte.
  try {
    $r = Invoke-WebRequest -Uri $d.Url -Method Get -Headers @{ Range = 'bytes=0-0' } `
           -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 60
    return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
  } catch { return $false }
}
function Get-Deb($ver){
  $d = Deb-Url $ver
  $out = Join-Path $debDir $d.File
  if ((Test-Path $out) -and (Get-Item $out).Length -gt 1MB) { Ok "deb $ver already downloaded"; return }
  Info "Downloading deb $ver ..."
  $attempt = 0
  while ($true) {
    $attempt++
    try {
      Invoke-WebRequest -Uri $d.Url -OutFile $out -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 1800
      if ((Get-Item $out).Length -lt 1MB) { throw "downloaded file suspiciously small" }
      Ok ("deb {0} -> {1} ({2:N0} MB)" -f $ver, $d.File, ((Get-Item $out).Length/1MB))
      break
    } catch {
      if ($attempt -ge 4) { Fail "Failed to download deb $ver after $attempt attempts: $_" }
      $wait = [math]::Pow(2,$attempt)
      Warn "deb $ver download failed (attempt $attempt): $_. Retrying in ${wait}s..."
      Start-Sleep -Seconds $wait
    }
  }
}
function Test-Image($ver){
  $ref = Image-Ref $ver
  & docker manifest inspect $ref *> $null
  return ($LASTEXITCODE -eq 0)
}
function Save-Image($ver){
  $ref = Image-Ref $ver
  $tar = Join-Path $dockerDir (Image-Tar $ver)
  if ((Test-Path $tar) -and (Get-Item $tar).Length -gt 100MB) { Ok "image $ver already saved"; return }
  Info "Pulling image $ref ..."
  & docker pull $ref
  if ($LASTEXITCODE -ne 0) { Fail "docker pull failed for $ref" }
  Info "Saving image to $(Split-Path $tar -Leaf) ..."
  & docker save -o $tar $ref
  if ($LASTEXITCODE -ne 0) { Fail "docker save failed for $ref" }
  Ok ("image {0} -> {1} ({2:N0} MB)" -f $ver, (Image-Tar $ver), ((Get-Item $tar).Length/1MB))
}

# ---- validate mode -----------------------------------------------------------
if ($Validate) {
  Info "VALIDATE mode: checking that every asset exists (no download).`n"
  $bad = 0
  foreach ($v in $downloadSet) {
    if ($Deb) {
      if (Test-Deb $v) { Ok "deb    $v  OK" } else { Warn "deb    $v  MISSING (check the version/patch number)"; $bad++ }
    }
    if ($Docker) {
      if (Test-Image $v) { Ok "image  $v  OK" } else { Warn "image  $v  MISSING (check the version/patch number, and that Docker is running)"; $bad++ }
    }
  }
  Write-Host ""
  if ($bad -gt 0) { Fail "$bad asset(s) not found. Fix config\upgrade-path.conf (see the official upgrade-path tool) and re-validate." }
  Ok "All assets are available. Re-run WITHOUT -Validate to download them."
  exit 0
}

# ---- download ----------------------------------------------------------------
foreach ($v in $downloadSet) {
  if ($Deb)    { Get-Deb   $v }
  if ($Docker) { Save-Image $v }
}

# ---- copy linux scripts + config ---------------------------------------------
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $SkipScripts) {
  $linuxDir = Join-Path $repoRoot 'linux'
  if (Test-Path $linuxDir) {
    Info "Copying Linux scripts into bundle..."
    Copy-Item (Join-Path $linuxDir 'gitlab-offline-upgrade.sh') $OutDir -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'lib') | Out-Null
    Copy-Item (Join-Path $linuxDir 'lib\*.sh') (Join-Path $OutDir 'lib') -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'config') | Out-Null
    Copy-Item $Config (Join-Path $OutDir 'config\upgrade-path.conf') -Force
    $readme = Join-Path $repoRoot 'README.md'
    if (Test-Path $readme) { Copy-Item $readme $OutDir -Force }
    Ok "Scripts copied."
  } else {
    Warn "linux\ folder not found next to this script; run the Linux scripts from the repo separately."
  }
}

# ---- write manifest (bundle.conf) --------------------------------------------
$pathStr = ($plan -join ' ')
$curStr  = ($CurrentVersion -join ',')
$bundleConf = @(
  "# Generated by Download-GitLabAssets.ps1 on $(Get-Date -Format s)"
  "EDITION=$Edition"
  "CODENAME=$Codename"
  "CURRENT_VERSION=$curStr"
  "TARGET_VERSION=$TargetVersion"
  "UPGRADE_PATH=`"$pathStr`""
  "INCLUDES_DEB=$([int][bool]$Deb)"
  "INCLUDES_DOCKER=$([int][bool]$Docker)"
) -join "`n"
[IO.File]::WriteAllText((Join-Path $OutDir 'bundle.conf'), $bundleConf + "`n")
Ok "Wrote bundle.conf"

# ---- checksums ---------------------------------------------------------------
Info "Computing SHA256SUMS (for integrity verification on the server)..."
$sumsFile = Join-Path $OutDir 'SHA256SUMS'
if (Test-Path $sumsFile) { Remove-Item $sumsFile -Force }
$lines = @()
Get-ChildItem -Path $OutDir -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS' } | ForEach-Object {
  $rel = $_.FullName.Substring($OutDir.Length).TrimStart('\','/').Replace('\','/')
  $h = (Get-FileHash -Algorithm SHA256 -Path $_.FullName).Hash.ToLower()
  $lines += "$h  $rel"
}
[IO.File]::WriteAllText($sumsFile, (($lines -join "`n") + "`n"))
Ok "Wrote SHA256SUMS ($($lines.Count) files)"

# ---- summary -----------------------------------------------------------------
$size = (Get-ChildItem -Path $OutDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ""
Ok ("Bundle ready: {0}" -f $OutDir)
Ok ("Total size  : {0:N2} GB" -f ($size/1GB))
Info "Next steps:"
Info "  1. Copy the ENTIRE '$OutDir' folder to each offline Ubuntu server."
Info "  2. On the server:  chmod +x gitlab-offline-upgrade.sh"
Info "  3. Run:            sudo ./gitlab-offline-upgrade.sh preflight"
Info "  4. Then:           sudo ./gitlab-offline-upgrade.sh upgrade"
