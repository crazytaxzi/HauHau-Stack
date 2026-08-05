[CmdletBinding()]
param(
    [string]$LlmCommandLine,
    [string]$ModelPath,
    [ValidateSet('Auto', 'Vulkan', 'Cuda', 'Cpu')]
    [string]$Runtime = 'Auto',
    [switch]$SkipTtsModelDownload,
    [switch]$NoPathUpdate,
    [switch]$Repair,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:LOCALAPPDATA 'HauHauVoiceStack'
$RuntimeDir = Join-Path $InstallDir 'runtime'
$CrispCacheDir = Join-Path $InstallDir 'models\crispasr'
$DownloadDir = Join-Path $InstallDir 'downloads'
$StateDir = Join-Path $InstallDir 'state'
$ConfigFile = Join-Path $InstallDir 'config.ps1'
$InstallLog = Join-Path $StateDir 'install.log'
$TtsPreloadLog = Join-Path $StateDir 'tts-preload.log'
$CrispAsrReleaseTag = 'v0.8.25'
$LlamaCppReleaseTag = 'b10280'
$TtsTalkerName = 'qwen3-tts-12hz-0.6b-base-q8_0.gguf'
$TtsCodecName = 'qwen3-tts-tokenizer-12hz.gguf'
$TtsVoiceName = 'qwen3-tts-voice-default.gguf'
$TtsTalkerUrl = 'https://huggingface.co/cstr/qwen3-tts-0.6b-base-GGUF/resolve/main/qwen3-tts-12hz-0.6b-base-q8_0.gguf'
$TtsCodecUrl = 'https://huggingface.co/cstr/qwen3-tts-tokenizer-12hz-GGUF/resolve/main/qwen3-tts-tokenizer-12hz.gguf'
$TtsVoiceUrl = 'https://huggingface.co/cstr/qwen3-tts-voices-GGUF/resolve/main/qwen3-tts-voice-default.gguf'
$TtsTalkerPath = Join-Path $CrispCacheDir $TtsTalkerName
$TtsCodecPath = Join-Path $CrispCacheDir $TtsCodecName
$TtsVoicePath = Join-Path $CrispCacheDir $TtsVoiceName
$script:TtsModelsPreloaded = $false
$GitHubHeaders = @{
    'User-Agent' = 'HauHauVoiceStackInstaller/3.0.4'
    'Accept' = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

New-Item -ItemType Directory -Force -Path $InstallDir, $RuntimeDir, $CrispCacheDir, $DownloadDir, $StateDir | Out-Null
Start-Transcript -LiteralPath $InstallLog -Append | Out-Null

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host ('== {0} ==' -f $Message) -ForegroundColor Cyan
}

function ConvertTo-PowerShellLiteral {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Quote-CmdPath {
    param([Parameter(Mandatory)][string]$Path)
    return '"' + $Path.Replace('"', '""') + '"'
}

function Get-PropertyString {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$ExpectedSha256 = ''
    )

    $partial = "$Destination.partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null

    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Host ("Downloading {0} (attempt {1}/3)..." -f (Split-Path -Leaf $Destination), $attempt)
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -Headers @{ 'User-Agent' = $GitHubHeaders['User-Agent'] }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            $lastError = $null
            break
        } catch {
            $lastError = $_
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }
    if ($null -ne $lastError) { throw $lastError }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected = $ExpectedSha256.ToLowerInvariant().Replace('sha256:', '')
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "SHA-256 verification failed for $Destination. Expected $expected, got $actual."
        }
        Write-Host 'SHA-256 verified.' -ForegroundColor Green
    }
}

function Test-GgufFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MinimumBytes = 1024
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
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

function ConvertTo-NativeArgumentList {
    param([Parameter(Mandatory)][string[]]$Arguments)
    return @($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') {
            '"' + $value.Replace('"', '\"') + '"'
        } else {
            $value
        }
    })
}

