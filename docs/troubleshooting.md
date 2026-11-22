# Troubleshooting

## `start-local.cmd`

| Message | Cause and fix |
|---|---|
| `The pasted text (N characters, ...) is not an API key` | The paste did not arrive (N is 0), or text with spaces was copied. Copy the key itself from the provider's website and paste with right-click or Ctrl+V. Or open `.env` in the repository root (`notepad .env`), put the key after `OPENAI_API_KEY=` or `GEMINI_API_KEY=` (no quotes, no spaces), save, run again |
| `The provider rejected this key, so it was not saved` | The key is wrong, deleted, or (Gemini) an older unrestricted standard key, which Google now rejects. Create a new key in AI Studio; new keys are "auth keys" and do not start with `AIza` |
| Replies fail with `provider_auth_failed`; the server log shows `401 Incorrect API key provided` | The value in `.env` is not a valid key. Fix it in `.env`, or empty it and let the script ask again, then restart the script |
| `localhost refused to connect` | The server is not running yet: wait until the window prints `Ready: http://localhost:8000` (the browser opens by itself), and keep that window open |
| `Python 3.12 or newer is required` | Install Python from <https://www.python.org/downloads/> (tick "Add python.exe to PATH" or use the `py` launcher) |
| `Flutter is needed once to build the web app` | Install Flutter, or put it on `PATH`. Only the first run (and app changes) need it |
| `Port 8000 is already in use` | Another program (or a second copy of the script) uses the port. Close it, or run `start-local.cmd -Port 8080` |
| The page loads but replies say "No AI provider is configured" | The key line in `.env` is commented out or empty. Fix it and restart the script |
| `provider_auth_failed` / `provider_rate_limited` under a reply | The key is wrong or the OpenAI account has no credit: check <https://platform.openai.com/settings/organization/billing> |
| Old app version after changing the Flutter code | Run `start-local.cmd -RebuildWeb` |

## Ollama (local models)

| Symptom | Cause and fix |
|---|---|
| "Ollama is not running on this computer" under a reply | Start Ollama from the Start menu (its icon appears in the taskbar tray), then retry |
| "No model available" in the app although `OLLAMA_BASE_URL` is set | Ollama is not running, or has no chat model: run `ollama pull gemma4:e4b`, wait about 15 s, reload the page |
| "The selected model is not installed in Ollama" | The model was removed (`ollama rm`). Pick another one in the model menu, or pull it again |
| The first reply takes long, later ones are quick | Ollama loads the model into memory on first use (and after 5 idle minutes). Normal |
| Replies are slow | The model does not fit in the GPU memory and partly runs on the CPU. Use a smaller model (`gemma4:e2b`) or close other GPU programs |
| `ollama` is not recognized in a terminal | Open a new terminal after installing Ollama, or use `%LOCALAPPDATA%\Programs\Ollama\ollama.exe` |
| The voice button says voice is not available | Ollama models are text only; voice mode needs Gemini or OpenAI. Add a free Gemini key: stop the server, run `start-local.cmd -AddKey` (setup.md, section 2c) |

## Windows: "The filename or extension is too long" / "Failed to canonicalize path ... (122)"

Windows limits paths to 260 characters unless long paths are enabled. A deep
checkout breaks:

- the Python venv (`DLL load failed while importing _collections_cy`), and
- Flutter's native-asset hooks (`Building assets for package:objective_c failed`).

Fix: move the repository to a short path such as `C:\dev\voice-assistant`, or
enable Win32 long paths (admin, Group Policy or registry `LongPathsEnabled=1`).
The venv can also live elsewhere, e.g. `python -m venv C:\venvs\assistant`.

## `alembic upgrade head` → "unable to open database file"

Fixed since phase 1: the migration runner now creates the SQLite folder. If you
still see it, check that `DATABASE_URL` points at a writable location.

## Flutter web: "Can't reach the server"

- Is the backend running? `curl http://localhost:8000/health/ready`
- CORS: the backend allows `http://localhost:<any port>` while
  `CORS_ALLOW_LOCALHOST=true`. For other origins, add them to `CORS_ORIGINS`.
