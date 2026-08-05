[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'start', 'stop', 'down', 'restart', 'status', 'test', 'logs', 'config', 'doctor', 'repair', 'help')]
    [string]$Command = 'up'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = if ($env:HAUHAU_VOICE_STACK_CONFIG) {
    $env:HAUHAU_VOICE_STACK_CONFIG
} else {
    Join-Path $InstallDir 'config.ps1'
}
$StateDir = if ($env:HAUHAU_VOICE_STACK_STATE) {
    $env:HAUHAU_VOICE_STACK_STATE
} else {
    Join-Path $InstallDir 'state'
}

$LlmPidFile = Join-Path $StateDir 'llm.pid'
$ProxyPidFile = Join-Path $StateDir 'proxy.pid'
$LlmLog = Join-Path $StateDir 'llm.log'
$LlmErrorLog = Join-Path $StateDir 'llm.error.log'
$ProxyLog = Join-Path $StateDir 'proxy.log'
$ProxyErrorLog = Join-Path $StateDir 'proxy.error.log'
$TtsLog = Join-Path $StateDir 'tts.log'
$TtsErrorLog = Join-Path $StateDir 'tts.error.log'
$TtsPidFile = Join-Path $StateDir 'tts.pid'

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    throw "Missing config: $ConfigFile`nRun install.ps1 again."
}
. $ConfigFile

$PublicUrl = if (Get-Variable -Name PUBLIC_URL -ErrorAction SilentlyContinue) { $PUBLIC_URL } else { 'http://127.0.0.1:8080' }
$BackendUrl = if (Get-Variable -Name BACKEND_URL -ErrorAction SilentlyContinue) { $BACKEND_URL } else { 'http://127.0.0.1:8082' }
$TtsUrl = if (Get-Variable -Name TTS_URL -ErrorAction SilentlyContinue) { $TTS_URL } else { 'http://127.0.0.1:9080' }
$TtsSpeed = if (Get-Variable -Name TTS_SPEED -ErrorAction SilentlyContinue) { [double]$TTS_SPEED } else { 0.94 }
$LlmStartupTimeout = if (Get-Variable -Name LLM_STARTUP_TIMEOUT -ErrorAction SilentlyContinue) { [int]$LLM_STARTUP_TIMEOUT } else { 900 }
$TtsStartupTimeout = if (Get-Variable -Name TTS_STARTUP_TIMEOUT -ErrorAction SilentlyContinue) { [int]$TTS_STARTUP_TIMEOUT } else { 1200 }
$ProxyStartupTimeout = if (Get-Variable -Name PROXY_STARTUP_TIMEOUT -ErrorAction SilentlyContinue) { [int]$PROXY_STARTUP_TIMEOUT } else { 30 }

if (-not (Get-Variable -Name LLM_COMMAND_LINE -ErrorAction SilentlyContinue) -or [string]::IsNullOrWhiteSpace($LLM_COMMAND_LINE)) {
    throw "LLM_COMMAND_LINE is missing from $ConfigFile"
}
if (-not (Get-Variable -Name PYTHON_COMMAND_LINE -ErrorAction SilentlyContinue) -or [string]::IsNullOrWhiteSpace($PYTHON_COMMAND_LINE)) {
    $PYTHON_COMMAND_LINE = 'py -3'
}
if (-not (Get-Variable -Name TTS_START_COMMAND_LINE -ErrorAction SilentlyContinue)) { $TTS_START_COMMAND_LINE = '' }
if (-not (Get-Variable -Name TTS_STOP_COMMAND_LINE -ErrorAction SilentlyContinue)) { $TTS_STOP_COMMAND_LINE = '' }

function Test-HttpReady {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3 -Method Get
        return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
    } catch {
        return $false
    }
}

function Test-BackendReady { Test-HttpReady "$BackendUrl/v1/models" }
function Test-TtsReady { Test-HttpReady "$TtsUrl/health" }
function Test-ProxyReady { Test-HttpReady "$PublicUrl/__voice/status" }

function Wait-UntilReady {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][scriptblock]$Check,
        [string[]]$LogFiles = @()
    )
    Write-Host -NoNewline "Waiting for $Name"
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextDot = 10
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Check) {
            Write-Host ' ready.'
            return
        }
        Start-Sleep -Seconds 2
        if ($watch.Elapsed.TotalSeconds -ge $nextDot) {
            Write-Host -NoNewline '.'
            $nextDot += 10
        }
    }
    Write-Host ''
    Write-Warning "$Name did not become ready within $TimeoutSeconds seconds."
    foreach ($file in $LogFiles) {
        if (Test-Path -LiteralPath $file) {
            Write-Host "--- $file ---"
            Get-Content -LiteralPath $file -Tail 80 -ErrorAction SilentlyContinue
        }
    }
    throw "$Name startup failed."
}

