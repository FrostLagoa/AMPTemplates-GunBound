param(
    [string]$ServerRoot = "D:\Gunbound\Server",
    [string]$PythonExecutable = "D:\Python\Python310\python.exe",
    [string]$JavaExecutable = "C:\Program Files\Common Files\Oracle\Java\javapath\java.exe",
    [string]$CredentialStorePath = "D:\Gunbound\Server\config\iris-sql-vault.local.json",
    [string]$DatabaseHost = "127.0.0.1",
    [int]$DatabasePort = 3306,
    [string]$DatabaseName = "gunbound",
    [int]$BrokerPort = 8372,
    [int]$GamePort = 8360,
    [int]$BuddyPort = 8352,
    [int]$BuddyUdpPort = 8381,
    [string]$AutoRestart = "true",
    [int]$RestartLimit = 3,
    [int]$RestartBackoffSeconds = 3,
    [int]$ShutdownTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:stopping = $false
$script:exitCode = 0
$script:runtime = $null
$script:restartCount = 0

function ConvertTo-Switch {
    param([string]$Value)
    return @("1", "true", "yes", "on", "enabled") -contains $Value.Trim().ToLowerInvariant()
}

function Assert-SafePath {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOf('"') -ge 0) {
        throw "$Name is invalid"
    }
    return [IO.Path]::GetFullPath($Value)
}

$restartEnabled = ConvertTo-Switch $AutoRestart
$RestartLimit = [Math]::Max(0, [Math]::Min(10, $RestartLimit))
$RestartBackoffSeconds = [Math]::Max(1, [Math]::Min(60, $RestartBackoffSeconds))
$ShutdownTimeoutSeconds = [Math]::Max(5, [Math]::Min(120, $ShutdownTimeoutSeconds))
$ServerRoot = Assert-SafePath $ServerRoot "ServerRoot"
$PythonExecutable = Assert-SafePath $PythonExecutable "PythonExecutable"
$JavaExecutable = Assert-SafePath $JavaExecutable "JavaExecutable"
$CredentialStorePath = Assert-SafePath $CredentialStorePath "CredentialStorePath"
$DatabaseHost = $DatabaseHost.Trim()
$DatabaseName = $DatabaseName.Trim()
if ([string]::IsNullOrWhiteSpace($DatabaseHost) -or $DatabaseHost.IndexOf('"') -ge 0) {
    throw "DatabaseHost is invalid"
}
if ([string]::IsNullOrWhiteSpace($DatabaseName) -or $DatabaseName.IndexOf('"') -ge 0) {
    throw "DatabaseName is invalid"
}
if ($DatabasePort -lt 1 -or $DatabasePort -gt 65535) { throw "DatabasePort is invalid" }
$launcher = Join-Path $PSScriptRoot "gunbound-launcher.py"
$jar = Join-Path $ServerRoot "target\GunBoundJavaEmulator-1.0-SNAPSHOT-jar-with-dependencies.jar"

foreach ($required in @($ServerRoot)) {
    if (-not (Test-Path -LiteralPath $required -PathType Container)) {
        throw "Required folder does not exist: $required"
    }
}
foreach ($required in @($PythonExecutable, $JavaExecutable, $launcher, $jar, $CredentialStorePath, (Join-Path $ServerRoot "config\config.properties"))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required GunBound runtime file is missing: $required"
    }
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

function Test-UdpPort {
    param([int]$Port)
    try {
        return @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction Stop).Count -gt 0
    }
    catch { return $false }
}

function Start-GunBound {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PythonExecutable
    $startInfo.Arguments = ('"{0}" --server-root "{1}" --credential-store "{2}" --database-host "{3}" --database-port {4} --database-name "{5}" --java "{6}"' -f $launcher, $ServerRoot, $CredentialStorePath, $DatabaseHost, $DatabasePort, $DatabaseName, $JavaExecutable)
    $startInfo.WorkingDirectory = $ServerRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start the GunBound launcher" }
    $script:runtime = [pscustomobject]@{
        Process = $process
        StdoutTask = $process.StandardOutput.ReadLineAsync()
        StderrTask = $process.StandardError.ReadLineAsync()
        StartedAt = [DateTime]::UtcNow
    }
    [Console]::WriteLine(("[supervisor] STARTED pid={0}" -f $process.Id))
}

