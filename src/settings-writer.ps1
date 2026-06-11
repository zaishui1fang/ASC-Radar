param(
  [string]$DbFile = "",
  [string]$MutexName = "",
  [string]$CloseToTray = "true",
  [string]$AutoDiscoverApps = "false",
  [int]$AppDiscoveryIntervalHours = 6
)

$ErrorActionPreference = "Stop"

function New-DefaultDb {
  return [ordered]@{
    version = 1
    accounts = @()
    apps = @()
    alerts = @()
    syncLogs = @()
    settings = [ordered]@{}
  }
}

if ([string]::IsNullOrWhiteSpace($DbFile) -or [string]::IsNullOrWhiteSpace($MutexName)) {
  exit 0
}

if (@(3, 6, 9) -notcontains $AppDiscoveryIntervalHours) {
  $AppDiscoveryIntervalHours = 6
}

$closeToTrayValue = ([string]$CloseToTray).ToLowerInvariant() -eq "true"
$autoDiscoverAppsValue = ([string]$AutoDiscoverApps).ToLowerInvariant() -eq "true"

$mutex = New-Object Threading.Mutex($false, $MutexName)
$hasLock = $false
try {
  try {
    $hasLock = $mutex.WaitOne(15000)
  } catch [Threading.AbandonedMutexException] {
    $hasLock = $true
  }
  if (-not $hasLock) { exit 0 }

  if (Test-Path -LiteralPath $DbFile) {
    $raw = Get-Content -LiteralPath $DbFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
      $db = New-DefaultDb
    } else {
      $db = $raw | ConvertFrom-Json
    }
  } else {
    $db = New-DefaultDb
  }

  if ($null -eq $db.settings) {
    $db | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{}) -Force
  }

  $db.settings | Add-Member -NotePropertyName closeToTray -NotePropertyValue $closeToTrayValue -Force
  $db.settings | Add-Member -NotePropertyName autoDiscoverApps -NotePropertyValue $autoDiscoverAppsValue -Force
  $db.settings | Add-Member -NotePropertyName appDiscoveryIntervalHours -NotePropertyValue $AppDiscoveryIntervalHours -Force
  $db.settings | Add-Member -NotePropertyName updatedAt -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force

  $dir = Split-Path -Parent $DbFile
  if (![string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $db | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $DbFile -Encoding UTF8
} catch {
  exit 0
} finally {
  if ($hasLock) { $mutex.ReleaseMutex() }
  if ($null -ne $mutex) { $mutex.Dispose() }
}