function Get-StoredPid {
    param([Parameter(Mandatory)][string]$PidFile)
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    $rawValue = Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue
    if ($null -eq $rawValue) { return $null }
    $raw = $rawValue.Trim()
    if ($raw -notmatch '^\d+$') { return $null }
    return [int]$raw
}

function Test-ProcessAlive {
    param([Parameter(Mandatory)][int]$ProcessId)
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Stop-ProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not (Test-ProcessAlive $ProcessId)) { return }
    & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
}

function Start-ManagedCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$PidFile,
        [Parameter(Mandatory)][string]$StdoutLog,
        [Parameter(Mandatory)][string]$StderrLog
    )
    Set-Content -LiteralPath $StdoutLog -Value '' -Encoding utf8
    Set-Content -LiteralPath $StderrLog -Value '' -Encoding utf8
    $launcher = Join-Path $StateDir ("launch-{0}.cmd" -f $Name.ToLowerInvariant().Replace(' ', '-'))
    $content = @(
        '@echo off',
        'setlocal',
        'cd /d "' + $InstallDir.Replace('"', '""') + '"',
        $CommandLine + ' 1>>"' + $StdoutLog.Replace('"', '""') + '" 2>>"' + $StderrLog.Replace('"', '""') + '"'
    )
    Set-Content -LiteralPath $launcher -Value $content -Encoding ascii
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', ('"{0}"' -f $launcher)) -WorkingDirectory $InstallDir -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $PidFile -Value $process.Id -Encoding ascii
}

function Get-BackendCommandLine {
    $commandLine = [string]$LLM_COMMAND_LINE
    $pattern = '(?i)(^|\s)(--port|-p)(?:=|\s+)\d+'
    if ([regex]::IsMatch($commandLine, $pattern)) {
        return [regex]::Replace(
            $commandLine,
            $pattern,
            { param($match) "$($match.Groups[1].Value)$($match.Groups[2].Value) 8082" },
            1
        )
    }
    return "$commandLine --port 8082"
}

