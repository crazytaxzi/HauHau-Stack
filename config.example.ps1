# Example only. INSTALL.cmd generates the real file at:
# %LOCALAPPDATA%\HauHauVoiceStack\config.ps1

$INSTALL_RUNTIME = 'Vulkan'
$LLM_COMMAND_LINE = '"C:\Users\You\AppData\Local\HauHauVoiceStack\runtime\llama.cpp\llama-server.exe" --model "C:\Models\HauHauCS-Qwen3.5-4B.gguf" --host 127.0.0.1 --port 8080 --ctx-size 32768 --jinja --n-gpu-layers 99'
$PYTHON_COMMAND_LINE = '"C:\Users\You\AppData\Roaming\uv\python\cpython-3.12\python.exe"'
$TTS_START_COMMAND_LINE = '"C:\Users\You\AppData\Local\HauHauVoiceStack\runtime\crispasr\crispasr.exe" --server --backend qwen3-tts -m "C:\Users\You\AppData\Local\HauHauVoiceStack\models\crispasr\qwen3-tts-12hz-0.6b-base-q8_0.gguf" --codec-model "C:\Users\You\AppData\Local\HauHauVoiceStack\models\crispasr\qwen3-tts-tokenizer-12hz.gguf" --voice "C:\Users\You\AppData\Local\HauHauVoiceStack\models\crispasr\qwen3-tts-voice-default.gguf" --cache-dir "C:\Users\You\AppData\Local\HauHauVoiceStack\models\crispasr" --host 127.0.0.1 --port 9080 --no-warmup'
$TTS_STOP_COMMAND_LINE = ''
$TTS_MODEL_PRELOADED = $true

$PUBLIC_URL = 'http://127.0.0.1:8080'
$BACKEND_URL = 'http://127.0.0.1:8082'
$TTS_URL = 'http://127.0.0.1:9080'
$TTS_SPEED = 0.94
$LLM_STARTUP_TIMEOUT = 900
$TTS_STARTUP_TIMEOUT = 1200
$PROXY_STARTUP_TIMEOUT = 30
