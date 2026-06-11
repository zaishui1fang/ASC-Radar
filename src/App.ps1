Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
if (![string]::IsNullOrWhiteSpace([string]$global:ASCRadarAppRoot)) {
  $Script:AppRoot = [string]$global:ASCRadarAppRoot
} elseif (![string]::IsNullOrWhiteSpace([string]$MyInvocation.MyCommand.Path)) {
  $Script:AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
} else {
  $Script:AppRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
$Script:SrcDir = Join-Path $Script:AppRoot "src"
$Script:DataDir = Join-Path $Script:AppRoot "data"
$Script:DbFile = Join-Path $Script:DataDir "store.json"
$Script:KeyFile = Join-Path $Script:DataDir "local.key"
$Script:AssetDir = Join-Path $Script:AppRoot "assets"
$Script:AppIconPng = Join-Path $Script:AssetDir "app-logo.png"
$Script:AppIconIco = Join-Path $Script:AssetDir "app-logo.ico"

function Get-NameHash([string]$Text) {
  $md5 = [Security.Cryptography.MD5]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant())
    return [BitConverter]::ToString($md5.ComputeHash($bytes)).Replace("-", "")
  } finally {
    $md5.Dispose()
  }
}

function New-WpfBitmapImage([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path -LiteralPath $Path)) { return $null }
  $bitmap = New-Object Windows.Media.Imaging.BitmapImage
  $bitmap.BeginInit()
  $bitmap.UriSource = [Uri]::new($Path, [UriKind]::Absolute)
  $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  $bitmap.EndInit()
  $bitmap.Freeze()
  return $bitmap
}

$Script:InstanceMutexName = "Local\ASCRadarInstance_$(Get-NameHash $Script:AppRoot)"
$Script:InstanceEventName = "Local\ASCRadarShow_$(Get-NameHash $Script:AppRoot)"
$Script:InstanceMutex = $null
$Script:InstanceEvent = $null
$Script:InstanceEventTimer = $null
$Script:InstanceMutexHeld = $false

$instanceCreated = $false
$Script:InstanceMutex = [System.Threading.Mutex]::new($true, $Script:InstanceMutexName, [ref]$instanceCreated)
if (-not $instanceCreated) {
  for ($i = 0; $i -lt 10; $i++) {
    try {
      $existingEvent = [System.Threading.EventWaitHandle]::OpenExisting($Script:InstanceEventName)
      [void]$existingEvent.Set()
      $existingEvent.Dispose()
      break
    } catch {
      Start-Sleep -Milliseconds 100
    }
  }
  exit 0
}
$Script:InstanceMutexHeld = $true
$instanceEventCreated = $false
$Script:InstanceEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, $Script:InstanceEventName, [ref]$instanceEventCreated)

$Script:DbLockDepth = 0
$Script:State = $null
$Script:LastStatusSnapshot = $null
$Script:RecentStatusNotificationMap = @{}
$Script:AccountFilterMap = @{}
$Script:StatusFilterMap = @{}
$Script:NotificationWindows = @()
$Script:AutoSyncTimer = $null
$Script:AutoSyncRunning = $false
$Script:AutoSyncProcess = $null
$Script:AutoSyncPollTimer = $null
$Script:AutoSyncResultPath = ""
$Script:AutoSyncStartedAt = $null
$Script:AutoSyncForcedError = ""
$Script:ManualSyncRunning = $false
$Script:ManualSyncProcess = $null
$Script:ManualSyncPollTimer = $null
$Script:ManualSyncResultPath = ""
$Script:ManualSyncMode = ""
$Script:ManualSyncAccountId = ""
$Script:ManualSyncStartedAt = $null
$Script:ManualSyncForcedError = ""
$Script:SyncSpinnerTimer = $null
$Script:SyncSpinnerIndex = 0
$Script:WpfApp = $null
$Script:TrayIcon = $null
$Script:TrayIconImage = $null
$Script:TrayRestoreWindow = $null
$Script:ReallyExit = $false
$Script:LoadingSettings = $false
$Script:SettingsCache = [ordered]@{ closeToTray = $true; autoDiscoverApps = $false; appDiscoveryIntervalHours = 6 }
$Script:SettingsWriteTimer = $null
New-Item -ItemType Directory -Force -Path $Script:DataDir | Out-Null

function Get-StoreMutexName {
  return "Local\ASCRadarStore_$(Get-NameHash $Script:DbFile)"
}

$Script:DbMutexName = Get-StoreMutexName

function Invoke-DbLocked([scriptblock]$Action) {
  if ($Script:DbLockDepth -gt 0) {
    return & $Action
  }

  $mutex = New-Object System.Threading.Mutex($false, $Script:DbMutexName)
  $hasLock = $false
  try {
    try {
      $hasLock = $mutex.WaitOne(15000)
    } catch [System.Threading.AbandonedMutexException] {
      $hasLock = $true
    }
    if (-not $hasLock) {
      throw "数据文件正在被同步占用，请稍后再试。"
    }
    $Script:DbLockDepth++
    return & $Action
  } finally {
    if ($Script:DbLockDepth -gt 0) { $Script:DbLockDepth-- }
    if ($hasLock) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
  }
}

function New-Id([string]$Prefix) {
  return "$Prefix" + "_" + ([Guid]::NewGuid().ToString("N").Substring(0, 16))
}

function Get-NowIso {
  return [DateTime]::UtcNow.ToString("o")
}

function ConvertTo-JsonText($Value) {
  return $Value | ConvertTo-Json -Depth 20
}

function New-DefaultDb {
  return [ordered]@{
    version = 1
    accounts = @()
    apps = @()
    alerts = @()
    syncLogs = @()
    settings = [ordered]@{ createdAt = Get-NowIso; closeToTray = $true; autoDiscoverApps = $false; appDiscoveryIntervalHours = 6 }
  }
}

function ConvertTo-HashtableDeep($InputObject) {
  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [System.Collections.IDictionary]) {
    $hash = [ordered]@{}
    foreach ($key in $InputObject.Keys) {
      $hash[$key] = ConvertTo-HashtableDeep $InputObject[$key]
    }
    return $hash
  }
  if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
    $items = @()
    foreach ($item in $InputObject) { $items += ConvertTo-HashtableDeep $item }
    return $items
  }
  if ($InputObject.PSObject.Properties.Count -gt 0 -and $InputObject -isnot [string]) {
    $hash = [ordered]@{}
    foreach ($prop in $InputObject.PSObject.Properties) {
      $hash[$prop.Name] = ConvertTo-HashtableDeep $prop.Value
    }
    return $hash
  }
  return $InputObject
}

function Get-ListItems($Value) {
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Collections.IDictionary]) { return @($Value) }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return @($Value) }
  return @($Value)
}

function Set-ObjectValue($Object, [string]$Name, $Value) {
  if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return }
  if ($Object -is [System.Collections.IDictionary]) {
    $Object[$Name] = $Value
    return
  }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -ne $prop) {
    $prop.Value = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Ensure-DbSettings($Db) {
  $changed = $false
  if ($null -eq $Db["settings"] -or $Db["settings"] -isnot [System.Collections.IDictionary]) {
    $Db["settings"] = [ordered]@{}
    $changed = $true
  }
  if ($null -eq $Db["settings"]["createdAt"]) {
    $Db["settings"]["createdAt"] = Get-NowIso
    $changed = $true
  }
  if ($null -eq $Db["settings"]["closeToTray"]) {
    $Db["settings"]["closeToTray"] = $true
    $changed = $true
  }
  if ($null -eq $Db["settings"]["autoDiscoverApps"]) {
    $Db["settings"]["autoDiscoverApps"] = $false
    $changed = $true
  }
  if ($null -eq $Db["settings"]["appDiscoveryIntervalHours"]) {
    $Db["settings"]["appDiscoveryIntervalHours"] = 6
    $changed = $true
  }
  return $changed
}

function New-StatusHistoryEntry([string]$Kind, [string]$Name, [string]$PreviousStatus, [string]$Status, [string]$DetectedAt, [bool]$Initial = $false) {
  return [ordered]@{
    kind = $Kind
    name = $Name
    previousStatus = $PreviousStatus
    status = $Status
    detectedAt = $DetectedAt
    initial = $Initial
  }
}

function Limit-StatusHistory($History) {
  $items = @($History | Where-Object { $null -ne $_ })
  if ($items.Count -gt 80) { return @($items | Select-Object -Last 80) }
  return @($items)
}

function Ensure-AppStatusTimingRecords($Db) {
  $changed = $false
  $now = Get-NowIso
  $nextApps = @()
  foreach ($app in @(Get-ListItems $Db.apps)) {
    if ($null -eq $app) { continue }
    $appRecord = ConvertTo-HashtableDeep $app
    $status = if (![string]::IsNullOrWhiteSpace([string](Get-ObjectValue $appRecord "status"))) { Normalize-Status ([string](Get-ObjectValue $appRecord "status")) } else { "NO_VERSION" }
    $existingHistory = @(Get-ListItems (Get-ObjectValue $appRecord "statusHistory"))
    $firstHistoryAt = ""
    if ($existingHistory.Count -gt 0) {
      $firstHistoryAt = [string](Get-ObjectValue ($existingHistory | Select-Object -First 1) "detectedAt")
    }
    $statusChangedAt = [string](Get-ObjectValue $appRecord "statusChangedAt")
    if ([string]::IsNullOrWhiteSpace($statusChangedAt)) {
      $statusChangedAt = if (![string]::IsNullOrWhiteSpace($firstHistoryAt)) { $firstHistoryAt } else { $now }
      Set-ObjectValue $appRecord "statusChangedAt" $statusChangedAt
      $changed = $true
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-ObjectValue $appRecord "statusCheckedAt"))) {
      Set-ObjectValue $appRecord "statusCheckedAt" $now
      $changed = $true
    }
    if ($existingHistory.Count -eq 0) {
      Set-ObjectValue $appRecord "statusHistory" @(New-StatusHistoryEntry -Kind "main" -Name "版本" -PreviousStatus "" -Status $status -DetectedAt $statusChangedAt -Initial $true)
      $changed = $true
    } else {
      $latestHistory = $existingHistory | Sort-Object detectedAt | Select-Object -Last 1
      $latestStatus = Normalize-Status ([string](Get-ObjectValue $latestHistory "status"))
      $hasCurrentStatusHistory = @(Get-ListItems $existingHistory | Where-Object {
        (Normalize-Status ([string](Get-ObjectValue $_ "status"))) -eq $status
      }).Count -gt 0
      if ($status -and $latestStatus -and $status -ne $latestStatus -and $status -ne "NO_VERSION") {
        $previousStatus = if ($latestStatus -eq "NO_VERSION") { "" } else { $latestStatus }
        $statusChangedAt = if (![string]::IsNullOrWhiteSpace([string](Get-ObjectValue $appRecord "statusCheckedAt"))) { [string](Get-ObjectValue $appRecord "statusCheckedAt") } else { $now }
        $existingHistory += New-StatusHistoryEntry -Kind "main" -Name "版本" -PreviousStatus $previousStatus -Status $status -DetectedAt $statusChangedAt -Initial $false
        Set-ObjectValue $appRecord "statusChangedAt" $statusChangedAt
        Set-ObjectValue $appRecord "statusHistory" @(Limit-StatusHistory $existingHistory)
        $changed = $true
      } elseif ($hasCurrentStatusHistory -and [string]::IsNullOrWhiteSpace($statusChangedAt)) {
        $currentHistory = @(Get-ListItems $existingHistory | Where-Object {
          (Normalize-Status ([string](Get-ObjectValue $_ "status"))) -eq $status
        } | Sort-Object detectedAt | Select-Object -Last 1)
        if ($currentHistory.Count -gt 0) {
          Set-ObjectValue $appRecord "statusChangedAt" ([string](Get-ObjectValue $currentHistory[0] "detectedAt"))
          $changed = $true
        }
      }
    }

    $nextReviews = @()
    $reviewChanged = $false
    foreach ($review in @(Get-ListItems (Get-ObjectValue $appRecord "extraReviews"))) {
      if ($null -eq $review) { continue }
      $reviewRecord = ConvertTo-HashtableDeep $review
      $reviewStatus = if (![string]::IsNullOrWhiteSpace([string](Get-ObjectValue $reviewRecord "status"))) { Normalize-Status ([string](Get-ObjectValue $reviewRecord "status")) } else { "UNKNOWN" }
      if (@("NO_VERSION", "UNKNOWN") -contains $reviewStatus) {
        $changed = $true
        continue
      }
      $reviewName = if (![string]::IsNullOrWhiteSpace([string](Get-ObjectValue $reviewRecord "typeLabel"))) { [string](Get-ObjectValue $reviewRecord "typeLabel") } else { "产品页面优化" }
      $reviewHistory = @(Get-ListItems (Get-ObjectValue $reviewRecord "statusHistory"))
      $firstReviewHistoryAt = ""
      if ($reviewHistory.Count -gt 0) {
        $firstReviewHistoryAt = [string](Get-ObjectValue ($reviewHistory | Select-Object -First 1) "detectedAt")
      }
      $reviewStatusChangedAt = [string](Get-ObjectValue $reviewRecord "statusChangedAt")
      if ([string]::IsNullOrWhiteSpace($reviewStatusChangedAt)) {
        $reviewStatusChangedAt = if (![string]::IsNullOrWhiteSpace($firstReviewHistoryAt)) { $firstReviewHistoryAt } else { $now }
        Set-ObjectValue $reviewRecord "statusChangedAt" $reviewStatusChangedAt
        $reviewChanged = $true
      }
      if ([string]::IsNullOrWhiteSpace([string](Get-ObjectValue $reviewRecord "statusCheckedAt"))) {
        Set-ObjectValue $reviewRecord "statusCheckedAt" $now
        $reviewChanged = $true
      }
      if ($reviewHistory.Count -eq 0) {
        Set-ObjectValue $reviewRecord "statusHistory" @(New-StatusHistoryEntry -Kind "extraReview" -Name $reviewName -PreviousStatus "" -Status $reviewStatus -DetectedAt $reviewStatusChangedAt -Initial $true)
        $reviewChanged = $true
      }
      $nextReviews += $reviewRecord
    }
    if ($reviewChanged) {
      Set-ObjectValue $appRecord "extraReviews" @($nextReviews)
      $changed = $true
    }
    $nextApps += $appRecord
  }
  if ($changed) {
    $Db.apps = @($nextApps)
  }
  return $changed
}

function Read-Db {
  return Invoke-DbLocked {
    if (!(Test-Path $Script:DbFile)) {
      $db = New-DefaultDb
      Write-Db $db
      return $db
    }
    $raw = Get-Content -LiteralPath $Script:DbFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
      $db = New-DefaultDb
      Write-Db $db
      return $db
    }

    try {
      $db = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
    } catch {
      $backup = "$Script:DbFile.broken-$(Get-Date -Format yyyyMMddHHmmss)"
      Copy-Item -LiteralPath $Script:DbFile -Destination $backup -Force
      $db = New-DefaultDb
      $db.syncLogs += [ordered]@{
        id = New-Id "log"
        level = "error"
        message = "数据文件损坏，已备份。"
        createdAt = Get-NowIso
      }
      Write-Db $db
      return $db
    }

    foreach ($key in @("accounts", "apps", "alerts", "syncLogs")) {
      if ($null -eq $db[$key]) {
        $db[$key] = @()
      } elseif ($db[$key] -isnot [System.Array]) {
        $db[$key] = @($db[$key])
      }
    }

    try {
      $settingsChanged = Ensure-DbSettings $db
      $repairChanged = Repair-LegacySyncErrorRecords $db
      $timingChanged = Ensure-AppStatusTimingRecords $db
      if ($settingsChanged -or $repairChanged -or $timingChanged) {
        Write-Db $db
      }
    } catch {
      $db.syncLogs += [ordered]@{
        id = New-Id "log"
        level = "error"
        message = "启动维护失败：$($_.Exception.Message)"
        createdAt = Get-NowIso
      }
      Write-Db $db
    }
    return $db
  }
}

function Write-Db($Db) {
  Invoke-DbLocked {
    foreach ($key in @("accounts", "apps", "alerts", "syncLogs")) {
      if ($null -eq $Db[$key]) {
        $Db[$key] = @()
      } elseif ($Db[$key] -isnot [System.Array]) {
        $Db[$key] = @($Db[$key])
      }
    }
    [void](Ensure-DbSettings $Db)
    ConvertTo-JsonText $Db | Set-Content -LiteralPath $Script:DbFile -Encoding UTF8
  }
}

function Get-CloseToTraySetting {
  if ($null -eq $Script:SettingsCache -or $null -eq $Script:SettingsCache.closeToTray) { return $true }
  return [bool]$Script:SettingsCache.closeToTray
}

function Set-CloseToTraySetting([bool]$Enabled) {
  Set-CachedSettingValue "closeToTray" $Enabled
}

function Get-AppDiscoveryIntervalHoursFromSettings($Settings) {
  $hours = 6
  try {
    if ($null -ne $Settings -and $null -ne $Settings.appDiscoveryIntervalHours) {
      $hours = [int]$Settings.appDiscoveryIntervalHours
    }
  } catch {
    $hours = 6
  }
  if (@(3, 6, 9) -notcontains $hours) { $hours = 6 }
  return $hours
}

function Update-SettingsCacheFromDb($Db) {
  if ($null -eq $Script:SettingsCache) {
    $Script:SettingsCache = [ordered]@{ closeToTray = $true; autoDiscoverApps = $false; appDiscoveryIntervalHours = 6 }
  }
  $settings = if ($null -ne $Db -and $null -ne $Db.settings) { $Db.settings } else { $null }
  $Script:SettingsCache.closeToTray = if ($null -eq $settings -or $null -eq $settings.closeToTray) { $true } else { [bool]$settings.closeToTray }
  $Script:SettingsCache.autoDiscoverApps = if ($null -eq $settings -or $null -eq $settings.autoDiscoverApps) { $false } else { [bool]$settings.autoDiscoverApps }
  $Script:SettingsCache.appDiscoveryIntervalHours = Get-AppDiscoveryIntervalHoursFromSettings $settings
}

function Set-CachedSettingValue([string]$Name, $Value) {
  if ($null -eq $Script:SettingsCache) {
    $Script:SettingsCache = [ordered]@{ closeToTray = $true; autoDiscoverApps = $false; appDiscoveryIntervalHours = 6 }
  }
  $Script:SettingsCache[$Name] = $Value
  Queue-SettingsWrite
}