- Wrong URL: pass `--dart-define=API_BASE_URL=...`.

## Android emulator can't reach the backend

The emulator reaches your PC at `10.0.2.2`, which is the app's default on
Android. A physical device needs your PC's LAN IP
(`--dart-define=API_BASE_URL=http://192.168.x.y:8000`) and the backend listening on
`0.0.0.0` (`uvicorn ... --host 0.0.0.0`). Plain HTTP works only in debug builds.

## `flutter doctor`: Visual Studio not installed

Windows desktop builds need Visual Studio or Build Tools with the "Desktop
development with C++" workload. VS Code alone is not enough. Web, Android and
tests don't need it.

## "Building with plugins requires symlink support"

Enable Developer Mode on Windows (*Settings → System → For developers*). It's
only needed for Windows desktop builds and `flutter run`/`flutter build` in
`apps/flutter_app`; `start-local.cmd` builds the web app from a copy without the
platform folders and works without it.

## Signed out unexpectedly

Refresh tokens rotate on every use, and reusing an old one revokes the session
(theft protection). This happens if two app instances share one stored session
or if the server's `JWT_SECRET` changed (for example, it was empty in
development and the server restarted). Set a fixed `JWT_SECRET` in `.env`.

## 429 Too Many Requests

Auth endpoints allow `RATE_LIMIT_AUTH_PER_MINUTE` requests per IP per minute;
other endpoints `RATE_LIMIT_API_PER_MINUTE` per user. Wait for `Retry-After`
seconds, or raise the limits in `.env` for local testing.

## Chat replies fail

The error under the reply (or the banner above the composer) names the cause.
The server log has the provider's full message.

| Message / code | What to do |
|---|---|
| "No AI provider is configured" (`provider_not_available`) | Set `OPENAI_API_KEY`, `GEMINI_API_KEY`, `ANTHROPIC_API_KEY` or `OLLAMA_BASE_URL` and restart the backend |
| `provider_out_of_credit` (Claude) | The Claude Console account has no API credit or reached its spend limit. Add credit at <https://platform.claude.com>; a claude.ai Pro/Max subscription does not cover the API |
| `provider_auth_failed` | The key is wrong, revoked, or lacks access to the model (Gemini reports an invalid key as HTTP 400 "API key not valid"; it is mapped here too) |
| `provider_content_blocked` | The provider's safety system declined the request (Gemini `promptFeedback.blockReason`, or a safety stop before any text). Rephrase the message |
| `provider_rate_limited` | OpenAI rate limit or quota reached; check usage and billing |
| `provider_model_unavailable` | A model in `OPENAI_MODELS` / `GEMINI_MODELS` doesn't exist for your account; re-check the provider's models page |
| `provider_timeout` / `provider_unavailable` | Network problem or OpenAI outage; try again, or raise `AI_REQUEST_TIMEOUT_SECONDS` |
| "Too many messages" (`rate_limited`) | `RATE_LIMIT_CHAT_PER_MINUTE` reached |

## Attachments

| Message / code | What to do |
|---|---|
| **+** button disabled ("… doesn't accept images or PDFs") | The conversation's model has no image/PDF input. Pick another model in the model menu. Models set via `OPENAI_MODELS` / `GEMINI_MODELS` that the app does not know are treated as text-only |
| "… is not a PNG, JPEG or WEBP image or a PDF" / `attachment_type_not_supported` | Other formats (GIF, HEIC, Word, …) are not accepted. Convert the file, e.g. export a photo as JPEG or a document as PDF |
| "… is larger than 10.0 MB" / `attachment_too_large` | Over `ATTACHMENT_MAX_BYTES`. Behind Nginx, a very large file can also be refused with 413 before it reaches the API (`client_max_body_size`) |
| `attachments_too_large` | The files of one message exceed `ATTACHMENT_CONTEXT_MAX_BYTES` together. Send them in separate messages |
| `attachments_not_supported` (the message shows **Retry**) | The model was switched to one that cannot read the file. Switch back, or discard the message |
| `attachment_not_found` | The upload expired (unsent for `ATTACHMENT_PENDING_TTL_HOURS`) or was already sent. Attach it again |
| A PDF does not open | Opening uses a signed link valid for 5 minutes. Make sure a browser or PDF viewer is installed. On the web, allow pop-ups for the app |
| The model mentions an "earlier image is not repeated" | Older files are left out once a request reaches `ATTACHMENT_CONTEXT_MAX_BYTES`; attach the file again if it is needed |