function Invoke-CurlDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [long]$MinimumBytes = 1024
    )

    if (Test-GgufFile -Path $Destination -MinimumBytes $MinimumBytes) {
        Write-Host ("Already downloaded and valid: {0}" -f (Split-Path -Leaf $Destination)) -ForegroundColor Green
        return
    }

    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    $partial = "$Destination.partial"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null

    if (Test-GgufFile -Path $partial -MinimumBytes $MinimumBytes) {
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        Write-Host ("Recovered completed partial download: {0}" -f (Split-Path -Leaf $Destination)) -ForegroundColor Green
        return
    }

    $curlCommand = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curlCommand) {
        throw 'Windows curl.exe was not found. Install a current Windows 10/11 curl package or place curl.exe on PATH.'
    }

    $baseArguments = @(
        '--location',
        '--fail',
        '--show-error',
        '--http1.1',
        '--retry', '10',
        '--retry-delay', '5',
        '--connect-timeout', '30'
    )

    $attempts = @($true, $false)
    foreach ($resume in $attempts) {
        if (-not $resume) {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }

        $arguments = @($baseArguments)
        if ($resume -and (Test-Path -LiteralPath $partial)) {
            Write-Host ("Resuming with curl.exe: {0}" -f (Split-Path -Leaf $Destination))
            $arguments += @('--continue-at', '-')
        } else {
            Write-Host ("Downloading with curl.exe: {0}" -f (Split-Path -Leaf $Destination))
        }
        $arguments += @('--output', $partial, $Url)

        $process = Start-Process -FilePath ([string]$curlCommand.Source) `
            -ArgumentList (ConvertTo-NativeArgumentList -Arguments $arguments) `
            -NoNewWindow `
            -Wait `
            -PassThru

        if ($process.ExitCode -eq 0 -and (Test-GgufFile -Path $partial -MinimumBytes $MinimumBytes)) {
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            Write-Host ("Downloaded and validated: {0}" -f (Split-Path -Leaf $Destination)) -ForegroundColor Green
            return
        }

        if ($resume) {
            Write-Warning 'The resumed curl transfer did not validate. Retrying that file from zero.'
        }
    }

    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    throw "curl.exe could not retrieve a valid GGUF file from $Url"
}

function Get-GitHubRelease {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [string]$Tag = ''
    )
    $uri = if ([string]::IsNullOrWhiteSpace($Tag)) {
        "https://api.github.com/repos/$Repository/releases/latest"
    } else {
        "https://api.github.com/repos/$Repository/releases/tags/$Tag"
    }
    try {
        return Invoke-RestMethod -Uri $uri -Headers $GitHubHeaders
    } catch {
        $label = if ([string]::IsNullOrWhiteSpace($Tag)) { 'latest release' } else { "release $Tag" }
        throw "Could not query $Repository $label from GitHub: $($_.Exception.Message)"
    }
}

function Find-ReleaseAsset {
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$NameRegex
    )
    $matches = @($Release.assets | Where-Object { [string]$_.name -match $NameRegex })
    if ($matches.Count -ne 1) {
        $names = @($Release.assets | ForEach-Object { [string]$_.name }) -join ', '
        throw "Expected one release asset matching '$NameRegex', found $($matches.Count). Available assets: $names"
    }
    return $matches[0]
}

