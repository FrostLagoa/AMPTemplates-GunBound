param(
    [string]$ServerRoot = "D:\Gunbound",
    [string]$PythonExecutable = "D:\Python\Python310\python.exe",
    [string]$CredentialStorePath = "D:\Gunbound\config\iris-sql-vault.local.json",
    [string]$DatabaseHost = "127.0.0.1",
    [int]$DatabasePort = 3303,
    [string]$DatabaseName = "gunbound",
    [int]$DatabaseReadyGraceSeconds = 5,
    [int]$BrokerPort = 8400,
    [int]$GamePort = 8401,
    [int]$ShutdownTimeoutSeconds = 30,
    [string]$RuntimeTaskName = "Iris-GunBoundWC2",
    [string]$RuntimeLogPath = "D:\Gunbound\Logs\standalone-runtime.log",
    [string]$StopSignalPath = "D:\Gunbound\control\iris-stop.request",
    [string]$RuntimeStatePath = "D:\Gunbound\control\iris-runtime.json"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:runtimeLogOffset = 0L
$script:stopping = $false

function Assert-SafePath {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOf('"') -ge 0) { throw "$Name is invalid" }
    return [IO.Path]::GetFullPath($Value)
}

function Test-TcpPort {
    param([int]$Port, [int]$TimeoutMilliseconds = 500)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync("127.0.0.1", $Port)
        if (-not $connect.Wait($TimeoutMilliseconds)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Test-ListeningPort {
    param([int]$Port)
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Test-RuntimeHeartbeat {
    if (-not (Test-Path -LiteralPath $RuntimeStatePath -PathType Leaf)) { return $false }
    try {
        $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $RuntimeStatePath -Force).LastWriteTimeUtc).TotalSeconds
        return $age -ge -5 -and $age -le 30
    }
    catch { return $false }
}

function Ensure-CompatibilityDatabase {
    if (-not (Test-TcpPort -Port $DatabasePort)) {
        throw "GunBound MySQL 5.7 must be running separately on 127.0.0.1:$DatabasePort before AMP starts the game services"
    }
    [Console]::WriteLine("[supervisor] DATABASE reachable host=127.0.0.1 port=$DatabasePort owner=external-service")
}

function Wait-CompatibilityDatabaseStability {
    param([int]$Port, [int]$GraceSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($GraceSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-TcpPort -Port $Port)) { throw "GunBound MySQL 5.7 stopped responding during its startup grace period" }
        Start-Sleep -Milliseconds 250
    }
    [Console]::WriteLine("[supervisor] DATABASE stable host=127.0.0.1 port=$Port grace_seconds=$GraceSeconds")
}

function Ensure-LegacySettings {
    param([string]$Path)
    $defaults = @(
        "# Iris-managed, non-secret GunBound WC2 v894 settings.",
        "broker.port=$BrokerPort",
        "broker.lan.port=8402",
        "broker.lan.world.address=192.168.15.5",
        "broker.world.name=Kallidos Gunbound",
        "broker.world.description=Welcome to the Server!",
        "broker.world.address=server.kallidos.com",
        "broker.world.capacity=500",
        "broker.world.mode=0",
        "game.port=$GamePort",
        "game.max.connection=500"
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        [IO.File]::WriteAllLines($Path, $defaults, [Text.UTF8Encoding]::new($false))
        return
    }
    $lines = [Collections.Generic.List[string]]([IO.File]::ReadAllLines($Path))
    foreach ($default in $defaults) {
        if ($default.StartsWith("#") -or $default -notmatch "=") { continue }
        $key = $default.Split("=", 2)[0]
        if (-not ($lines | Where-Object { $_ -match ("^\s*" + [Regex]::Escape($key) + "\s*=") })) { $lines.Add($default) }
    }
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function Set-SettingValue {
    param([string]$Path, [string]$Key, [string]$Value)
    $lines = [Collections.Generic.List[string]]([IO.File]::ReadAllLines($Path))
    $pattern = "^\s*" + [Regex]::Escape($Key) + "\s*="
    $updated = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match $pattern) { $lines[$index] = "$Key=$Value"; $updated = $true; break }
    }
    if (-not $updated) { $lines.Add("$Key=$Value") }
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function Get-SettingInteger {
    param([string]$Path, [string]$Key, [int]$Minimum = 1, [int]$Maximum = 65535)
    $match = [IO.File]::ReadAllLines($Path) | Where-Object { $_ -match ("^\s*" + [Regex]::Escape($Key) + "\s*=") } | Select-Object -First 1
    if ($null -eq $match) { throw "Required setting $Key is missing" }
    $valueText = ($match -split "=", 2)[1].Trim()
    $value = 0
    if (-not [int]::TryParse($valueText, [ref]$value) -or $value -lt $Minimum -or $value -gt $Maximum) { throw "Setting $Key must be an integer between $Minimum and $Maximum" }
    return $value
}

function Get-RuntimeTask {
    try { return Get-ScheduledTask -TaskName $RuntimeTaskName -ErrorAction Stop }
    catch { throw "The local runtime task '$RuntimeTaskName' is not available to AMP. Run Install-GunBound-WC2-Task.ps1 once with UAC." }
}

function Start-RuntimeTask {
    Get-RuntimeTask | Out-Null
    if (Test-Path -LiteralPath $StopSignalPath -PathType Leaf) { Remove-Item -LiteralPath $StopSignalPath -Force }
    # Task Scheduler does not reliably expose the Running state of an
    # InteractiveToken task to NetworkService. IgnoreNew makes this idempotent.
    Start-ScheduledTask -TaskName $RuntimeTaskName -ErrorAction Stop
    [Console]::WriteLine("[supervisor] START requested task=$RuntimeTaskName owner=Kallidos")
}

