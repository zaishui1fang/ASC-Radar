param(
  [string]$Mode = "all",
  [string]$AccountId = "",
  [string]$ResultPath = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Security

$Script:AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Script:DataDir = Join-Path $Script:AppRoot "data"
$Script:DbFile = Join-Path $Script:DataDir "store.json"
$Script:KeyFile = Join-Path $Script:DataDir "local.key"
$Script:IconDir = Join-Path $Script:DataDir "icons"
$Script:DbLockDepth = 0
New-Item -ItemType Directory -Force -Path $Script:DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $Script:IconDir | Out-Null
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Get-StoreMutexName {
  $md5 = [Security.Cryptography.MD5]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Script:DbFile.ToLowerInvariant())
    $hash = [BitConverter]::ToString($md5.ComputeHash($bytes)).Replace("-", "")
    return "Local\ASCRadarStore_$hash"
  } finally {
    $md5.Dispose()
  }
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
      throw "Store file is busy. Please try again later."
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
  return $Value | ConvertTo-Json -Depth 24
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
  if ($InputObject.PSObject.Properties.Count -gt 0 -and $InputObject.GetType().Name -eq "PSCustomObject") {
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

function Ensure-DbSettings($Db) {
  if ($null -eq $Db["settings"]) { $Db["settings"] = [ordered]@{} }
  if ($null -eq $Db["settings"]["createdAt"]) { $Db["settings"]["createdAt"] = Get-NowIso }
  if ($null -eq $Db["settings"]["closeToTray"]) { $Db["settings"]["closeToTray"] = $true }
  if ($null -eq $Db["settings"]["autoDiscoverApps"]) { $Db["settings"]["autoDiscoverApps"] = $false }
  if ($null -eq $Db["settings"]["appDiscoveryIntervalHours"]) { $Db["settings"]["appDiscoveryIntervalHours"] = 6 }
}

function Resolve-IconFilePath([string]$IconPath) {
  if ([string]::IsNullOrWhiteSpace($IconPath)) { return "" }
  if ([IO.Path]::IsPathRooted($IconPath)) { return $IconPath }
  return (Join-Path $Script:AppRoot $IconPath)
}

function Test-IconFile([string]$IconPath) {
  $path = Resolve-IconFilePath $IconPath
  if ([string]::IsNullOrWhiteSpace($path)) { return $false }
  return (Test-Path -LiteralPath $path -PathType Leaf)
}

function Get-IconExtensionFromUrl([string]$IconUrl) {
  try {
    $uri = [Uri]$IconUrl
    $ext = [IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant()
    if (@(".png", ".jpg", ".jpeg") -contains $ext) { return $ext }
  } catch {
  }
  return ".jpg"
}

function Get-IconRelativePath([string]$AccountId, [string]$AppleId, [string]$IconUrl) {
  $safeAccount = ([string]$AccountId) -replace "[^A-Za-z0-9_.-]", "_"
  $safeApp = ([string]$AppleId) -replace "[^A-Za-z0-9_.-]", "_"
  if ([string]::IsNullOrWhiteSpace($safeAccount)) { $safeAccount = "account" }
  if ([string]::IsNullOrWhiteSpace($safeApp)) { $safeApp = "app" }
  $fileName = "$safeAccount`_$safeApp$(Get-IconExtensionFromUrl $IconUrl)"
  return [IO.Path]::Combine("data", "icons", $fileName)
}

function Save-RemoteIconFile([string]$IconUrl, [string]$TargetPath) {
  $tempPath = "$TargetPath.tmp"
  $request = [Net.HttpWebRequest]::Create($IconUrl)
  $request.Method = "GET"
  $request.Timeout = 8000
  $request.ReadWriteTimeout = 8000
  $request.UserAgent = "ASC Radar"
  $response = $null
  $inputStream = $null
  $outputStream = $null
  try {
    $response = $request.GetResponse()
    $inputStream = $response.GetResponseStream()
    $outputStream = [IO.File]::Open($tempPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $buffer = New-Object byte[] 8192
    $total = 0
    while ($true) {
      $read = $inputStream.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }
      $total += $read
      if ($total -gt 5242880) { throw "Icon file is too large." }
      $outputStream.Write($buffer, 0, $read)
    }
    $outputStream.Close()
    $outputStream = $null
    if ($total -le 0) { throw "Icon download returned an empty file." }
    if (Test-Path -LiteralPath $TargetPath) {
      Remove-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $tempPath -Destination $TargetPath -Force
  } finally {
    if ($null -ne $outputStream) { $outputStream.Close() }
    if ($null -ne $inputStream) { $inputStream.Close() }
    if ($null -ne $response) { $response.Close() }
    if (Test-Path -LiteralPath $tempPath) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-CachedIconPath([string]$AccountId, [string]$AppleId, [string]$IconUrl, $OldApp) {
  $existingPath = ""
  $oldUrl = ""
  if ($OldApp) {
    if (![string]::IsNullOrWhiteSpace($OldApp.iconPath) -and (Test-IconFile ([string]$OldApp.iconPath))) {
      $existingPath = [string]$OldApp.iconPath
    }
    if (![string]::IsNullOrWhiteSpace($OldApp.iconUrl)) {
      $oldUrl = [string]$OldApp.iconUrl
    }
  }

  if ([string]::IsNullOrWhiteSpace($IconUrl)) {
    return $existingPath
  }
  if (![string]::IsNullOrWhiteSpace($existingPath) -and $oldUrl -eq $IconUrl) {
    return $existingPath
  }

  $relativePath = Get-IconRelativePath $AccountId $AppleId $IconUrl
  $targetPath = Resolve-IconFilePath $relativePath
  if ((Test-Path -LiteralPath $targetPath -PathType Leaf) -and ($oldUrl -eq $IconUrl -or [string]::IsNullOrWhiteSpace($oldUrl))) {
    return $relativePath
  }

  try {
    New-Item -ItemType Directory -Force -Path $Script:IconDir | Out-Null
    Save-RemoteIconFile $IconUrl $targetPath
    if (Test-Path -LiteralPath $targetPath -PathType Leaf) { return $relativePath }
  } catch {
  }

  return $existingPath
}

function Read-Db {
  return Invoke-DbLocked {
    if (!(Test-Path $Script:DbFile)) { return New-DefaultDb }
    $raw = Get-Content -LiteralPath $Script:DbFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return New-DefaultDb }
    $db = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
    foreach ($key in @("accounts", "apps", "alerts", "syncLogs")) {
      if ($null -eq $db[$key]) {
        $db[$key] = @()
      } elseif ($db[$key] -isnot [System.Array]) {
        $db[$key] = @($db[$key])
      }
    }
    Ensure-DbSettings $db
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
    Ensure-DbSettings $Db
    ConvertTo-JsonText $Db | Set-Content -LiteralPath $Script:DbFile -Encoding UTF8
  }
}

function Merge-AccountResultIntoLatestDb($LatestDb, $AccountId, $NextApps, $AccountUpdates, $SyncLogMessage, $Changes, $FailureMode = $false) {
  $latestAccount = $LatestDb.accounts | Where-Object { $_.id -eq $AccountId } | Select-Object -First 1
  if (!$latestAccount) {
    throw "Account does not exist."
  }

  $LatestDb.apps = @($LatestDb.apps | Where-Object { $_.accountId -ne $AccountId })
  if ($null -ne $NextApps) {
    $LatestDb.apps += @($NextApps)
  }

  if ($null -ne $AccountUpdates) {
    foreach ($key in $AccountUpdates.Keys) {
      $latestAccount[$key] = $AccountUpdates[$key]
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($SyncLogMessage)) {
    $LatestDb.syncLogs += [ordered]@{
      id = New-Id "log"
      level = if ($FailureMode) { "error" } else { "success" }
      accountId = $AccountId
      message = $SyncLogMessage
      createdAt = Get-NowIso
    }
  }

  return $LatestDb
}

function Get-LocalKey {
  if (!(Test-Path $Script:KeyFile)) {
    throw "Missing local encryption key. Please re-save the account."
  }
  return [Convert]::FromBase64String((Get-Content -LiteralPath $Script:KeyFile -Raw).Trim())
}

function Unprotect-Text([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  if (!$Value.StartsWith("v1:")) { return $Value }
  $parts = $Value.Split(":")
  if ($parts.Count -lt 3 -or [string]::IsNullOrWhiteSpace($parts[1]) -or [string]::IsNullOrWhiteSpace($parts[2])) {
    throw "Private key data is incomplete. Please reselect the .p8 key."
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

function Get-FriendlySyncError([string]$Message) {
  if ([string]::IsNullOrWhiteSpace($Message)) { return "Sync failed. Please try again later." }
  $text = $Message.Trim()
  if ($text -like "*Private key data is incomplete*" -or $text -like "*Missing .p8 private key*") {
    return "Local private key could not be read. Please reselect the .p8 key."
  }
  if ($text -like "*Missing Issuer ID or Key ID*") {
    return "Missing Issuer ID or Key ID. Please edit the account and sync again."
  }
  if ($text -like "*Apple API 401*" -or $text -like "*Apple API 403*") {
    return "Apple API authorization failed. Please check Issuer ID, Key ID, .p8 key, and permissions."
  }
  return $text
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

function Resolve-AlertsByKeyPrefix($Db, [string]$KeyPrefix) {
  foreach ($alert in @($Db.alerts | Where-Object { ([string]$_.key).StartsWith($KeyPrefix) -and -not $_.resolvedAt })) {
    $alert.resolvedAt = Get-NowIso
    $alert.updatedAt = Get-NowIso
  }
}

function Update-AlertsForApps($Db, $Account, $Apps) {
  foreach ($app in @($Apps)) {
    if (@("REJECTED", "METADATA_REJECTED", "INVALID_BINARY") -contains $app.status) {
      Add-Alert $Db ([ordered]@{
        key = "review:$($app.id):$($app.status)"
        severity = "critical"
        type = "REVIEW_BLOCKED"
        accountId = $Account.id
        accountName = $Account.name
        appId = $app.id
        appName = $app.name
        title = "$($app.name) $($app.status)"
        message = "$($app.accountName) / $($app.version) needs attention."
      })
    }
  }
}

function Remove-AlertsForApps($Db, $Apps) {
  $removedIds = @{}
  foreach ($app in @($Apps)) {
    if (![string]::IsNullOrWhiteSpace($app.id)) { $removedIds[[string]$app.id] = $true }
  }
  if ($removedIds.Count -eq 0) { return }
  $Db.alerts = @($Db.alerts | Where-Object {
    [string]::IsNullOrWhiteSpace($_.appId) -or -not $removedIds.ContainsKey([string]$_.appId)
  })
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

  $NextApp.statusChangedAt = $changedAt
  $NextApp.statusCheckedAt = $Now
  $NextApp.statusHistory = @(Limit-StatusHistory @($history.ToArray()))
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
    $key = Get-ExtraReviewIdentityKey $NextApp $review
    $oldReview = if ($oldMap.ContainsKey($key)) { $oldMap[$key] } else { $null }
    $newStatus = Normalize-Status ([string](Get-ObjectValue $review "status"))
    if ([string]::IsNullOrWhiteSpace($newStatus) -or @("NO_VERSION", "UNKNOWN") -contains $newStatus) { continue }
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

    $review.statusChangedAt = $changedAt
    $review.statusCheckedAt = $Now
    $review.statusHistory = @(Limit-StatusHistory @($history.ToArray()))
    $nextReviews += $review
  }

  $NextApp.extraReviews = @($nextReviews)
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
    if ([string]::IsNullOrWhiteSpace($newStatus) -or $newStatus -eq "NO_VERSION") { continue }
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
      oldLabel = $oldStatus
      newStatus = $newStatus
      newLabel = $newStatus
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
        oldLabel = $oldStatus
        newStatus = $newStatus
        newLabel = $newStatus
      }
    }
  }
  return @($changes)
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

function Test-AppNeedsFastStatusSync($App) {
  $reviewStatuses = @("IN_REVIEW", "WAITING_FOR_REVIEW")
  if ($reviewStatuses -contains (Normalize-Status $App.status)) { return $true }
  foreach ($review in @(Get-ListItems (Get-ObjectValue $App "extraReviews"))) {
    if ($null -eq $review) { continue }
    if ($reviewStatuses -contains (Normalize-Status ([string](Get-ObjectValue $review "status")))) {
      return $true
    }
  }
  return $false
}

function Set-NextAutoSync($Db, $Account, [int]$Minutes) {
  $Account.nextAutoSyncAt = [DateTime]::UtcNow.AddMinutes($Minutes).ToString("o")
  $Account.updatedAt = Get-NowIso
}

function Get-AppDiscoveryIntervalHours($Db) {
  $hours = 6
  try {
    if ($null -ne $Db.settings -and $null -ne $Db.settings.appDiscoveryIntervalHours) {
      $hours = [int]$Db.settings.appDiscoveryIntervalHours
    }
  } catch {
    $hours = 6
  }
  if ($hours -lt 1) { return 1 }
  if ($hours -gt 72) { return 72 }
  return $hours
}

function Set-NextAppDiscovery($Db, $Account, [int]$Hours) {
  $Account.nextAppDiscoveryAt = [DateTime]::UtcNow.AddHours($Hours).ToString("o")
  $Account.lastAppDiscoveryAt = Get-NowIso
  $Account.updatedAt = Get-NowIso
}

function Get-FailureRetryMinutes([string]$RawMessage) {
  if ([string]::IsNullOrWhiteSpace($RawMessage)) { return 15 }
  if (
    $RawMessage -like "*Private key data is incomplete*" -or
    $RawMessage -like "*Missing .p8 private key*" -or
    $RawMessage -like "*Missing Issuer ID or Key ID*" -or
    $RawMessage -like "*Apple API 401*" -or
    $RawMessage -like "*Apple API 403*"
  ) {
    return 720
  }
  return 15
}

function Invoke-AppleApiSync($Account, $OldApps, [string]$SyncMode = "full") {
  $node = Join-Path $Script:AppRoot "runtime\node.exe"
  if (!(Test-Path $node)) { throw "Missing runtime node.exe. Cannot create Apple API JWT." }
  $helper = Join-Path $PSScriptRoot "apple-sync.js"
  if (!(Test-Path $helper)) { throw "Missing Apple API sync module." }

  $knownIcons = [ordered]@{}
  foreach ($oldApp in @($OldApps)) {
    if (![string]::IsNullOrWhiteSpace($oldApp.appleId) -and ![string]::IsNullOrWhiteSpace($oldApp.iconUrl)) {
      $knownIcons[[string]$oldApp.appleId] = [ordered]@{
        buildId = if (![string]::IsNullOrWhiteSpace($oldApp.buildId)) { [string]$oldApp.buildId } else { "" }
        iconUrl = [string]$oldApp.iconUrl
      }
    }
  }

  $trackedApps = @()
  foreach ($oldApp in @($OldApps)) {
    if (![string]::IsNullOrWhiteSpace($oldApp.appleId)) {
      $trackedApps += [ordered]@{
        appleId = [string]$oldApp.appleId
        name = if (![string]::IsNullOrWhiteSpace($oldApp.name)) { [string]$oldApp.name } else { "" }
        bundleId = if (![string]::IsNullOrWhiteSpace($oldApp.bundleId)) { [string]$oldApp.bundleId } else { "" }
      }
    }
  }

  $payload = [ordered]@{
    mode = $SyncMode
    account = [ordered]@{
      id = $Account.id
      name = $Account.name
      issuerId = $Account.issuerId
      keyId = $Account.keyId
      privateKey = (Unprotect-Text $Account.privateKeyEnc)
    }
    knownIcons = $knownIcons
    trackedApps = $trackedApps
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
    throw "Apple API sync returned no result."
  }

  $result = $out | ConvertFrom-Json
  if (-not $result.ok) { throw $result.error }
  return $result
}

function Sync-AccountWorker([string]$TargetAccountId) {
  $db = Read-Db
  $account = $db.accounts | Where-Object { $_.id -eq $TargetAccountId } | Select-Object -First 1
  if (!$account) { throw "Account does not exist." }

  $oldApps = @($db.apps | Where-Object { $_.accountId -eq $account.id })
  $result = Invoke-AppleApiSync $account $oldApps "full"
  $nextApps = @()
  $detectedAt = Get-NowIso
  foreach ($app in @($result.apps)) {
    $normalizedStatus = Normalize-Status $app.status
    $oldApp = $oldApps | Where-Object { (Get-AppIdentityKey $_) -eq [string]$app.appleId } | Select-Object -First 1
    $iconUrl = if (![string]::IsNullOrWhiteSpace($app.iconUrl)) {
      [string]$app.iconUrl
    } elseif ($oldApp -and ![string]::IsNullOrWhiteSpace($oldApp.iconUrl)) {
      [string]$oldApp.iconUrl
    } else {
      ""
    }
    $iconPath = Get-CachedIconPath $account.id $app.appleId $iconUrl $oldApp
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
      iconPath = $iconPath
      processingState = $app.processingState
      status = $normalizedStatus
      statusLabel = $normalizedStatus
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
  $nextAppMap = @{}
  foreach ($nextApp in @($nextApps)) {
    $nextAppMap[(Get-AppIdentityKey $nextApp)] = $true
  }
  $removedApps = @($oldApps | Where-Object { -not $nextAppMap.ContainsKey((Get-AppIdentityKey $_)) })
  Invoke-DbLocked {
    $latestDb = Read-Db
    $latestAccount = $latestDb.accounts | Where-Object { $_.id -eq $account.id } | Select-Object -First 1
    if (!$latestAccount) { throw "Account does not exist." }
    $now = Get-NowIso
    $latestAccount.status = "connected"
    $latestAccount.lastError = ""
    $latestAccount.lastSyncAt = $now
    $latestAccount.updatedAt = $now
    $latestDb = Merge-AccountResultIntoLatestDb $latestDb $account.id $nextApps ([ordered]@{
      status = $latestAccount.status
      lastError = $latestAccount.lastError
      lastSyncAt = $latestAccount.lastSyncAt
      updatedAt = $latestAccount.updatedAt
      nextAutoSyncAt = (Get-NowIso)
    }) "$($account.name) sync succeeded, found $(@($nextApps).Count) apps" $changes $false
    Update-AlertsForApps $latestDb $latestAccount $nextApps
    Remove-AlertsForApps $latestDb $removedApps
    Resolve-AlertsByKeyPrefix $latestDb "sync:$($account.id)"
    Set-NextAutoSync $latestDb $latestAccount (Get-AutoSyncIntervalMinutes $latestDb $latestAccount)
    Set-NextAppDiscovery $latestDb $latestAccount (Get-AppDiscoveryIntervalHours $latestDb)
    Write-Db $latestDb
  }

  return [ordered]@{
    accountId = $account.id
    accountName = $account.name
    count = @($nextApps).Count
    changes = @($changes)
  }
}

function Sync-AccountStatusWorker([string]$TargetAccountId) {
  $db = Read-Db
  $account = $db.accounts | Where-Object { $_.id -eq $TargetAccountId } | Select-Object -First 1
  if (!$account) { throw "Account does not exist." }

  $oldApps = @($db.apps | Where-Object { $_.accountId -eq $account.id })
  if ($oldApps.Count -eq 0) {
    Invoke-DbLocked {
      $latestDb = Read-Db
      $latestAccount = $latestDb.accounts | Where-Object { $_.id -eq $account.id } | Select-Object -First 1
      if (!$latestAccount) { throw "Account does not exist." }
      $latestAccount.status = "connected"
      $latestAccount.lastError = ""
      $latestAccount.lastSyncAt = Get-NowIso
      $latestAccount.updatedAt = Get-NowIso
      Set-NextAutoSync $latestDb $latestAccount (Get-AutoSyncIntervalMinutes $latestDb $latestAccount)
      Write-Db $latestDb
    }
    return [ordered]@{
      accountId = $account.id
      accountName = $account.name
      count = 0
      changes = @()
    }
  }

  $trackedApps = @($oldApps | Where-Object { Test-AppNeedsFastStatusSync $_ })
  if ($trackedApps.Count -eq 0) { $trackedApps = $oldApps }

  $result = Invoke-AppleApiSync $account $trackedApps "status"
  $statusMap = @{}
  $deletedMap = @{}
  foreach ($app in @($result.apps)) {
    if (![string]::IsNullOrWhiteSpace($app.appleId)) {
      $statusMap[[string]$app.appleId] = $app
      if ($app.deleted -eq $true -or (Normalize-Status $app.status) -eq "DELETED") {
        $deletedMap[[string]$app.appleId] = $true
      }
    }
  }

  $nextApps = @()
  $removedApps = @()
  $detectedAt = Get-NowIso
  foreach ($oldApp in @($oldApps)) {
    $nextApp = [ordered]@{}
    foreach ($key in $oldApp.Keys) { $nextApp[$key] = $oldApp[$key] }
    $key = [string]$oldApp.appleId
    if (![string]::IsNullOrWhiteSpace($key) -and $deletedMap.ContainsKey($key)) {
      $removedApps += $oldApp
      continue
    }
    if (![string]::IsNullOrWhiteSpace($key) -and $statusMap.ContainsKey($key)) {
      $statusApp = $statusMap[$key]
      $nextApp.status = Normalize-Status $statusApp.status
      $nextApp.statusLabel = $nextApp.status
      $nextApp.extraReviews = @($statusApp.extraReviews)
      $nextApp.extraReviewError = if (![string]::IsNullOrWhiteSpace($statusApp.extraReviewError)) { [string]$statusApp.extraReviewError } else { "" }
      if (![string]::IsNullOrWhiteSpace($statusApp.version)) { $nextApp.version = [string]$statusApp.version }
      $nextApp.versionError = if (![string]::IsNullOrWhiteSpace($statusApp.versionError)) { [string]$statusApp.versionError } else { "" }
      if (![string]::IsNullOrWhiteSpace($statusApp.submittedAt)) { $nextApp.submittedAt = [string]$statusApp.submittedAt }
      if (![string]::IsNullOrWhiteSpace($statusApp.updatedAt)) { $nextApp.updatedAt = [string]$statusApp.updatedAt }
    }
    Update-AppStatusTiming $nextApp $oldApp $detectedAt
    Update-ExtraReviewTiming $nextApp $oldApp $detectedAt
    $nextApps += $nextApp
  }

  $changes = Get-AppStatusChanges $oldApps $nextApps
  Invoke-DbLocked {
    $latestDb = Read-Db
    $latestAccount = $latestDb.accounts | Where-Object { $_.id -eq $account.id } | Select-Object -First 1
    if (!$latestAccount) { throw "Account does not exist." }
    $now = Get-NowIso
    $latestAccount.status = "connected"
    $latestAccount.lastError = ""
    $latestAccount.lastSyncAt = $now
    $latestAccount.updatedAt = $now
    $latestDb = Merge-AccountResultIntoLatestDb $latestDb $account.id $nextApps ([ordered]@{
      status = $latestAccount.status
      lastError = $latestAccount.lastError
      lastSyncAt = $latestAccount.lastSyncAt
      updatedAt = $latestAccount.updatedAt
      nextAutoSyncAt = (Get-NowIso)
    }) "$($account.name) auto status sync succeeded, checked $(@($trackedApps).Count) apps" $changes $false
    Update-AlertsForApps $latestDb $latestAccount $nextApps
    Remove-AlertsForApps $latestDb $removedApps
    Resolve-AlertsByKeyPrefix $latestDb "sync:$($account.id)"
    Set-NextAutoSync $latestDb $latestAccount (Get-AutoSyncIntervalMinutes $latestDb $latestAccount)
    if (@($removedApps).Count -gt 0) {
      $latestDb.syncLogs += [ordered]@{
        id = New-Id "log"
        level = "info"
        accountId = $account.id
        message = "$($account.name) removed $(@($removedApps).Count) deleted apps from local list"
        createdAt = Get-NowIso
      }
    }
    Write-Db $latestDb
  }

  return [ordered]@{
    accountId = $account.id
    accountName = $account.name
    count = @($trackedApps).Count
    changes = @($changes)
  }
}

function Discover-NewAppsWorker([string]$TargetAccountId) {
  $db = Read-Db
  $account = $db.accounts | Where-Object { $_.id -eq $TargetAccountId } | Select-Object -First 1
  if (!$account) { throw "Account does not exist." }

  $oldApps = @($db.apps | Where-Object { $_.accountId -eq $account.id })
  $result = Invoke-AppleApiSync $account $oldApps "discover"
  $existingMap = @{}
  foreach ($oldApp in @($oldApps)) {
    $key = Get-AppIdentityKey $oldApp
    if (![string]::IsNullOrWhiteSpace($key)) { $existingMap[$key] = $true }
  }

  $newApps = @()
  $detectedAt = Get-NowIso
  foreach ($app in @($result.apps)) {
    $appKey = [string]$app.appleId
    if ([string]::IsNullOrWhiteSpace($appKey) -or $existingMap.ContainsKey($appKey)) { continue }
    $normalizedStatus = Normalize-Status $app.status
    $iconUrl = if (![string]::IsNullOrWhiteSpace($app.iconUrl)) { [string]$app.iconUrl } else { "" }
    $iconPath = Get-CachedIconPath $account.id $app.appleId $iconUrl $null
    $newApps += [ordered]@{
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
      iconPath = $iconPath
      processingState = $app.processingState
      status = $normalizedStatus
      statusLabel = $normalizedStatus
      versionError = $app.versionError
      extraReviews = @($app.extraReviews)
      extraReviewError = if (![string]::IsNullOrWhiteSpace($app.extraReviewError)) { [string]$app.extraReviewError } else { "" }
      submittedAt = $app.submittedAt
      updatedAt = $app.updatedAt
      owner = $account.owner
      notes = ""
    }
    Update-AppStatusTiming $newApps[-1] $null $detectedAt
    Update-ExtraReviewTiming $newApps[-1] $null $detectedAt
  }

  $addedApps = @(Invoke-DbLocked {
    $latestDb = Read-Db
    $latestAccount = $latestDb.accounts | Where-Object { $_.id -eq $account.id } | Select-Object -First 1
    if (!$latestAccount) { throw "Account does not exist." }
    $latestExistingMap = @{}
    foreach ($latestApp in @($latestDb.apps | Where-Object { $_.accountId -eq $account.id })) {
      $latestKey = Get-AppIdentityKey $latestApp
      if (![string]::IsNullOrWhiteSpace($latestKey)) { $latestExistingMap[$latestKey] = $true }
    }
    $appsToAdd = @()
    foreach ($newApp in @($newApps)) {
      $newKey = Get-AppIdentityKey $newApp
      if (![string]::IsNullOrWhiteSpace($newKey) -and -not $latestExistingMap.ContainsKey($newKey)) {
        $appsToAdd += $newApp
        $latestExistingMap[$newKey] = $true
      }
    }
    if ($appsToAdd.Count -gt 0) {
      $latestDb.apps += @($appsToAdd)
      Update-AlertsForApps $latestDb $latestAccount $appsToAdd
    }
    $now = Get-NowIso
    $latestAccount.status = "connected"
    $latestAccount.lastError = ""
    $latestAccount.updatedAt = $now
    Set-NextAppDiscovery $latestDb $latestAccount (Get-AppDiscoveryIntervalHours $latestDb)
    $latestDb.syncLogs += [ordered]@{
      id = New-Id "log"
      level = "success"
      accountId = $account.id
      message = "$($account.name) app discovery succeeded, found $(@($appsToAdd).Count) new apps"
      createdAt = Get-NowIso
    }
    Write-Db $latestDb
    return @($appsToAdd)
  })

  return [ordered]@{
    accountId = $account.id
    accountName = $account.name
    count = @($addedApps).Count
    changes = @()
  }
}

function Record-SyncFailure([string]$TargetAccountId, [string]$RawMessage, [string]$Title, [string]$FailureKind = "sync") {
  $db = Read-Db
  $target = $db.accounts | Where-Object { $_.id -eq $TargetAccountId } | Select-Object -First 1
  if (!$target) { return Get-FriendlySyncError $RawMessage }
  $friendlyError = Get-FriendlySyncError $RawMessage
  Invoke-DbLocked {
    $latestDb = Read-Db
    $latestTarget = $latestDb.accounts | Where-Object { $_.id -eq $TargetAccountId } | Select-Object -First 1
    if (!$latestTarget) { return }
    $retryMinutes = Get-FailureRetryMinutes $RawMessage
    if ($FailureKind -eq "discover") {
      $latestTarget.nextAppDiscoveryAt = [DateTime]::UtcNow.AddMinutes($retryMinutes).ToString("o")
      $latestTarget.updatedAt = Get-NowIso
      $latestDb.syncLogs += [ordered]@{
        id = New-Id "log"
        level = "error"
        accountId = $target.id
        message = "$($target.name) app discovery failed: $friendlyError"
        createdAt = Get-NowIso
      }
      Write-Db $latestDb
      return
    } else {
      $latestTarget.status = "error"
      $latestTarget.lastError = $friendlyError
      $latestTarget.updatedAt = Get-NowIso
      Set-NextAutoSync $latestDb $latestTarget $retryMinutes
    }
    Add-Alert $latestDb ([ordered]@{
      key = "sync:$($target.id)"
      severity = "high"
      type = "SYNC_FAILED"
      accountId = $target.id
      accountName = $target.name
      title = $Title
      message = $friendlyError
    })
    $latestDb.syncLogs += [ordered]@{
      id = New-Id "log"
      level = "error"
      accountId = $target.id
      message = "$($target.name) sync failed: $friendlyError"
      createdAt = Get-NowIso
    }
    Write-Db $latestDb
  }
  return $friendlyError
}

function Write-Result($Result) {
  if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    ConvertTo-JsonText $Result | Write-Output
    return
  }
  $dir = Split-Path -Parent $ResultPath
  if (![string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  ConvertTo-JsonText $Result | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

try {
  $db = Read-Db
  $apiAccounts = @($db.accounts | Where-Object {
    ![string]::IsNullOrWhiteSpace([string]$_.issuerId) -and
    ![string]::IsNullOrWhiteSpace([string]$_.keyId) -and
    ![string]::IsNullOrWhiteSpace([string]$_.privateKeyEnc)
  })
  $targetAccounts = @()
  $targetModes = @{}
  if ($Mode -eq "selected") {
    $targetAccounts = @($db.accounts | Where-Object { $_.id -eq $AccountId } | Select-Object -First 1)
  } elseif ($Mode -eq "discover") {
    if (![string]::IsNullOrWhiteSpace($AccountId)) {
      $targetAccounts = @($db.accounts | Where-Object { $_.id -eq $AccountId } | Select-Object -First 1)
    } else {
      $targetAccounts = @($apiAccounts)
    }
    foreach ($account in @($targetAccounts)) {
      if ($null -ne $account) { $targetModes[[string]$account.id] = "discover" }
    }
  } elseif ($Mode -eq "auto") {
    $now = [DateTime]::UtcNow
    $dueStatus = @()
    $dueDiscover = @()
    $discoverEnabled = $false
    if ($null -ne $db.settings -and $null -ne $db.settings.autoDiscoverApps) {
      try { $discoverEnabled = [bool]$db.settings.autoDiscoverApps } catch { $discoverEnabled = $false }
    }
    foreach ($account in @($apiAccounts)) {
      $nextAt = $null
      if (![string]::IsNullOrWhiteSpace($account.nextAutoSyncAt)) {
        try { $nextAt = [DateTime]::Parse($account.nextAutoSyncAt).ToUniversalTime() } catch { $nextAt = $null }
      }
      if ($null -eq $nextAt -or $nextAt -le $now) {
        $dueStatus += $account
      }

      if ($discoverEnabled) {
        $nextDiscoverAt = $null
        if (![string]::IsNullOrWhiteSpace($account.nextAppDiscoveryAt)) {
          try { $nextDiscoverAt = [DateTime]::Parse($account.nextAppDiscoveryAt).ToUniversalTime() } catch { $nextDiscoverAt = $null }
        }
        if ($null -eq $nextDiscoverAt -or $nextDiscoverAt -le $now) {
          $dueDiscover += $account
        }
      }
    }
    $targetAccounts = @($dueStatus)
    foreach ($account in @($dueStatus)) {
      $targetModes[[string]$account.id] = "status"
    }
    $discoverAccount = @($dueDiscover | Where-Object { -not $targetModes.ContainsKey([string]$_.id) } | Select-Object -First 1)
    if ($discoverAccount.Count -gt 0) {
      $targetAccounts += $discoverAccount[0]
      $targetModes[[string]$discoverAccount[0].id] = "discover"
    }
  } else {
    $targetAccounts = @($apiAccounts)
  }
  if ($targetAccounts.Count -eq 0) {
    if ($Mode -eq "auto") {
      Write-Result ([ordered]@{
        ok = $true
        mode = $Mode
        accountId = $AccountId
        okCount = 0
        failCount = 0
        totalApps = 0
        changes = @()
        errors = @()
      })
      exit 0
    }
    throw "No account to sync."
  }

  $ok = 0
  $fail = 0
  $totalApps = 0
  $errors = @()
  $changes = @()

  foreach ($account in @($targetAccounts)) {
    $currentMode = $Mode
    try {
      if ($Mode -eq "auto") {
        $accountMode = if ($targetModes.ContainsKey([string]$account.id)) { $targetModes[[string]$account.id] } else { "status" }
        $currentMode = $accountMode
        if ($accountMode -eq "discover") {
          $syncResult = Discover-NewAppsWorker $account.id
        } else {
          $syncResult = Sync-AccountStatusWorker $account.id
        }
      } elseif ($Mode -eq "discover") {
        $currentMode = "discover"
        $syncResult = Discover-NewAppsWorker $account.id
      } else {
        $syncResult = Sync-AccountWorker $account.id
      }
      $ok++
      $totalApps += [int]$syncResult.count
      $changes += @($syncResult.changes)
    } catch {
      $fail++
      $failureKind = if ($currentMode -eq "discover") { "discover" } else { "sync" }
      $friendly = Record-SyncFailure $account.id ([string]$_.Exception.Message) "Account sync failed" $failureKind
      $errors += [ordered]@{
        accountId = $account.id
        accountName = $account.name
        message = $friendly
      }
    }
  }

  Write-Result ([ordered]@{
    ok = $true
    mode = $Mode
    accountId = $AccountId
    okCount = $ok
    failCount = $fail
    totalApps = $totalApps
    changes = @($changes)
    errors = @($errors)
  })
} catch {
  Write-Result ([ordered]@{
    ok = $false
    mode = $Mode
    accountId = $AccountId
    error = Get-FriendlySyncError ([string]$_.Exception.Message)
  })
  exit 1
}