function Drain-GunBoundOutput {
    $state = $script:runtime
    if ($null -eq $state) { return }
    foreach ($stream in @(
        [pscustomobject]@{ TaskProperty = "StdoutTask"; Reader = $state.Process.StandardOutput; Prefix = "gunbound" },
        [pscustomobject]@{ TaskProperty = "StderrTask"; Reader = $state.Process.StandardError; Prefix = "gunbound:stderr" }
    )) {
        $task = $state.($stream.TaskProperty)
        while ($null -ne $task -and $task.IsCompleted) {
            try { $line = $task.GetAwaiter().GetResult() }
            catch {
                [Console]::WriteLine(("[{0}] OUTPUT_READ_FAILED {1}" -f $stream.Prefix, $_.Exception.Message))
                $line = $null
            }
            if ($null -eq $line) {
                $state.($stream.TaskProperty) = $null
                break
            }
            [Console]::WriteLine(("[{0}] {1}" -f $stream.Prefix, $line))
            $task = $stream.Reader.ReadLineAsync()
            $state.($stream.TaskProperty) = $task
        }
    }
}

function Test-GunBoundReady {
    return (Test-TcpPort -Port $BrokerPort) -and
        (Test-TcpPort -Port $GamePort) -and
        (Test-TcpPort -Port $BuddyPort) -and
        (Test-UdpPort -Port $BuddyUdpPort)
}