function Queue-SettingsWrite {
  if ($null -eq $Script:SettingsWriteTimer) {
    $Script:SettingsWriteTimer = New-Object Windows.Threading.DispatcherTimer
    $Script:SettingsWriteTimer.Interval = [TimeSpan]::FromMilliseconds(350)
    $Script:SettingsWriteTimer.Add_Tick({
      $Script:SettingsWriteTimer.Stop()
      Start-SettingsWriteWorker
    })
  }
  $Script:SettingsWriteTimer.Stop()
  $Script:SettingsWriteTimer.Start()
}

function Start-SettingsWriteWorker {
  try {
    $writer = Join-Path $Script:SrcDir "settings-writer.ps1"
    if (!(Test-Path -LiteralPath $writer)) { return }
    $psExe = Join-Path $PSHOME "powershell.exe"
    if (!(Test-Path -LiteralPath $psExe)) { $psExe = "powershell.exe" }

    $args = @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", "`"$writer`"",
      "-DbFile", "`"$Script:DbFile`"",
      "-MutexName", "`"$Script:DbMutexName`"",
      "-CloseToTray", "`"$([bool]$Script:SettingsCache.closeToTray)`"",
      "-AutoDiscoverApps", "`"$([bool]$Script:SettingsCache.autoDiscoverApps)`"",
      "-AppDiscoveryIntervalHours", "`"$([int]$Script:SettingsCache.appDiscoveryIntervalHours)`""
    ) -join " "

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = $args
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($psi)
  } catch {
  }
}

function Get-AutoDiscoverAppsSetting {
  if ($null -eq $Script:SettingsCache -or $null -eq $Script:SettingsCache.autoDiscoverApps) { return $false }
  return [bool]$Script:SettingsCache.autoDiscoverApps
}

function Get-AppDiscoveryIntervalHoursSetting {
  return Get-AppDiscoveryIntervalHoursFromSettings $Script:SettingsCache
}

function Set-AutoDiscoverAppsSetting([bool]$Enabled) {
  Set-CachedSettingValue "autoDiscoverApps" $Enabled
}

function Set-AppDiscoveryIntervalHoursSetting([int]$Hours) {
  if (@(3, 6, 9) -notcontains $Hours) { $Hours = 6 }
  Set-CachedSettingValue "appDiscoveryIntervalHours" $Hours
}

function Update-SettingsUi {
  if ($null -eq $CloseToTrayToggle) { return }
  $Script:LoadingSettings = $true
  try {
    $settings = $Script:SettingsCache
    $enabled = if ($null -eq $settings -or $null -eq $settings.closeToTray) { $true } else { [bool]$settings.closeToTray }
    $CloseToTrayToggle.IsChecked = $enabled
    if ($null -ne $SettingsTrayStatusText) {
      if ($enabled) {
        $SettingsTrayStatusText.Text = "当前：关闭窗口后缩到右下角托盘"
        $SettingsTrayStatusText.Foreground = "#0A84FF"
      } else {
        $SettingsTrayStatusText.Text = "当前：关闭窗口后直接退出程序"
        $SettingsTrayStatusText.Foreground = "#BD2838"
      }
    }

    if ($null -ne $AutoDiscoverAppsToggle) {
      $discoverEnabled = if ($null -eq $settings -or $null -eq $settings.autoDiscoverApps) { $false } else { [bool]$settings.autoDiscoverApps }
      $discoverHours = Get-AppDiscoveryIntervalHoursFromSettings $settings
      $AutoDiscoverAppsToggle.IsChecked = $discoverEnabled
      if ($null -ne $AppDiscoveryIntervalCombo) {
        foreach ($item in @($AppDiscoveryIntervalCombo.Items)) {
          if ([string]$item.Tag -eq [string]$discoverHours) {
            $AppDiscoveryIntervalCombo.SelectedItem = $item
            break
          }
        }
        $AppDiscoveryIntervalCombo.IsEnabled = $true
      }
      if ($null -ne $SettingsDiscoverStatusText) {
        if ($discoverEnabled) {
          $SettingsDiscoverStatusText.Text = "当前：每 $discoverHours 小时低频扫描一次新 App"
          $SettingsDiscoverStatusText.Foreground = "#0A84FF"
        } else {
          $SettingsDiscoverStatusText.Text = "当前：不会自动发现全新 App"
          $SettingsDiscoverStatusText.Foreground = "#BD2838"
        }
      }
    }
  } finally {
    $Script:LoadingSettings = $false
  }
}

function Save-CloseToTrayFromUi {
  if ($Script:LoadingSettings -or $null -eq $CloseToTrayToggle) { return }
  $enabled = [bool]$CloseToTrayToggle.IsChecked
  if ($null -ne $SettingsTrayStatusText) {
    if ($enabled) {
      $SettingsTrayStatusText.Text = "当前：关闭窗口后缩到右下角托盘"
      $SettingsTrayStatusText.Foreground = "#0A84FF"
    } else {
      $SettingsTrayStatusText.Text = "当前：关闭窗口后直接退出程序"
      $SettingsTrayStatusText.Foreground = "#BD2838"
    }
  }
  Set-CloseToTraySetting $enabled
}

function Save-AutoDiscoverAppsFromUi {
  if ($Script:LoadingSettings -or $null -eq $AutoDiscoverAppsToggle) { return }
  $enabled = [bool]$AutoDiscoverAppsToggle.IsChecked
  $hours = 6
  if ($null -ne $AppDiscoveryIntervalCombo -and $null -ne $AppDiscoveryIntervalCombo.SelectedItem) {
    try { $hours = [int]$AppDiscoveryIntervalCombo.SelectedItem.Tag } catch { $hours = 6 }
  }
  if ($null -ne $SettingsDiscoverStatusText) {
    if ($enabled) {
      $SettingsDiscoverStatusText.Text = "当前：每 $hours 小时低频扫描一次新 App"
      $SettingsDiscoverStatusText.Foreground = "#0A84FF"
    } else {
      $SettingsDiscoverStatusText.Text = "当前：不会自动发现全新 App"
      $SettingsDiscoverStatusText.Foreground = "#BD2838"
    }
  }
  Set-AutoDiscoverAppsSetting $enabled
}

function Save-AppDiscoveryIntervalFromUi {
  if ($Script:LoadingSettings -or $null -eq $AppDiscoveryIntervalCombo -or $null -eq $AppDiscoveryIntervalCombo.SelectedItem) { return }
  $hours = 6
  try { $hours = [int]$AppDiscoveryIntervalCombo.SelectedItem.Tag } catch { $hours = 6 }
  Set-AppDiscoveryIntervalHoursSetting $hours
  if ($null -ne $SettingsDiscoverStatusText) {
    if ($null -ne $AutoDiscoverAppsToggle -and $AutoDiscoverAppsToggle.IsChecked -eq $true) {
      $SettingsDiscoverStatusText.Text = "当前：每 $hours 小时低频扫描一次新 App"
      $SettingsDiscoverStatusText.Foreground = "#0A84FF"
    } else {
      $SettingsDiscoverStatusText.Text = "当前：不会自动发现全新 App"
      $SettingsDiscoverStatusText.Foreground = "#BD2838"
    }
  }
}

function Start-InstanceEventTimer {
  if ($null -eq $Script:InstanceEvent -or $null -ne $Script:InstanceEventTimer) { return }
  $Script:InstanceEventTimer = New-Object Windows.Threading.DispatcherTimer
  $Script:InstanceEventTimer.Interval = [TimeSpan]::FromMilliseconds(450)
  $Script:InstanceEventTimer.Add_Tick({
    if ($null -eq $Script:InstanceEvent) { return }
    try {
      if ($Script:InstanceEvent.WaitOne(0)) {
        Show-MainWindowFromTray
      }
    } catch {
    }
  })
  $Script:InstanceEventTimer.Start()
}

function Show-MainWindowFromTray {
  if ($null -eq $Window) { return }
  Close-TrayRestoreWindow
  $Window.Show()
  $Window.WindowState = "Normal"
  $Window.Activate() | Out-Null
}

function Hide-MainWindowToTray {
  if ($null -eq $Window) { return }
  $Window.Hide()
  if ($null -ne $Script:TrayIcon) {
    $Script:TrayIcon.Visible = $true
  }
}

function Close-TrayRestoreWindow {
  if ($null -ne $Script:TrayRestoreWindow) {
    try {
      if ($Script:TrayRestoreWindow.IsVisible) {
        $Script:TrayRestoreWindow.Close()
      }
    } catch {
    }
    $Script:TrayRestoreWindow = $null
  }
}

function Show-TrayRestoreWindow {
  try {
    if ($null -ne $Script:TrayRestoreWindow -and $Script:TrayRestoreWindow.IsVisible) {
      $workArea = [System.Windows.SystemParameters]::WorkArea
      $Script:TrayRestoreWindow.Left = $workArea.Right - $Script:TrayRestoreWindow.Width - 18
      $Script:TrayRestoreWindow.Top = $workArea.Bottom - $Script:TrayRestoreWindow.Height - 18
      return
    }

    $mini = New-Object Windows.Window
    $mini.Title = "ASC Radar"
    $mini.Width = 238
    $mini.Height = 58
    $mini.WindowStyle = "None"
    $mini.ResizeMode = "NoResize"
    $mini.ShowInTaskbar = $false
    $mini.Topmost = $true
    $mini.AllowsTransparency = $true
    $mini.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0, 255, 255, 255))
    $mini.Cursor = "Hand"

    $shell = New-Object Windows.Controls.Border
    $shell.Background = "#FFFFFF"
    $shell.BorderBrush = "#1E1E1E"
    $shell.BorderThickness = 1
    $shell.CornerRadius = "0"
    $shell.Padding = "14,9"
    $shell.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{
      BlurRadius = 18
      ShadowDepth = 0
      Opacity = 0.24
      Color = [Windows.Media.ColorConverter]::ConvertFromString("#202124")
    }

    $grid = New-Object Windows.Controls.Grid
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = "*" }))
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))

    $copy = New-Object Windows.Controls.StackPanel
    $title = New-Object Windows.Controls.TextBlock
    $title.Text = "ASC Radar 后台运行"
    $title.Foreground = "#101928"
    $title.FontSize = 13
    $title.FontWeight = "Black"
    $sub = New-Object Windows.Controls.TextBlock
    $sub.Text = "自动同步继续运行"
    $sub.Foreground = "#7A8796"
    $sub.FontSize = 11
    $sub.Margin = "0,3,0,0"
    $copy.Children.Add($title) | Out-Null
    $copy.Children.Add($sub) | Out-Null
    [Windows.Controls.Grid]::SetColumn($copy, 0)

    $openPill = New-Object Windows.Controls.Border
    $openPill.Background = "#0A84FF"
    $openPill.CornerRadius = "0"
    $openPill.Padding = "12,7"
    $openPill.VerticalAlignment = "Center"
    $openText = New-Object Windows.Controls.TextBlock
    $openText.Text = "打开"
    $openText.Foreground = "#FFFFFF"
    $openText.FontSize = 12
    $openText.FontWeight = "Bold"
    $openPill.Child = $openText
    [Windows.Controls.Grid]::SetColumn($openPill, 1)

    $grid.Children.Add($copy) | Out-Null
    $grid.Children.Add($openPill) | Out-Null
    $shell.Child = $grid
    $mini.Content = $shell

    $mini.Add_MouseLeftButtonUp({ Show-MainWindowFromTray })
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $mini.Left = $workArea.Right - $mini.Width - 18
    $mini.Top = $workArea.Bottom - $mini.Height - 18
    $Script:TrayRestoreWindow = $mini
    $mini.Show()
  } catch {
  }
}

function Exit-Application {
  $Script:ReallyExit = $true
  Close-TrayRestoreWindow
  if ($null -ne $Script:InstanceEventTimer) {
    $Script:InstanceEventTimer.Stop()
    $Script:InstanceEventTimer = $null
  }
  if ($null -ne $Script:SettingsWriteTimer) {
    $Script:SettingsWriteTimer.Stop()
    $Script:SettingsWriteTimer = $null
  }
  if ($null -ne $Script:TrayIcon) {
    $Script:TrayIcon.Visible = $false
  }
  if ($null -ne $Window) {
    $Window.Close()
  }
  if ($null -ne $Script:WpfApp) {
    $Script:WpfApp.Shutdown()
  }
}

function New-TrayIconImage {
  if (Test-Path -LiteralPath $Script:AppIconIco) {
    try {
      return New-Object System.Drawing.Icon -ArgumentList $Script:AppIconIco
    } catch {
    }
  }

  $bitmap = New-Object System.Drawing.Bitmap 32, 32
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.Clear([System.Drawing.Color]::Transparent)

  $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(10, 132, 255))
  $graphics.FillEllipse($bg, 2, 2, 28, 28)
  $bg.Dispose()

  $font = New-Object System.Drawing.Font "Segoe UI", 15, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $textBrush = [System.Drawing.Brushes]::White
  $format = New-Object System.Drawing.StringFormat
  $format.Alignment = [System.Drawing.StringAlignment]::Center
  $format.LineAlignment = [System.Drawing.StringAlignment]::Center
  $graphics.DrawString("A", $font, $textBrush, (New-Object System.Drawing.RectangleF 0, 0, 32, 31), $format)
  $font.Dispose()
  $format.Dispose()
  $graphics.Dispose()

  $handle = $bitmap.GetHicon()
  return [System.Drawing.Icon]::FromHandle($handle)
}

function Initialize-AppBranding {
  $icon = New-WpfBitmapImage $Script:AppIconPng
  if ($null -eq $icon) { return }
  $Window.Icon = $icon
  if ($null -ne $BrandLogo) {
    $BrandLogo.Source = $icon
  }
}

function Initialize-TrayIcon {
  if ($null -ne $Script:TrayIcon) { return }
  $Script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
  $Script:TrayIcon.Text = "ASC Radar - Apple 审核状态同步"
  $Script:TrayIconImage = New-TrayIconImage
  $Script:TrayIcon.Icon = $Script:TrayIconImage
  $Script:TrayIcon.Visible = $true

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $openItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $openItem.Text = "打开主界面"
  $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
  $exitItem.Text = "退出程序"
  [void]$menu.Items.Add($openItem)
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  [void]$menu.Items.Add($exitItem)
  $Script:TrayIcon.ContextMenuStrip = $menu

  $openItem.Add_Click({ Show-MainWindowFromTray })
  $exitItem.Add_Click({ Exit-Application })
  $Script:TrayIcon.Add_DoubleClick({ Show-MainWindowFromTray })
}

function Repair-LegacySyncErrorRecords($Db) {
  $changed = $false
  $legacyMessages = @(
    "本地账号数据不完整，请编辑账号并重新选择 .p8 私钥后再同步。",
    "本地账号私钥无法读取，请编辑账号并重新选择 .p8 私钥后再同步。"
  )

  foreach ($account in @($Db.accounts)) {
    $lastError = [string]$account.lastError
    $isLocalHistoryBug = ($lastError -like "*Initial*" -or $lastError -like "*kind*")
    if (($legacyMessages -contains $lastError) -or $isLocalHistoryBug) {
      $account.lastError = ""
      if (![string]::IsNullOrWhiteSpace([string]$account.lastSyncAt)) {
        $account.status = "connected"
      } else {
        $account.status = "unchecked"
      }
      $account.updatedAt = Get-NowIso
      $changed = $true
    }
  }

  foreach ($alert in @($Db.alerts)) {
    $message = [string]$alert.message
    $isLocalHistoryBug = ($message -like "*Initial*" -or $message -like "*kind*")
    if (
      -not $alert.resolvedAt -and
      [string]$alert.type -eq "SYNC_FAILED" -and
      (($legacyMessages -contains $message) -or $isLocalHistoryBug)
    ) {
      $alert.resolvedAt = Get-NowIso
      $alert.updatedAt = Get-NowIso
      $changed = $true
    }
  }

  return $changed
}

function Get-LocalKey {
  if (!(Test-Path $Script:KeyFile)) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes) | Set-Content -LiteralPath $Script:KeyFile -Encoding ASCII
  }
  return [Convert]::FromBase64String((Get-Content -LiteralPath $Script:KeyFile -Raw).Trim())
}

function Protect-Text([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  $aes = [Security.Cryptography.Aes]::Create()
  $aes.Key = Get-LocalKey
  $aes.GenerateIV()
  $aes.Mode = [Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
  $enc = $aes.CreateEncryptor()
  $plain = [Text.Encoding]::UTF8.GetBytes($Text)
  $cipher = $enc.TransformFinalBlock($plain, 0, $plain.Length)
  return ("v1:{0}:{1}" -f [Convert]::ToBase64String($aes.IV), [Convert]::ToBase64String($cipher))
}

function Unprotect-Text([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  if (!$Value.StartsWith("v1:")) { return $Value }
  $parts = $Value.Split(":")
  if ($parts.Count -lt 3 -or [string]::IsNullOrWhiteSpace($parts[1]) -or [string]::IsNullOrWhiteSpace($parts[2])) {
    throw "账号私钥数据不完整，请编辑账号并重新选择 .p8 私钥。"
  }
  $aes = [Security.Cryptography.Aes]::Create()
  $aes.Key = Get-LocalKey
  $aes.IV = [Convert]::FromBase64String($parts[1])
  $aes.Mode = [Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
  $dec = $aes.CreateDecryptor()
  $cipher = [Convert]::FromBase64String($parts[2])
  $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
  return [Text.Encoding]::UTF8.GetString($plain)
}

function Get-StatusLabel([string]$Status) {
  $map = @{
    PREPARE_FOR_SUBMISSION = "准备提交"
    READY_FOR_REVIEW = "可提交审核"
    WAITING_FOR_REVIEW = "等待审核"
    IN_REVIEW = "审核中"
    UNRESOLVED_ISSUES = "存在问题"
    CANCELING = "取消中"
    COMPLETING = "完成中"
    COMPLETE = "已完成"
    ACCEPTED = "已接受"
    APPROVED = "已通过"
    COMPLETED = "已完成"
    STOPPED = "已停止"
    REMOVED = "已移除"
    PENDING_DEVELOPER_RELEASE = "待开发者发布"
    READY_FOR_DISTRIBUTION = "已可分发"
    READY_FOR_SALE = "已可分发"
    REJECTED = "审核被拒"
    METADATA_REJECTED = "元数据被拒"
    INVALID_BINARY = "二进制无效"
    DEVELOPER_REJECTED = "开发者撤回"
    UNKNOWN = "未返回状态"
    NO_VERSION = "未创建版本"
  }
  if ($map.ContainsKey($Status)) { return $map[$Status] }
  return $Status
}

function Normalize-Status([string]$Status) {
  $raw = if ($Status) { $Status.ToUpperInvariant() } else { "NO_VERSION" }
  if ($raw -eq "READY_FOR_SALE") { return "READY_FOR_DISTRIBUTION" }
  return $raw
}

function Get-ObjectValue($Object, [string]$Name) {
  if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $null
  }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -ne $prop) { return $prop.Value }
  return $null
}

function Get-StatusBrush([string]$Status) {
  switch ($Status) {
    "READY_FOR_DISTRIBUTION" { return "#187653" }
    "PENDING_DEVELOPER_RELEASE" { return "#187653" }
    "ACCEPTED" { return "#187653" }
    "APPROVED" { return "#187653" }
    "COMPLETE" { return "#187653" }
    "COMPLETED" { return "#187653" }
    "IN_REVIEW" { return "#A45C00" }
    "WAITING_FOR_REVIEW" { return "#A45C00" }
    "COMPLETING" { return "#A45C00" }
    "CANCELING" { return "#A45C00" }
    "READY_FOR_REVIEW" { return "#2455D6" }
    "UNRESOLVED_ISSUES" { return "#BE2D3A" }
    "REJECTED" { return "#BE2D3A" }
    "METADATA_REJECTED" { return "#BE2D3A" }
    "INVALID_BINARY" { return "#BE2D3A" }
    "REMOVED" { return "#56616A" }
    "STOPPED" { return "#56616A" }
    "PREPARE_FOR_SUBMISSION" { return "#7047A8" }
    "NO_VERSION" { return "#56616A" }
    default { return "#56616A" }
  }
}

function Get-StatusBackground([string]$Status) {
  switch ($Status) {
    "READY_FOR_DISTRIBUTION" { return "#DCF4E9" }
    "PENDING_DEVELOPER_RELEASE" { return "#DCF4E9" }
    "ACCEPTED" { return "#DCF4E9" }
    "APPROVED" { return "#DCF4E9" }
    "COMPLETE" { return "#DCF4E9" }
    "COMPLETED" { return "#DCF4E9" }
    "IN_REVIEW" { return "#FFF0D6" }
    "WAITING_FOR_REVIEW" { return "#FFF0D6" }
    "COMPLETING" { return "#FFF0D6" }
    "CANCELING" { return "#FFF0D6" }
    "READY_FOR_REVIEW" { return "#E7EDFF" }
    "UNRESOLVED_ISSUES" { return "#FFE2E5" }
    "REJECTED" { return "#FFE2E5" }
    "METADATA_REJECTED" { return "#FFE2E5" }
    "INVALID_BINARY" { return "#FFE2E5" }
    "REMOVED" { return "#EDF0F2" }
    "STOPPED" { return "#EDF0F2" }
    "PREPARE_FOR_SUBMISSION" { return "#EFE7FF" }
    "NO_VERSION" { return "#EDF0F2" }
    default { return "#EDF0F2" }
  }
}

function Get-DisplayReviewName([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  return $Text.Replace("主状态", "版本").Replace("附加审核", "产品页面优化")
}

function Update-CustomNotificationPositions {
  $alive = @()
  foreach ($notice in @($Script:NotificationWindows)) {
    if ($null -ne $notice -and $notice.IsVisible) { $alive += $notice }
  }
  $Script:NotificationWindows = @($alive)

  $workArea = [System.Windows.SystemParameters]::WorkArea
  $bottom = $workArea.Bottom - 18
  foreach ($notice in @($Script:NotificationWindows)) {
    $notice.Left = $workArea.Right - $notice.Width - 18
    $notice.Top = $bottom - $notice.Height
    $bottom = $notice.Top - 12
  }
}

function Close-ExistingNotificationForKey([string]$NotificationKey) {
  if ([string]::IsNullOrWhiteSpace($NotificationKey)) { return }
  foreach ($notice in @($Script:NotificationWindows)) {
    if ($null -ne $notice -and $notice.IsVisible -and [string]$notice.Tag -eq $NotificationKey) {
      $notice.Close()
    }
  }
}

function Show-DesktopNotification(
  [string]$Title,
  [string]$Message,
  [string]$Status = "UNKNOWN",
  [string]$AppName = "",
  [string]$Version = "",
  [string]$OldLabel = "",
  [string]$NewLabel = "",
  [string]$AccountName = "",
  [string]$NotificationKey = ""
) {
  try {
    if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($Message)) { return }
    Close-ExistingNotificationForKey $NotificationKey

    $normalizedStatus = Normalize-Status $Status
    $notice = New-Object Windows.Window
    $notice.Tag = $NotificationKey
    $notice.Width = 380
    $notice.Height = 188
    $notice.WindowStyle = "None"
    $notice.ResizeMode = "NoResize"
    $notice.ShowInTaskbar = $false
    $notice.Topmost = $true
    $notice.AllowsTransparency = $true
    $notice.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0, 255, 255, 255))

    $shell = New-Object Windows.Controls.Border
    $shell.Background = "#FFFFFF"
    $shell.BorderBrush = "#1E1E1E"
    $shell.BorderThickness = 1
    $shell.CornerRadius = "0"
    $shell.ClipToBounds = $true
    $shell.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{
      BlurRadius = 26
      ShadowDepth = 0
      Opacity = 0.30
      Color = [Windows.Media.ColorConverter]::ConvertFromString("#202124")
    }

    $root = New-Object Windows.Controls.Grid
    $root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = "38" }))
    $root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = "*" }))

    $titleBar = New-Object Windows.Controls.Grid
    $titleBar.Background = "#2F2F2F"
    $titleBar.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = "*" }))
    $titleBar.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    [Windows.Controls.Grid]::SetRow($titleBar, 0)

    $barTitle = New-Object Windows.Controls.TextBlock
    $barTitle.Text = "ASC Radar"
    $barTitle.Foreground = "#E8EAED"
    $barTitle.FontSize = 12
    $barTitle.FontWeight = "Bold"
    $barTitle.Margin = "16,0,0,0"
    $barTitle.VerticalAlignment = "Center"
    $barTitle.TextTrimming = "CharacterEllipsis"
    [Windows.Controls.Grid]::SetColumn($barTitle, 0)

    $closeBtn = New-Object Windows.Controls.Button
    $closeBtn.Content = "×"
    $closeBtn.Width = 30
    $closeBtn.Height = 26
    $closeBtn.MinWidth = 0
    $closeBtn.MinHeight = 0
    $closeBtn.Padding = "0"
    $closeBtn.Background = "Transparent"
    $closeBtn.Foreground = "#D6D6D6"
    $closeBtn.BorderThickness = 0
    $closeBtn.FontSize = 14
    $closeBtn.Margin = "0,0,10,0"
    $closeBtn.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetColumn($closeBtn, 1)

    $titleBar.Children.Add($barTitle) | Out-Null
    $titleBar.Children.Add($closeBtn) | Out-Null

    $body = New-Object Windows.Controls.Grid
    $body.Background = "#FFFFFF"
    $body.Margin = "0"
    $body.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $body.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = "*" }))
    [Windows.Controls.Grid]::SetRow($body, 1)

    $accent = New-Object Windows.Controls.Border
    $accent.Width = 48
    $accent.Height = 48
    $accent.CornerRadius = "14"
    $accent.Background = Get-StatusBackground $normalizedStatus
    $accent.Margin = "18,18,14,0"
    $accent.VerticalAlignment = "Top"
    [Windows.Controls.Grid]::SetColumn($accent, 0)
    $badgeText = New-Object Windows.Controls.TextBlock
    $badgeText.Text = "!"
    $badgeText.Foreground = Get-StatusBrush $normalizedStatus
    $badgeText.FontSize = 24
    $badgeText.FontWeight = "Black"
    $badgeText.HorizontalAlignment = "Center"
    $badgeText.VerticalAlignment = "Center"
    $accent.Child = $badgeText

    $content = New-Object Windows.Controls.StackPanel
    $content.Margin = "0,17,18,0"
    [Windows.Controls.Grid]::SetColumn($content, 1)
    $titleBlock = New-Object Windows.Controls.TextBlock
    $titleBlock.Text = $Title
    $titleBlock.Foreground = "#101928"
    $titleBlock.FontSize = 15
    $titleBlock.FontWeight = "Black"
    $titleBlock.TextTrimming = "CharacterEllipsis"
    $content.Children.Add($titleBlock) | Out-Null

    if (![string]::IsNullOrWhiteSpace($AppName) -and ![string]::IsNullOrWhiteSpace($NewLabel)) {
      $appLine = New-Object Windows.Controls.TextBlock
      $appLine.Text = if (![string]::IsNullOrWhiteSpace($Version)) { "$AppName v$Version" } else { $AppName }
      $appLine.Foreground = "#263548"
      $appLine.FontSize = 13
      $appLine.FontWeight = "Bold"
      $appLine.Margin = "0,8,0,0"
      $appLine.TextTrimming = "CharacterEllipsis"
      $content.Children.Add($appLine) | Out-Null

      $newPill = New-Object Windows.Controls.Border
      $newPill.Background = Get-StatusBackground $normalizedStatus
      $newPill.CornerRadius = "13"
      $newPill.Padding = "14,7"
      $newPill.Margin = "0,10,0,0"
      $newPill.HorizontalAlignment = "Left"
      $newText = New-Object Windows.Controls.TextBlock
      $newText.Text = $NewLabel
      $newText.Foreground = Get-StatusBrush $normalizedStatus
      $newText.FontWeight = "Black"
      $newText.FontSize = 15
      $newPill.Child = $newText
      $content.Children.Add($newPill) | Out-Null

      $accountLine = New-Object Windows.Controls.TextBlock
      $accountLine.Text = if (![string]::IsNullOrWhiteSpace($AccountName)) { "账号：$AccountName" } else { "账号：未命名账号" }
      $accountLine.Foreground = "#7A8796"
      $accountLine.FontSize = 12
      $accountLine.Margin = "0,10,0,0"
      $accountLine.TextTrimming = "CharacterEllipsis"
      $content.Children.Add($accountLine) | Out-Null
    } else {
      $messageBlock = New-Object Windows.Controls.TextBlock
      $messageBlock.Text = $Message
      $messageBlock.Foreground = "#526173"
      $messageBlock.FontSize = 13
      $messageBlock.Margin = "0,8,0,0"
      $messageBlock.TextWrapping = "Wrap"
      $messageBlock.LineHeight = 18
      $content.Children.Add($messageBlock) | Out-Null
    }

    $body.Children.Add($accent) | Out-Null
    $body.Children.Add($content) | Out-Null
    $root.Children.Add($titleBar) | Out-Null
    $root.Children.Add($body) | Out-Null
    $shell.Child = $root
    $notice.Content = $shell

    $closeBtn.Add_Click({
      param($sender, $eventArgs)
      $ownerWindow = [Windows.Window]::GetWindow($sender)
      if ($null -ne $ownerWindow) { $ownerWindow.Close() }
    })
    $notice.Add_Closed({ Update-CustomNotificationPositions })
    $Script:NotificationWindows += $notice
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $stackIndex = @($Script:NotificationWindows | Where-Object { $null -ne $_ }).Count - 1
    $notice.Left = $workArea.Right - $notice.Width - 18
    $notice.Top = $workArea.Bottom - $notice.Height - 18 - ($stackIndex * ($notice.Height + 12))
    if ($notice.Top -lt ($workArea.Top + 18)) { $notice.Top = $workArea.Top + 18 }
    $notice.Show()
    Update-CustomNotificationPositions
  } catch {
    # Notifications are best-effort; syncing should never fail because the UI toast could not render.
  }
}

function Get-AppIdentityKey($App) {
  if (![string]::IsNullOrWhiteSpace($App.appleId)) { return [string]$App.appleId }
  if (![string]::IsNullOrWhiteSpace($App.id)) { return [string]$App.id }
  return "$($App.bundleId)|$($App.name)"
}

function Get-ExtraReviewIdentityKey($App, $Review) {
  $appKey = Get-AppIdentityKey $App
  $reviewType = [string](Get-ObjectValue $Review "type")
  $reviewId = [string](Get-ObjectValue $Review "id")
  if ([string]::IsNullOrWhiteSpace($reviewType)) { $reviewType = [string](Get-ObjectValue $Review "typeLabel") }
  if ([string]::IsNullOrWhiteSpace($reviewId)) { $reviewId = [string](Get-ObjectValue $Review "name") }
  return "$appKey|extra|$reviewType|$reviewId"
}

function Update-AppStatusTiming($NextApp, $OldApp, [string]$Now) {
  $newStatus = Normalize-Status ([string](Get-ObjectValue $NextApp "status"))
  $oldStatus = if ($OldApp) { Normalize-Status ([string](Get-ObjectValue $OldApp "status")) } else { "" }
  $history = New-Object "System.Collections.Generic.List[object]"
  if ($OldApp) {
    foreach ($entry in @(Get-ListItems (Get-ObjectValue $OldApp "statusHistory"))) {
      if ($null -ne $entry) { [void]$history.Add($entry) }
    }
  }
  $changedAt = if ($OldApp) { [string](Get-ObjectValue $OldApp "statusChangedAt") } else { "" }
  $hasCurrentStatusHistory = @($history | Where-Object {
    (Normalize-Status ([string](Get-ObjectValue $_ "status"))) -eq $newStatus
  }).Count -gt 0

  if ([string]::IsNullOrWhiteSpace($changedAt)) {
    $changedAt = $Now
    [void]$history.Add((New-StatusHistoryEntry -Kind "main" -Name "版本" -PreviousStatus "" -Status $newStatus -DetectedAt $Now -Initial $true))
  } elseif ($oldStatus -and $newStatus -and $oldStatus -ne $newStatus) {
    $changedAt = $Now
    [void]$history.Add((New-StatusHistoryEntry -Kind "main" -Name "版本" -PreviousStatus $oldStatus -Status $newStatus -DetectedAt $Now -Initial $false))
  } elseif ($hasCurrentStatusHistory) {
    $currentHistory = @($history | Where-Object {
      (Normalize-Status ([string](Get-ObjectValue $_ "status"))) -eq $newStatus
    } | Sort-Object detectedAt | Select-Object -Last 1)
    if ($currentHistory.Count -gt 0) {
      $changedAt = [string](Get-ObjectValue $currentHistory[0] "detectedAt")
    }
  }

  Set-ObjectValue $NextApp "statusChangedAt" $changedAt
  Set-ObjectValue $NextApp "statusCheckedAt" $Now
  Set-ObjectValue $NextApp "statusHistory" @(Limit-StatusHistory @($history.ToArray()))
}

function Update-ExtraReviewTiming($NextApp, $OldApp, [string]$Now) {
  $oldMap = @{}
  foreach ($oldReview in @(Get-ListItems (Get-ObjectValue $OldApp "extraReviews"))) {
    if ($null -eq $oldReview) { continue }
    $oldMap[(Get-ExtraReviewIdentityKey $OldApp $oldReview)] = $oldReview
  }

  $nextReviews = @()
  foreach ($rawReview in @(Get-ListItems (Get-ObjectValue $NextApp "extraReviews"))) {
    if ($null -eq $rawReview) { continue }
    $review = ConvertTo-HashtableDeep $rawReview
    $newStatus = Normalize-Status ([string](Get-ObjectValue $review "status"))
    if ([string]::IsNullOrWhiteSpace($newStatus) -or @("NO_VERSION", "UNKNOWN") -contains $newStatus) { continue }
    $key = Get-ExtraReviewIdentityKey $NextApp $review
    $oldReview = if ($oldMap.ContainsKey($key)) { $oldMap[$key] } else { $null }
    $oldStatus = if ($oldReview) { Normalize-Status ([string](Get-ObjectValue $oldReview "status")) } else { "" }
    $history = New-Object "System.Collections.Generic.List[object]"
    if ($oldReview) {
      foreach ($entry in @(Get-ListItems (Get-ObjectValue $oldReview "statusHistory"))) {
        if ($null -ne $entry) { [void]$history.Add($entry) }
      }
    }
    $changedAt = if ($oldReview) { [string](Get-ObjectValue $oldReview "statusChangedAt") } else { "" }
    $name = [string](Get-ObjectValue $review "typeLabel")
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "产品页面优化" }

    if ([string]::IsNullOrWhiteSpace($changedAt)) {
      $changedAt = $Now
      [void]$history.Add((New-StatusHistoryEntry -Kind "extraReview" -Name $name -PreviousStatus "" -Status $newStatus -DetectedAt $Now -Initial $true))
    } elseif ($oldStatus -and $newStatus -and $oldStatus -ne $newStatus) {
      $changedAt = $Now
      [void]$history.Add((New-StatusHistoryEntry -Kind "extraReview" -Name $name -PreviousStatus $oldStatus -Status $newStatus -DetectedAt $Now -Initial $false))
    }

    Set-ObjectValue $review "statusChangedAt" $changedAt
    Set-ObjectValue $review "statusCheckedAt" $Now
    Set-ObjectValue $review "statusHistory" @(Limit-StatusHistory @($history.ToArray()))
    $nextReviews += $review
  }

  Set-ObjectValue $NextApp "extraReviews" @($nextReviews)
}

function Get-ExtraReviewChanges($OldApp, $NewApp) {
  $oldMap = @{}
  foreach ($oldReview in @(Get-ListItems (Get-ObjectValue $OldApp "extraReviews"))) {
    if ($null -eq $oldReview) { continue }
    $oldMap[(Get-ExtraReviewIdentityKey $OldApp $oldReview)] = $oldReview
  }

  $changes = @()
  foreach ($newReview in @(Get-ListItems (Get-ObjectValue $NewApp "extraReviews"))) {
    if ($null -eq $newReview) { continue }
    $key = Get-ExtraReviewIdentityKey $NewApp $newReview
    $oldReview = $null
    $oldStatus = ""
    if ($oldMap.ContainsKey($key)) {
      $oldReview = $oldMap[$key]
      $oldStatus = Normalize-Status ([string](Get-ObjectValue $oldReview "status"))
    }
    $newStatus = Normalize-Status ([string](Get-ObjectValue $newReview "status"))
    if ([string]::IsNullOrWhiteSpace($newStatus) -or @("NO_VERSION", "UNKNOWN") -contains $newStatus) { continue }
    if ($oldReview -and $oldStatus -eq $newStatus) { continue }

    $changes += [ordered]@{
      kind = "extraReview"
      notificationKey = $key
      appName = $NewApp.name
      accountName = $NewApp.accountName
      version = $NewApp.version
      extraType = [string](Get-ObjectValue $newReview "type")
      extraTypeLabel = [string](Get-ObjectValue $newReview "typeLabel")
      extraName = [string](Get-ObjectValue $newReview "name")
      oldStatus = $oldStatus
      oldLabel = Get-StatusLabel $oldStatus
      newStatus = $newStatus
      newLabel = Get-StatusLabel $newStatus
    }
  }
  return @($changes)
}

function Get-AppStatusChanges($OldApps, $NewApps) {
  $oldMap = @{}
  foreach ($oldApp in @($OldApps)) {
    $oldMap[(Get-AppIdentityKey $oldApp)] = $oldApp
  }

  $changes = @()
  foreach ($newApp in @($NewApps)) {
    $key = Get-AppIdentityKey $newApp
    if (!$oldMap.ContainsKey($key)) { continue }
    $oldApp = $oldMap[$key]
    $changes += @(Get-ExtraReviewChanges $oldApp $newApp)
    $oldStatus = Normalize-Status $oldApp.status
    $newStatus = Normalize-Status $newApp.status
    if ($oldStatus -and $newStatus -and $oldStatus -ne $newStatus) {
      $changes += [ordered]@{
        notificationKey = $key
        kind = "appStatus"
        appName = $newApp.name
        accountName = $newApp.accountName
        version = $newApp.version
        oldStatus = $oldStatus
        oldLabel = Get-StatusLabel $oldStatus
        newStatus = $newStatus
        newLabel = Get-StatusLabel $newStatus
      }
    }
  }
  return @($changes)
}

function Get-AppStatusSnapshot($Db) {
  $snapshot = @{}
  if ($null -eq $Db) { return $snapshot }

  foreach ($app in @(Get-ListItems (Get-ObjectValue $Db "apps"))) {
    if ($null -eq $app) { continue }
    $appKey = Get-AppIdentityKey $app
    if ([string]::IsNullOrWhiteSpace($appKey)) { continue }

    $appStatus = Normalize-Status ([string](Get-ObjectValue $app "status"))
    $snapshot[$appKey] = [ordered]@{
      kind = "appStatus"
      notificationKey = $appKey
      appName = [string](Get-ObjectValue $app "name")
      accountName = [string](Get-ObjectValue $app "accountName")
      version = [string](Get-ObjectValue $app "version")
      status = $appStatus
      label = Get-StatusLabel $appStatus
    }

    foreach ($review in @(Get-ListItems (Get-ObjectValue $app "extraReviews"))) {
      if ($null -eq $review) { continue }
      $reviewStatus = Normalize-Status ([string](Get-ObjectValue $review "status"))
      if ([string]::IsNullOrWhiteSpace($reviewStatus) -or @("NO_VERSION", "UNKNOWN") -contains $reviewStatus) { continue }

      $reviewKey = Get-ExtraReviewIdentityKey $app $review
      if ([string]::IsNullOrWhiteSpace($reviewKey)) { continue }
      $typeLabel = [string](Get-ObjectValue $review "typeLabel")
      if ([string]::IsNullOrWhiteSpace($typeLabel)) { $typeLabel = "产品页面优化" }

      $snapshot[$reviewKey] = [ordered]@{
        kind = "extraReview"
        notificationKey = $reviewKey
        appName = [string](Get-ObjectValue $app "name")
        accountName = [string](Get-ObjectValue $app "accountName")
        version = [string](Get-ObjectValue $app "version")
        extraType = [string](Get-ObjectValue $review "type")
        extraTypeLabel = $typeLabel
        extraName = [string](Get-ObjectValue $review "name")
        status = $reviewStatus
        label = Get-StatusLabel $reviewStatus
      }
    }
  }

  return $snapshot
}

function Get-SnapshotStatusChanges($OldSnapshot, $NewSnapshot) {
  $changes = @()
  if ($null -eq $OldSnapshot -or $null -eq $NewSnapshot) { return @($changes) }

  foreach ($key in @($NewSnapshot.Keys)) {
    if (-not $OldSnapshot.ContainsKey($key)) { continue }
    $oldItem = $OldSnapshot[$key]
    $newItem = $NewSnapshot[$key]
    $oldStatus = Normalize-Status ([string](Get-ObjectValue $oldItem "status"))
    $newStatus = Normalize-Status ([string](Get-ObjectValue $newItem "status"))
    if ([string]::IsNullOrWhiteSpace($oldStatus) -or [string]::IsNullOrWhiteSpace($newStatus) -or $oldStatus -eq $newStatus) {
      continue
    }

    $changes += [ordered]@{
      kind = [string](Get-ObjectValue $newItem "kind")
      notificationKey = [string](Get-ObjectValue $newItem "notificationKey")
      appName = [string](Get-ObjectValue $newItem "appName")
      accountName = [string](Get-ObjectValue $newItem "accountName")
      version = [string](Get-ObjectValue $newItem "version")
      extraType = [string](Get-ObjectValue $newItem "extraType")
      extraTypeLabel = [string](Get-ObjectValue $newItem "extraTypeLabel")
      extraName = [string](Get-ObjectValue $newItem "extraName")
      oldStatus = $oldStatus
      oldLabel = Get-StatusLabel $oldStatus
      newStatus = $newStatus
      newLabel = Get-StatusLabel $newStatus
    }
  }

  return @($changes)
}

function Test-RecentStatusNotification([string]$NotificationKey, [string]$Kind, [string]$Status) {
  if ([string]::IsNullOrWhiteSpace($NotificationKey)) { return $false }

  $now = [DateTime]::UtcNow
  foreach ($key in @($Script:RecentStatusNotificationMap.Keys)) {
    $rememberedAt = $Script:RecentStatusNotificationMap[$key]
    if ($rememberedAt -is [DateTime] -and ($now - $rememberedAt).TotalSeconds -gt 8) {
      $Script:RecentStatusNotificationMap.Remove($key)
    }
  }

  $dedupeKey = "$Kind|$NotificationKey|$(Normalize-Status $Status)"
  if ($Script:RecentStatusNotificationMap.ContainsKey($dedupeKey)) {
    $rememberedAt = $Script:RecentStatusNotificationMap[$dedupeKey]
    if ($rememberedAt -is [DateTime] -and ($now - $rememberedAt).TotalSeconds -lt 4) {
      return $true
    }
  }

  $Script:RecentStatusNotificationMap[$dedupeKey] = $now
  return $false
}

function ConvertTo-ExtraReviewRows($Reviews) {
  $rows = New-Object "System.Collections.ObjectModel.ObservableCollection[object]"
  foreach ($review in @($Reviews)) {
    if ($null -eq $review) { continue }
    $status = Normalize-Status ([string](Get-ObjectValue $review "status"))
    if ([string]::IsNullOrWhiteSpace($status) -or @("NO_VERSION", "UNKNOWN") -contains $status) { continue }
    $typeLabel = [string](Get-ObjectValue $review "typeLabel")
    if ([string]::IsNullOrWhiteSpace($typeLabel)) { $typeLabel = "产品页面优化" }
    $typeLabel = Get-DisplayReviewName $typeLabel
    $name = [string](Get-ObjectValue $review "name")
    $name = Get-DisplayReviewName $name
    if ([string]::IsNullOrWhiteSpace($name) -or $name -eq $typeLabel) {
      $display = $typeLabel
    } else {
      $display = "$typeLabel - $name"
    }
    $rows.Add([pscustomobject][ordered]@{
      id = [string](Get-ObjectValue $review "id")
      type = [string](Get-ObjectValue $review "type")
      typeLabel = $typeLabel
      name = $name
      display = $display
      status = $status
      statusLabel = Get-StatusLabel $status
      statusBrush = Get-StatusBrush $status
      statusBackground = Get-StatusBackground $status
    })
  }
  Write-Output -NoEnumerate $rows
}

function Get-ExtraReviewSummaryText($Reviews) {
  $items = ConvertTo-ExtraReviewRows $Reviews
  if ($items.Count -eq 0) { return "" }
  if ($items.Count -eq 1) {
    return "$($items[0].typeLabel)：$($items[0].statusLabel)"
  }
  $grouped = @($items | Group-Object statusLabel | Sort-Object Count -Descending)
  $top = $grouped | Select-Object -First 1
  if ($null -ne $top) {
    return "产品页面优化：$($items.Count) 项，$($top.Name) $($top.Count) 项"
  }
  return "产品页面优化：$($items.Count) 项"
}

function Notify-AppStatusChanges($Changes) {
  if ($null -eq $Changes) { return }
  foreach ($change in @($Changes)) {
    if ($null -eq $change) { continue }
    $kind = [string](Get-ObjectValue $change "kind")
    $appName = [string](Get-ObjectValue $change "appName")
    $accountName = [string](Get-ObjectValue $change "accountName")
    $version = [string](Get-ObjectValue $change "version")
    $oldStatus = [string](Get-ObjectValue $change "oldStatus")
    $oldLabel = [string](Get-ObjectValue $change "oldLabel")
    $newLabel = [string](Get-ObjectValue $change "newLabel")
    $newStatus = [string](Get-ObjectValue $change "newStatus")
    $notificationKey = [string](Get-ObjectValue $change "notificationKey")
    $extraTypeLabel = [string](Get-ObjectValue $change "extraTypeLabel")
    if ([string]::IsNullOrWhiteSpace($extraTypeLabel)) { $extraTypeLabel = "产品页面优化" }
    if ([string]::IsNullOrWhiteSpace($notificationKey)) { $notificationKey = "$kind|$appName|$version" }
    if ([string]::IsNullOrWhiteSpace($oldLabel)) { $oldLabel = $oldStatus }
    if ([string]::IsNullOrWhiteSpace($newLabel)) { $newLabel = $newStatus }
    if (![string]::IsNullOrWhiteSpace($oldLabel)) { $oldLabel = Get-StatusLabel (Normalize-Status $oldLabel) }
    if (![string]::IsNullOrWhiteSpace($newLabel)) { $newLabel = Get-StatusLabel (Normalize-Status $newLabel) }
    if ([string]::IsNullOrWhiteSpace($appName) -or [string]::IsNullOrWhiteSpace($oldLabel) -or [string]::IsNullOrWhiteSpace($newLabel)) {
      continue
    }
    if (Test-RecentStatusNotification $notificationKey $kind $newStatus) { continue }
    $versionText = if (![string]::IsNullOrWhiteSpace($version)) { " v$version" } else { "" }
    $accountText = if (![string]::IsNullOrWhiteSpace($accountName)) { $accountName } else { "未命名账号" }
    $title = if ($kind -eq "extraReview") { "$extraTypeLabel 状态已变化" } else { "App 状态已变化" }
    $messagePrefix = if ($kind -eq "extraReview") { "$appName$versionText $extraTypeLabel" } else { "$appName$versionText" }
    Show-DesktopNotification `
      -Title $title `
      -Message "$messagePrefix：$oldLabel → $newLabel`n账号：$accountText" `
      -Status $newStatus `
      -AppName $appName `
      -Version $version `
      -OldLabel $oldLabel `
      -NewLabel $newLabel `
      -AccountName $accountText `
      -NotificationKey $notificationKey
  }
}

