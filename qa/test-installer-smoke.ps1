$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repository = "NaldoJr5/diario-de-bordo-updates"
$tag = "v0.2.2-test.2"
$version1 = "0.2.2-test.1"
$version2 = "0.2.2-test.2"
$releaseApi = "https://api.github.com/repos/$repository/releases/tags/$tag"
$workRoot = Join-Path $env:RUNNER_TEMP "diario-updater-installer-smoke"
$markerRelativePath = "com.naldotech.diariodebordoupdaterqa\qa-update-preservation.json"
$expectedMarker = '{"purpose":"fictional updater QA marker","mustSurvive":"0.2.2-test.1 to 0.2.2-test.2"}'

function Get-RequiredAsset([object] $Release, [string] $Name) {
  $found = @($Release.assets | Where-Object { $_.name -ceq $Name })
  if ($found.Count -ne 1) {
    throw "Release $tag must contain exactly one asset named $Name."
  }
  return $found[0]
}

function Get-InstalledQaEntry {
  $roots = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
  )
  $foundEntries = @()
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
      $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
      if ($entry -and $entry.PSObject.Properties["DisplayName"] -and $entry.DisplayName -and
          $entry.DisplayName -match "Di[aá]rio de Bordo" -and
          $entry.DisplayName -match "Updater QA|Atualizador QA") {
        $foundEntries += $entry
      }
    }
  }
  if ($foundEntries.Count -ne 1) {
    throw "Expected exactly one installed QA app entry; found $($foundEntries.Count)."
  }
  if (-not $foundEntries[0].PSObject.Properties["DisplayVersion"]) {
    throw "The QA app uninstall entry does not expose its installed version."
  }
  return $foundEntries[0]
}

function Assert-InstalledVersion([string] $Expected) {
  $entry = Get-InstalledQaEntry
  $actual = ([string]$entry.DisplayVersion).Trim().TrimStart("v")
  if ($actual -cne $Expected) {
    throw "Expected installed version $Expected; uninstall registration reports '$actual'."
  }
  Write-Host "PASS installed version $Expected (Windows uninstall registration)"
}

function Invoke-SilentInstaller([string] $Path, [string] $ExpectedVersion) {
  Write-Host "Installing $ExpectedVersion silently from the published QA package."
  $process = Start-Process -FilePath $Path -ArgumentList "/S" -PassThru -WindowStyle Hidden
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    throw "Silent installation of $ExpectedVersion returned exit code $($process.ExitCode)."
  }
  Assert-InstalledVersion $ExpectedVersion
}

try {
  if ($env:GITHUB_ACTIONS -cne "true" -or $env:RUNNER_OS -cne "Windows" -or -not $env:RUNNER_TEMP) {
    throw "This test must run only on a GitHub-hosted Windows runner."
  }
  New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

  $release = Invoke-RestMethod -Uri $releaseApi -Headers @{ "User-Agent" = "diario-updater-qa-smoke" }
  if ($release.tag_name -cne $tag -or -not $release.prerelease -or $release.draft) {
    throw "The pinned QA tag is missing, is not a prerelease, or is a draft."
  }

  $assetNames = @(
    "diario-updater-qa-0.2.2-test.1-x64-setup.exe",
    "diario-updater-qa-0.2.2-test.1-x64-setup.exe.sig",
    "diario-updater-qa-0.2.2-test.2-x64-setup.exe",
    "diario-updater-qa-0.2.2-test.2-x64-setup.exe.sig",
    "latest.json",
    "SHA256SUMS.txt"
  )
  $downloaded = @{}
  foreach ($name in $assetNames) {
    $asset = Get-RequiredAsset $release $name
    $path = Join-Path $workRoot $name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $path -MaximumRedirection 10
    if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -le 0) {
      throw "Asset download is empty: $name."
    }
    if (-not $asset.digest -or $asset.digest -notmatch "^sha256:([0-9a-fA-F]{64})$") {
      throw "GitHub did not provide a SHA-256 digest for $name."
    }
    $downloaded[$name] = $path
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $published = $Matches[1].ToLowerInvariant()
    if ($actual -cne $published) {
      throw "GitHub asset digest mismatch for $name."
    }
    Write-Host "PASS GitHub asset digest: $name"
  }

  $checksums = @{}
  foreach ($line in Get-Content -LiteralPath $downloaded["SHA256SUMS.txt"]) {
    if ($line -match "^(?<hash>[0-9a-fA-F]{64})\s+\*?(?<name>.+?)\s*$") {
      $checksums[$Matches.name] = $Matches.hash.ToLowerInvariant()
    }
  }
  foreach ($name in $assetNames | Where-Object { $_ -ne "SHA256SUMS.txt" }) {
    if (-not $checksums.ContainsKey($name)) { throw "SHA256SUMS.txt has no checksum for $name." }
    $actual = (Get-FileHash -LiteralPath $downloaded[$name] -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $checksums[$name]) { throw "SHA256SUMS.txt mismatch for $name." }
    Write-Host "PASS release checksum: $name"
  }

  $manifest = Get-Content -LiteralPath $downloaded["latest.json"] -Raw | ConvertFrom-Json
  if ($manifest.version -cne $version2) { throw "The QA manifest does not advertise $version2." }
  $platform = $manifest.platforms.'windows-x86_64'
  if (-not $platform -or
      $platform.url -cne (Get-RequiredAsset $release "diario-updater-qa-0.2.2-test.2-x64-setup.exe").browser_download_url) {
    throw "The QA manifest does not point to the published .2 installer."
  }
  $signature2 = (Get-Content -LiteralPath $downloaded["diario-updater-qa-0.2.2-test.2-x64-setup.exe.sig"] -Raw).Trim()
  if (-not $signature2 -or $platform.signature.Trim() -cne $signature2) {
    throw "The manifest signature field does not match the published .2 signature file."
  }
  Write-Host "PASS manifest points to .2 and carries its published signature text (not a plugin signature test)"

  Invoke-SilentInstaller $downloaded["diario-updater-qa-0.2.2-test.1-x64-setup.exe"] $version1

  $markerPath = Join-Path $env:APPDATA $markerRelativePath
  New-Item -ItemType Directory -Path (Split-Path -Parent $markerPath) -Force | Out-Null
  Set-Content -LiteralPath $markerPath -Value $expectedMarker -Encoding utf8NoBOM
  $markerBefore = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash

  Invoke-SilentInstaller $downloaded["diario-updater-qa-0.2.2-test.2-x64-setup.exe"] $version2

  if (-not (Test-Path -LiteralPath $markerPath)) { throw "The fictitious app-data marker was removed." }
  if ((Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash -cne $markerBefore) {
    throw "The fictitious app-data marker changed during the .1 to .2 installer update."
  }
  if ((Get-Content -LiteralPath $markerPath -Raw).Trim() -cne $expectedMarker) {
    throw "The fictitious app-data marker content changed."
  }
  Write-Host "PASS fictional app-data marker preserved across silent .1 to .2 install"
  Write-Host "PASS installer smoke only; no GUI, confirmation, plugin updater, or real-update flow was exercised."
}
finally {
  if ($workRoot -and $env:RUNNER_TEMP -and
      [System.IO.Path]::GetFullPath($workRoot).StartsWith([System.IO.Path]::GetFullPath($env:RUNNER_TEMP), [System.StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $workRoot)) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
  }
}