## Production deployment (Docker)

| Symptom | Cause and fix |
|---|---|
| `nginx` exits: `cannot load certificate "/etc/nginx/certs/fullchain.pem"` | No certificate yet. Use Let's Encrypt, your own files in `infrastructure/certs/`, or `make-dev-cert.sh` for a local trial (deployment.md, section 4). With Let's Encrypt, also set `TLS_CERTIFICATE` / `TLS_CERTIFICATE_KEY` |
| `certbot certonly --standalone`: port 80 already in use | Nginx is running. Stop it for the first certificate (`docker compose ... stop nginx`), or use `--webroot -w /var/www/certbot` while it runs |
| `Set SERVER_NAME in .env` (or `JWT_SECRET`, `POSTGRES_PASSWORD`) | Required value missing in `.env` |
| `!override` / `yaml: unknown tag` | Docker Compose is older than 2.24; update it |
| Backend restarts with `CORS_ORIGINS must list https:// origins` / `... must be an https:// URL in production` | Production refuses insecure settings. Use `https://` origins (or leave `CORS_ORIGINS` empty) and HTTPS provider base URLs |
| The web app shows "Can't reach the server at …" | A web build made for another server. The web image uses `API_BASE_URL=/` (same origin); a separately hosted web build needs `--dart-define=API_BASE_URL=https://<api host>` and that origin in `CORS_ORIGINS` |
| Voice mode in the browser fails, console shows `Refused to connect … Content Security Policy` | `OPENAI_BASE_URL` points at a gateway. Add its host to `CSP_CONNECT_SRC` on the nginx service (deployment.md, section 8) |
| Everyone gets 429 at once | A load balancer/CDN in front of Nginx: all requests appear to come from it. Configure `real_ip` (deployment.md, section 8) |
| `413 Request Entity Too Large` | Upload above Nginx's `client_max_body_size` (25 MB, `snippets/http-common.conf`) |
| `/docs` returns 404 in production | Intended: `ENABLE_API_DOCS=false` in the production overlay. Set it to `true` in `.env` to publish the docs |
| After a deploy the browser still runs the old app | `index.html` and `flutter_bootstrap.js` are revalidated on every load; reload once. A proxy/CDN in front must not cache them longer |

## Release builds