function Get-AutoSyncIntervalMinutes($Db, $Account) {
  $statuses = @()
  foreach ($app in @($Db.apps | Where-Object { $_.accountId -eq $Account.id })) {
    $statuses += Normalize-Status $app.status
    foreach ($review in @(Get-ListItems (Get-ObjectValue $app "extraReviews"))) {
      if ($null -eq $review) { continue }
      $statuses += Normalize-Status ([string](Get-ObjectValue $review "status"))
    }
  }
  if ($statuses -contains "IN_REVIEW") { return 1 }
  if ($statuses -contains "WAITING_FOR_REVIEW") { return 5 }
  return 15
}

function Get-AutoDiscoverAppsSettingFromDb($Db) {
  if ($null -eq $Db -or $null -eq $Db.settings -or $null -eq $Db.settings.autoDiscoverApps) { return $false }
  try { return [bool]$Db.settings.autoDiscoverApps } catch { return $false }
}

function Set-NextAutoSync($Db, $Account, [int]$Minutes) {
  $Account.nextAutoSyncAt = [DateTime]::UtcNow.AddMinutes($Minutes).ToString("o")
  $Account.updatedAt = Get-NowIso
}

function Update-AutoSyncStatusText([string]$Text) {
  if ($null -ne $AutoSyncStatusText) {
    $AutoSyncStatusText.Text = $Text
  }
}