function Install-ZipAsset {
    param(
        [Parameter(Mandatory)]$Asset,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Overlay
    )

    $assetName = [string]$Asset.name
    $archive = Join-Path $DownloadDir $assetName
    $digest = Get-PropertyString -Object $Asset -Name 'digest'
    if ($Force -or -not (Test-Path -LiteralPath $archive)) {
        Invoke-Download -Url ([string]$Asset.browser_download_url) -Destination $archive -ExpectedSha256 $digest
    } elseif (-not [string]::IsNullOrWhiteSpace($digest)) {
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected = $digest.ToLowerInvariant().Replace('sha256:', '')
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $archive -Force
            Invoke-Download -Url ([string]$Asset.browser_download_url) -Destination $archive -ExpectedSha256 $digest
        } else {
            Write-Host "Using verified cached download: $assetName"
        }
    } else {
        Write-Host "Using cached download: $assetName"
    }

    $extractDir = Join-Path $env:TEMP ('hauhau-extract-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force
        if (-not $Overlay) {
            Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null

        $rootItems = @(Get-ChildItem -LiteralPath $extractDir -Force)
        $copyRoot = $extractDir
        if ($rootItems.Count -eq 1 -and $rootItems[0].PSIsContainer) {
            $copyRoot = $rootItems[0].FullName
        }
        Get-ChildItem -LiteralPath $copyRoot -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
        }
    } finally {
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ExecutableFromCommandLine {
    param([AllowEmptyString()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $trimmed = $CommandLine.Trim()
    if ($trimmed -match '^"([^"]+)"') { return $matches[1] }
    if ($trimmed -match '^([^\s]+)') { return $matches[1] }
    return ''
}

function Get-ModelFromCommandLine {
    param([AllowEmptyString()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $pattern = '(?i)(?:^|\s)(?:--model|-m)(?:=|\s+)(?:"([^"]+)"|([^\s]+))'
    $match = [regex]::Match($CommandLine, $pattern)
    if (-not $match.Success) { return '' }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Test-PythonCommand {
    param([Parameter(Mandatory)][string]$CommandLine)
    try {
        $output = & $env:ComSpec /d /s /c "$CommandLine -c `"import sys; assert sys.version_info >= (3, 10); print(sys.executable)`"" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $lines = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($lines.Count -eq 0) { return $null }
        return [string]$lines[$lines.Count - 1]
    } catch {
        return $null
    }
}

function Resolve-PythonCommand {
    param([AllowEmptyString()][string]$ExistingCommand)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ExistingCommand)) { $candidates += $ExistingCommand }
    $candidates += @('py -3', 'python', 'python3')
    foreach ($candidate in $candidates | Select-Object -Unique) {
        $resolved = Test-PythonCommand -CommandLine $candidate
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            Write-Host "Python dependency ready: $resolved"
            return $candidate
        }
    }

    Write-Host 'Python 3.10+ was not found. Installing a private managed Python runtime...'
    $uvDir = Join-Path $RuntimeDir 'uv'
    $uvExe = Join-Path $uvDir 'uv.exe'
    if ($Force -or -not (Test-Path -LiteralPath $uvExe)) {
        $release = Get-GitHubRelease -Repository 'astral-sh/uv'
        $asset = Find-ReleaseAsset -Release $release -NameRegex '^uv-x86_64-pc-windows-msvc\.zip$'
        Install-ZipAsset -Asset $asset -Destination $uvDir
    }
    if (-not (Test-Path -LiteralPath $uvExe)) { throw "uv installation did not produce $uvExe" }

    $previousUvPythonDir = $env:UV_PYTHON_INSTALL_DIR
    $previousUvCacheDir = $env:UV_CACHE_DIR
    $previousUvInstallBin = $env:UV_PYTHON_INSTALL_BIN
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $RuntimeDir 'python'
    $env:UV_CACHE_DIR = Join-Path $DownloadDir 'uv-cache'
    $env:UV_PYTHON_INSTALL_BIN = 'false'
    try {
        & $uvExe python install 3.12
        if ($LASTEXITCODE -ne 0) { throw 'uv could not install Python 3.12.' }
        $pythonExe = [string](& $uvExe python find --managed-python 3.12 | Select-Object -Last 1)
    } finally {
        $env:UV_PYTHON_INSTALL_DIR = $previousUvPythonDir
        $env:UV_CACHE_DIR = $previousUvCacheDir
        $env:UV_PYTHON_INSTALL_BIN = $previousUvInstallBin
    }
    $pythonExe = $pythonExe.Trim()
    if ([string]::IsNullOrWhiteSpace($pythonExe) -or -not (Test-Path -LiteralPath $pythonExe)) {
        throw 'uv installed Python but its executable could not be located.'
    }
    $command = Quote-CmdPath $pythonExe
    if ($null -eq (Test-PythonCommand -CommandLine $command)) {
        throw "The managed Python runtime failed its validation check: $pythonExe"
    }
    Write-Host "Managed Python ready: $pythonExe" -ForegroundColor Green
    return $command
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-VcRuntime {
    $required = @(
        (Join-Path $env:WINDIR 'System32\vcruntime140.dll'),
        (Join-Path $env:WINDIR 'System32\msvcp140.dll'),
        (Join-Path $env:WINDIR 'System32\vcruntime140_1.dll')
    )
    $missingRuntimeFiles = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missingRuntimeFiles.Count -eq 0) {
        Write-Host 'Microsoft Visual C++ runtime ready.'
        return
    }

    Write-Host 'Microsoft Visual C++ runtime is missing. Retrieving the official x64 redistributable...'
    $installer = Join-Path $DownloadDir 'vc_redist.x64.exe'
    Invoke-Download -Url 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -Destination $installer
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
        throw 'The downloaded Visual C++ redistributable did not have a valid Microsoft signature.'
    }
    Write-Host 'Microsoft signature verified.' -ForegroundColor Green
    $arguments = @('/install', '/quiet', '/norestart')
    if (Test-IsAdministrator) {
        $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    } else {
        Write-Host 'Windows will request administrator approval for the Microsoft runtime.'
        $process = Start-Process -FilePath $installer -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    }
    if ($process.ExitCode -notin @(0, 1638, 3010)) {
        throw "Microsoft Visual C++ runtime installer exited with code $($process.ExitCode)."
    }
    $missingRuntimeFilesAfterInstall = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missingRuntimeFilesAfterInstall.Count -gt 0) {
        throw 'The Microsoft Visual C++ runtime still appears to be missing after installation.'
    }
    Write-Host 'Microsoft Visual C++ runtime installed.' -ForegroundColor Green
}

function Find-NvidiaSmi {
    $candidates = @()
    $pathCommand = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($null -ne $pathCommand -and -not [string]::IsNullOrWhiteSpace([string]$pathCommand.Source)) {
        $candidates += [string]$pathCommand.Source
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) {
        $candidates += (Join-Path $env:WINDIR 'System32\nvidia-smi.exe')
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return ''
}

function Get-NvidiaGpuNames {
    $names = @()
    try {
        $names += @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object {
            [string]$_.Name
        } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and $_ -match '(?i)NVIDIA|GeForce|RTX'
        })
    } catch {
        Write-Verbose "Win32_VideoController detection failed: $($_.Exception.Message)"
    }

    $smi = Find-NvidiaSmi
    if (-not [string]::IsNullOrWhiteSpace($smi)) {
        try {
            $smiNames = @(& $smi '--query-gpu=name' '--format=csv,noheader' 2>$null | ForEach-Object {
                ([string]$_).Trim()
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $names += $smiNames
        } catch {
            Write-Verbose "nvidia-smi detection failed: $($_.Exception.Message)"
        }
    }

    return @($names | Select-Object -Unique)
}

function Resolve-Runtime {
    param([Parameter(Mandatory)][string]$Requested)
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'This installer requires 64-bit Windows.'
    }

    $nvidiaGpus = @(Get-NvidiaGpuNames)
    $hasNvidiaGpu = $nvidiaGpus.Count -gt 0

    if ($Requested -eq 'Cuda') {
        if (-not $hasNvidiaGpu) {
            throw 'CUDA was selected, but an NVIDIA GPU/driver was not detected. Use -Runtime Vulkan or -Runtime Cpu.'
        }
        Write-Host ('Detected NVIDIA GPU: {0}' -f ($nvidiaGpus -join ', ')) -ForegroundColor Green
        return 'Cuda'
    }
    if ($Requested -ne 'Auto') { return $Requested }

    # NVIDIA cards should use the CUDA build first. Vulkan is the cross-vendor fallback.
    if ($hasNvidiaGpu) {
        Write-Host ('Detected NVIDIA GPU: {0}' -f ($nvidiaGpus -join ', ')) -ForegroundColor Green
        return 'Cuda'
    }

    $vulkanLoader = Join-Path $env:WINDIR 'System32\vulkan-1.dll'
    if (Test-Path -LiteralPath $vulkanLoader) { return 'Vulkan' }
    return 'Cpu'
}

function Find-FileRecursiveLimited {
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [Parameter(Mandatory)][string]$Filter
    )
    $results = @()
    foreach ($root in $Roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique) {
        try {
            $remaining = 200 - $results.Count
            if ($remaining -le 0) { break }
            $results += @(Get-ChildItem -LiteralPath $root -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First $remaining)
        } catch { }
        if ($results.Count -ge 200) { break }
    }
    return @($results)
}

function Get-GgufScore {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $name = $File.Name.ToLowerInvariant()
    $score = 0
    if ($name -match 'hauhaucs') { $score += 200 }
    elseif ($name -match 'hauhau') { $score += 150 }
    if ($name -match 'qwen.?3\.5') { $score += 80 }
    elseif ($name -match 'qwen.?3') { $score += 50 }
    if ($name -match '4b') { $score += 30 }
    if ($name -match 'instruct') { $score += 10 }
    if ($name -match 'tts|tokenizer|codec|voice|mmproj|embedding') { $score -= 250 }
    if ($File.Length -gt 500MB) { $score += 5 }
    return $score
}

function Select-GgufWithDialog {
    param([string]$InitialDirectory)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select the HauHauCS / Qwen GGUF model'
        $dialog.Filter = 'GGUF model (*.gguf)|*.gguf|All files (*.*)|*.*'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory)) {
            $dialog.InitialDirectory = $InitialDirectory
        }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
    } catch {
        Write-Warning "The Windows file picker could not be opened: $($_.Exception.Message)"
    }
    return ''
}

function Resolve-ModelPath {
    param([AllowEmptyString()][string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolved = (Resolve-Path -LiteralPath $RequestedPath).Path
        if ([IO.Path]::GetExtension($resolved) -ne '.gguf') { throw "Model is not a GGUF file: $resolved" }
        return $resolved
    }

    $roots = @(
        $SourceDir,
        (Split-Path -Parent $SourceDir),
        (Join-Path $env:LOCALAPPDATA 'Cinder_Alpha'),
        (Join-Path $env:USERPROFILE 'models'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE '.cache')
    )
    $candidates = @(Find-FileRecursiveLimited -Roots $roots -Filter '*.gguf' | ForEach-Object {
        [PSCustomObject]@{ File = $_; Score = (Get-GgufScore -File $_) }
    } | Where-Object { $_.Score -gt -100 } | Sort-Object -Property @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.File.LastWriteTime }; Descending = $true })

    $hauhau = @($candidates | Where-Object { $_.Score -ge 150 })
    if ($hauhau.Count -eq 1) {
        Write-Host "Found HauHau model: $($hauhau[0].File.FullName)"
        return $hauhau[0].File.FullName
    }
    if ($candidates.Count -gt 0) {
        Write-Host 'Candidate GGUF models found:'
        $candidates | Select-Object -First 10 | ForEach-Object { Write-Host ('  {0}' -f $_.File.FullName) }
    }
    $initial = if ($candidates.Count -gt 0) { $candidates[0].File.DirectoryName } else { Join-Path $env:USERPROFILE 'Downloads' }
    $selected = Select-GgufWithDialog -InitialDirectory $initial
    if (-not [string]::IsNullOrWhiteSpace($selected)) { return $selected }

    throw "A HauHauCS GGUF model is required, but none could be selected. Rerun INSTALL.cmd and choose the model, or run install.ps1 -ModelPath 'C:\path\model.gguf'."
}

function Find-RunningLlamaCommand {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^llama-server(\.exe)?$' -and
        $_.CommandLine -and
        $_.CommandLine -match '(?i)(?:--port|-p)(?:=|\s+)8080(?:\s|$)'
    })
    $selected = $processes | Select-Object -First 1
    if ($null -ne $selected) { return [string]$selected.CommandLine }
    return ''
}

function Find-LlamaServerExecutable {
    param([AllowEmptyString()][string]$ExistingCommand)
    $fromCommand = Get-ExecutableFromCommandLine -CommandLine $ExistingCommand
    if ($fromCommand -and (Test-Path -LiteralPath $fromCommand)) { return (Resolve-Path -LiteralPath $fromCommand).Path }

    $pathCommand = Get-Command llama-server.exe -ErrorAction SilentlyContinue
    if ($pathCommand -and (Test-Path -LiteralPath $pathCommand.Source)) { return $pathCommand.Source }

    $known = @(
        (Join-Path $RuntimeDir 'llama.cpp'),
        (Join-Path $env:LOCALAPPDATA 'Cinder_Alpha\runtime')
    )
    $found = Find-FileRecursiveLimited -Roots $known -Filter 'llama-server.exe' | Select-Object -First 1
    if ($found) { return $found.FullName }
    return ''
}

function Install-LlamaCpp {
    param([Parameter(Mandatory)][string]$SelectedRuntime)
    $destination = Join-Path $RuntimeDir 'llama.cpp'
    $release = Get-GitHubRelease -Repository 'ggml-org/llama.cpp' -Tag $LlamaCppReleaseTag
    switch ($SelectedRuntime) {
        'Cuda' {
            $main = Find-ReleaseAsset -Release $release -NameRegex '^llama-.*-bin-win-cuda-12\.4-x64\.zip$'
            $cudart = Find-ReleaseAsset -Release $release -NameRegex '^cudart-llama-bin-win-cuda-12\.4-x64\.zip$'
            Install-ZipAsset -Asset $main -Destination $destination
            Install-ZipAsset -Asset $cudart -Destination $destination -Overlay
        }
        'Vulkan' {
            $asset = Find-ReleaseAsset -Release $release -NameRegex '^llama-.*-bin-win-vulkan-x64\.zip$'
            Install-ZipAsset -Asset $asset -Destination $destination
        }
        default {
            $asset = Find-ReleaseAsset -Release $release -NameRegex '^llama-.*-bin-win-cpu-x64\.zip$'
            Install-ZipAsset -Asset $asset -Destination $destination
        }
    }
    $exe = Get-ChildItem -LiteralPath $destination -Filter 'llama-server.exe' -File -Recurse | Select-Object -First 1
    if (-not $exe) { throw 'llama.cpp was downloaded, but llama-server.exe was not found after extraction.' }
    return $exe.FullName
}

function Resolve-LlmCommandLine {
    param(
        [AllowEmptyString()][string]$RequestedCommand,
        [AllowEmptyString()][string]$ExistingCommand,
        [Parameter(Mandatory)][string]$SelectedRuntime,
        [AllowEmptyString()][string]$RequestedModel
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedCommand)) { return $RequestedCommand }

    $running = Find-RunningLlamaCommand
    if (-not [string]::IsNullOrWhiteSpace($running)) {
        Write-Host 'Captured the running HauHau llama-server command on port 8080.'
        return $running
    }

    if (-not [string]::IsNullOrWhiteSpace($ExistingCommand)) {
        $existingExe = Get-ExecutableFromCommandLine -CommandLine $ExistingCommand
        $existingModel = Get-ModelFromCommandLine -CommandLine $ExistingCommand
        $existingExeReady = ($existingExe -and (Test-Path -LiteralPath $existingExe)) -or ($existingExe -and (Get-Command $existingExe -ErrorAction SilentlyContinue))
        $existingModelReady = $existingModel -and (Test-Path -LiteralPath $existingModel)
        if ($existingExeReady -and $existingModelReady) {
            Write-Host 'Keeping the existing HauHau llama-server command.'
            return $ExistingCommand
        }
        if ([string]::IsNullOrWhiteSpace($RequestedModel)) {
            $RequestedModel = $existingModel
        }
    }

    $serverExe = Find-LlamaServerExecutable -ExistingCommand $ExistingCommand
    if ([string]::IsNullOrWhiteSpace($serverExe)) {
        Write-Host 'llama-server.exe was not found. Retrieving the pinned compatible official Windows build...'
        $serverExe = Install-LlamaCpp -SelectedRuntime $SelectedRuntime
    } else {
        Write-Host "llama.cpp dependency ready: $serverExe"
    }

    $resolvedModel = Resolve-ModelPath -RequestedPath $RequestedModel
    $gpuLayers = if ($SelectedRuntime -eq 'Cpu') { 0 } else { 99 }
    return ('{0} --model {1} --host 127.0.0.1 --port 8080 --ctx-size 32768 --jinja --n-gpu-layers {2}' -f (Quote-CmdPath $serverExe), (Quote-CmdPath $resolvedModel), $gpuLayers)
}

function Install-CrispAsr {
    param([Parameter(Mandatory)][string]$SelectedRuntime)
    $destination = Join-Path $RuntimeDir 'crispasr'
    $kindFile = Join-Path $destination 'hauhau-runtime.txt'
    $installedKind = if (Test-Path -LiteralPath $kindFile) { (Get-Content -LiteralPath $kindFile -Raw).Trim() } else { '' }
    $existing = Get-ChildItem -LiteralPath $destination -Filter 'crispasr.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing -and -not $Force -and $installedKind -eq $SelectedRuntime) {
        Write-Host "CrispASR dependency ready: $($existing.FullName)"
        return $existing.FullName
    }

    Write-Host 'Retrieving the pinned compatible official CrispASR Windows build...'
    $release = Get-GitHubRelease -Repository 'CrispStrobe/CrispASR' -Tag $CrispAsrReleaseTag
    switch ($SelectedRuntime) {
        'Cuda' { $regex = '^crispasr-windows-x86_64-cuda\.zip$' }
        'Vulkan' { $regex = '^crispasr-windows-x86_64-vulkan\.zip$' }
        default { $regex = '^crispasr-windows-x86_64-cpu\.zip$' }
    }
    $asset = Find-ReleaseAsset -Release $release -NameRegex $regex
    Install-ZipAsset -Asset $asset -Destination $destination
    $exe = Get-ChildItem -LiteralPath $destination -Filter 'crispasr.exe' -File -Recurse | Select-Object -First 1
    if (-not $exe) { throw 'CrispASR was downloaded, but crispasr.exe was not found after extraction.' }
    Set-Content -LiteralPath $kindFile -Value $SelectedRuntime -Encoding ascii
    return $exe.FullName
}

function Preload-TtsModel {
    param([Parameter(Mandatory)][string]$CrispAsrExe)

    $haveTalker = Test-GgufFile -Path $TtsTalkerPath -MinimumBytes 800MB
    $haveCodec = Test-GgufFile -Path $TtsCodecPath -MinimumBytes 10MB
    $haveVoice = Test-GgufFile -Path $TtsVoicePath -MinimumBytes 4KB

    if ($SkipTtsModelDownload -and -not ($haveTalker -and $haveCodec -and $haveVoice)) {
        Write-Warning 'Qwen3-TTS model preload was skipped. The service will need the model set before it can start.'
        $script:TtsModelsPreloaded = $false
        return
    }

    Write-Host 'Retrieving and validating the Qwen3-TTS model set with curl.exe.'
    Write-Host 'This avoids CrispASR WinHTTP failures and stores explicit local model paths.'

    Invoke-CurlDownload -Url $TtsTalkerUrl -Destination $TtsTalkerPath -MinimumBytes 800MB
    Invoke-CurlDownload -Url $TtsCodecUrl -Destination $TtsCodecPath -MinimumBytes 10MB
    Invoke-CurlDownload -Url $TtsVoiceUrl -Destination $TtsVoicePath -MinimumBytes 4KB

    $testWav = Join-Path $StateDir 'tts-install-test.wav'
    Remove-Item -LiteralPath $testWav -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $TtsPreloadLog -Value '' -Encoding utf8

    $arguments = @(
        '--backend', 'qwen3-tts',
        '-m', $TtsTalkerPath,
        '--codec-model', $TtsCodecPath,
        '--voice', $TtsVoicePath,
        '--cache-dir', $CrispCacheDir,
        '--tts', 'HauHau voice installation check.',
        '--tts-output', $testWav,
        '--seed', '42'
    )
    if ($SelectedRuntime -eq 'Cpu') { $arguments += '--no-gpu' }

    $startedAt = Get-Date
    Set-Content -LiteralPath $TtsPreloadLog -Encoding utf8 -Value @(
        'HauHau Qwen3-TTS preload summary',
        ('Started: {0:o}' -f $startedAt),
        ('Executable: {0}' -f $CrispAsrExe),
        ('Talker: {0}' -f $TtsTalkerPath),
        ('Codec: {0}' -f $TtsCodecPath),
        ('Voice: {0}' -f $TtsVoicePath)
    )

    $process = Start-Process -FilePath $CrispAsrExe `
        -ArgumentList (ConvertTo-NativeArgumentList -Arguments $arguments) `
        -WorkingDirectory $InstallDir `
        -NoNewWindow `
        -Wait `
        -PassThru
    $crispExitCode = [int]$process.ExitCode

    Add-Content -LiteralPath $TtsPreloadLog -Encoding utf8 -Value @(
        ('Finished: {0:o}' -f (Get-Date)),
        ('Exit code: {0}' -f $crispExitCode),
        ('Validation WAV: {0}' -f $testWav)
    )
    if ($crispExitCode -ne 0) {
        throw "Qwen3-TTS validation failed. CrispASR exited with code $crispExitCode. See $TtsPreloadLog."
    }
    if (-not (Test-Path -LiteralPath $testWav)) { throw 'Qwen3-TTS validation did not create a WAV file.' }
    $header = [IO.File]::ReadAllBytes($testWav)
    if ($header.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($header, 0, 4) -ne 'RIFF') {
        throw 'Qwen3-TTS validation output was not a valid WAV file.'
    }

    $script:TtsModelsPreloaded = $true
    Write-Host "Qwen3-TTS model and audio generation validated: $testWav" -ForegroundColor Green
}

function Install-ApplicationFiles {
    $files = @(
        'voice_proxy.py',
        'hauhau-voice-stack.ps1',
        'hauhau-voice-stack.cmd',
        'README.md',
        'uninstall.ps1',
        'install.ps1',
        'INSTALL.cmd',
        'INSTALL_CUDA.cmd',
        'INSTALL_DEFER_TTS.cmd',
        'START_HAUHAU.cmd',
        'STOP_HAUHAU.cmd',
        'REPAIR_HAUHAU.cmd',
        'CHECK_HAUHAU.cmd',
        'config.example.ps1',
        'VERSION.txt'
    )
    foreach ($file in $files) {
        $source = Join-Path $SourceDir $file
        if (Test-Path -LiteralPath $source) {
            $destination = Join-Path $InstallDir $file
            if (-not ([IO.Path]::GetFullPath($source) -ieq [IO.Path]::GetFullPath($destination))) {
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
        }
    }
}

function Add-UserPath {
    if ($NoPathUpdate) { return }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $alreadyPresent = @($entries | Where-Object { $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\') }).Count -gt 0
    if (-not $alreadyPresent) {
        [Environment]::SetEnvironmentVariable('Path', (($entries + $InstallDir) -join ';'), 'User')
        $env:Path = "$env:Path;$InstallDir"
        Write-Host "Added to your user PATH: $InstallDir"
    }
}

function Install-Shortcuts {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'HauHau Voice Stack'
        New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
        $items = @(
            @{ Name = 'Start HauHau Voice.lnk'; Target = 'START_HAUHAU.cmd'; Description = 'Start HauHau with automatic Qwen voice' },
            @{ Name = 'Stop HauHau Voice.lnk'; Target = 'STOP_HAUHAU.cmd'; Description = 'Stop the HauHau voice stack' },
            @{ Name = 'Repair HauHau Voice.lnk'; Target = 'REPAIR_HAUHAU.cmd'; Description = 'Check and repair HauHau dependencies' },
            @{ Name = 'Check HauHau Voice.lnk'; Target = 'CHECK_HAUHAU.cmd'; Description = 'Run HauHau dependency and service diagnostics' }
        )
        foreach ($item in $items) {
            $shortcut = $shell.CreateShortcut((Join-Path $startMenu $item.Name))
            $shortcut.TargetPath = Join-Path $InstallDir $item.Target
            $shortcut.WorkingDirectory = $InstallDir
            $shortcut.Description = $item.Description
            $shortcut.Save()
        }
    } catch {
        Write-Warning "Start Menu shortcuts could not be created: $($_.Exception.Message)"
    }
}

try {
    Write-Host 'HauHau Automatic Voice Stack - Windows installer' -ForegroundColor White
    Write-Host "Install folder: $InstallDir"

    $existingLlm = ''
    $existingPython = ''
    $existingRuntime = ''
    if (Test-Path -LiteralPath $ConfigFile) {
        try {
            . $ConfigFile
            if (Get-Variable -Name LLM_COMMAND_LINE -ErrorAction SilentlyContinue) { $existingLlm = [string]$LLM_COMMAND_LINE }
            if (Get-Variable -Name PYTHON_COMMAND_LINE -ErrorAction SilentlyContinue) { $existingPython = [string]$PYTHON_COMMAND_LINE }
            if (Get-Variable -Name INSTALL_RUNTIME -ErrorAction SilentlyContinue) { $existingRuntime = [string]$INSTALL_RUNTIME }
        } catch {
            Write-Warning "Existing configuration could not be read and will be rebuilt: $($_.Exception.Message)"
        }
    }

    $installedLauncher = Join-Path $InstallDir 'hauhau-voice-stack.cmd'
    if (Test-Path -LiteralPath $installedLauncher) {
        try { & $installedLauncher stop | Out-Null } catch { }
    }

    Write-Step 'Hardware and native runtime'
    # Auto is deliberately re-detected on every install/repair so stale config cannot pin the wrong GPU backend.
    $SelectedRuntime = Resolve-Runtime -Requested $Runtime
    Write-Host "Selected compute runtime: $SelectedRuntime"
    Ensure-VcRuntime

    Write-Step 'Python dependency'
    $PythonCommandLine = Resolve-PythonCommand -ExistingCommand $existingPython

    Write-Step 'HauHau language-model runtime'
    $FinalLlmCommand = Resolve-LlmCommandLine -RequestedCommand $LlmCommandLine -ExistingCommand $existingLlm -SelectedRuntime $SelectedRuntime -RequestedModel $ModelPath

    Write-Step 'Qwen3-TTS runtime'
    $CrispAsrExe = Install-CrispAsr -SelectedRuntime $SelectedRuntime

    Write-Step 'Qwen3-TTS model dependency'
    Preload-TtsModel -CrispAsrExe $CrispAsrExe

    Write-Step 'Application files and configuration'
    Install-ApplicationFiles
    if ($script:TtsModelsPreloaded) {
        $ttsCommand = ('{0} --server --backend qwen3-tts -m {1} --codec-model {2} --voice {3} --cache-dir {4} --host 127.0.0.1 --port 9080 --no-warmup' -f (Quote-CmdPath $CrispAsrExe), (Quote-CmdPath $TtsTalkerPath), (Quote-CmdPath $TtsCodecPath), (Quote-CmdPath $TtsVoicePath), (Quote-CmdPath $CrispCacheDir))
    } else {
        $ttsCommand = ('{0} --server --backend qwen3-tts -m auto --cache-dir {1} --host 127.0.0.1 --port 9080 --no-warmup' -f (Quote-CmdPath $CrispAsrExe), (Quote-CmdPath $CrispCacheDir))
    }
    if ($SelectedRuntime -eq 'Cpu') { $ttsCommand += ' --no-gpu' }

    $ttsPreloadedLiteral = if ($script:TtsModelsPreloaded) { '$true' } else { '$false' }
    $config = @(
        '# HauHau Voice Stack for Windows configuration',
        '# Generated by install.ps1. The supervisor rewrites the LLM port to 8082.',
        ('$INSTALL_RUNTIME = {0}' -f (ConvertTo-PowerShellLiteral $SelectedRuntime)),
        ('$LLM_COMMAND_LINE = {0}' -f (ConvertTo-PowerShellLiteral $FinalLlmCommand)),
        ('$PYTHON_COMMAND_LINE = {0}' -f (ConvertTo-PowerShellLiteral $PythonCommandLine)),
        ('$TTS_START_COMMAND_LINE = {0}' -f (ConvertTo-PowerShellLiteral $ttsCommand)),
        '$TTS_STOP_COMMAND_LINE = ''''',
        ('$TTS_MODEL_PRELOADED = {0}' -f $ttsPreloadedLiteral),
        '',
        '$PUBLIC_URL = ''http://127.0.0.1:8080''',
        '$BACKEND_URL = ''http://127.0.0.1:8082''',
        '$TTS_URL = ''http://127.0.0.1:9080''',
        '$TTS_SPEED = 0.94',
        '$LLM_STARTUP_TIMEOUT = 900',
        '$TTS_STARTUP_TIMEOUT = 1200',
        '$PROXY_STARTUP_TIMEOUT = 30'
    )
    Set-Content -LiteralPath $ConfigFile -Value $config -Encoding utf8

    $manifest = [ordered]@{
        installed_at = (Get-Date).ToString('o')
        compute_runtime = $SelectedRuntime
        python_command = $PythonCommandLine
        llama_cpp_release = $LlamaCppReleaseTag
        crispasr_release = $CrispAsrReleaseTag
        crispasr_executable = $CrispAsrExe
        crispasr_model_cache = $CrispCacheDir
        crispasr_talker_model = if ($script:TtsModelsPreloaded) { $TtsTalkerPath } else { '' }
        crispasr_codec_model = if ($script:TtsModelsPreloaded) { $TtsCodecPath } else { '' }
        crispasr_voice_model = if ($script:TtsModelsPreloaded) { $TtsVoicePath } else { '' }
        llm_command = $FinalLlmCommand
    } | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath (Join-Path $InstallDir 'dependencies.json') -Value $manifest -Encoding utf8

    Add-UserPath
    Install-Shortcuts

    try { & (Join-Path $InstallDir 'hauhau-voice-stack.cmd') stop | Out-Null } catch { }

    Write-Step 'Final dependency check'
    & (Join-Path $InstallDir 'hauhau-voice-stack.cmd') doctor
    if ($LASTEXITCODE -ne 0) { throw 'The final dependency check failed.' }

    Write-Host ''
    Write-Host 'HauHau Voice Stack installed successfully.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Start it by double-clicking START_HAUHAU.cmd or running:'
    Write-Host '  hauhau-voice-stack up' -ForegroundColor White
    Write-Host ''
    Write-Host 'Repair or re-check dependencies later with:'
    Write-Host '  hauhau-voice-stack repair'
    Write-Host '  hauhau-voice-stack doctor'
    Write-Host ''
    Write-Host "Install log: $InstallLog"
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}
