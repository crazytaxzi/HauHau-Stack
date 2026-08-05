[CmdletBinding()]
param([switch]$KeepConfig)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$InstallDir = Join-Path $env:LOCALAPPDATA 'HauHauVoiceStack'
$launcher = Join-Path $InstallDir 'hauhau-voice-stack.cmd'
if (Test-Path -LiteralPath $launcher) { & $launcher stop | Out-Null }

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\') })
[Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')

$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'HauHau Voice Stack'
Remove-Item -LiteralPath $startMenu -Recurse -Force -ErrorAction SilentlyContinue

if ($KeepConfig) {
    Get-ChildItem -LiteralPath $InstallDir -Force |
        Where-Object { $_.Name -notin @('config.ps1', 'dependencies.json') } |
        Remove-Item -Recurse -Force
    Write-Host "Removed HauHau Voice Stack but kept configuration in: $InstallDir"
} else {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host 'HauHau automatic voice stack removed.'
}