function Stop-RuntimeTask {
    try {
        Get-RuntimeTask | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $StopSignalPath) -Force | Out-Null
        [IO.File]::WriteAllText($StopSignalPath, "stop`n", [Text.UTF8Encoding]::new($false))
        [Console]::WriteLine("[supervisor] STOP requested task=$RuntimeTaskName owner=Kallidos")
        $deadline = [DateTime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
        do { Start-Sleep -Milliseconds 250 } while ((Test-RuntimeHeartbeat) -and [DateTime]::UtcNow -lt $deadline)
        if (Test-RuntimeHeartbeat) { throw "Timed out waiting for the GunBound runtime heartbeat to stop" }
        & $PythonExecutable $launcher --server-root $ServerRoot --credential-store $CredentialStorePath --sanitize 2>&1 | ForEach-Object { [Console]::WriteLine("[runtime] $_") }
    }
    catch { [Console]::WriteLine("[supervisor] STOP warning=$($_.Exception.Message)") }
}

function Write-RuntimeLogTail {
    if (-not (Test-Path -LiteralPath $RuntimeLogPath -PathType Leaf)) { return }
    $stream = [IO.File]::Open($RuntimeLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -lt $script:runtimeLogOffset) { $script:runtimeLogOffset = 0L }
        $stream.Seek($script:runtimeLogOffset, [IO.SeekOrigin]::Begin) | Out-Null
        $reader = [IO.StreamReader]::new($stream)
        try {
            while (($line = $reader.ReadLine()) -ne $null) { [Console]::WriteLine("[runtime] $line") }
            $script:runtimeLogOffset = $stream.Position
        }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Wait-GunBoundReady {
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while ([DateTime]::UtcNow -lt $deadline) {
        Write-RuntimeLogTail
        if (Test-RuntimeHeartbeat) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Test-GunBoundPorts {
    param([int]$LanBrokerPort)
    return (Test-ListeningPort -Port $BrokerPort) -and (Test-ListeningPort -Port $LanBrokerPort) -and (Test-ListeningPort -Port $GamePort)
}

$ShutdownTimeoutSeconds = [Math]::Max(5, [Math]::Min(120, $ShutdownTimeoutSeconds))
$DatabaseReadyGraceSeconds = [Math]::Max(1, [Math]::Min(30, $DatabaseReadyGraceSeconds))
$ServerRoot = Assert-SafePath $ServerRoot "ServerRoot"
$PythonExecutable = Assert-SafePath $PythonExecutable "PythonExecutable"
$CredentialStorePath = Assert-SafePath $CredentialStorePath "CredentialStorePath"
$RuntimeLogPath = Assert-SafePath $RuntimeLogPath "RuntimeLogPath"
$StopSignalPath = Assert-SafePath $StopSignalPath "StopSignalPath"
$RuntimeStatePath = Assert-SafePath $RuntimeStatePath "RuntimeStatePath"
if ($RuntimeTaskName -notmatch '^[A-Za-z0-9_.-]+$') { throw "RuntimeTaskName is invalid" }
if ([string]::IsNullOrWhiteSpace($DatabaseHost) -or [string]::IsNullOrWhiteSpace($DatabaseName) -or $DatabasePort -lt 1 -or $DatabasePort -gt 65535) { throw "The database endpoint is invalid" }

& (Join-Path $PSScriptRoot "amp-config-link.ps1") -ServerRoot $ServerRoot
$launcher = Join-Path $PSScriptRoot "legacy-gunbound-launcher.py"
$settings = Join-Path $ServerRoot "iris-legacy-settings.properties"
foreach ($required in @($PythonExecutable, $CredentialStorePath, $launcher, (Join-Path $ServerRoot "BrokerServer\BrokerServer.exe"), (Join-Path $ServerRoot "GameServer\GameServer.exe"))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required WC2 runtime file is missing: $required" }
}
Ensure-LegacySettings -Path $settings
Set-SettingValue -Path $settings -Key "broker.port" -Value ([string]$BrokerPort)
Set-SettingValue -Path $settings -Key "game.port" -Value ([string]$GamePort)
$LanBrokerPort = Get-SettingInteger -Path $settings -Key "broker.lan.port"
if ($LanBrokerPort -eq $BrokerPort -or $LanBrokerPort -eq $GamePort) { throw "The LAN Broker port must differ from the external Broker and Game Server ports" }

try {
    Ensure-CompatibilityDatabase
    Wait-CompatibilityDatabaseStability -Port $DatabasePort -GraceSeconds $DatabaseReadyGraceSeconds
    Start-RuntimeTask
    if (-not (Wait-GunBoundReady)) { throw "GunBound WC2 did not publish its runtime heartbeat within 120 seconds" }
    [Console]::WriteLine("[supervisor] READY external_broker=$BrokerPort lan_broker=$LanBrokerPort game=$GamePort")
    while ($true) {
        Write-RuntimeLogTail
        if (-not (Test-RuntimeHeartbeat)) { throw "GunBound WC2 stopped publishing its runtime heartbeat" }
        if (-not (Test-TcpPort -Port $DatabasePort)) { throw "GunBound MySQL 5.7 is no longer listening on TCP port $DatabasePort" }
        Start-Sleep -Seconds 1
    }
}
finally {
    Stop-RuntimeTask
    [Console]::WriteLine("[supervisor] STOPPED")
}