function Get-DueAutoSyncAccounts($Db) {
  $now = [DateTime]::UtcNow
  $dueAccounts = @()
  $autoDiscoverEnabled = Get-AutoDiscoverAppsSettingFromDb $Db
  foreach ($account in @($Db.accounts)) {
    $nextAt = $null
    if (![string]::IsNullOrWhiteSpace($account.nextAutoSyncAt)) {
      try { $nextAt = [DateTime]::Parse($account.nextAutoSyncAt).ToUniversalTime() } catch { $nextAt = $null }
    }
    $statusDue = ($null -eq $nextAt -or $nextAt -le $now)

    $discoverDue = $false
    if ($autoDiscoverEnabled) {
      $nextDiscoverAt = $null
      if (![string]::IsNullOrWhiteSpace($account.nextAppDiscoveryAt)) {
        try { $nextDiscoverAt = [DateTime]::Parse($account.nextAppDiscoveryAt).ToUniversalTime() } catch { $nextDiscoverAt = $null }
      }
      $discoverDue = ($null -eq $nextDiscoverAt -or $nextDiscoverAt -le $now)
    }

    if ($statusDue -or $discoverDue) {
      $dueAccounts += $account
    }
  }
  return @($dueAccounts)
}

function Invoke-AutoSyncDueAccounts {
  if ($Script:AutoSyncRunning -or $Script:ManualSyncRunning) { return }
  if ($null -eq $AutoSyncToggle -or $AutoSyncToggle.IsChecked -ne $true) {
    Update-AutoSyncStatusText "自动同步已关闭"
    return
  }

  $db = Read-Db
  $dueAccounts = @(Get-DueAutoSyncAccounts $db)
  if ($dueAccounts.Count -eq 0) {
    Update-AutoSyncStatusText "自动同步运行中"
    return
  }

  Start-AutoSyncWorker
}

function Complete-AutoSync {
  if ($null -ne $Script:AutoSyncPollTimer) {
    $Script:AutoSyncPollTimer.Stop()
    $Script:AutoSyncPollTimer = $null
  }

  $workerProcess = $Script:AutoSyncProcess
  $workerOutput = ""
  $workerError = ""
  if ($null -ne $workerProcess) {
    try { $workerOutput = $workerProcess.StandardOutput.ReadToEnd() } catch {}
    try { $workerError = $workerProcess.StandardError.ReadToEnd() } catch {}
  }

  $result = $null
  try {
    if (![string]::IsNullOrWhiteSpace($Script:AutoSyncResultPath) -and (Test-Path -LiteralPath $Script:AutoSyncResultPath)) {
      $result = ConvertTo-HashtableDeep ((Get-Content -LiteralPath $Script:AutoSyncResultPath -Raw -Encoding UTF8) | ConvertFrom-Json)
    } elseif (![string]::IsNullOrWhiteSpace($workerOutput) -and $workerOutput.Trim().StartsWith("{")) {
      $result = ConvertTo-HashtableDeep ($workerOutput | ConvertFrom-Json)
    }
  } catch {
    $result = [ordered]@{ ok = $false; error = $_.Exception.Message }
  }

  $forcedError = $Script:AutoSyncForcedError
  $Script:AutoSyncRunning = $false
  $Script:AutoSyncProcess = $null
  $Script:AutoSyncStartedAt = $null
  $Script:AutoSyncForcedError = ""
  Refresh-Ui

  if (![string]::IsNullOrWhiteSpace($forcedError)) {
    Update-AutoSyncStatusText $forcedError
  } elseif ($null -eq $result) {
    $detail = ""
    if (![string]::IsNullOrWhiteSpace($workerError)) {
      $detail = $workerError.Trim()
    } elseif (![string]::IsNullOrWhiteSpace($workerOutput)) {
      $detail = $workerOutput.Trim()
    }
    if (![string]::IsNullOrWhiteSpace($detail)) {
      Update-AutoSyncStatusText "自动同步失败：$(Get-FriendlySyncError $detail)"
    } else {
      Update-AutoSyncStatusText "自动同步没有返回结果"
    }
  } elseif ($result.ok) {
    try { Notify-AppStatusChanges $result.changes } catch {}
    if ([int]$result.okCount -gt 0 -and [int]$result.failCount -eq 0) {
      Update-AutoSyncStatusText "自动同步已更新"
    } elseif ([int]$result.failCount -gt 0) {
      Update-AutoSyncStatusText "自动同步完成，部分账号失败"
    } else {
      Update-AutoSyncStatusText "自动同步运行中"
    }
  } else {
    $message = if (![string]::IsNullOrWhiteSpace($result.error)) { Get-FriendlySyncError $result.error } else { "同步失败，请稍后重试。" }
    Update-AutoSyncStatusText "自动同步失败：$message"
  }

  if (![string]::IsNullOrWhiteSpace($Script:AutoSyncResultPath)) {
    Remove-Item -LiteralPath $Script:AutoSyncResultPath -Force -ErrorAction SilentlyContinue
  }
  $Script:AutoSyncResultPath = ""

  if ($null -ne $AutoSyncToggle -and $AutoSyncToggle.IsChecked -ne $true) {
    Update-AutoSyncStatusText "自动同步已关闭"
  }
}

function Start-AutoSyncPollTimer {
  if ($null -ne $Script:AutoSyncPollTimer) {
    $Script:AutoSyncPollTimer.Stop()
  }
  $Script:AutoSyncPollTimer = New-Object Windows.Threading.DispatcherTimer
  $Script:AutoSyncPollTimer.Interval = [TimeSpan]::FromMilliseconds(600)
  $Script:AutoSyncPollTimer.Add_Tick({
    if ($null -eq $Script:AutoSyncProcess) {
      Complete-AutoSync
      return
    }
    if ($null -ne $Script:AutoSyncStartedAt -and ([DateTime]::UtcNow - $Script:AutoSyncStartedAt).TotalMinutes -gt 10) {
      $Script:AutoSyncForcedError = "自动同步超时，已停止本次后台任务"
      try {
        if (!$Script:AutoSyncProcess.HasExited) { $Script:AutoSyncProcess.Kill() }
      } catch {
      }
      Complete-AutoSync
      return
    }
    try {
      if ($Script:AutoSyncProcess.HasExited) {
        Complete-AutoSync
      }
    } catch {
      Complete-AutoSync
    }
  })
  $Script:AutoSyncPollTimer.Start()
}

