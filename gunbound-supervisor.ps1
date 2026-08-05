param(
    [string]$ServerRoot = "D:\Gunbound",
    [string]$PythonExecutable = "D:\Python\Python310\python.exe",
    [string]$CredentialStorePath = "D:\Gunbound\config\iris-sql-vault.local.json",
    [string]$DatabaseHost = "127.0.0.1",
    [int]$DatabasePort = 3303,
    [string]$DatabaseName = "gunbound",
    [string]$CompatibilityMySqlExecutable = "D:\Laragon\bin\mysql\mysql-5.7.44-winx64\bin\mysqld.exe",
    [string]$CompatibilityMySqlConfig = "D:\Laragon\bin\mysql\mysql-5.7.44-winx64\my-gunbound.ini",
    [int]$BrokerPort = 8400,
    [int]$GamePort = 8401,
    [string]$AutoRestart = "true",
    [int]$RestartLimit = 3,
    [int]$RestartBackoffSeconds = 3,
    [int]$ShutdownTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:stopping = $false
$script:runtime = $null
$script:compatibilityDatabase = $null
$script:restartCount = 0

function ConvertTo-Switch {
    param([string]$Value)
    return @("1", "true", "yes", "on", "enabled") -contains $Value.Trim().ToLowerInvariant()
}

function Assert-SafePath {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOf('"') -ge 0) { throw "$Name is invalid" }
    return [IO.Path]::GetFullPath($Value)
}

