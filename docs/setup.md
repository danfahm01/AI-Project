# Setup

## 0. Run it on this PC (one command, Windows)

The quickest way to use the app: the backend and the web app run together as
one local server at <http://localhost:8000>. No Docker, Visual Studio or Nginx.

Needs Python 3.12+, Flutter 3.50+ (only to build the web app; the script also
finds it in `C:\src\flutter` or `%USERPROFILE%\develop\flutter` when it is not
on `PATH`) and an AI model: a free local one through [Ollama](#2c-local-models-ollama-no-api-key)
(no key), or an OpenAI or Gemini API key.

1. Double-click `start-local.cmd` in the repository root, or run it in a terminal:

   ```powershell
   .\start-local.cmd
   ```

2. If Ollama runs on the PC and no key is set, the script uses Ollama
   (`OLLAMA_BASE_URL=http://127.0.0.1:11434` in `.env`) and asks nothing.
   Otherwise it asks for a key: paste it and press Enter (the input is hidden).
   A key starting with `sk-` is an OpenAI key, one starting with `AIza` a
   (standard) Gemini key; for any other key, such as the Gemini "auth keys" AI
   Studio creates since 2026-05-28, the script asks which provider it belongs to.
   It checks the key with the provider (a list-models call), then saves it as
   `OPENAI_API_KEY` or `GEMINI_API_KEY` in `.env` on this PC; the browser never
   receives it. To change it later, run `start-local.cmd -AddKey` or edit `.env`.
3. The script (`scripts/start-local.ps1`) then:
   - creates `.env` with a random `JWT_SECRET`, so sign-ins survive restarts;
   - creates `backend\.venv` and installs the backend (again only when
     `requirements.txt` changes);
   - creates or migrates the SQLite database in `backend\data\`;
   - builds the web app with `API_BASE_URL=/` (again only when the app's sources
     change, or with `-RebuildWeb`). It builds from a copy without the platform
     folders (`apps\flutter_app\build\local-web`), so Windows Developer Mode is
     not needed;
   - starts the server with `WEB_APP_DIR` pointing at the build and opens the browser.
4. Create an account in the app and start chatting. Voice mode works too: the
   browser allows the microphone on `localhost`.

Keep the window open while you use the app; **Ctrl+C** stops it. Options:
`-Port 8080`, `-RebuildWeb`, `-NoBrowser`, and `-AddKey` (asks for an OpenAI or
Gemini key even when Ollama is already set up, e.g. to add voice mode). The server listens on `127.0.0.1`
only, so other devices on the network cannot reach it.

## 1. Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Git | any recent | Flutter itself and version control |
| Python | 3.12+ (3.14 tested) | Backend |
| Flutter | 3.50+ (Dart 3.14) | App on every platform |
| Docker Desktop | recent | PostgreSQL/Redis stack (optional for local dev) |
| Visual Studio or Build Tools (2022 or newer) with "Desktop development with C++" | | Windows desktop builds on your PC (optional: GitHub Actions can build them, see section 6) |
| Android Studio (SDK + JDK) | | Android builds |
| Xcode (on a Mac) | | iOS and macOS builds |

Run `flutter doctor` to see what's missing. VS Code with the Flutter extension
is a good editor, but it does **not** provide the C++ toolchain that Windows
builds need.

> **Windows path length.** Clone into a short path (for example
> `C:\dev\voice-assistant`). Deep paths break Flutter's native-asset hooks and the
> Python venv (`The filename or extension is too long`). Alternatively, enable
> Windows long paths (admin): *Local Group Policy → Computer Configuration →
> Administrative Templates → System → Filesystem → Enable Win32 long paths*.

## 2. Configuration

```powershell
copy .env.example .env
```

Settings are read from environment variables, then `.env` in the repo root,
then `backend/.env` (later wins). Key values:

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_URL` | `sqlite+aiosqlite:///./data/dev.db` | Use `postgresql+asyncpg://user:pass@host/db` for PostgreSQL |
| `REDIS_URL` | empty | Empty = in-process rate limiter (single worker only) |
| `JWT_SECRET` | empty | Required (32+ chars) in production and with Docker; random per process otherwise |
| `CORS_ALLOW_LOCALHOST` | `true` | Allows the Flutter web dev server; must be `false` in production |
| `CORS_ORIGINS` | empty | Comma-separated production origins |
| `OPENAI_API_KEY`, `GEMINI_API_KEY` | empty | Server-side only; each enables that provider's text chat and voice |
| `OPENAI_REALTIME_MODEL` | `gpt-realtime-2.1` | OpenAI voice model; empty disables OpenAI voice |
| `GEMINI_LIVE_MODEL` | `gemini-3.8-live` | Gemini voice model; empty disables Gemini voice |
| `DEFAULT_AI_PROVIDER` | empty | `openai` or `gemini` when both are configured; empty = OpenAI (first registered) |
| `OLLAMA_BASE_URL` | empty | Local models through Ollama, no key (`http://127.0.0.1:11434`); see section 2c |
| `WEB_APP_DIR` | empty | A Flutter web build (`API_BASE_URL=/`) to serve at `/` from the API server; set by `start-local.ps1` |

## 2b. Enabling AI replies (OpenAI)

1. Create an API key at <https://platform.openai.com/api-keys> and put it in
   `.env` as `OPENAI_API_KEY=...`. It stays on the server and is never sent to apps.
2. Optionally choose the offered models (`OPENAI_MODELS`, `OPENAI_DEFAULT_MODEL`).
   The defaults (`gpt-6.2-astra`, `gpt-6.2-sol`, `gpt-6-luna`) were checked against
   <https://developers.openai.com/api/docs/models> on 2026-11-20. Re-check before
   changing them: model IDs change over time.
3. Restart the backend. `GET /api/v1/providers` now lists OpenAI and the app's
   model picker becomes active.

Responses are requested with `store=false` (OpenAI doesn't keep them), and with
`safety_identifier` set to a hash of the user id (never an email).

## 2c. Local models (Ollama, no API key)

[Ollama](https://ollama.com) runs open models on your own computer: no key, no
cost per message, and conversations never leave the PC. Text chat only (no voice
mode); models with the `vision` capability also read images.

1. Install Ollama: <https://ollama.com/download> (Windows: `OllamaSetup.exe`, per
   user, no admin rights). It runs in the background and serves
   `http://127.0.0.1:11434`.
2. Install a model, for example:

   ```powershell
   ollama pull gemma4:e4b
   ```

   `gemma4:e4b` (about 6.6 GB, reads images) suits a laptop with 6-8 GB of GPU
   memory; `gemma4:e2b` (about 4.6 GB) is faster but simpler. See
   <https://ollama.com/library> for others; larger models need more memory.
3. Set `OLLAMA_BASE_URL=http://127.0.0.1:11434` in `.env` (`start-local.cmd` does
   this itself when it finds Ollama and no key is set) and restart the backend.

The app lists every installed chat model (embedding-only models are left out)
and picks up models pulled later within about 15 seconds; reload the page to see
them. Limit the list with `OLLAMA_ALLOWED_MODELS` and choose the default with
`OLLAMA_DEFAULT_MODEL`. The first reply after a pause takes longer while Ollama
loads the model into memory.

**Voice mode next to local models.** Ollama has no speech-to-speech model (its
text-to-speech model, Phonon, needs Apple Silicon and has no Indonesian voice), so
voice mode needs Gemini or OpenAI. A free Gemini key is enough: stop the server
(Ctrl+C), run `start-local.cmd -AddKey`, paste the key. Text chats can stay on the
local model (pick it in the model menu); voice mode uses Gemini Live
(`gemini-3.8-live`, free of charge on the Free Tier as of 2026-11-22, where Google
may use the data to improve its products). With both configured, new chats default
to Gemini; set `DEFAULT_AI_PROVIDER=ollama` to keep the local model as default. With Docker, use
`OLLAMA_BASE_URL=http://host.docker.internal:11434`.

### Voice mode (OpenAI Realtime)

The same key enables voice. `OPENAI_REALTIME_MODEL` defaults to `gpt-realtime-2.1`
(set it empty to turn voice off). The voices, transcription model, client-secret
lifetime and voice rate limit are in `.env.example`. Then:

1. Open voice mode (the waveform button), press the call button, and allow the
   microphone when asked.
2. Talk. In **hands-free** mode the assistant answers when you pause, and you can
   interrupt it by speaking. In **push-to-talk** mode (Settings → Voice), hold the
   talk button or **Space** while you speak.
3. Close voice mode: the transcript is saved in the conversation.

Platform notes: on the web the microphone works only on `https://` or `localhost`.
Android and iOS ask for permission on first use. On macOS the
`com.apple.security.device.audio-input` entitlement is already set.

**Testing without credits:** `tests/fakes/fake_openai_server.py` imitates the
Responses API streaming format, and its replies say they come from a test
server. It also mints fake realtime client secrets, so voice session creation
can be checked. It cannot run WebRTC calls, so voice ends with "Could not reach
the voice service". Real voice needs a real key. Point the backend at it for an
end-to-end check of streaming, Stop and Regenerate:

```powershell
cd backend
.venv\Scripts\python -m tests.fakes.fake_openai_server --port 9100
# second terminal:
$env:OPENAI_API_KEY="local-test"; $env:OPENAI_BASE_URL="http://127.0.0.1:9100/v1"
.venv\Scripts\uvicorn app.main:create_app --factory --port 8000
```

## 2c. Enabling Google Gemini

1. Create a key at <https://aistudio.google.com/apikey> and put it in `.env` as
   `GEMINI_API_KEY=...`. Like the OpenAI key, it stays on the server.
2. Optionally choose models: `GEMINI_MODELS` / `GEMINI_DEFAULT_MODEL` for text and
   `GEMINI_LIVE_MODEL` for voice. The defaults (`gemini-4-hydrogen`, `gemini-4-carbon`,
   `gemini-3.5-flash-lite`; `gemini-3.8-live`) were checked against
   <https://aistudio.google.com/docs/models> on 2026-11-21.
3. Restart the backend. With both keys set, the chat model picker groups models
   by provider, and Settings → Voice has a **Voice model** picker. Set
   `DEFAULT_AI_PROVIDER=gemini` to make Gemini the default for new users.

Gemini voice streams raw audio over a WebSocket, so the app captures the
microphone with `record` and plays replies with `mp_audio_stream`:

- **Web:** works on `https://` or `localhost`, like OpenAI voice.
- **Linux:** needs `parecord`, `pactl` and `ffmpeg` with PulseAudio or PipeWire
  (`sudo apt install pulseaudio-utils ffmpeg`).
- **Android, iOS, macOS:** use the microphone permissions that are already set up.

Gemini voices have no speed setting, so the slider is hidden. The language comes
from your speech; your language preference is passed in the instructions.

**Testing without credits:** `tests/fakes/fake_gemini_server.py` imitates
`streamGenerateContent`, the token endpoint and the Live WebSocket. It answers
each voice turn with a short silence and a transcript saying it is a test server; it
does not understand speech.

```powershell
cd backend
.venv\Scripts\python -m tests.fakes.fake_gemini_server --port 9200
# second terminal:
$env:GEMINI_API_KEY="local-test"; $env:GEMINI_BASE_URL="http://127.0.0.1:9200/"
.venv\Scripts\uvicorn app.main:create_app --factory --port 8000
```

## 2d. Images and PDFs

Attachments work with both providers once a key is set. Nothing else needs
enabling.

- **Use:** in a chat, press **+** to attach images (PNG, JPEG, WEBP) or PDF documents.
  Android and iOS also offer **Take a photo**. The button is disabled, with a tooltip,
  when the selected model cannot read files.
- **Storage:** files are stored in `ATTACHMENT_STORAGE_DIR` (`backend/data/attachments`
  locally; the `attachments-data` volume with Docker). Back this up together with the
  database.
- **Limits:** see the *Attachments* block in `.env.example`. The defaults are 10 MB per
  file and 5 files per message. Nginx accepts request bodies up to 25 MB
  (`client_max_body_size`); keep it above `ATTACHMENT_MAX_BYTES`.
- **Testing without credits:** both local test servers report the attachments they
  receive ("Attachments received: …"), so you can check the whole path without real
  model answers.

## 3. Backend (without Docker)

```powershell
cd backend
python -m venv .venv
.venv\Scripts\pip install -r requirements-dev.txt
.venv\Scripts\alembic upgrade head          # creates data/dev.db
.venv\Scripts\uvicorn app.main:create_app --factory --reload --port 8000
```

- Health: <http://localhost:8000/health/ready>
- Interactive API docs: <http://localhost:8000/docs>

New migration after changing models:

```powershell
.venv\Scripts\alembic revision --autogenerate -m "describe change"
```

## 4. Backend with Docker (PostgreSQL + Redis + Nginx)

1. Set `JWT_SECRET` and `POSTGRES_PASSWORD` in `.env`.
2. `docker compose up --build`
3. The API is served through Nginx at <http://localhost/api/v1> (docs at <http://localhost/docs>).

Migrations run automatically when the backend container starts
(`RUN_MIGRATIONS=false` disables this).

This stack is plain HTTP for development. For a server (HTTPS, the web app,
production settings, certificates, backups), see [deployment.md](deployment.md).

## 5. Flutter app

```powershell
cd apps/flutter_app
flutter pub get
flutter run -d chrome
```

The app talks to `http://localhost:8000` by default (`http://10.0.2.2:8000` on the
Android emulator). Point it elsewhere with:

```powershell
flutter run --dart-define=API_BASE_URL=https://api.example.com
```

When running against Docker/Nginx locally use `--dart-define=API_BASE_URL=http://localhost`.
A **web** build served by the same server as the API (the production web image)
uses `--dart-define=API_BASE_URL=/`, which means the page's own origin.

Release builds for every platform can also come from GitHub Actions without
any local toolchain: *Actions → Build apps → Run workflow*, then download the
artifacts. Tagged releases are described in
[deployment.md](deployment.md#9-releases-with-github-actions).

## 6. Windows desktop build

**On your PC:**

1. Install Visual Studio or the Build Tools (2022 or newer) with the **Desktop
   development with C++** workload; `flutter doctor` must show it as installed.
2. Enable Developer Mode (*Settings → System → For developers*): Flutter needs
   symlink support for plugins.
3. Build:
   ```powershell
   cd apps/flutter_app
   flutter build windows --release --dart-define=API_BASE_URL=https://api.example.com
   ```
   Output: `build\windows\x64\runner\Release\`. Ship the whole folder (the `.exe`,
   `flutter_windows.dll`, the plugin DLLs such as `libwebrtc.dll`, and `data\`),
   plus `msvcp140.dll`, `vcruntime140.dll` and `vcruntime140_1.dll` from
   `C:\Windows\System32`, unless the users have the Visual C++ Redistributable installed.

**Without Visual Studio:** the *Build apps* workflow builds on a GitHub-hosted
Windows runner and produces `voice-assistant-windows-x64.zip`, which already
contains the runtime DLLs. Unzip it and run `voice_assistant.exe`. Windows
SmartScreen warns about unsigned apps; sign the `.exe` (or package it as MSIX)
before distributing it widely.

## 7. Android build

1. Install Android Studio, then the Android SDK and command-line tools from its
   SDK Manager; run `flutter doctor --android-licenses`. Gradle must run on
   **JDK 21** (Android Studio's bundled JDK is fine): with JDK 17, Android lint
   in release builds crashes with `NoSuchMethodError ... List.removeLast()`.
2. Change the application id (`com.example.voice_assistant`) in
   `android/app/build.gradle.kts` before publishing: Google Play rejects `com.example`.
3. Debug builds may use plain HTTP to `10.0.2.2` (allowed in
   `android/app/src/debug/AndroidManifest.xml` only). Release builds require HTTPS.
4. **Signing.** Create an upload keystore once and keep it (and its passwords) safe.
   Losing it means you can no longer update the app:
   ```powershell
   keytool -genkey -v -keystore $env:USERPROFILE\upload-keystore.jks `
           -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
   Then create `android/key.properties` (git-ignored):
   ```properties
   storePassword=<keystore password>
   keyPassword=<key password>
   keyAlias=upload
   storeFile=C:\\Users\\<you>\\upload-keystore.jks
   ```
   Without this file, release builds are signed with the debug key: fine for
   installing on your own phone, but not for Google Play. For CI, see the
   `ANDROID_*` secrets in [deployment.md](deployment.md#9-releases-with-github-actions).
5. Build:
   ```powershell
   # One smaller APK per CPU type (arm64-v8a fits almost every current phone):
   flutter build apk --release --split-per-abi --dart-define=API_BASE_URL=https://api.example.com
   # App bundle for Google Play (Play generates per-device APKs):
   flutter build appbundle --release --dart-define=API_BASE_URL=https://api.example.com
   ```
   Output: `build/app/outputs/flutter-apk/` and `build/app/outputs/bundle/release/`.
   Release builds are shrunk by R8 (flutter_webrtc ships its own keep rules).
   `minSdk` is Flutter's default, 24 (Android 7.0), which the plugins require.

## 8. iOS, macOS and Linux

- **iOS** (Mac with Xcode; deployment target iOS 15, required by `image_picker`):
  1. Change the bundle identifier `com.example.voiceAssistant` in Xcode
     (*Runner → Signing & Capabilities*) and choose your team.
  2. `flutter build ipa --release --dart-define=API_BASE_URL=https://api.example.com`
     produces `build/ios/ipa/*.ipa` for App Store Connect / TestFlight.
  3. Microphone, camera and photo-library permission texts are already in `Info.plist`.
  CI runs `flutter build ios --release --no-codesign` to check that it compiles; an
  installable build needs your Apple Developer account and signing.
- **macOS** (macOS 12+): `flutter build macos --release --dart-define=API_BASE_URL=...`
  produces `build/macos/Build/Products/Release/voice_assistant.app`. The sandbox
  entitlements allow network access, the microphone and user-selected files. CI
  builds an unsigned zip; for distribution outside the App Store, sign it with a
  Developer ID certificate and notarize it, otherwise Gatekeeper blocks it.
- **Linux** build dependencies (Ubuntu/Debian):
  ```bash
  sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev \
    libsecret-1-dev libpulse-dev
  flutter build linux --release --dart-define=API_BASE_URL=https://api.example.com
  ```
  Output: `build/linux/x64/release/bundle/` (run `voice_assistant`; keep `lib/` and
  `data/` next to it). On users' machines the app needs GTK 3, libsecret (secure
  token storage) and PulseAudio or PipeWire; Gemini voice also needs
  `pulseaudio-utils` and `ffmpeg` (microphone capture).

## 9. Running the tests

```powershell
cd backend
.venv\Scripts\ruff check . ; .venv\Scripts\ruff format --check .
.venv\Scripts\pytest -q --cov=app            # coverage report; CI requires >= 90 %
.venv\Scripts\pip-audit                      # known vulnerabilities in installed packages

cd ..\apps\flutter_app
dart format --line-length 120 --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

The rate-limiter tests against a real Redis run when `REDIS_TEST_URL` is set
(for example `redis://localhost:6379/0`).

**Against a running server:** `backend/scripts/smoke_test.py` checks a live
deployment end to end (health, headers, sign-in, conversations, attachments,
chat WebSocket). See [deployment.md](deployment.md#6-verify).

```powershell
.venv\Scripts\python scripts\smoke_test.py --base-url http://localhost:8000
```

CI (`.github/workflows/ci.yml`) runs all of the above, migrations against
PostgreSQL, and the full production Docker stack over HTTPS with the smoke test.