function Start-AutoSyncWorker {
  if ($Script:AutoSyncRunning -or $Script:ManualSyncRunning) { return }
  $worker = Join-Path $Script:SrcDir "sync-worker.ps1"
  if (!(Test-Path -LiteralPath $worker)) {
    Update-AutoSyncStatusText "缺少后台同步模块"
    return
  }

  $resultPath = Join-Path ([IO.Path]::GetTempPath()) ("asc-radar-auto-{0}.json" -f [Guid]::NewGuid().ToString("N"))
  $psExe = Join-Path $PSHOME "powershell.exe"
  if (!(Test-Path -LiteralPath $psExe)) { $psExe = "powershell.exe" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$worker`" -Mode `"auto`" -ResultPath `"$resultPath`""
  $psi.WorkingDirectory = $Script:AppRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

  try {
    $Script:AutoSyncProcess = New-Object System.Diagnostics.Process
    $Script:AutoSyncProcess.StartInfo = $psi
    $Script:AutoSyncResultPath = $resultPath
    $Script:AutoSyncStartedAt = [DateTime]::UtcNow
    $Script:AutoSyncForcedError = ""
    $Script:AutoSyncRunning = $true
    Update-AutoSyncStatusText "自动同步中..."
    [void]$Script:AutoSyncProcess.Start()
    Start-AutoSyncPollTimer
  } catch {
    $Script:AutoSyncRunning = $false
    $Script:AutoSyncProcess = $null
    $Script:AutoSyncResultPath = ""
    Update-AutoSyncStatusText "自动同步失败：$($_.Exception.Message)"
  }
}

function Start-AutoSyncTimer {
  if ($null -ne $Script:AutoSyncTimer) { return }
  $Script:AutoSyncTimer = New-Object Windows.Threading.DispatcherTimer
  $Script:AutoSyncTimer.Interval = [TimeSpan]::FromSeconds(30)
  $Script:AutoSyncTimer.Add_Tick({ Invoke-AutoSyncDueAccounts })
  $Script:AutoSyncTimer.Start()
}

function Stop-SyncSpinner {
  if ($null -ne $Script:SyncSpinnerTimer) {
    $Script:SyncSpinnerTimer.Stop()
    $Script:SyncSpinnerTimer = $null
  }
}

function Start-SyncSpinner {
  Stop-SyncSpinner
  $Script:SyncSpinnerIndex = 0
  $Script:SyncSpinnerTimer = New-Object Windows.Threading.DispatcherTimer
  $Script:SyncSpinnerTimer.Interval = [TimeSpan]::FromMilliseconds(110)
  $Script:SyncSpinnerTimer.Add_Tick({
    $frames = @("◜", "◠", "◝", "◞", "◡", "◟")
    $Script:SyncSpinnerIndex = ($Script:SyncSpinnerIndex + 1) % $frames.Count
    $frame = $frames[$Script:SyncSpinnerIndex]
    foreach ($spinner in @($SyncAllSpinner, $SyncSelectedSpinner)) {
      if ($null -ne $spinner -and [string]$spinner.Visibility -eq "Visible") {
        $spinner.Text = $frame
      }
    }
  })
  $Script:SyncSpinnerTimer.Start()
}

function Set-ManualSyncUi([bool]$Busy, [string]$Mode = "") {
  if ($null -ne $SyncAllBtn) { $SyncAllBtn.IsEnabled = -not $Busy }
  if ($null -ne $SyncSelectedAccountBtn) { $SyncSelectedAccountBtn.IsEnabled = -not $Busy }
  if ($null -ne $DiscoverAppsNowBtn) { $DiscoverAppsNowBtn.IsEnabled = -not $Busy }

  if ($Busy) {
    if ($Mode -eq "selected") {
      if ($null -ne $SyncSelectedSpinner) { $SyncSelectedSpinner.Visibility = "Visible" }
      if ($null -ne $SyncSelectedText) { $SyncSelectedText.Text = "同步中" }
      if ($null -ne $SyncAllSpinner) { $SyncAllSpinner.Visibility = "Collapsed" }
      if ($null -ne $SyncAllText) { $SyncAllText.Text = "同步全部" }
    } elseif ($Mode -eq "discover") {
      if ($null -ne $SyncAllSpinner) { $SyncAllSpinner.Visibility = "Visible" }
      if ($null -ne $SyncAllText) { $SyncAllText.Text = "发现中" }
      if ($null -ne $SyncSelectedSpinner) { $SyncSelectedSpinner.Visibility = "Collapsed" }
      if ($null -ne $SyncSelectedText) { $SyncSelectedText.Text = "同步选中账号" }
      if ($null -ne $DiscoverAppsNowBtn) { $DiscoverAppsNowBtn.Content = "发现中" }
    } else {
      if ($null -ne $SyncAllSpinner) { $SyncAllSpinner.Visibility = "Visible" }
      if ($null -ne $SyncAllText) { $SyncAllText.Text = "同步中" }
      if ($null -ne $SyncSelectedSpinner) { $SyncSelectedSpinner.Visibility = "Collapsed" }
      if ($null -ne $SyncSelectedText) { $SyncSelectedText.Text = "同步选中账号" }
    }
    Update-AutoSyncStatusText "手动同步中，自动同步排队"
    Start-SyncSpinner
    return
  }

  Stop-SyncSpinner
  if ($null -ne $SyncAllSpinner) { $SyncAllSpinner.Visibility = "Collapsed"; $SyncAllSpinner.Text = "◜" }
  if ($null -ne $SyncAllText) { $SyncAllText.Text = "同步全部" }
  if ($null -ne $SyncSelectedSpinner) { $SyncSelectedSpinner.Visibility = "Collapsed"; $SyncSelectedSpinner.Text = "◜" }
  if ($null -ne $SyncSelectedText) { $SyncSelectedText.Text = "同步选中账号" }
  if ($null -ne $DiscoverAppsNowBtn) { $DiscoverAppsNowBtn.Content = "立即发现" }
  if ($null -ne $SyncAllBtn) { $SyncAllBtn.IsEnabled = $true }
  if ($null -ne $SyncSelectedAccountBtn) { $SyncSelectedAccountBtn.IsEnabled = $true }
  if ($null -ne $DiscoverAppsNowBtn) { $DiscoverAppsNowBtn.IsEnabled = $true }
  if ($null -ne $AutoSyncToggle -and $AutoSyncToggle.IsChecked -eq $true) {
    Update-AutoSyncStatusText "自动同步运行中"
  } else {
    Update-AutoSyncStatusText "自动同步已关闭"
  }
}

function Get-ManualSyncResultText($Result) {
  if ($Result.mode -eq "discover") {
    if ([int]$Result.failCount -gt 0) {
      $firstError = @($Result.errors | Select-Object -First 1)
      if ($firstError.Count -gt 0) { return "发现失败：$($firstError[0].message)" }
      return "发现失败，请稍后重试。"
    }
    return "发现完成，新增 $($Result.totalApps) 个 App。"
  }

  if ($Result.mode -eq "selected") {
    if ([int]$Result.failCount -gt 0) {
      $firstError = @($Result.errors | Select-Object -First 1)
      if ($firstError.Count -gt 0) { return "同步失败：$($firstError[0].message)" }
      return "同步失败，请稍后重试。"
    }
    return "同步完成，发现 $($Result.totalApps) 个 App。"
  }

  $message = "同步完成：成功 $($Result.okCount) 个，失败 $($Result.failCount) 个。"
  $errorLines = @($Result.errors | ForEach-Object {
    if (![string]::IsNullOrWhiteSpace($_.accountName) -and ![string]::IsNullOrWhiteSpace($_.message)) {
      "$($_.accountName)：$(Get-FriendlySyncError $_.message)"
    }
  })
  if ($errorLines.Count -gt 0) {
    $message += "`n`n" + ($errorLines -join "`n")
  }
  return $message
}

function Complete-ManualSync {
  if ($null -ne $Script:ManualSyncPollTimer) {
    $Script:ManualSyncPollTimer.Stop()
    $Script:ManualSyncPollTimer = $null
  }

  $workerProcess = $Script:ManualSyncProcess
  $workerOutput = ""
  $workerError = ""
  if ($null -ne $workerProcess) {
    try { $workerOutput = $workerProcess.StandardOutput.ReadToEnd() } catch {}
    try { $workerError = $workerProcess.StandardError.ReadToEnd() } catch {}
  }

  $result = $null
  try {
    if (![string]::IsNullOrWhiteSpace($Script:ManualSyncResultPath) -and (Test-Path -LiteralPath $Script:ManualSyncResultPath)) {
      $result = ConvertTo-HashtableDeep ((Get-Content -LiteralPath $Script:ManualSyncResultPath -Raw -Encoding UTF8) | ConvertFrom-Json)
    } elseif (![string]::IsNullOrWhiteSpace($workerOutput) -and $workerOutput.Trim().StartsWith("{")) {
      $result = ConvertTo-HashtableDeep ($workerOutput | ConvertFrom-Json)
    }
  } catch {
    $result = [ordered]@{ ok = $false; error = $_.Exception.Message }
  }

  $mode = $Script:ManualSyncMode
  $accountId = $Script:ManualSyncAccountId
  $forcedError = $Script:ManualSyncForcedError
  $Script:ManualSyncRunning = $false
  $Script:ManualSyncProcess = $null
  $Script:ManualSyncStartedAt = $null
  $Script:ManualSyncForcedError = ""
  Set-ManualSyncUi $false
  Refresh-Ui
  if ($null -ne $AutoSyncToggle -and $AutoSyncToggle.IsChecked -eq $true) {
    Invoke-AutoSyncDueAccounts
  }

  if (![string]::IsNullOrWhiteSpace($forcedError)) {
    [Windows.MessageBox]::Show($forcedError, "同步失败", "OK", "Warning") | Out-Null
  } elseif ($null -eq $result) {
    $detail = ""
    if (![string]::IsNullOrWhiteSpace($workerError)) {
      $detail = $workerError.Trim()
    } elseif (![string]::IsNullOrWhiteSpace($workerOutput)) {
      $detail = $workerOutput.Trim()
    }
    $message = if (![string]::IsNullOrWhiteSpace($detail)) {
      "后台同步异常退出：`n$(Get-FriendlySyncError $detail)"
    } else {
      "后台同步没有返回结果，请稍后重试。"
    }
    [Windows.MessageBox]::Show($message, "同步失败", "OK", "Warning") | Out-Null
  } elseif ($result.ok) {
    try { Notify-AppStatusChanges $result.changes } catch {}
    if ($mode -eq "discover" -and [int]$result.failCount -eq 0) {
      Show-View "apps"
    } elseif ($mode -eq "selected" -and ![string]::IsNullOrWhiteSpace($accountId) -and [int]$result.failCount -eq 0) {
      Show-View "apps"
      Select-AppAccount $accountId
    }
    $hasFailure = ([int]$result.failCount -gt 0)
    $boxTitle = if ($hasFailure) { "同步失败" } else { "同步完成" }
    $boxIcon = if ($hasFailure) { "Warning" } else { "Information" }
    [Windows.MessageBox]::Show((Get-ManualSyncResultText $result), $boxTitle, "OK", $boxIcon) | Out-Null
  } else {
    $message = if (![string]::IsNullOrWhiteSpace($result.error)) { Get-FriendlySyncError $result.error } else { "同步失败，请稍后重试。" }
    [Windows.MessageBox]::Show($message, "同步失败", "OK", "Warning") | Out-Null
  }

  if (![string]::IsNullOrWhiteSpace($Script:ManualSyncResultPath)) {
    Remove-Item -LiteralPath $Script:ManualSyncResultPath -Force -ErrorAction SilentlyContinue
  }
  $Script:ManualSyncResultPath = ""
  $Script:ManualSyncMode = ""
  $Script:ManualSyncAccountId = ""
}

function Start-ManualSyncPollTimer {
  if ($null -ne $Script:ManualSyncPollTimer) {
    $Script:ManualSyncPollTimer.Stop()
  }
  $Script:ManualSyncPollTimer = New-Object Windows.Threading.DispatcherTimer
  $Script:ManualSyncPollTimer.Interval = [TimeSpan]::FromMilliseconds(450)
  $Script:ManualSyncPollTimer.Add_Tick({
    if ($null -eq $Script:ManualSyncProcess) {
      Complete-ManualSync
      return
    }
    if ($null -ne $Script:ManualSyncStartedAt -and ([DateTime]::UtcNow - $Script:ManualSyncStartedAt).TotalMinutes -gt 10) {
      $Script:ManualSyncForcedError = "同步超过 10 分钟没有完成，已自动停止。请稍后重试，或减少同时同步的账号数量。"
      try {
        if (!$Script:ManualSyncProcess.HasExited) { $Script:ManualSyncProcess.Kill() }
      } catch {
      }
      Complete-ManualSync
      return
    }
    try {
      if ($Script:ManualSyncProcess.HasExited) {
        Complete-ManualSync
      }
    } catch {
      Complete-ManualSync
    }
  })
  $Script:ManualSyncPollTimer.Start()
}

function Start-ManualSync([string]$Mode, [string]$AccountId = "") {
  if ($Script:ManualSyncRunning) {
    [Windows.MessageBox]::Show("当前正在同步，请等这次同步完成后再操作。", "同步中", "OK", "Information") | Out-Null
    return
  }
  if ($Script:AutoSyncRunning) {
    [Windows.MessageBox]::Show("自动同步正在进行，请稍后再手动同步。", "同步中", "OK", "Information") | Out-Null
    return
  }
  $worker = Join-Path $Script:SrcDir "sync-worker.ps1"
  if (!(Test-Path -LiteralPath $worker)) {
    [Windows.MessageBox]::Show("缺少后台同步模块。", "同步失败", "OK", "Warning") | Out-Null
    return
  }

  $resultPath = Join-Path ([IO.Path]::GetTempPath()) ("asc-radar-sync-{0}.json" -f [Guid]::NewGuid().ToString("N"))
  $psExe = Join-Path $PSHOME "powershell.exe"
  if (!(Test-Path -LiteralPath $psExe)) { $psExe = "powershell.exe" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$worker`" -Mode `"$Mode`" -AccountId `"$AccountId`" -ResultPath `"$resultPath`""
  $psi.WorkingDirectory = $Script:AppRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

  try {
    $Script:ManualSyncProcess = New-Object System.Diagnostics.Process
    $Script:ManualSyncProcess.StartInfo = $psi
    $Script:ManualSyncMode = $Mode
    $Script:ManualSyncAccountId = $AccountId
    $Script:ManualSyncResultPath = $resultPath
    $Script:ManualSyncStartedAt = [DateTime]::UtcNow
    $Script:ManualSyncForcedError = ""
    $Script:ManualSyncRunning = $true
    Set-ManualSyncUi $true $Mode
    [void]$Script:ManualSyncProcess.Start()
    Start-ManualSyncPollTimer
  } catch {
    $Script:ManualSyncRunning = $false
    $Script:ManualSyncProcess = $null
    Set-ManualSyncUi $false
    [Windows.MessageBox]::Show($_.Exception.Message, "同步失败", "OK", "Warning") | Out-Null
  }
}

function Get-FriendlySyncError([string]$Message) {
  if ([string]::IsNullOrWhiteSpace($Message)) { return "同步失败，请稍后重试。" }
  $text = $Message.Trim()
  if ($text -like "*账号私钥数据不完整*" -or $text -like "*缺少 .p8 私钥*" -or $text -like "*Private key data is incomplete*" -or $text -like "*Local private key could not be read*") {
    return "本地账号私钥无法读取，请编辑账号并重新选择 .p8 私钥后再同步。"
  }
  if ($text -like "*缺少 Issuer ID 或 Key ID*" -or $text -like "*Missing Issuer ID or Key ID*") {
    return "缺少 Issuer ID 或 Key ID，请编辑账号后再同步。"
  }
  if ($text -like "*Missing local encryption key*") {
    return "缺少本地加密密钥，请在主界面重新保存账号。"
  }
  if ($text -like "*No account to sync*") {
    return "没有可同步的账号。"
  }
  if ($text -like "*Apple API sync returned no result*" -or $text -like "*background sync returned no result*") {
    return "Apple API 同步没有返回结果，请稍后重试。"
  }
  if ($text -like "*Null 数组*" -or $text -like "*Cannot index into a null array*") {
    return "自动同步读取本地数据时遇到异常，已跳过本次同步；请重启工具后再试。"
  }
  return $text
}

function Test-SyncConfigurationError([string]$Message) {
  if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
  return (
    $Message -like "*账号私钥数据不完整*" -or
    $Message -like "*缺少 .p8 私钥*" -or
    $Message -like "*缺少 Issuer ID 或 Key ID*"
  )
}

function Test-SyncInternalReadError([string]$Message) {
  if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
  return ($Message -like "*Null 数组*" -or $Message -like "*Cannot index into a null array*")
}

function Add-Alert($Db, $Alert) {
  $existing = $Db.alerts | Where-Object { $_.key -eq $Alert.key -and -not $_.resolvedAt } | Select-Object -First 1
  if ($existing) {
    foreach ($key in $Alert.Keys) { $existing[$key] = $Alert[$key] }
    $existing.updatedAt = Get-NowIso
    return
  }
  $Db.alerts += [ordered]@{
    id = New-Id "alert"
    key = $Alert.key
    severity = if ($Alert.severity) { $Alert.severity } else { "medium" }
    type = if ($Alert.type) { $Alert.type } else { "NOTICE" }
    accountId = if ($Alert.accountId) { $Alert.accountId } else { "" }
    accountName = if ($Alert.accountName) { $Alert.accountName } else { "" }
    appId = if ($Alert.appId) { $Alert.appId } else { "" }
    appName = if ($Alert.appName) { $Alert.appName } else { "" }
    title = $Alert.title
    message = $Alert.message
    createdAt = Get-NowIso
    updatedAt = Get-NowIso
    resolvedAt = $null
  }
}

function Resolve-Alert([string]$AlertId) {
  Invoke-DbLocked {
    $db = Read-Db
    $alert = $db.alerts | Where-Object { $_.id -eq $AlertId } | Select-Object -First 1
    if (!$alert) { throw "提醒不存在" }
    $alert.resolvedAt = Get-NowIso
    $alert.updatedAt = Get-NowIso
    Write-Db $db
  }
}

function Resolve-AlertsByKeyPrefix($Db, [string]$KeyPrefix) {
  foreach ($alert in @($Db.alerts | Where-Object { ([string]$_.key).StartsWith($KeyPrefix) -and -not $_.resolvedAt })) {
    $alert.resolvedAt = Get-NowIso
    $alert.updatedAt = Get-NowIso
  }
}

function Update-AlertsForApps($Db, $Account, $Apps) {
  foreach ($app in $Apps) {
    if (@("REJECTED", "METADATA_REJECTED", "INVALID_BINARY") -contains $app.status) {
      Add-Alert $Db ([ordered]@{
        key = "review:$($app.id):$($app.status)"
        severity = "critical"
        type = "REVIEW_BLOCKED"
        accountId = $Account.id
        accountName = $Account.name
        appId = $app.id
        appName = $app.name
        title = "$($app.name) $(Get-StatusLabel $app.status)"
        message = "$($app.accountName) / $($app.version) 需要处理。"
      })
    }
  }
}

function Convert-DateText($Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return "-" }
  try { return ([DateTime]::Parse($Value)).ToLocalTime().ToString("MM-dd HH:mm") } catch { return "-" }
}

function Convert-DateTimeText($Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return "-" }
  try { return ([DateTime]::Parse($Value)).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") } catch { return "-" }
}

function Resolve-AppFilePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
  if ([IO.Path]::IsPathRooted($Path)) { return $Path }
  return (Join-Path $Script:AppRoot $Path)
}

function Resolve-ExistingAppFile([string]$Path) {
  $resolved = Resolve-AppFilePath $Path
  if ([string]::IsNullOrWhiteSpace($resolved)) { return "" }
  if (Test-Path -LiteralPath $resolved -PathType Leaf) { return ([Uri]$resolved).AbsoluteUri }
  return ""
}

function Get-Summary($Db) {
  $apps = @($Db.apps)
  $alerts = @($Db.alerts | Where-Object { -not $_.resolvedAt })
  $reviewCount = @($apps | Where-Object { (Normalize-Status ([string]$_.status)) -eq "IN_REVIEW" }).Count
  $extraReviewCount = 0
  foreach ($app in @($apps)) {
    foreach ($review in @(Get-ListItems (Get-ObjectValue $app "extraReviews"))) {
      if ($null -ne $review -and (Normalize-Status ([string](Get-ObjectValue $review "status"))) -eq "IN_REVIEW") {
        $extraReviewCount++
      }
    }
  }
  return [ordered]@{
    accounts = @($Db.accounts).Count
    connected = @($Db.accounts | Where-Object { $_.status -eq "connected" }).Count
    apps = $apps.Count
    inReview = $reviewCount
    extraInReview = $extraReviewCount
    rejected = @($apps | Where-Object { @("REJECTED", "METADATA_REJECTED") -contains $_.status }).Count
    alerts = $alerts.Count
  }
}

function ConvertTo-StatusHistoryRows($History, [string]$FallbackName = "状态") {
  $rows = New-Object "System.Collections.ObjectModel.ObservableCollection[object]"
  foreach ($entry in @((Get-ListItems $History) | Where-Object { $null -ne $_ } | Sort-Object detectedAt -Descending)) {
    $status = Normalize-Status ([string](Get-ObjectValue $entry "status"))
    if ([string]::IsNullOrWhiteSpace($status) -or @("NO_VERSION", "UNKNOWN") -contains $status) { continue }
    $name = [string](Get-ObjectValue $entry "name")
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $FallbackName }
    $name = Get-DisplayReviewName $name
    $previousStatus = Normalize-Status ([string](Get-ObjectValue $entry "previousStatus"))
    $isInitial = [bool](Get-ObjectValue $entry "initial")
    $changeText = if ($isInitial -or [string]::IsNullOrWhiteSpace($previousStatus) -or $previousStatus -eq "NO_VERSION") {
      "变成" + (Get-StatusLabel $status)
    } else {
      "$(Get-StatusLabel $previousStatus) -> $(Get-StatusLabel $status)"
    }
    $detectedAt = [string](Get-ObjectValue $entry "detectedAt")
    $rows.Add([pscustomobject][ordered]@{
      title = $name
      status = $status
      statusLabel = Get-StatusLabel $status
      statusBrush = Get-StatusBrush $status
      statusBackground = Get-StatusBackground $status
      detectedAt = $detectedAt
      timeText = "状态时间：" + (Convert-DateTimeText $detectedAt)
      changeText = $changeText
    })
  }
  Write-Output -NoEnumerate $rows
}

function Get-AppById([string]$AppId) {
  if ([string]::IsNullOrWhiteSpace($AppId)) { return $null }
  if ($null -eq $Script:State) { $Script:State = Read-Db }
  return ($Script:State.apps | Where-Object { $_.id -eq $AppId } | Select-Object -First 1)
}

function Get-ExtraReviewHistoryRows($App) {
  $allRows = New-Object "System.Collections.ObjectModel.ObservableCollection[object]"
  foreach ($review in @(Get-ListItems (Get-ObjectValue $App "extraReviews"))) {
    if ($null -eq $review) { continue }
    $status = Normalize-Status ([string](Get-ObjectValue $review "status"))
    if ([string]::IsNullOrWhiteSpace($status) -or @("NO_VERSION", "UNKNOWN") -contains $status) { continue }
    $name = if (![string]::IsNullOrWhiteSpace([string](Get-ObjectValue $review "typeLabel"))) { [string](Get-ObjectValue $review "typeLabel") } else { "产品页面优化" }
    $name = Get-DisplayReviewName $name
    $reviewName = [string](Get-ObjectValue $review "name")
    $reviewName = Get-DisplayReviewName $reviewName
    if (![string]::IsNullOrWhiteSpace($reviewName) -and $reviewName -ne $name) {
      $name = "$name - $reviewName"
    }
    $rows = ConvertTo-StatusHistoryRows (Get-ObjectValue $review "statusHistory") $name
    if ($rows.Count -eq 0) {
      $detectedAt = if (![string]::IsNullOrWhiteSpace([string](Get-ObjectValue $review "statusChangedAt"))) { [string](Get-ObjectValue $review "statusChangedAt") } else { [string](Get-ObjectValue $review "statusCheckedAt") }
      $allRows.Add([pscustomobject][ordered]@{
        title = $name
        status = $status
        statusLabel = Get-StatusLabel $status
        statusBrush = Get-StatusBrush $status
        statusBackground = Get-StatusBackground $status
        detectedAt = $detectedAt
        timeText = "状态时间：" + (Convert-DateTimeText $detectedAt)
        changeText = "变成" + (Get-StatusLabel $status)
      }) | Out-Null
    } else {
      foreach ($row in @($rows)) { $allRows.Add($row) | Out-Null }
    }
  }

  Write-Output -NoEnumerate $allRows
}

function Show-AppDetail([string]$AppId) {
  $Script:State = Read-Db
  $app = Get-AppById $AppId
  if ($null -eq $app) {
    [Windows.MessageBox]::Show("这个 App 已不存在或还没有同步到本地。", "提示", "OK", "Information") | Out-Null
    return
  }

  $status = Normalize-Status $app.status
  $DetailAppName.Text = if (![string]::IsNullOrWhiteSpace($app.name)) { [string]$app.name } else { "未命名 App" }
  $DetailBundleId.Text = if (![string]::IsNullOrWhiteSpace($app.bundleId)) { [string]$app.bundleId } else { "-" }
  $DetailAccountName.Text = if (![string]::IsNullOrWhiteSpace($app.accountName)) { [string]$app.accountName } else { "-" }
  $DetailVersion.Text = if (![string]::IsNullOrWhiteSpace($app.version)) { [string]$app.version } else { "-" }
  $DetailBuild.Text = if (![string]::IsNullOrWhiteSpace($app.build)) { [string]$app.build } else { "-" }
  $DetailMainStatusText.Text = Get-StatusLabel $status
  $DetailMainStatusText.Foreground = Get-StatusBrush $status
  $DetailMainStatusPill.Background = Get-StatusBackground $status
  $DetailMainChangedAt.Text = "状态时间：" + (Convert-DateTimeText $app.statusChangedAt)

  $iconPath = Resolve-ExistingAppFile $app.iconPath
  if (![string]::IsNullOrWhiteSpace($iconPath)) {
    $DetailAppIcon.Source = $iconPath
    $DetailAppIcon.Visibility = "Visible"
    $DetailAppInitial.Visibility = "Collapsed"
  } else {
    $DetailAppIcon.Source = $null
    $DetailAppIcon.Visibility = "Collapsed"
    $DetailAppInitial.Visibility = "Visible"
    $DetailAppInitial.Text = if (![string]::IsNullOrWhiteSpace($app.name)) { $app.name.Substring(0, 1).ToUpperInvariant() } else { "A" }
  }

  $mainRows = ConvertTo-StatusHistoryRows $app.statusHistory "版本"
  if ($mainRows.Count -eq 0) {
    $mainRows.Add([pscustomobject][ordered]@{
      title = "版本"
      status = $status
      statusLabel = Get-StatusLabel $status
      statusBrush = Get-StatusBrush $status
      statusBackground = Get-StatusBackground $status
      detectedAt = [string]$app.statusChangedAt
      timeText = "状态时间：" + (Convert-DateTimeText $app.statusChangedAt)
      changeText = "变成" + (Get-StatusLabel $status)
    }) | Out-Null
  }
  $MainStatusHistoryList.ItemsSource = $mainRows
  $ExtraStatusHistoryList.ItemsSource = Get-ExtraReviewHistoryRows $app

  Show-View "appDetail"
}

function ConvertTo-ViewRows($Items, [string]$Kind) {
  $rows = New-Object "System.Collections.ObjectModel.ObservableCollection[object]"
  foreach ($item in @($Items)) {
    $row = [ordered]@{}
    foreach ($prop in $item.Keys) { $row[$prop] = $item[$prop] }
    if ($Kind -eq "account") {
      $row.statusText = switch ($item.status) { "connected" { "已连接" } "error" { "异常" } default { "未测试" } }
      $row.lastSyncText = Convert-DateText $item.lastSyncAt
      $row.noteDisplay = if (![string]::IsNullOrWhiteSpace($item.notes)) { $item.notes } else { "未备注账号" }
      $row.accountStatusBrush = switch ($item.status) { "connected" { "#187653" } "error" { "#BD2838" } default { "#607082" } }
      $row.accountStatusBackground = switch ($item.status) { "connected" { "#DCF4E9" } "error" { "#FFF0F2" } default { "#EDF2F7" } }
    }
    if ($Kind -eq "app") {
      $row.status = Normalize-Status $item.status
      $row.statusLabel = Get-StatusLabel $row.status
      $row.statusBrush = Get-StatusBrush $row.status
      $row.statusBackground = Get-StatusBackground $row.status
      $row.updatedText = Convert-DateText $item.updatedAt
      $row.iconUrl = if (![string]::IsNullOrWhiteSpace($item.iconUrl)) { [string]$item.iconUrl } else { "" }
      $row.iconPath = Resolve-ExistingAppFile $item.iconPath
      $row.appIconVisibility = if (![string]::IsNullOrWhiteSpace($row.iconPath)) { "Visible" } else { "Collapsed" }
      $row.appInitialVisibility = if (![string]::IsNullOrWhiteSpace($row.iconPath)) { "Collapsed" } else { "Visible" }
      $row.appInitial = if (![string]::IsNullOrWhiteSpace($item.name)) { $item.name.Substring(0, 1).ToUpperInvariant() } else { "A" }
      $row.versionDisplay = if (![string]::IsNullOrWhiteSpace($item.version)) { $item.version } else { "-" }
      $row.buildDisplay = if (![string]::IsNullOrWhiteSpace($item.build)) { $item.build } else { "-" }
      $row.accountDisplay = if (![string]::IsNullOrWhiteSpace($item.accountName)) { $item.accountName } else { "-" }
      $extraReviewRows = ConvertTo-ExtraReviewRows $item.extraReviews
      $row.extraReviews = $extraReviewRows
      $row.extraReviewSummary = Get-ExtraReviewSummaryText $item.extraReviews
      $row.extraReviewsVisibility = if ($extraReviewRows.Count -gt 0) { "Visible" } else { "Collapsed" }
      if ($extraReviewRows.Count -gt 0) {
        $firstExtraReview = $extraReviewRows[0]
        if ($extraReviewRows.Count -eq 1) {
          $row.extraReviewDisplay = $firstExtraReview.display
          $row.extraReviewStatusLabel = $firstExtraReview.statusLabel
          $row.extraReviewStatusBrush = $firstExtraReview.statusBrush
          $row.extraReviewStatusBackground = $firstExtraReview.statusBackground
        } else {
          $row.extraReviewDisplay = "产品页面优化 $($extraReviewRows.Count) 项"
          $row.extraReviewStatusLabel = $firstExtraReview.statusLabel
          $row.extraReviewStatusBrush = $firstExtraReview.statusBrush
          $row.extraReviewStatusBackground = $firstExtraReview.statusBackground
        }
      } else {
        $row.extraReviewDisplay = ""
        $row.extraReviewStatusLabel = ""
        $row.extraReviewStatusBrush = "#56616A"
        $row.extraReviewStatusBackground = "#EDF0F2"
      }
    }
    if ($Kind -eq "alert") {
      $row.createdText = Convert-DateText $item.createdAt
    }
    $rows.Add([pscustomobject]$row)
  }
  return ,$rows
}

function Refresh-Ui {
  $nextState = Read-Db
  Update-SettingsCacheFromDb $nextState
  $nextSnapshot = Get-AppStatusSnapshot $nextState
  $snapshotChanges = @()
  if ($null -ne $Script:LastStatusSnapshot) {
    $snapshotChanges = Get-SnapshotStatusChanges $Script:LastStatusSnapshot $nextSnapshot
  }

  $Script:State = $nextState
  $Script:LastStatusSnapshot = $nextSnapshot
  if (@($snapshotChanges).Count -gt 0) {
    try { Notify-AppStatusChanges $snapshotChanges } catch {}
  }

  $summary = Get-Summary $Script:State
  $MetricAccounts.Text = [string]$summary.accounts
  $MetricConnected.Text = "$($summary.connected) 个已连接"
  $MetricApps.Text = [string]$summary.apps
  $MetricReview.Text = [string]$summary.inReview
  if ($null -ne $MetricExtraReview) { $MetricExtraReview.Text = [string]$summary.extraInReview }
  $MetricAlerts.Text = [string]$summary.alerts
  $MetricRejected.Text = "$($summary.rejected) 个被拒"

  $AccountsGrid.ItemsSource = ConvertTo-ViewRows $Script:State.accounts "account"
  $currentAccountId = ""
  if ($AccountFilter.SelectedItem -and $Script:AccountFilterMap.ContainsKey([string]$AccountFilter.SelectedItem)) {
    $currentAccountId = [string]$Script:AccountFilterMap[[string]$AccountFilter.SelectedItem]
  }
  $AccountFilter.Items.Clear()
  $Script:AccountFilterMap = @{}
  [void]$AccountFilter.Items.Add("全部账号")
  $Script:AccountFilterMap["全部账号"] = ""
  foreach ($account in @($Script:State.accounts)) {
    $count = @($Script:State.apps | Where-Object { $_.accountId -eq $account.id }).Count
    $label = if (![string]::IsNullOrWhiteSpace($account.notes)) {
      "$($account.notes) - $($account.name)"
    } else {
      $account.name
    }
    $display = "$label  ($count)"
    [void]$AccountFilter.Items.Add($display)
    $Script:AccountFilterMap[$display] = $account.id
  }
  $accountRestored = $false
  foreach ($item in @($AccountFilter.Items)) {
    if ($Script:AccountFilterMap.ContainsKey([string]$item) -and [string]$Script:AccountFilterMap[[string]$item] -eq $currentAccountId) {
      $AccountFilter.SelectedItem = $item
      $accountRestored = $true
      break
    }
  }
  if (-not $accountRestored) { $AccountFilter.SelectedIndex = 0 }
  Refresh-AppsGrid
  $activeAlerts = @($Script:State.alerts | Where-Object { -not $_.resolvedAt })
  $AlertsGrid.ItemsSource = ConvertTo-ViewRows $activeAlerts "alert"
  $DashboardAlertsList.ItemsSource = ConvertTo-ViewRows (@($activeAlerts | Select-Object -First 5)) "alert"
  $RecentAppsGrid.ItemsSource = ConvertTo-ViewRows (@($Script:State.apps | Sort-Object updatedAt -Descending | Select-Object -First 8)) "app"

  $current = $StatusFilter.SelectedItem
  $StatusFilter.Items.Clear()
  $Script:StatusFilterMap = @{}
  [void]$StatusFilter.Items.Add("全部状态")
  $Script:StatusFilterMap["全部状态"] = ""
  foreach ($status in @($Script:State.apps | ForEach-Object { $_.status } | Sort-Object -Unique)) {
    $display = Get-StatusLabel (Normalize-Status $status)
    if ($StatusFilter.Items -notcontains $display) {
      [void]$StatusFilter.Items.Add($display)
      $Script:StatusFilterMap[$display] = $status
    }
  }
  if ($current -and $StatusFilter.Items.Contains($current)) { $StatusFilter.SelectedItem = $current } else { $StatusFilter.SelectedIndex = 0 }
}

function Refresh-AppsGrid {
  if ($null -eq $Script:State) { return }
  $accountId = ""
  $accountName = "全部账号"
  if ($AccountFilter.SelectedItem -and $Script:AccountFilterMap.ContainsKey([string]$AccountFilter.SelectedItem)) {
    $accountId = [string]$Script:AccountFilterMap[[string]$AccountFilter.SelectedItem]
    $accountName = [string]$AccountFilter.SelectedItem
  }
  $status = ""
  if ($StatusFilter.SelectedItem -and $Script:StatusFilterMap.ContainsKey([string]$StatusFilter.SelectedItem)) {
    $status = [string]$Script:StatusFilterMap[[string]$StatusFilter.SelectedItem]
  }
  $items = @($Script:State.apps | Where-Object {
    $okAccount = ([string]::IsNullOrWhiteSpace($accountId) -or $_.accountId -eq $accountId)
    $okStatus = ([string]::IsNullOrWhiteSpace($status) -or $status -eq "全部状态" -or $_.status -eq $status)
    $okAccount -and $okStatus
  })
  $AppsGrid.ItemsSource = ConvertTo-ViewRows $items "app"
  if ([string]::IsNullOrWhiteSpace($accountId)) {
    $AppScopeText.Text = "当前显示全部账号，共 $(@($items).Count) 个 App。"
  } else {
    $AppScopeText.Text = "当前账号：$accountName，共 $(@($items).Count) 个 App。"
  }
}

function Select-AppAccount([string]$AccountId) {
  foreach ($item in @($AccountFilter.Items)) {
    if ($Script:AccountFilterMap.ContainsKey([string]$item) -and [string]$Script:AccountFilterMap[[string]$item] -eq $AccountId) {
      $AccountFilter.SelectedItem = $item
      break
    }
  }
  Refresh-AppsGrid
}

function Remove-Account([string]$AccountId) {
  Invoke-DbLocked {
    $db = Read-Db
    $account = $db.accounts | Where-Object { $_.id -eq $AccountId } | Select-Object -First 1
    if (!$account) { throw "账号不存在" }
    $db.accounts = @($db.accounts | Where-Object { $_.id -ne $AccountId })
    $db.apps = @($db.apps | Where-Object { $_.accountId -ne $AccountId })
    $db.alerts = @($db.alerts | Where-Object { $_.accountId -ne $AccountId })
    $db.syncLogs += [ordered]@{
      id = New-Id "log"
      level = "info"
      accountId = $AccountId
      message = "已删除账号 $($account.name)"
      createdAt = Get-NowIso
    }
    Write-Db $db
  }
}

function Update-Account(
  [string]$AccountId,
  [string]$Name,
  [string]$IssuerId,
  [string]$KeyId,
  [string]$Notes,
  [string]$PrivateKey,
  [bool]$HasPrivateKeyUpdate
) {
  Invoke-DbLocked {
    $db = Read-Db
    $account = $db.accounts | Where-Object { $_.id -eq $AccountId } | Select-Object -First 1
    if (!$account) { throw "账号不存在" }

    $oldName = [string]$account.name
    $authChanged = ([string]$account.issuerId -ne $IssuerId) -or ([string]$account.keyId -ne $KeyId) -or $HasPrivateKeyUpdate

    $account.name = $Name
    $account.issuerId = $IssuerId
    $account.keyId = $KeyId
    $account.notes = $Notes
    if ($HasPrivateKeyUpdate) {
      $account.privateKeyEnc = Protect-Text $PrivateKey
    }
    if ($authChanged) {
      $account.status = "unchecked"
      $account.lastError = ""
    }
    $account.updatedAt = Get-NowIso

    foreach ($app in @($db.apps | Where-Object { $_.accountId -eq $AccountId })) {
      $app.accountName = $Name
    }
    foreach ($alert in @($db.alerts | Where-Object { $_.accountId -eq $AccountId })) {
      $alert.accountName = $Name
      if (![string]::IsNullOrWhiteSpace($alert.message) -and ![string]::IsNullOrWhiteSpace($oldName)) {
        $alert.message = ([string]$alert.message).Replace($oldName, $Name)
      }
    }
    $db.syncLogs += [ordered]@{
      id = New-Id "log"
      level = "info"
      accountId = $AccountId
      message = "已更新账号 $Name"
      createdAt = Get-NowIso
    }
    Write-Db $db
  }
}

function Show-View([string]$Name) {
  $views = @($DashboardView, $AccountsView, $AppsView, $AppDetailView, $AlertsView, $SettingsView)
  foreach ($view in $views) { $view.Visibility = "Collapsed" }
  $buttons = @($NavDashboard, $NavAccounts, $NavApps, $NavAlerts, $NavSettings)
  foreach ($button in $buttons) {
    $button.Background = [Windows.Media.Brushes]::Transparent
    $button.Foreground = "#6A7889"
  }
  switch ($Name) {
    "dashboard" { $DashboardView.Visibility = "Visible"; $NavDashboard.Background = "#E8F3FF"; $NavDashboard.Foreground = "#152234" }
    "accounts" { $AccountsView.Visibility = "Visible"; $NavAccounts.Background = "#E8F3FF"; $NavAccounts.Foreground = "#152234" }
    "apps" { $AppsView.Visibility = "Visible"; $NavApps.Background = "#E8F3FF"; $NavApps.Foreground = "#152234" }
    "appDetail" { $AppDetailView.Visibility = "Visible"; $NavApps.Background = "#E8F3FF"; $NavApps.Foreground = "#152234" }
    "alerts" { $AlertsView.Visibility = "Visible"; $NavAlerts.Background = "#E8F3FF"; $NavAlerts.Foreground = "#152234" }
    "settings" { $SettingsView.Visibility = "Visible"; $NavSettings.Background = "#E8F3FF"; $NavSettings.Foreground = "#152234"; Update-SettingsUi }
  }
}

function Select-AccountRow([string]$AccountId) {
  foreach ($item in @($AccountsGrid.Items)) {
    if ([string]$item.id -eq $AccountId) {
      $AccountsGrid.SelectedItem = $item
      $AccountsGrid.ScrollIntoView($item)
      break
    }
  }
}

function Show-AddAccountDialog {
  $dialog = New-Object Windows.Window
  $dialog.Title = "连接 App Store Connect"
  $dialog.Width = 760
  $dialog.Height = 640
  $dialog.WindowStartupLocation = "CenterOwner"
  $dialog.Owner = $Window
  $dialog.Background = "#F8FAFD"
  $dialog.ResizeMode = "NoResize"

  $root = New-Object Windows.Controls.DockPanel
  $root.Margin = "28"
  $root.LastChildFill = $true

  $buttonHost = New-Object Windows.Controls.Border
  $buttonHost.Padding = "0,16,0,0"
  $buttonHost.Background = "#F8FAFD"
  [Windows.Controls.DockPanel]::SetDock($buttonHost, "Bottom")
  $root.Children.Add($buttonHost) | Out-Null

  $scroll = New-Object Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = "Auto"
  $scroll.HorizontalScrollBarVisibility = "Disabled"
  $root.Children.Add($scroll) | Out-Null

  $grid = New-Object Windows.Controls.Grid
  $grid.Margin = "0"
  for ($i = 0; $i -lt 5; $i++) {
    $row = New-Object Windows.Controls.RowDefinition
    $row.Height = "Auto"
    $grid.RowDefinitions.Add($row)
  }
  $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
  $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
  $scroll.Content = $grid

  $titlePanel = New-Object Windows.Controls.StackPanel
  $titlePanel.Margin = "0,0,0,20"
  [Windows.Controls.Grid]::SetRow($titlePanel, 0)
  [Windows.Controls.Grid]::SetColumnSpan($titlePanel, 2)
  $title = New-Object Windows.Controls.TextBlock
  $title.Text = "添加账号资料"
  $title.FontSize = 24
  $title.FontWeight = "Black"
  $title.Foreground = "#101928"
  $subTitle = New-Object Windows.Controls.TextBlock
  $subTitle.Text = "填写 App Store Connect API Key 信息，保存后可立即同步账号下的 App。"
  $subTitle.FontSize = 13
  $subTitle.Foreground = "#7A8796"
  $subTitle.Margin = "0,6,0,0"
  $titlePanel.Children.Add($title) | Out-Null
  $titlePanel.Children.Add($subTitle) | Out-Null
  $grid.Children.Add($titlePanel) | Out-Null

  function Add-LabelBox($Text, $Row, $Column, $Name) {
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = "0,0,18,18"
    [Windows.Controls.Grid]::SetRow($panel, $Row)
    [Windows.Controls.Grid]::SetColumn($panel, $Column)
    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontWeight = "Bold"
    $label.Foreground = "#4C5861"
    $label.Margin = "0,0,0,6"
    $box = New-Object Windows.Controls.TextBox
    $box.Name = $Name
    $box.Height = 42
    $box.FontSize = 14
    $box.Padding = "12,8"
    $box.Background = "#FFFFFF"
    $box.BorderBrush = "#DDE4EC"
    $box.BorderThickness = 1
    $panel.Children.Add($label) | Out-Null
    $panel.Children.Add($box) | Out-Null
    $grid.Children.Add($panel) | Out-Null
    return $box
  }

  $nameBox = Add-LabelBox "账号名称" 1 0 "NameBox"
  [Windows.Controls.Grid]::SetColumnSpan(($nameBox.Parent), 2)
  $issuerBox = Add-LabelBox "Issuer ID" 2 0 "IssuerBox"
  $keyIdBox = Add-LabelBox "Key ID" 2 1 "KeyIdBox"
  $notesBox = Add-LabelBox "备注" 3 0 "NotesBox"
  [Windows.Controls.Grid]::SetColumnSpan(($notesBox.Parent), 2)

  $keyPanel = New-Object Windows.Controls.StackPanel
  $keyPanel.Margin = "0,4,0,18"
  [Windows.Controls.Grid]::SetRow($keyPanel, 4)
  [Windows.Controls.Grid]::SetColumnSpan($keyPanel, 2)
  $keyHeader = New-Object Windows.Controls.DockPanel
  $keyLabel = New-Object Windows.Controls.TextBlock
  $keyLabel.Text = ".p8 私钥内容"
  $keyLabel.FontWeight = "Bold"
  $keyLabel.Foreground = "#4C5861"
  $pickBtn = New-Object Windows.Controls.Button
  $pickBtn.Content = "选择 .p8 文件"
  $pickBtn.Background = "#FFFFFF"
  $pickBtn.Foreground = "#516173"
  $pickBtn.BorderBrush = "#E1E7EF"
  $pickBtn.BorderThickness = 1
  $pickBtn.Padding = "16,8"
  [Windows.Controls.DockPanel]::SetDock($pickBtn, "Right")
  $keyHeader.Children.Add($pickBtn) | Out-Null
  $keyHeader.Children.Add($keyLabel) | Out-Null
  $privateBox = New-Object Windows.Controls.TextBox
  $privateBox.AcceptsReturn = $true
  $privateBox.TextWrapping = "NoWrap"
  $privateBox.VerticalScrollBarVisibility = "Auto"
  $privateBox.Height = 92
  $privateBox.FontFamily = "Consolas"
  $privateBox.FontSize = 13
  $privateBox.Padding = "12,10"
  $privateBox.Background = "#FFFFFF"
  $privateBox.BorderBrush = "#DDE4EC"
  $privateBox.BorderThickness = 1
  $hint = New-Object Windows.Controls.TextBlock
  $hint.Text = "可以选择 .p8 文件，也可以直接粘贴私钥内容。"
  $hint.Foreground = "#8A97A8"
  $hint.FontSize = 12
  $hint.Margin = "0,6,0,0"
  $keyPanel.Children.Add($keyHeader) | Out-Null
  $keyPanel.Children.Add($privateBox) | Out-Null
  $keyPanel.Children.Add($hint) | Out-Null
  $grid.Children.Add($keyPanel) | Out-Null

  $buttons = New-Object Windows.Controls.StackPanel
  $buttons.Orientation = "Horizontal"
  $buttons.HorizontalAlignment = "Right"
  $buttons.Margin = "0"
  $cancelBtn = New-Object Windows.Controls.Button
  $cancelBtn.Content = "取消"
  $cancelBtn.Background = "#FFFFFF"
  $cancelBtn.Foreground = "#516173"
  $cancelBtn.BorderBrush = "#E1E7EF"
  $cancelBtn.BorderThickness = 1
  $cancelBtn.Padding = "20,10"
  $cancelBtn.Margin = "0,0,10,0"
  $saveBtn = New-Object Windows.Controls.Button
  $saveBtn.Content = "保存连接"
  $saveBtn.Background = "#0A84FF"
  $saveBtn.Foreground = "White"
  $saveBtn.BorderThickness = 0
  $saveBtn.Padding = "22,10"
  $buttons.Children.Add($cancelBtn) | Out-Null
  $buttons.Children.Add($saveBtn) | Out-Null
  $buttonHost.Child = $buttons

  $pickBtn.Add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Filter = "Private Key (*.p8)|*.p8|Text (*.txt)|*.txt|All files (*.*)|*.*"
    if ($ofd.ShowDialog($dialog)) {
      $privateBox.Text = Get-Content -LiteralPath $ofd.FileName -Raw
    }
  })
  $cancelBtn.Add_Click({ $dialog.DialogResult = $false })
  $saveBtn.Add_Click({
    if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
      [Windows.MessageBox]::Show("请填写账号名称。", "提示", "OK", "Information") | Out-Null
      return
    }
    try {
      $accountId = Invoke-DbLocked {
        $db = Read-Db
        $account = [ordered]@{
          id = New-Id "acct"
          name = $nameBox.Text.Trim()
          teamName = ""
          teamId = ""
          issuerId = $issuerBox.Text.Trim()
          keyId = $keyIdBox.Text.Trim()
          privateKeyEnc = Protect-Text $privateBox.Text.Trim()
          owner = ""
          notes = $notesBox.Text.Trim()
          status = "unchecked"
          lastError = ""
          lastSyncAt = $null
          createdAt = Get-NowIso
          updatedAt = Get-NowIso
        }
        $db.accounts += $account
        $db.syncLogs += [ordered]@{ id = New-Id "log"; level = "info"; accountId = $account.id; message = "已添加账号 $($account.name)"; createdAt = Get-NowIso }
        Write-Db $db
        return $account.id
      }
      $dialog.Tag = [string]$accountId
      $dialog.DialogResult = $true
    } catch {
      [Windows.MessageBox]::Show($_.Exception.Message, "保存失败", "OK", "Warning") | Out-Null
    }
  })

  $dialog.Content = $root
  if ($dialog.ShowDialog()) {
    Refresh-Ui
    $answer = [Windows.MessageBox]::Show("账号已保存。是否现在同步这个账号下的 App？", "同步 App", "YesNo", "Question")
    if ($answer -eq "Yes") {
      Start-ManualSync "selected" ([string]$dialog.Tag)
    }
  }
}

function Show-EditAccountDialog($SelectedAccount) {
  if ($null -eq $SelectedAccount) {
    [Windows.MessageBox]::Show("请先在账号列表里选中一个账号。", "提示", "OK", "Information") | Out-Null
    return
  }

  $db = Read-Db
  $account = $db.accounts | Where-Object { $_.id -eq $SelectedAccount.id } | Select-Object -First 1
  if (!$account) {
    [Windows.MessageBox]::Show("账号不存在，可能已经被删除。", "提示", "OK", "Warning") | Out-Null
    Refresh-Ui
    return
  }

  $dialog = New-Object Windows.Window
  $dialog.Title = "编辑账号"
  $dialog.Width = 760
  $dialog.Height = 640
  $dialog.WindowStartupLocation = "CenterOwner"
  $dialog.Owner = $Window
  $dialog.Background = "#F8FAFD"
  $dialog.ResizeMode = "NoResize"

  $root = New-Object Windows.Controls.DockPanel
  $root.Margin = "28"
  $root.LastChildFill = $true

  $buttonHost = New-Object Windows.Controls.Border
  $buttonHost.Padding = "0,16,0,0"
  $buttonHost.Background = "#F8FAFD"
  [Windows.Controls.DockPanel]::SetDock($buttonHost, "Bottom")
  $root.Children.Add($buttonHost) | Out-Null

  $scroll = New-Object Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = "Auto"
  $scroll.HorizontalScrollBarVisibility = "Disabled"
  $root.Children.Add($scroll) | Out-Null

  $grid = New-Object Windows.Controls.Grid
  $grid.Margin = "0"
  for ($i = 0; $i -lt 5; $i++) {
    $row = New-Object Windows.Controls.RowDefinition
    $row.Height = "Auto"
    $grid.RowDefinitions.Add($row)
  }
  $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
  $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
  $scroll.Content = $grid

  $titlePanel = New-Object Windows.Controls.StackPanel
  $titlePanel.Margin = "0,0,0,20"
  [Windows.Controls.Grid]::SetRow($titlePanel, 0)
  [Windows.Controls.Grid]::SetColumnSpan($titlePanel, 2)
  $title = New-Object Windows.Controls.TextBlock
  $title.Text = "编辑账号资料"
  $title.FontSize = 24
  $title.FontWeight = "Black"
  $title.Foreground = "#101928"
  $subTitle = New-Object Windows.Controls.TextBlock
  $subTitle.Text = "可以补充备注或修正账号信息；私钥留空则保持原来的 .p8。"
  $subTitle.FontSize = 13
  $subTitle.Foreground = "#7A8796"
  $subTitle.Margin = "0,6,0,0"
  $titlePanel.Children.Add($title) | Out-Null
  $titlePanel.Children.Add($subTitle) | Out-Null
  $grid.Children.Add($titlePanel) | Out-Null

  function Add-EditLabelBox($Text, $Row, $Column, $Name, $Value) {
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = "0,0,18,18"
    [Windows.Controls.Grid]::SetRow($panel, $Row)
    [Windows.Controls.Grid]::SetColumn($panel, $Column)
    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontWeight = "Bold"
    $label.Foreground = "#4C5861"
    $label.Margin = "0,0,0,6"
    $box = New-Object Windows.Controls.TextBox
    $box.Name = $Name
    $box.Text = [string]$Value
    $box.Height = 42
    $box.FontSize = 14
    $box.Padding = "12,8"
    $box.Background = "#FFFFFF"
    $box.BorderBrush = "#DDE4EC"
    $box.BorderThickness = 1
    $panel.Children.Add($label) | Out-Null
    $panel.Children.Add($box) | Out-Null
    $grid.Children.Add($panel) | Out-Null
    return $box
  }

  $nameBox = Add-EditLabelBox "账号名称" 1 0 "EditNameBox" $account.name
  [Windows.Controls.Grid]::SetColumnSpan(($nameBox.Parent), 2)
  $issuerBox = Add-EditLabelBox "Issuer ID" 2 0 "EditIssuerBox" $account.issuerId
  $keyIdBox = Add-EditLabelBox "Key ID" 2 1 "EditKeyIdBox" $account.keyId
  $notesBox = Add-EditLabelBox "备注" 3 0 "EditNotesBox" $account.notes
  [Windows.Controls.Grid]::SetColumnSpan(($notesBox.Parent), 2)

  $keyPanel = New-Object Windows.Controls.StackPanel
  $keyPanel.Margin = "0,4,0,18"
  [Windows.Controls.Grid]::SetRow($keyPanel, 4)
  [Windows.Controls.Grid]::SetColumnSpan($keyPanel, 2)
  $keyHeader = New-Object Windows.Controls.DockPanel
  $keyLabel = New-Object Windows.Controls.TextBlock
  $keyLabel.Text = "更换 .p8 私钥"
  $keyLabel.FontWeight = "Bold"
  $keyLabel.Foreground = "#4C5861"
  $pickBtn = New-Object Windows.Controls.Button
  $pickBtn.Content = "选择 .p8 文件"
  $pickBtn.Background = "#FFFFFF"
  $pickBtn.Foreground = "#516173"
  $pickBtn.BorderBrush = "#E1E7EF"
  $pickBtn.BorderThickness = 1
  $pickBtn.Padding = "16,8"
  [Windows.Controls.DockPanel]::SetDock($pickBtn, "Right")
  $keyHeader.Children.Add($pickBtn) | Out-Null
  $keyHeader.Children.Add($keyLabel) | Out-Null
  $privateBox = New-Object Windows.Controls.TextBox
  $privateBox.AcceptsReturn = $true
  $privateBox.TextWrapping = "NoWrap"
  $privateBox.VerticalScrollBarVisibility = "Auto"
  $privateBox.Height = 92
  $privateBox.FontFamily = "Consolas"
  $privateBox.FontSize = 13
  $privateBox.Padding = "12,10"
  $privateBox.Background = "#FFFFFF"
  $privateBox.BorderBrush = "#DDE4EC"
  $privateBox.BorderThickness = 1
  $hint = New-Object Windows.Controls.TextBlock
  $hint.Text = "留空代表继续使用当前私钥。只有在粘贴或选择新 .p8 后，私钥才会被替换。"
  $hint.Foreground = "#8A97A8"
  $hint.FontSize = 12
  $hint.Margin = "0,6,0,0"
  $keyPanel.Children.Add($keyHeader) | Out-Null
  $keyPanel.Children.Add($privateBox) | Out-Null
  $keyPanel.Children.Add($hint) | Out-Null
  $grid.Children.Add($keyPanel) | Out-Null

  $buttons = New-Object Windows.Controls.StackPanel
  $buttons.Orientation = "Horizontal"
  $buttons.HorizontalAlignment = "Right"
  $buttons.Margin = "0"
  $cancelBtn = New-Object Windows.Controls.Button
  $cancelBtn.Content = "取消"
  $cancelBtn.Background = "#FFFFFF"
  $cancelBtn.Foreground = "#516173"
  $cancelBtn.BorderBrush = "#E1E7EF"
  $cancelBtn.BorderThickness = 1
  $cancelBtn.Padding = "20,10"
  $cancelBtn.Margin = "0,0,10,0"
  $saveBtn = New-Object Windows.Controls.Button
  $saveBtn.Content = "保存修改"
  $saveBtn.Background = "#0A84FF"
  $saveBtn.Foreground = "White"
  $saveBtn.BorderThickness = 0
  $saveBtn.Padding = "22,10"
  $buttons.Children.Add($cancelBtn) | Out-Null
  $buttons.Children.Add($saveBtn) | Out-Null
  $buttonHost.Child = $buttons

  $pickBtn.Add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Filter = "Private Key (*.p8)|*.p8|Text (*.txt)|*.txt|All files (*.*)|*.*"
    if ($ofd.ShowDialog($dialog)) {
      $privateBox.Text = Get-Content -LiteralPath $ofd.FileName -Raw
    }
  })
  $cancelBtn.Add_Click({ $dialog.DialogResult = $false })
  $saveBtn.Add_Click({
    if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
      [Windows.MessageBox]::Show("请填写账号名称。", "提示", "OK", "Information") | Out-Null
      return
    }
    try {
      $hasPrivateKeyUpdate = ![string]::IsNullOrWhiteSpace($privateBox.Text)
      Update-Account `
        -AccountId ([string]$account.id) `
        -Name $nameBox.Text.Trim() `
        -IssuerId $issuerBox.Text.Trim() `
        -KeyId $keyIdBox.Text.Trim() `
        -Notes $notesBox.Text.Trim() `
        -PrivateKey $privateBox.Text.Trim() `
        -HasPrivateKeyUpdate $hasPrivateKeyUpdate
      $dialog.Tag = [string]$account.id
      $dialog.DialogResult = $true
    } catch {
      [Windows.MessageBox]::Show($_.Exception.Message, "保存失败", "OK", "Warning") | Out-Null
    }
  })

  $dialog.Content = $root
  if ($dialog.ShowDialog()) {
    Refresh-Ui
    Show-View "accounts"
    Select-AccountRow ([string]$dialog.Tag)
    [Windows.MessageBox]::Show("账号资料已更新。", "完成", "OK", "Information") | Out-Null
  }
}