| Symptom | Cause and fix |
|---|---|
| Release workflow: `API_BASE_URL must start with https://` | Set the repository variable `API_BASE_URL` (Settings → Secrets and variables → Actions → Variables) |
| Google Play rejects the bundle as debug-signed | No `key.properties` (local) or `ANDROID_*` secrets (CI): see setup.md, section 7 |
| Android release app can't reach the server | Release builds allow HTTPS only; build with an `https://` `API_BASE_URL` |
| Android: `Execution failed for task ':mp_audio_stream:checkReleaseAarMetadata'` … `is currently compiled against android-31` | A plugin pins an old compileSdk/NDK. `android/build.gradle.kts` raises every plugin to the app's compileSdk, minSdk and NDK; keep that block if the `android/` folder is regenerated |
| Android: `lintVitalAnalyzeRelease` fails with `NoSuchMethodError` … `List.removeLast()` | Gradle runs on JDK 17. Use JDK 21 (`flutter config --jdk-dir <JDK 21>` or Android Studio's bundled JDK) |
| Windows: "VCRUNTIME140_1.dll was not found" | The Visual C++ runtime DLLs are missing next to the `.exe` (the CI zip includes them; for local builds see setup.md, section 6) |
| macOS: "app is damaged" / "unidentified developer" | CI builds are unsigned. Right-click → Open for testing; sign and notarize for distribution |
| Linux: `error while loading shared libraries: libsecret-1.so.0` | Install `libsecret-1-0` (and `libgtk-3-0`) on the target machine |

## "Connection lost. Reconnecting…"

The chat WebSocket dropped and the app retries with backoff (1 s up to 30 s).
Behind Nginx, `/api/` needs the `Upgrade`/`Connection` headers (already in
`infrastructure/nginx/nginx.conf`). A reply that was generating when the
connection dropped keeps going on the server and shows up after reconnecting.

## Voice mode

| Message | Cause and fix |
|---|---|
| "Voice needs a realtime-capable AI provider…" (call button disabled) | No realtime model on the server. Set `OPENAI_API_KEY` and keep `OPENAI_REALTIME_MODEL` (default `gpt-realtime-2.1`) non-empty, then restart the backend |
| "Microphone access was denied…" | Allow the microphone. **Web:** click the lock icon in the address bar → Microphone → Allow, then reload. Browsers only allow the microphone on `https://` or `localhost`/`127.0.0.1`. **Windows:** Settings → Privacy & security → Microphone → allow desktop apps. **macOS:** System Settings → Privacy & Security → Microphone. **Android/iOS:** app settings → Permissions → Microphone |
| "No microphone was found…" | Connect or enable an input device; check it is not exclusively used by another app |
| **Web:** the call ends right after it starts; the server log shows `GET /assets/packages/record_web/assets/js/record.worklet.js` → 404 | The web build is missing the fixed-name plugin scripts: `--web-content-hash` renames them, but the plugins load them by their original name. After `flutter build web`, run `dart run tool/fixed_name_web_assets.dart build/web` in `apps/flutter_app` (the web image, CI and `start-local.cmd` do this). `start-local.cmd` redoes older builds by itself |
| "The voice session expired before it connected" | The client secret (`VOICE_TOKEN_TTL_SECONDS`, default 120 s) ran out before the WebRTC handshake finished, often because of a very slow network or a device clock far off. Try again; raise the TTL if it keeps happening |
| "Could not reach the voice service…" | The device cannot reach `api.openai.com` (firewall, proxy, offline), or the server points `OPENAI_BASE_URL` at a gateway without realtime support. The local test server (`tests.fakes.fake_openai_server`) also ends here on purpose, because it cannot run WebRTC calls |
| "Too many requests" when starting | `RATE_LIMIT_VOICE_SESSIONS_PER_MINUTE` reached |
| "Connection lost. Start a new voice session…" | The call dropped and one automatic retry failed. Turns finished before the drop are already saved in the conversation |

The assistant hears itself (echo): use headphones, or keep **echo cancellation**
on in Settings → Voice. Transcripts appear in the conversation after you close
voice mode. A turn whose transcription failed is skipped rather than saved empty.

### Gemini voice

| Symptom | Cause and fix |
|---|---|
| Voice uses OpenAI although Gemini is configured | Voice mode uses the **Voice model** chosen in Settings → Voice. Without one, it follows the open conversation's provider, else the server default |
| "The voice session expired before it connected" | The ephemeral token was not used within `VOICE_TOKEN_TTL_SECONDS`, or the server rejected it (close code 1008). Try again; check the device clock |
| "The voice service did not respond" | No `setupComplete` within 15 s: network, proxy, or the token's API version. Ephemeral tokens need `GEMINI_API_VERSION=v1beta` |
| Brief "Reconnecting…" every ~10 minutes | Live API connections are limited to about 10 minutes. The app normally switches connections silently on `goAway`; a visible reconnect means the switch happened mid-reply. The conversation context is kept |
| Session ends after `VOICE_SESSION_MAX_SECONDS` | The token stops working then (default 30 min). Raise it (max 72000) or start a new session |
| No microphone on Linux | Install `pulseaudio-utils` and `ffmpeg` (`parecord`, `pactl`, `ffmpeg` are used for capture) |
| No sound on the web | The browser blocked audio output until a tap; start the session with the call button (a tap) and check the tab is not muted |
| The stop button stops playback, but the transcript is shorter than the reply | Expected: the Live API cannot cancel a reply, so the app drops the rest and saves what was heard |