function Wait-GunBoundReady {
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    do {
        Drain-GunBoundOutput
        if ($script:runtime.Process.HasExited) {
            Drain-GunBoundOutput
            return $false
        }
        if (Test-GunBoundReady) { return $true }
        Start-Sleep -Milliseconds 400
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Write-GunBoundStatus {
    $running = $null -ne $script:runtime -and -not $script:runtime.Process.HasExited
    $pidText = if ($running) { [string]$script:runtime.Process.Id } else { "-" }
    $brokerReady = Test-TcpPort -Port $BrokerPort -TimeoutMilliseconds 200
    $gameReady = Test-TcpPort -Port $GamePort -TimeoutMilliseconds 200
    $buddyReady = Test-TcpPort -Port $BuddyPort -TimeoutMilliseconds 200
    $buddyUdpReady = Test-UdpPort -Port $BuddyUdpPort
    [Console]::WriteLine(("[supervisor] STATUS running={0} pid={1} broker={2} game={3} buddy={4} buddy_udp={5}" -f $running.ToString().ToLowerInvariant(), $pidText, $brokerReady.ToString().ToLowerInvariant(), $gameReady.ToString().ToLowerInvariant(), $buddyReady.ToString().ToLowerInvariant(), $buddyUdpReady.ToString().ToLowerInvariant()))
}

function Stop-Descendants {
    param([int]$ParentId)
    $children = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId={0}" -f $ParentId) -ErrorAction SilentlyContinue)
    foreach ($child in $children) { Stop-Descendants -ParentId ([int]$child.ProcessId) }
    foreach ($child in $children) {
        Stop-Process -Id ([int]$child.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

function Stop-GunBound {
    if ($script:stopping) { return }
    $script:stopping = $true
    $state = $script:runtime
    if ($null -eq $state -or $state.Process.HasExited) { return }
    [Console]::WriteLine("[supervisor] STOPPING")
    try {
        $state.Process.StandardInput.WriteLine("ampstop")
        $state.Process.StandardInput.Flush()
        [Console]::WriteLine("[supervisor] GRACEFUL_STOP_REQUESTED")
    }
    catch {
        [Console]::WriteLine(("[supervisor] GRACEFUL_STOP_FAILED {0}" -f $_.Exception.Message))
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
    while (-not $state.Process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Drain-GunBoundOutput
        Start-Sleep -Milliseconds 200
    }
    if (-not $state.Process.HasExited) {
        [Console]::WriteLine(("[supervisor] FORCE_STOP pid={0}" -f $state.Process.Id))
        Stop-Descendants -ParentId $state.Process.Id
        $state.Process.Kill()
        [void]$state.Process.WaitForExit(5000)
    }
    Drain-GunBoundOutput
    $state.Process.Dispose()
    [Console]::WriteLine("[supervisor] STOPPED")
}

function Send-IrisChatCommand {
    param([Parameter(Mandatory = $true)][string]$CommandText)
    $state = $script:runtime
    if ($null -eq $state -or $state.Process.HasExited) {
        [Console]::WriteLine("[supervisor] IRIS_CHAT_REJECTED runtime_unavailable")
        return
    }
    if ($CommandText -notmatch '^iris-chat ([A-Za-z0-9+/]{1,512}={0,2})$') {
        [Console]::WriteLine("[supervisor] IRIS_CHAT_REJECTED invalid_envelope")
        return
    }
    try {
        $bytes = [Convert]::FromBase64String($Matches[1])
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        $message = $strictUtf8.GetString($bytes)
        if (-not $message.StartsWith('Iris: ', [StringComparison]::Ordinal) -or
            $message.Length -gt 60 -or $message -match '[\x00-\x1F\x7F]') {
            [Console]::WriteLine("[supervisor] IRIS_CHAT_REJECTED invalid_message")
            return
        }
        $state.Process.StandardInput.WriteLine($CommandText)
        $state.Process.StandardInput.Flush()
        [Console]::WriteLine("[supervisor] IRIS_CHAT_FORWARDED")
    }
    catch {
        [Console]::WriteLine("[supervisor] IRIS_CHAT_REJECTED decode_failed")
    }
}

try {
    [Console]::WriteLine(("[supervisor] ROOT {0}" -f $ServerRoot))
    Start-GunBound
    if (-not (Wait-GunBoundReady)) {
        throw "GunBound did not open TCP ports $BrokerPort, $GamePort, $BuddyPort and UDP port $BuddyUdpPort within 180 seconds"
    }
    [Console]::WriteLine(("[supervisor] READY broker={0} game={1} buddy={2} buddy_udp={3}" -f $BrokerPort, $GamePort, $BuddyPort, $BuddyUdpPort))
    $inputClosed = $false
    $readTask = [Console]::In.ReadLineAsync()
    $keepRunning = $true
    while ($keepRunning -and -not $script:stopping) {
        Drain-GunBoundOutput
        if ($script:runtime.Process.HasExited) {
            $exitCode = $script:runtime.Process.ExitCode
            $lifetime = ([DateTime]::UtcNow - $script:runtime.StartedAt).TotalSeconds
            [Console]::WriteLine(("[supervisor] EXITED code={0} lifetime_seconds={1:N1}" -f $exitCode, $lifetime))
            $script:runtime.Process.Dispose()
            $script:runtime = $null
            if (-not $restartEnabled) { throw "GunBound exited and automatic restart is disabled" }
            if ($lifetime -ge 300) { $script:restartCount = 0 }
            $script:restartCount++
            if ($script:restartCount -gt $RestartLimit) { throw "GunBound exceeded the restart limit" }
            $delay = [Math]::Min(60, $RestartBackoffSeconds * $script:restartCount)
            [Console]::WriteLine(("[supervisor] RESTARTING attempt={0}/{1} delay_seconds={2}" -f $script:restartCount, $RestartLimit, $delay))
            Start-Sleep -Seconds $delay
            Start-GunBound
            if (-not (Wait-GunBoundReady)) { throw "GunBound failed readiness after restart" }
            [Console]::WriteLine(("[supervisor] READY broker={0} game={1} buddy={2} buddy_udp={3}" -f $BrokerPort, $GamePort, $BuddyPort, $BuddyUdpPort))
        }
        if (-not $inputClosed -and $readTask.IsCompleted) {
            try { $line = $readTask.GetAwaiter().GetResult() } catch { $line = $null }
            if ($null -eq $line) { $inputClosed = $true }
            else {
                $commandText = $line.Trim()
                $normalizedCommand = $commandText.ToLowerInvariant()
                if ($normalizedCommand -in @("ampstop", "shutdown", "exit", "quit")) { $keepRunning = $false }
                elseif ($normalizedCommand -eq "status") { Write-GunBoundStatus }
                elseif ($normalizedCommand.StartsWith("iris-chat ")) { Send-IrisChatCommand -CommandText $commandText }
                elseif (-not [string]::IsNullOrWhiteSpace($commandText)) {
                    [Console]::WriteLine("[supervisor] Unsupported command. Use status, iris-chat, or AMP controls.")
                }
                $readTask = [Console]::In.ReadLineAsync()
            }
        }
        Start-Sleep -Milliseconds 200
    }
}
catch {
    [Console]::WriteLine(("[supervisor] FATAL type={0} message={1}" -f $_.Exception.GetType().FullName, $_.Exception.Message))
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        [Console]::WriteLine(("[supervisor] FATAL_STACK {0}" -f ($_.ScriptStackTrace -replace "[\r\n]+", " | ")))
    }
    $script:exitCode = 1
}
finally {
    Stop-GunBound
}

exit $script:exitCode