function Sync-Account($AccountId) {
  $db = Read-Db
  $account = $db.accounts | Where-Object { $_.id -eq $AccountId } | Select-Object -First 1
  if (!$account) { throw "账号不存在" }
  $oldApps = @($db.apps | Where-Object { $_.accountId -eq $account.id })
  $node = Join-Path $Script:AppRoot "runtime\node.exe"
  if (!(Test-Path $node)) { throw "缺少 runtime\node.exe，无法生成 Apple API JWT。" }
  $helper = Join-Path $Script:SrcDir "apple-sync.js"
  if (!(Test-Path $helper)) { throw "缺少 Apple API 同步模块。" }

  $knownIcons = [ordered]@{}
  foreach ($oldApp in @($oldApps)) {
    if (![string]::IsNullOrWhiteSpace($oldApp.appleId) -and ![string]::IsNullOrWhiteSpace($oldApp.iconUrl)) {
      $knownIcons[[string]$oldApp.appleId] = [ordered]@{
        buildId = if (![string]::IsNullOrWhiteSpace($oldApp.buildId)) { [string]$oldApp.buildId } else { "" }
        iconUrl = [string]$oldApp.iconUrl
      }
    }
  }

  $payload = [ordered]@{
    account = [ordered]@{
      id = $account.id
      name = $account.name
      issuerId = $account.issuerId
      keyId = $account.keyId
      privateKey = (Unprotect-Text $account.privateKeyEnc)
    }
    knownIcons = $knownIcons
  } | ConvertTo-Json -Depth 8

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $node
  $psi.Arguments = "`"$helper`""
  $psi.WorkingDirectory = $Script:AppRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.CreateNoWindow = $true
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
  $proc.StandardInput.Write($payload)
  $proc.StandardInput.Close()
  $out = $proc.StandardOutput.ReadToEnd()
  $err = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ([string]::IsNullOrWhiteSpace($out)) {
    if (![string]::IsNullOrWhiteSpace($err)) { throw $err }
    throw "Apple API 同步没有返回结果。"
  }

  $result = $out | ConvertFrom-Json
  if (-not $result.ok) { throw $result.error }

  $nextApps = @()
  $detectedAt = Get-NowIso
  foreach ($app in @($result.apps)) {
    $oldApp = $oldApps | Where-Object { (Get-AppIdentityKey $_) -eq [string]$app.appleId } | Select-Object -First 1
    $iconUrl = if (![string]::IsNullOrWhiteSpace($app.iconUrl)) {
      [string]$app.iconUrl
    } elseif ($oldApp -and ![string]::IsNullOrWhiteSpace($oldApp.iconUrl)) {
      [string]$oldApp.iconUrl
    } else {
      ""
    }
    $nextApps += [ordered]@{
      id = "app_$($account.id)_$($app.appleId)"
      appleId = $app.appleId
      accountId = $account.id
      accountName = $account.name
      name = $app.name
      bundleId = $app.bundleId
      sku = $app.sku
      primaryLocale = $app.primaryLocale
      platform = $app.platform
      version = $app.version
      build = $app.build
      buildId = $app.buildId
      iconUrl = $iconUrl
      processingState = $app.processingState
      status = $app.status
      statusLabel = Get-StatusLabel (Normalize-Status $app.status)
      versionError = $app.versionError
      extraReviews = @($app.extraReviews)
      extraReviewError = if (![string]::IsNullOrWhiteSpace($app.extraReviewError)) { [string]$app.extraReviewError } else { "" }
      submittedAt = $app.submittedAt
      updatedAt = $app.updatedAt
      owner = $account.owner
      notes = ""
    }
    Update-AppStatusTiming $nextApps[-1] $oldApp $detectedAt
    Update-ExtraReviewTiming $nextApps[-1] $oldApp $detectedAt
  }

  $changes = Get-AppStatusChanges $oldApps $nextApps
  $db.apps = @($db.apps | Where-Object { $_.accountId -ne $account.id })
  $db.apps += $nextApps
  $account.status = "connected"
  $account.lastError = ""
  $account.lastSyncAt = Get-NowIso
  $account.updatedAt = Get-NowIso
  Update-AlertsForApps $db $account $nextApps
  Resolve-AlertsByKeyPrefix $db "sync:$($account.id)"
  $db.syncLogs += [ordered]@{
    id = New-Id "log"
    level = "success"
    accountId = $account.id
    message = "$($account.name) 同步成功，发现 $(@($nextApps).Count) 个 App"
    createdAt = Get-NowIso
  }
  Write-Db $db
  try {
    Notify-AppStatusChanges $changes
  } catch {
    # Status sync has already been saved; notification rendering must not mark the account as failed.
  }
  return @($nextApps).Count
}

[xml]$xaml = Get-Content -LiteralPath (Join-Path $Script:SrcDir "App.xaml") -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

$names = @(
  "BrandLogo","NavDashboard","NavAccounts","NavApps","NavAlerts","NavSettings","SyncAllBtn","SyncAllSpinner","SyncAllText","AddAccountBtn","AddAccountBtn2","EditSelectedAccountBtn",
  "DashboardView","AccountsView","AppsView","AppDetailView","AlertsView","SettingsView","MetricAccounts","MetricConnected","MetricApps","MetricReview","MetricExtraReview",
  "MetricAlerts","MetricRejected","DashboardAlertsList","RecentAppsGrid","AccountsGrid","AppsGrid","AlertsGrid",
  "StatusFilter","SyncSelectedAccountBtn","SyncSelectedSpinner","SyncSelectedText","DeleteSelectedAccountBtn","AccountFilter","AppScopeText","AutoSyncToggle","AutoSyncStatusText",
  "CloseToTrayToggle","SettingsTrayStatusText","AutoDiscoverAppsToggle","SettingsDiscoverStatusText","AppDiscoveryIntervalCombo","DiscoverAppsNowBtn",
  "BackToAppsBtn","DetailAppIcon","DetailAppInitial","DetailAppName","DetailBundleId","DetailAccountName","DetailVersion","DetailBuild",
  "DetailMainStatusPill","DetailMainStatusText","DetailMainChangedAt","MainStatusHistoryList","ExtraStatusHistoryList"
)
foreach ($name in $names) {
  Set-Variable -Name $name -Value $Window.FindName($name) -Scope Script
}

$NavDashboard.Add_Click({ Show-View "dashboard" })
$NavAccounts.Add_Click({ Show-View "accounts" })
$NavApps.Add_Click({ Show-View "apps" })
$NavAlerts.Add_Click({ Show-View "alerts" })
$NavSettings.Add_Click({ Show-View "settings" })
$AccountsGrid.Add_MouseDoubleClick({
  $selected = $AccountsGrid.SelectedItem
  if ($null -ne $selected) {
    Show-EditAccountDialog $selected
  }
})
$AddAccountBtn.Add_Click({ Show-AddAccountDialog })
$AddAccountBtn2.Add_Click({ Show-AddAccountDialog })
$EditSelectedAccountBtn.Add_Click({ Show-EditAccountDialog $AccountsGrid.SelectedItem })
$BackToAppsBtn.Add_Click({ Show-View "apps" })
$AppsGrid.Add_MouseLeftButtonUp({
  param($sender, $eventArgs)
  $source = $eventArgs.OriginalSource -as [Windows.DependencyObject]
  while ($null -ne $source -and $source -isnot [Windows.Controls.ContentPresenter]) {
    $source = [Windows.Media.VisualTreeHelper]::GetParent($source)
  }
  if ($null -eq $source) { return }
  $item = $source.DataContext
  if ($null -ne $item -and ![string]::IsNullOrWhiteSpace([string]$item.id)) {
    Show-AppDetail ([string]$item.id)
  }
})
$SyncSelectedAccountBtn.Add_Click({
  $selected = $AccountsGrid.SelectedItem
  if ($null -eq $selected) {
    [Windows.MessageBox]::Show("请先在账号列表里选中一个账号。", "提示", "OK", "Information") | Out-Null
    return
  }
  Start-ManualSync "selected" ([string]$selected.id)
})
$DeleteSelectedAccountBtn.Add_Click({
  $selected = $AccountsGrid.SelectedItem
  if ($null -eq $selected) {
    [Windows.MessageBox]::Show("请先在账号列表里选中一个账号。", "提示", "OK", "Information") | Out-Null
    return
  }
  $displayName = if (![string]::IsNullOrWhiteSpace($selected.notes)) { "$($selected.notes) - $($selected.name)" } else { $selected.name }
  $answer = [Windows.MessageBox]::Show("确定删除账号：$displayName？`n该账号下已同步的 App 和提醒也会一起删除。", "删除账号", "YesNo", "Warning")
  if ($answer -ne "Yes") { return }
  try {
    Remove-Account $selected.id
    Refresh-Ui
    Show-View "accounts"
    [Windows.MessageBox]::Show("账号已删除。", "完成", "OK", "Information") | Out-Null
  } catch {
    [Windows.MessageBox]::Show($_.Exception.Message, "删除失败", "OK", "Warning") | Out-Null
  }
})
$SyncAllBtn.Add_Click({
  Start-ManualSync "all"
})
$StatusFilter.Add_SelectionChanged({ Refresh-AppsGrid })
$AccountFilter.Add_SelectionChanged({ Refresh-AppsGrid })
$resolveAlertHandler = [Windows.RoutedEventHandler]{
  param($sender, $eventArgs)
  $button = $eventArgs.OriginalSource -as [Windows.Controls.Button]
  if ($null -eq $button -or [string]$button.Content -ne "已处理") { return }
  $alertId = [string]$button.Tag
  if ([string]::IsNullOrWhiteSpace($alertId)) { return }
  try {
    Resolve-Alert $alertId
    Refresh-Ui
    $eventArgs.Handled = $true
  } catch {
    [Windows.MessageBox]::Show($_.Exception.Message, "处理失败", "OK", "Warning") | Out-Null
  }
}
$DashboardAlertsList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, $resolveAlertHandler)
$AlertsGrid.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, $resolveAlertHandler)
$AutoSyncToggle.Add_Checked({
  Update-AutoSyncStatusText "自动同步运行中"
  Invoke-AutoSyncDueAccounts
})
$AutoSyncToggle.Add_Unchecked({
  Update-AutoSyncStatusText "自动同步已关闭"
})
$CloseToTrayToggle.Add_Checked({ Save-CloseToTrayFromUi })
$CloseToTrayToggle.Add_Unchecked({ Save-CloseToTrayFromUi })
$AutoDiscoverAppsToggle.Add_Checked({ Save-AutoDiscoverAppsFromUi })
$AutoDiscoverAppsToggle.Add_Unchecked({ Save-AutoDiscoverAppsFromUi })
$AppDiscoveryIntervalCombo.Add_SelectionChanged({ Save-AppDiscoveryIntervalFromUi })
$DiscoverAppsNowBtn.Add_Click({
  Start-ManualSync "discover"
})
$Window.Add_Closing({
  param($sender, $eventArgs)
  if ($Script:ReallyExit) { return }
  if (Get-CloseToTraySetting) {
    $eventArgs.Cancel = $true
    Hide-MainWindowToTray
    return
  }
  $Script:ReallyExit = $true
})
$Window.Add_Closed({
  Close-TrayRestoreWindow
  if ($null -ne $Script:AutoSyncTimer) {
    $Script:AutoSyncTimer.Stop()
    $Script:AutoSyncTimer = $null
  }
  Stop-SyncSpinner
  if ($null -ne $Script:InstanceEventTimer) {
    $Script:InstanceEventTimer.Stop()
    $Script:InstanceEventTimer = $null
  }
  if ($null -ne $Script:AutoSyncPollTimer) {
    $Script:AutoSyncPollTimer.Stop()
    $Script:AutoSyncPollTimer = $null
  }
  if ($null -ne $Script:AutoSyncProcess) {
    try {
      if (!$Script:AutoSyncProcess.HasExited) {
        $Script:AutoSyncProcess.Kill()
      }
    } catch {
    }
    $Script:AutoSyncProcess = $null
  }
  if (![string]::IsNullOrWhiteSpace($Script:AutoSyncResultPath)) {
    Remove-Item -LiteralPath $Script:AutoSyncResultPath -Force -ErrorAction SilentlyContinue
    $Script:AutoSyncResultPath = ""
  }
  if ($null -ne $Script:ManualSyncPollTimer) {
    $Script:ManualSyncPollTimer.Stop()
    $Script:ManualSyncPollTimer = $null
  }
  if ($null -ne $Script:ManualSyncProcess) {
    try {
      if (!$Script:ManualSyncProcess.HasExited) {
        $Script:ManualSyncProcess.Kill()
      }
    } catch {
    }
    $Script:ManualSyncProcess = $null
  }
  if (![string]::IsNullOrWhiteSpace($Script:ManualSyncResultPath)) {
    Remove-Item -LiteralPath $Script:ManualSyncResultPath -Force -ErrorAction SilentlyContinue
    $Script:ManualSyncResultPath = ""
  }
  foreach ($notice in @($Script:NotificationWindows)) {
    if ($null -ne $notice -and $notice.IsVisible) { $notice.Close() }
  }
  $Script:NotificationWindows = @()
  if ($null -ne $Script:TrayIcon) {
    $Script:TrayIcon.Visible = $false
    $Script:TrayIcon.Dispose()
    $Script:TrayIcon = $null
  }
  if ($null -ne $Script:TrayIconImage) {
    $Script:TrayIconImage.Dispose()
    $Script:TrayIconImage = $null
  }
  if ($null -ne $Script:InstanceEvent) {
    $Script:InstanceEvent.Dispose()
    $Script:InstanceEvent = $null
  }
  if ($Script:InstanceMutexHeld -and $null -ne $Script:InstanceMutex) {
    try { $Script:InstanceMutex.ReleaseMutex() } catch {}
    $Script:InstanceMutexHeld = $false
  }
  if ($null -ne $Script:InstanceMutex) {
    $Script:InstanceMutex.Dispose()
    $Script:InstanceMutex = $null
  }
  if ($Script:ReallyExit -and $null -ne $Script:WpfApp) {
    $Script:WpfApp.Shutdown()
  }
})

Initialize-TrayIcon
Initialize-AppBranding
Refresh-Ui
Update-SettingsUi
Show-View "dashboard"
Start-InstanceEventTimer
Start-AutoSyncTimer
if ($AutoSyncToggle.IsChecked -eq $true) {
  Update-AutoSyncStatusText "自动同步运行中"
} else {
  Update-AutoSyncStatusText "自动同步已关闭"
}
$Script:WpfApp = [Windows.Application]::Current
if ($null -eq $Script:WpfApp) {
  $Script:WpfApp = New-Object Windows.Application
}
$Script:WpfApp.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown
$Window.Show()
[void]$Script:WpfApp.Run()




































