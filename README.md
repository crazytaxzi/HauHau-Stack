# HauHau Automatic Voice Stack for Windows

This package installs and supervises the Windows HauHauCS voice stack: a local llama.cpp language-model backend, CrispASR Qwen3-TTS, and a voice-aware proxy on port 8080.

## Default language model

Installer 3.1.0 uses this model by default:

```text
HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive
Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
```

The model download is approximately 5.63 GB. The installer searches common model folders first, verifies the exact file with SHA-256, and reuses it when valid. When it is not present, the installer downloads it with Windows `curl.exe` into:

```text
%LOCALAPPDATA%\HauHauVoiceStack\models\llm
```

Expected SHA-256:

```text
2ca636d9e81d3d23ca9b60c234fe185d30ec082eeba69ce770fdb0c76559a4f5
```

An existing 27B HauHauCS command is no longer preserved automatically. Installation or repair rewrites the HauHau stack configuration to use the verified 9B model. A 27B GGUF stored outside the HauHau application folder is not deleted because another application may still use it.

## What the installer handles

The installer checks or installs:

- Microsoft Visual C++ x64 runtime, using Microsoft's signed redistributable only when required.
- Python 3.10 or newer. If none is available, it installs a private Python 3.12 runtime through `uv`.
- `llama-server.exe`. A valid existing executable is reused; otherwise the pinned compatible official Windows build is downloaded.
- The verified HauHauCS Qwen3.5 9B Q4_K_M language model.
- CrispASR v0.8.25 with the native Qwen3-TTS backend.
- The Qwen3-TTS talker, codec, and default voice pack, approximately 1.3 GB total.
- The HauHau voice proxy, service supervisor, command wrappers, PATH entry, logs, and Start Menu shortcuts.

The compatible llama.cpp runtime is pinned to build `b10280`. Runtime archives are selected for CUDA, Vulkan, or CPU and verified against the digest published with the upstream release.

Installer 3.1.0 retains the 3.0.4 TTS fixes: Qwen3-TTS files are downloaded through `curl.exe` rather than CrispASR's failing WinHTTP path, interrupted transfers can resume, model files are validated, and a real WAV-generation test confirms the TTS stack. The corrected CrispASR doctor check, NVIDIA-first CUDA selection, and Visual C++ strict-mode fixes remain included.

## Install or upgrade

1. Extract the release ZIP to a normal folder. Do not run it from inside the ZIP preview.
2. Double-click `INSTALL.cmd`.
3. Allow the 9B LLM download and SHA-256 verification to finish. A valid existing copy is reused.
4. Allow the Qwen3-TTS model validation to finish.
5. After the final dependency check passes, double-click `START_HAUHAU.cmd` or run:

```powershell
hauhau-voice-stack up
```

The application is installed per-user at:

```text
%LOCALAPPDATA%\HauHauVoiceStack
```

No administrator access is normally needed. Windows may request elevation only if the Microsoft Visual C++ runtime is missing.

## Runtime selection

`Auto` selects CUDA when an NVIDIA GPU is detected, including GeForce RTX cards. On non-NVIDIA systems it selects Vulkan when available and otherwise falls back to CPU.

To force a runtime:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Runtime Cuda
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Runtime Vulkan
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Runtime Cpu
```

`INSTALL_CUDA.cmd` is included as an explicit NVIDIA fallback.

## Advanced model override

The normal installer is intentionally pinned to the verified HauHauCS 9B model. An explicit model path or tuned llama.cpp command can still override the default:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -ModelPath 'D:\Models\custom-model.gguf'
```

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -LlmCommandLine '"C:\AI\llama-server.exe" --model "D:\Models\custom-model.gguf" --ctx-size 32768 --jinja --port 8080'
```

The supervisor moves the private LLM backend from port 8080 to port 8082. The browser and OpenAI-compatible API remain on port 8080 through the voice-aware proxy.

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

Click-to-run wrappers:

- `INSTALL_DEFER_TTS.cmd`
- `START_HAUHAU.cmd`
- `STOP_HAUHAU.cmd`
- `CHECK_HAUHAU.cmd`
- `REPAIR_HAUHAU.cmd`

## Ports

```text
127.0.0.1:8080  llama.cpp browser/API through the voice proxy
127.0.0.1:8082  private HauHauCS llama-server backend
127.0.0.1:9080  CrispASR Qwen3-TTS server
```

For streamed chat completions, the proxy collects the assistant's final answer, removes markup that should not be spoken, sends the cleaned text to `/v1/audio/speech`, saves the WAV, and plays it through Windows audio.

## Deferring the TTS download

The 9B language model is required during installation. Only the separate Qwen3-TTS model download can be deferred:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipTtsModelDownload
```

The first start can then remain on the TTS startup step while roughly 1.3 GB downloads.

## Logs and files

```text
%LOCALAPPDATA%\HauHauVoiceStack\config.ps1
%LOCALAPPDATA%\HauHauVoiceStack\dependencies.json
%LOCALAPPDATA%\HauHauVoiceStack\models\llm
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

```powershell
hauhau-voice-stack repair
hauhau-voice-stack doctor
```

Repair is idempotent. It switches stale LLM configuration to the verified HauHauCS 9B model, reuses valid cached downloads, and retrieves only dependencies that are absent or broken. Add `-Force` to `install.ps1` to redownload runtime archives.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\HauHauVoiceStack\uninstall.ps1"
```

Add `-KeepConfig` to retain `config.ps1` and `dependencies.json`. The uninstaller stops the process tree, removes the PATH entry and Start Menu shortcuts, and removes private runtimes, managed models, and application files.

## Upstream sources

The installer retrieves dependencies from:

- Microsoft Visual C++ redistributable: Microsoft's `aka.ms` release endpoint.
- `uv`: `astral-sh/uv` GitHub releases.
- llama.cpp: `ggml-org/llama.cpp` release `b10280`.
- CrispASR: `CrispStrobe/CrispASR` release `v0.8.25`.
- HauHauCS 9B LLM: `HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive` on Hugging Face.
- Qwen3-TTS files: official `cstr` Hugging Face GGUF repositories.