function Get-ProxyCommandLine {
    $script = Join-Path $InstallDir 'voice_proxy.py'
    $audio = Join-Path $InstallDir 'audio'
    return ('{0} "{1}" --listen-port 8080 --backend-port 8082 --tts-port 9080 --speed {2} --cache-dir "{3}"' -f `
        $PYTHON_COMMAND_LINE,
        $script.Replace('"', '\"'),
        $TtsSpeed.ToString([Globalization.CultureInfo]::InvariantCulture),
        $audio.Replace('"', '\"'))
}

function Start-Backend {
    if (Test-BackendReady) {
        Write-Host "HauHauCS backend already ready at $BackendUrl"
        return
    }
    Write-Host "Starting HauHauCS backend on $BackendUrl ..."
    Start-ManagedCommand -Name 'llm' -CommandLine (Get-BackendCommandLine) -PidFile $LlmPidFile -StdoutLog $LlmLog -StderrLog $LlmErrorLog
    Wait-UntilReady -Name 'HauHauCS backend' -TimeoutSeconds $LlmStartupTimeout -Check ${function:Test-BackendReady} -LogFiles @($LlmLog, $LlmErrorLog)
}

function Start-Tts {
    if (Test-TtsReady) {
        Write-Host "Qwen TTS already ready at $TtsUrl"
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$TTS_START_COMMAND_LINE)) {
        throw "TTS is not running and TTS_START_COMMAND_LINE is blank in $ConfigFile"
    }
    Write-Host "Starting Qwen TTS on $TtsUrl ..."
    Start-ManagedCommand -Name 'tts' -CommandLine ([string]$TTS_START_COMMAND_LINE) -PidFile $TtsPidFile -StdoutLog $TtsLog -StderrLog $TtsErrorLog
    Wait-UntilReady -Name 'Qwen TTS' -TimeoutSeconds $TtsStartupTimeout -Check ${function:Test-TtsReady} -LogFiles @($TtsLog, $TtsErrorLog)
}

function Start-Proxy {
    if (Test-ProxyReady) {
        Write-Host "Voice proxy already ready at $PublicUrl"
        return
    }
    Write-Host "Starting automatic voice proxy on $PublicUrl ..."
    Start-ManagedCommand -Name 'proxy' -CommandLine (Get-ProxyCommandLine) -PidFile $ProxyPidFile -StdoutLog $ProxyLog -StderrLog $ProxyErrorLog
    Wait-UntilReady -Name 'voice proxy' -TimeoutSeconds $ProxyStartupTimeout -Check ${function:Test-ProxyReady} -LogFiles @($ProxyLog, $ProxyErrorLog)
}

function Stop-LegacyPublicBackend {
    $legacy = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^llama-server(\.exe)?$' -and
            $_.CommandLine -and
            $_.CommandLine -match '(--port|-p)(=|\s+)8080'
        }
    foreach ($process in $legacy) {
        Write-Host "Stopping the existing llama-server on port 8080 (PID $($process.ProcessId)) ..."
        Stop-ProcessTree ([int]$process.ProcessId)
    }
    if ($legacy) { Start-Sleep -Seconds 1 }
}

function Start-All {
    Stop-LegacyPublicBackend
    Start-Backend
    Start-Tts
    Start-Proxy
    Write-Host ''
    Show-Status
}

function Stop-Proxy {
    $storedPid = Get-StoredPid $ProxyPidFile
    if ($null -ne $storedPid) { Stop-ProcessTree $storedPid }
    Remove-Item -LiteralPath $ProxyPidFile -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'voice_proxy\.py' -and $_.CommandLine -match 'backend-port\s+8082' } |
        ForEach-Object { Stop-ProcessTree ([int]$_.ProcessId) }
    Write-Host 'Voice proxy stopped.'
}

function Stop-Tts {
    if (-not [string]::IsNullOrWhiteSpace([string]$TTS_STOP_COMMAND_LINE)) {
        try { & $env:ComSpec /d /s /c ([string]$TTS_STOP_COMMAND_LINE) | Out-Null } catch { }
    }
    $storedPid = Get-StoredPid $TtsPidFile
    if ($null -ne $storedPid) { Stop-ProcessTree $storedPid }
    Remove-Item -LiteralPath $TtsPidFile -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^crispasr(\.exe)?$' -and
            $_.CommandLine -and
            $_.CommandLine -match '(?i)--server' -and
            $_.CommandLine -match '(?i)--port(?:=|\s+)9080(?:\s|$)'
        } |
        ForEach-Object { Stop-ProcessTree ([int]$_.ProcessId) }
    Write-Host 'Qwen TTS stopped.'
}

function Stop-Backend {
    $storedPid = Get-StoredPid $LlmPidFile
    if ($null -ne $storedPid) { Stop-ProcessTree $storedPid }
    Remove-Item -LiteralPath $LlmPidFile -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^llama-server(\.exe)?$' -and $_.CommandLine -and $_.CommandLine -match '(--port|-p)(=|\s+)8082' } |
        ForEach-Object { Stop-ProcessTree ([int]$_.ProcessId) }
    Write-Host 'HauHauCS backend stopped.'
}

function Stop-All {
    Write-Host 'Stopping HauHau voice stack ...'
    Stop-Proxy
    Stop-Tts
    Stop-Backend
    Write-Host 'Everything is down.'
}

function Write-StatusLine {
    param([string]$Label, [bool]$Ready, [string]$Url)
    $state = if ($Ready) { 'READY' } else { 'STOPPED' }
    Write-Host ('{0,-20} {1,-8} {2}' -f $Label, $state, $Url)
}

function Show-Status {
    Write-Host 'HauHau automatic voice stack for Windows'
    Write-Host '----------------------------------------'
    Write-StatusLine 'Browser + voice' (Test-ProxyReady) $PublicUrl
    Write-StatusLine 'HauHauCS backend' (Test-BackendReady) $BackendUrl
    Write-StatusLine 'Qwen TTS' (Test-TtsReady) $TtsUrl
    Write-Host ('{0,-20} {1,-8} {2}' -f 'MCP adapter', 'DISABLED', 'not needed')
}

function Invoke-VoiceTest {
    if (-not (Test-ProxyReady)) { Start-All }
    $payload = @{ text = 'This is a direct test of the automatic HauHau voice bridge on Windows.' } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$PublicUrl/__voice/test" -Method Post -ContentType 'application/json' -Body $payload | ConvertTo-Json -Compress
    Write-Host 'Voice test queued. TTS generation can take a moment.'
}

function Open-Chat {
    Start-All
    Start-Process $PublicUrl
}

function Show-Logs {
    $files = @($LlmLog, $LlmErrorLog, $TtsLog, $TtsErrorLog, $ProxyLog, $ProxyErrorLog)
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file)) { New-Item -ItemType File -Path $file | Out-Null }
    }
    Write-Host 'Following backend, TTS, and proxy logs. Ctrl+C leaves services running.'
    Get-Content -LiteralPath $files -Tail 50 -Wait
}

function Get-ConfiguredExecutable {
    param([AllowEmptyString()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $trimmed = $CommandLine.Trim()
    if ($trimmed -match '^"([^"]+)"') { return $matches[1] }
    if ($trimmed -match '^([^\s]+)') { return $matches[1] }
    return ''
}

function Get-ConfiguredModel {
    param([AllowEmptyString()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $match = [regex]::Match($CommandLine, '(?i)(?:^|\s)(?:--model|-m)(?:=|\s+)(?:"([^"]+)"|([^\s]+))')
    if (-not $match.Success) { return '' }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Test-ConfiguredExecutable {
    param([AllowEmptyString()][string]$CommandLine)
    $exe = Get-ConfiguredExecutable -CommandLine $CommandLine
    if ([string]::IsNullOrWhiteSpace($exe)) { return $false }
    if (Test-Path -LiteralPath $exe) { return $true }
    return $null -ne (Get-Command $exe -ErrorAction SilentlyContinue)
}

function Resolve-ConfiguredExecutablePath {
    param([AllowEmptyString()][string]$CommandLine)
    $exe = Get-ConfiguredExecutable -CommandLine $CommandLine
    if ([string]::IsNullOrWhiteSpace($exe)) { return '' }
    if (Test-Path -LiteralPath $exe) { return (Resolve-Path -LiteralPath $exe).Path }
    $command = Get-Command $exe -ErrorAction SilentlyContinue
    if ($command) { return [string]$command.Source }
    return ''
}

function Test-NativeExecutable {
    param([AllowEmptyString()][string]$CommandLine)
    $exe = Resolve-ConfiguredExecutablePath -CommandLine $CommandLine
    if ([string]::IsNullOrWhiteSpace($exe)) { return $false }
    try {
        & $exe --help 1>$null 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Test-CrispAsrExecutable {
    param([AllowEmptyString()][string]$CommandLine)
    $exe = Resolve-ConfiguredExecutablePath -CommandLine $CommandLine
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
    try {
        # The installer verifies the official release digest before extraction. CrispASR's
        # --help command is not a reliable health probe because some builds return a
        # non-zero usage exit code. A valid PE executable of realistic size is the stable
        # offline dependency check; live readiness is checked separately over /health.
        $file = Get-Item -LiteralPath $exe
        return $file.Length -gt 1MB
    } catch {
        return $false
    }
}

function Test-GgufFile {
    param(
        [AllowEmptyString()][string]$Path,
        [long]$MinimumBytes = 1MB
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $file = Get-Item -LiteralPath $Path
        if ($file.Length -lt $MinimumBytes) { return $false }
        $stream = [IO.File]::OpenRead($file.FullName)
        try {
            $header = New-Object byte[] 4
            if ($stream.Read($header, 0, 4) -ne 4) { return $false }
            return [Text.Encoding]::ASCII.GetString($header) -eq 'GGUF'
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $false
    }
}

function Test-PythonConfigured {
    try {
        & $env:ComSpec /d /s /c "$PYTHON_COMMAND_LINE -c `"import sys; assert sys.version_info >= (3, 10)`"" 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Write-DoctorLine {
    param([string]$Label, [bool]$Passed, [string]$Detail)
    $state = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0,-24} {1,-6} {2}' -f $Label, $state, $Detail)
}

