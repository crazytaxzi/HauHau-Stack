# HauHau Automatic Voice Stack for Windows

This package installs and supervises the full Windows voice stack for HauHauCS. Double-clicking `INSTALL.cmd` checks every required dependency, retrieves anything missing, verifies downloads where the upstream release provides SHA-256 digests, installs the stack per-user, and runs a final dependency audit.

## What the installer handles

The installer checks or installs:

- Microsoft Visual C++ x64 runtime, using Microsoft's signed redistributable only when required.
- Python 3.10 or newer. When no suitable Python exists, it installs a private Python 3.12 runtime through `uv`; it does not alter or replace your system Python.
- `llama-server.exe`. It reuses your existing llama.cpp installation when valid; otherwise it downloads the pinned compatible official Windows build.
- Your HauHauCS/Qwen GGUF model. It captures a running server command, searches common model locations, or opens a Windows file picker. It does **not** guess or replace your custom HauHauCS model.
- CrispASR v0.8.25 with the native Qwen3-TTS backend.
- The Qwen3-TTS model, codec, and default voice pack. The normal install downloads and validates roughly 1.3 GB of model data inside the application folder by generating a real WAV file.
- The HauHau reverse proxy, service supervisor, command wrappers, PATH entry, logs, and Start Menu shortcuts.

The compatible llama.cpp runtime is pinned to build `b10280`. Runtime archives are selected for Vulkan, CUDA, or CPU and are verified against the SHA-256 digest published with the GitHub release.

Installer 3.0.4 bypasses CrispASR's WinHTTP model downloader and retrieves the required Qwen3-TTS GGUF files with Windows `curl.exe`. CrispASR writes normal banners and download progress to stderr; Windows PowerShell 5.1 can mislabel that output as `NativeCommandError`, and piping it through `Tee-Object` can create a huge unreadable log. Version 3.0.4 resumes interrupted curl transfers when possible, retries failed transfers from zero, validates GGUF headers and minimum sizes, configures explicit local talker/codec/voice paths, and then runs a real CUDA or CPU WAV-generation test. It also keeps the corrected offline doctor check: CrispASR's usage/help exit code is not mistaken for a broken executable. The NVIDIA detection and Visual C++ strict-mode fixes remain included.

## Install

1. Extract this ZIP to a normal folder. Do not run it from inside the ZIP preview.
2. Double-click `INSTALL.cmd`. It automatically selects CUDA on an NVIDIA GeForce/RTX system.
3. Select your HauHauCS `.gguf` model if the installer cannot identify it automatically.
4. After the final dependency check passes, double-click `START_HAUHAU.cmd` or open a new terminal and run:

```powershell
hauhau-voice-stack up
```

The install location is:

```text
%LOCALAPPDATA%\HauHauVoiceStack
```

No administrator access is normally needed. Windows may request elevation only if the Microsoft Visual C++ runtime is genuinely missing.

## Runtime selection

The default `Auto` mode selects CUDA when an NVIDIA GPU is detected, including GeForce RTX cards. On non-NVIDIA systems it uses Vulkan when available and falls back to CPU otherwise.

To force a runtime, launch PowerShell in the extracted folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Runtime Vulkan
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Runtime Cuda
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Runtime Cpu
```

`INSTALL_CUDA.cmd` is also included as an explicit NVIDIA fallback. CUDA mode requires a detected NVIDIA driver and downloads substantially larger runtime packages.

## Supplying the model or existing server command

Select the model directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -ModelPath 'D:\Models\HauHauCS-Qwen3.5-4B.gguf'
```

Or preserve a tuned llama.cpp command:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -LlmCommandLine '"C:\AI\llama-server.exe" --model "D:\Models\HauHauCS.gguf" --ctx-size 32768 --jinja --port 8080'
```

The supervisor automatically moves the private LLM backend from port `8080` to `8082`. The browser and API remain on port `8080` through the voice-aware proxy.

## Commands

```text
hauhau-voice-stack up       Start everything and open the browser UI
hauhau-voice-stack start    Start everything without opening a browser
hauhau-voice-stack stop     Stop proxy, TTS, and LLM process trees
hauhau-voice-stack restart  Restart the complete stack
hauhau-voice-stack status   Show current service health
hauhau-voice-stack test     Generate and play a direct voice test
hauhau-voice-stack logs     Follow LLM, TTS, and proxy logs
hauhau-voice-stack doctor   Validate installed dependencies and service health
hauhau-voice-stack repair   Retrieve or reinstall missing dependencies
hauhau-voice-stack config   Print the active configuration
```

Click-to-run wrappers are included:

- `INSTALL_DEFER_TTS.cmd` (finish installation now and download the voice model on first start)
- `START_HAUHAU.cmd`
- `STOP_HAUHAU.cmd`
- `CHECK_HAUHAU.cmd`
- `REPAIR_HAUHAU.cmd`

## Ports

```text
127.0.0.1:8080  llama.cpp browser/API through the automatic voice proxy
127.0.0.1:8082  private HauHauCS llama-server backend
127.0.0.1:9080  CrispASR Qwen3-TTS server
```

The proxy forwards the existing llama.cpp UI and OpenAI-compatible API. For streamed chat completions, it collects the assistant's final answer, removes markup that should not be spoken, sends the cleaned text to `/v1/audio/speech`, saves the WAV, and plays it through Windows audio.

## Large TTS model download

The default installer downloads the Qwen3-TTS model set immediately and validates it. To defer that download until first startup:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipTtsModelDownload
```

That option makes installation faster, but the first start can then remain on the TTS startup step while roughly 1.3 GB downloads.

## Logs and files

```text
%LOCALAPPDATA%\HauHauVoiceStack\config.ps1
%LOCALAPPDATA%\HauHauVoiceStack\dependencies.json
%LOCALAPPDATA%\HauHauVoiceStack\models\crispasr
%LOCALAPPDATA%\HauHauVoiceStack\state\install.log
%LOCALAPPDATA%\HauHauVoiceStack\state\tts-preload.log
%LOCALAPPDATA%\HauHauVoiceStack\state\llm*.log
%LOCALAPPDATA%\HauHauVoiceStack\state\tts*.log
%LOCALAPPDATA%\HauHauVoiceStack\state\proxy*.log
%LOCALAPPDATA%\HauHauVoiceStack\audio
```

The audio cache keeps the ten newest generated replies plus `latest.wav`.

## Repair

Run either:

```powershell
hauhau-voice-stack repair
hauhau-voice-stack doctor
```

Repair is idempotent. It preserves a valid existing LLM command and model, reuses verified cached downloads, and retrieves only dependencies that are absent or broken. Add `-Force` to `install.ps1` to redownload runtime archives.

## Uninstall

Run:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\HauHauVoiceStack\uninstall.ps1"
```

Add `-KeepConfig` to retain `config.ps1` and `dependencies.json` for a later reinstall. The uninstaller stops the full process tree, removes the PATH entry and Start Menu shortcuts, then removes the private runtimes and application files.

## Internet sources used by the installer

The installer retrieves dependencies only from these official upstream locations:

- Microsoft Visual C++ redistributable: Microsoft's `aka.ms` release endpoint.
- `uv`: `astral-sh/uv` GitHub releases.
- llama.cpp: `ggml-org/llama.cpp` GitHub release `b10280`.
- CrispASR: `CrispStrobe/CrispASR` GitHub release `v0.8.25`.
- Qwen3-TTS model files: official `cstr` Hugging Face GGUF repositories, downloaded with Windows `curl.exe` and used through explicit local paths.