function Test-TcpPort {
    param([int]$Port, [int]$TimeoutMilliseconds = 500)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync("127.0.0.1", $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Ensure-CompatibilityDatabase {
    if (Test-TcpPort -Port $DatabasePort) {
        [Console]::WriteLine("[supervisor] DATABASE ready host=127.0.0.1 port=$DatabasePort owner=existing")
        return
    }
    $executable = Assert-SafePath $CompatibilityMySqlExecutable "CompatibilityMySqlExecutable"
    $configuration = Assert-SafePath $CompatibilityMySqlConfig "CompatibilityMySqlConfig"
    foreach ($required in @($executable, $configuration)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required GunBound compatibility MySQL file is missing: $required"
        }
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executable
    $startInfo.Arguments = ('--defaults-file="{0}"' -f $configuration)
    $startInfo.WorkingDirectory = Split-Path -Parent $executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start the GunBound compatibility MySQL service" }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) { throw "GunBound compatibility MySQL exited during startup ($($process.ExitCode))" }
        if (Test-TcpPort -Port $DatabasePort) {
            $script:compatibilityDatabase = $process
            [Console]::WriteLine("[supervisor] DATABASE ready host=127.0.0.1 port=$DatabasePort owner=AMP")
            return
        }
        Start-Sleep -Milliseconds 250
    }
    try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    throw "GunBound compatibility MySQL did not open TCP port $DatabasePort within 30 seconds"
}

function Ensure-LegacySettings {
    param([string]$Path)
    $defaults = @(
        "# Iris-managed, non-secret GunBound WC2 v894 settings.",
        "broker.port=$BrokerPort",
        "broker.world.name=Kallidos Gunbound",
        "broker.world.description=Welcome to the Server!",
        "broker.world.address=server.kallidos.com",
        "broker.world.capacity=500",
        "broker.world.mode=0",
        "game.port=$GamePort",
        "game.max.connection=500",
        "game.golf.factor=100",
        "game.score.factor=100",
        "game.grade.first=19",
        "game.grade.last=19",
        "game.function.restriction=1040384",
        "game.enable_item2=false",
        "game.channel.message=Welcome!",
        "game.room.message=Welcome!",
        "game.server.classic=0",
        "game.item.seal=30",
        "game.item.enchant.1_4=60",
        "game.item.enchant.5_8=50",
        "game.item.enchant.9_12=40",
        "game.item.enchant.13_16=30",
        "game.item.enchant.17_18=20",
        "game.item.enchant.19_20=10",
        "game.item.enchant.21_30=5",
        "client.version.first=1",
        "client.checksum=0",
        "event.actprop.0=0",
        "event.actprop.1=0",
        "event.actprop.2=0",
        "event.actprop.3=0",
        "event.cash.win_reward=250",
        "event.cash.lose_reward=100",
        "event.cash.enabled=false",
        "event.cash.expire=0",
        "diagnostics.log_packets=false"
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        [IO.File]::WriteAllLines($Path, $defaults, [Text.UTF8Encoding]::new($false))
        return
    }
    $lines = [Collections.Generic.List[string]]([IO.File]::ReadAllLines($Path))
    foreach ($default in $defaults) {
        if ($default.StartsWith("#") -or $default -notmatch "=") { continue }
        $key = $default.Split("=", 2)[0]
        $pattern = "^\s*" + [Regex]::Escape($key) + "\s*="
        if (-not ($lines | Where-Object { $_ -match $pattern })) { $lines.Add($default) }
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

function Get-DescendantProcessIds {
    param([int]$RootProcessId)
    $children = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ParentProcessId -eq $RootProcessId })
    $result = @()
    foreach ($child in $children) {
        $result += Get-DescendantProcessIds -RootProcessId ([int]$child.ProcessId)
        $result += [int]$child.ProcessId
    }
    return $result
}

function Stop-ProcessTree {
    param([Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    $descendants = @(Get-DescendantProcessIds -RootProcessId $Process.Id | Sort-Object -Descending -Unique)
    foreach ($processId in $descendants) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
    if (-not $Process.HasExited) {
        try { $Process.StandardInput.WriteLine("ampstop"); $Process.StandardInput.Flush() } catch {}
        if (-not $Process.WaitForExit($ShutdownTimeoutSeconds * 1000)) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
    }
}

$restartEnabled = ConvertTo-Switch $AutoRestart
$RestartLimit = [Math]::Max(0, [Math]::Min(10, $RestartLimit))
$RestartBackoffSeconds = [Math]::Max(1, [Math]::Min(60, $RestartBackoffSeconds))
$ShutdownTimeoutSeconds = [Math]::Max(5, [Math]::Min(120, $ShutdownTimeoutSeconds))
$ServerRoot = Assert-SafePath $ServerRoot "ServerRoot"
$PythonExecutable = Assert-SafePath $PythonExecutable "PythonExecutable"
$CredentialStorePath = Assert-SafePath $CredentialStorePath "CredentialStorePath"
$CompatibilityMySqlExecutable = Assert-SafePath $CompatibilityMySqlExecutable "CompatibilityMySqlExecutable"
$CompatibilityMySqlConfig = Assert-SafePath $CompatibilityMySqlConfig "CompatibilityMySqlConfig"
$DatabaseHost = $DatabaseHost.Trim()
$DatabaseName = $DatabaseName.Trim()
if ([string]::IsNullOrWhiteSpace($DatabaseHost) -or [string]::IsNullOrWhiteSpace($DatabaseName) -or $DatabasePort -lt 1 -or $DatabasePort -gt 65535) {
    throw "The database endpoint is invalid"
}
& (Join-Path $PSScriptRoot "amp-config-link.ps1") -ServerRoot $ServerRoot
$launcher = Join-Path $PSScriptRoot "legacy-gunbound-launcher.py"
$settings = Join-Path $ServerRoot "iris-legacy-settings.properties"
foreach ($required in @($PythonExecutable, $CredentialStorePath, $launcher, (Join-Path $ServerRoot "BrokerServer\BrokerServer.exe"), (Join-Path $ServerRoot "GameServer\GameServer.exe"))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required WC2 runtime file is missing: $required" }
}
Ensure-LegacySettings -Path $settings
Set-SettingValue -Path $settings -Key "broker.port" -Value ([string]$BrokerPort)
Set-SettingValue -Path $settings -Key "game.port" -Value ([string]$GamePort)
Ensure-CompatibilityDatabase

function Start-GunBound {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PythonExecutable
    $startInfo.Arguments = ('"{0}" --server-root "{1}" --credential-store "{2}" --database-host "{3}" --database-port {4} --database-name "{5}"' -f $launcher, $ServerRoot, $CredentialStorePath, $DatabaseHost, $DatabasePort, $DatabaseName)
    $startInfo.WorkingDirectory = $ServerRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start the GunBound WC2 launcher" }
    $script:runtime = [pscustomobject]@{
        Process = $process
        StdoutTask = $process.StandardOutput.ReadLineAsync()
        StderrTask = $process.StandardError.ReadLineAsync()
    }
    [Console]::WriteLine("[supervisor] STARTED launcher_pid=$($process.Id)")
}

function Drain-GunBoundOutput {
    if ($null -eq $script:runtime) { return }
    foreach ($stream in @(
        [pscustomobject]@{ TaskProperty = "StdoutTask"; Reader = $script:runtime.Process.StandardOutput; Prefix = "gunbound" },
        [pscustomobject]@{ TaskProperty = "StderrTask"; Reader = $script:runtime.Process.StandardError; Prefix = "gunbound:stderr" }
    )) {
        $task = $script:runtime.($stream.TaskProperty)
        while ($null -ne $task -and $task.IsCompleted) {
            $line = $task.GetAwaiter().GetResult()
            if ($null -ne $line) { [Console]::WriteLine("[$($stream.Prefix)] $line") }
            $script:runtime.($stream.TaskProperty) = $stream.Reader.ReadLineAsync()
            $task = $script:runtime.($stream.TaskProperty)
        }
    }
}

function Wait-GunBoundReady {
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while ([DateTime]::UtcNow -lt $deadline) {
        Drain-GunBoundOutput
        if ($script:runtime.Process.HasExited) { return $false }
        if ((Test-TcpPort -Port $BrokerPort) -and (Test-TcpPort -Port $GamePort)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Write-GunBoundStatus {
    $state = if ($null -ne $script:runtime -and -not $script:runtime.Process.HasExited) { "running" } else { "stopped" }
    [Console]::WriteLine("[supervisor] STATUS state=$state broker=$BrokerPort game=$GamePort restarts=$script:restartCount")
}

try {
    while (-not $script:stopping) {
        Start-GunBound
        if (-not (Wait-GunBoundReady)) { throw "GunBound WC2 did not open TCP ports $BrokerPort and $GamePort within 120 seconds" }
        [Console]::WriteLine("[supervisor] READY broker=$BrokerPort game=$GamePort")
        while (-not $script:runtime.Process.HasExited) {
            Drain-GunBoundOutput
            if (-not (Test-TcpPort -Port $DatabasePort)) {
                throw "GunBound compatibility MySQL is no longer listening on TCP port $DatabasePort"
            }
            Start-Sleep -Milliseconds 100
        }
        Drain-GunBoundOutput
        if ($script:stopping) { break }
        $exitCode = $script:runtime.Process.ExitCode
        if (-not $restartEnabled -or $script:restartCount -ge $RestartLimit) { throw "GunBound WC2 launcher exited unexpectedly ($exitCode)" }
        $script:restartCount++
        [Console]::WriteLine("[supervisor] RECOVERY attempt=$script:restartCount delay=$RestartBackoffSeconds")
        Start-Sleep -Seconds $RestartBackoffSeconds
    }
}
finally {
    if ($null -ne $script:runtime) { Stop-ProcessTree -Process $script:runtime.Process }
    if ($null -ne $script:compatibilityDatabase -and -not $script:compatibilityDatabase.HasExited) {
        try { Stop-Process -Id $script:compatibilityDatabase.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    [Console]::WriteLine("[supervisor] STOPPED")
}