function Write-DoctorServiceLine {
    param([string]$Label, [bool]$Running, [string]$Detail)
    $state = if ($Running) { 'RUNNING' } else { 'STOPPED' }
    Write-Host ('{0,-24} {1,-8} {2}' -f $Label, $state, $Detail)
}

function Invoke-Doctor {
    $failed = $false
    Write-Host 'HauHau dependency doctor'
    Write-Host '-------------------------'

    $requiredFiles = @('voice_proxy.py', 'hauhau-voice-stack.ps1', 'hauhau-voice-stack.cmd')
    foreach ($file in $requiredFiles) {
        $path = Join-Path $InstallDir $file
        $passed = Test-Path -LiteralPath $path
        Write-DoctorLine -Label $file -Passed $passed -Detail $path
        if (-not $passed) { $failed = $true }
    }

    $pythonReady = Test-PythonConfigured
    Write-DoctorLine -Label 'Python 3.10+' -Passed $pythonReady -Detail ([string]$PYTHON_COMMAND_LINE)
    if (-not $pythonReady) { $failed = $true }

    $llmExe = Get-ConfiguredExecutable -CommandLine ([string]$LLM_COMMAND_LINE)
    $llmReady = (Test-ConfiguredExecutable -CommandLine ([string]$LLM_COMMAND_LINE)) -and (Test-NativeExecutable -CommandLine ([string]$LLM_COMMAND_LINE))
    Write-DoctorLine -Label 'llama-server.exe' -Passed $llmReady -Detail $llmExe
    if (-not $llmReady) { $failed = $true }

    $model = Get-ConfiguredModel -CommandLine ([string]$LLM_COMMAND_LINE)
    $modelReady = Test-GgufFile -Path $model
    Write-DoctorLine -Label 'HauHau GGUF model' -Passed $modelReady -Detail $model
    if (-not $modelReady) { $failed = $true }

    $ttsExe = Get-ConfiguredExecutable -CommandLine ([string]$TTS_START_COMMAND_LINE)
    $ttsReady = Test-CrispAsrExecutable -CommandLine ([string]$TTS_START_COMMAND_LINE)
    Write-DoctorLine -Label 'CrispASR Qwen TTS' -Passed $ttsReady -Detail $ttsExe
    if (-not $ttsReady) { $failed = $true }

    $ttsCache = Join-Path $InstallDir 'models\crispasr'
    $preloaded = if (Get-Variable -Name TTS_MODEL_PRELOADED -ErrorAction SilentlyContinue) { [bool]$TTS_MODEL_PRELOADED } else { $false }
    if ($preloaded) {
        $requiredTtsModels = @(
            @{ Path = Join-Path $ttsCache 'qwen3-tts-12hz-0.6b-base-q8_0.gguf'; Minimum = 800MB },
            @{ Path = Join-Path $ttsCache 'qwen3-tts-tokenizer-12hz.gguf'; Minimum = 10MB },
            @{ Path = Join-Path $ttsCache 'qwen3-tts-voice-default.gguf'; Minimum = 4KB }
        )
        $validTtsModels = @($requiredTtsModels | Where-Object {
            Test-GgufFile -Path ([string]$_.Path) -MinimumBytes ([long]$_.Minimum)
        })
        $cacheReady = $validTtsModels.Count -eq $requiredTtsModels.Count
        Write-DoctorLine -Label 'Qwen3-TTS models' -Passed $cacheReady -Detail $ttsCache
        if (-not $cacheReady) { $failed = $true }
    } else {
        Write-Host ('{0,-24} {1,-8} {2}' -f 'Qwen3-TTS models', 'DEFERRED', $ttsCache)
    }

    $runtime = if (Get-Variable -Name INSTALL_RUNTIME -ErrorAction SilentlyContinue) { [string]$INSTALL_RUNTIME } else { 'unknown' }
    Write-Host ('{0,-24} {1,-6} {2}' -f 'Compute runtime', 'INFO', $runtime)
    Write-DoctorServiceLine -Label 'Browser + voice now' -Running (Test-ProxyReady) -Detail $PublicUrl
    Write-DoctorServiceLine -Label 'LLM service now' -Running (Test-BackendReady) -Detail $BackendUrl
    Write-DoctorServiceLine -Label 'TTS service now' -Running (Test-TtsReady) -Detail $TtsUrl
    Write-Host 'Stopped services are normal during an offline dependency check.'

    if ($failed) {
        Write-Host ''
        Write-Host 'One or more installed dependencies are broken. Run: hauhau-voice-stack repair' -ForegroundColor Red
        exit 1
    }
    Write-Host ''
    Write-Host 'All installed dependencies passed.' -ForegroundColor Green
}

function Invoke-Repair {
    $installer = Join-Path $InstallDir 'install.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw "Repair installer is missing: $installer" }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -Repair
    exit $LASTEXITCODE
}

function Show-Usage {
    @'
Usage: hauhau-voice-stack COMMAND

  up        Start everything and open the llama.cpp browser UI
  start     Start everything without opening a browser
  stop      Stop everything
  restart   Restart everything
  status    Show service status
  test      Generate and play a direct voice test
  logs      Follow all logs in one terminal
  config    Print the active configuration
  doctor    Check every installed dependency and current service health
  repair    Retrieve or reinstall missing dependencies
  help      Show this help
'@ | Write-Host
}

switch ($Command) {
    'up' { Open-Chat }
    'start' { Start-All }
    { $_ -in @('stop', 'down') } { Stop-All }
    'restart' { Stop-All; Start-All }
    'status' { Show-Status }
    'test' { Invoke-VoiceTest }
    'logs' { Show-Logs }
    'config' { Get-Content -LiteralPath $ConfigFile }
    'doctor' { Invoke-Doctor }
    'repair' { Invoke-Repair }
    'help' { Show-Usage }
}
