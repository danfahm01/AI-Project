# Architecture

This document is the reference design for the Voice Assistant monorepo. Sections
marked **(planned)** describe phases that are not implemented yet; everything
else exists in the code today.

## 1. System overview

```
┌──────────────────────────── Flutter app (Android/iOS/Windows/macOS/Linux/Web) ───────────────────────────┐
│ Presentation (features/*/presentation)  → widgets, screens, responsive shell                              │
│ Application  (features/*/application, providers/) → Riverpod notifiers, controllers                      │
│ Domain       (domain/)  → entities, repository interfaces, voice session state machine                   │
│ Data         (data/, core/network) → DTOs, Dio API client, secure token storage, repository impls        │
└───────────────┬────────────────────────────────────────────────────────────────┬─────────────────────────┘
                │ HTTPS REST (JSON) + WSS (chat stream)                            │ WebRTC (OpenAI) / WSS (Gemini)
                ▼                                                                  │ to the AI provider with a
┌──────────────────────── Nginx (TLS termination, WS upgrade, limits) ──────────┐  │ short-lived credential
└───────────────┬───────────────────────────────────────────────────────────────┘  │
                ▼                                                                  ▼
┌──────────────────────────── FastAPI backend ───────────────────────┐   ┌──────────────────────────┐
│ api/v1 (routers) → services → repositories → models (SQLAlchemy)    │   │ OpenAI Realtime API       │
│ schemas (Pydantic)   core (config, security, errors, rate limit)    │──▶│ Google Gemini Live API    │
│ ai_providers (adapter interface + registry; OpenAI, Gemini)         │   │ (server-side keys only)   │
└───────┬───────────────────────────────┬────────────────────────────┘   └──────────────────────────┘
        ▼                               ▼
   PostgreSQL (SQLite for local dev)   Redis (rate limiting; in-memory fallback in dev)
```

## 2. Layering rules

| Layer | Flutter | Backend | May depend on |
|---|---|---|---|
| Presentation | `features/*/presentation` | `app/api` | application/services |
| Application | `features/*/application`, `providers/` | `app/services` | domain, data interfaces |
| Domain | `domain/` | `app/schemas`, `app/ai_providers/base.py` | nothing app-specific |
| Data | `data/`, `core/network`, `core/storage` | `app/repositories`, `app/models` | domain |
| AI provider | `data/voice/` (realtime transports) | `app/ai_providers/*` | domain only |

UI code never imports a provider-specific class. Both sides talk to providers
through one adapter interface, and a registry picks the adapter from configuration.

## 3. AI provider adapter

`backend/app/ai_providers/base.py` defines the contract every provider implements:

- `capabilities` – a typed `ProviderCapabilities` object (text streaming, realtime
  voice, image/PDF input, voices, languages, speed control, VAD modes). The UI only
  shows options that the active provider/model reports.
- `stream_chat(request)` → async iterator of `ChatStreamEvent` (text deltas, usage, done, error).
- `create_realtime_session(request)` → `RealtimeSessionDescriptor` (transport,
  endpoint, short-lived client credential, expiry, negotiated config).
- `aclose()` – release network resources.
- `refresh(force=)` – optional: update the model list while the server runs
  (Ollama, whose installed models change with `ollama pull`). The registry calls it
  at startup, on `GET /providers` and before each chat reply; Ollama rate-limits it
  to one check per 15 s.

`ProviderRegistry` holds the adapters that are configured (API key or URL present
and enabled), resolves the default (`DEFAULT_AI_PROVIDER`, else the first configured),
and rejects unknown providers. Three adapters exist: `openai_provider.py`,
`gemini_provider.py` and `ollama_provider.py` (local models through Ollama's
`/api/chat`, no key, text and images only; a provider without models, such as
Ollama that is not running, is left out of `/providers`). Tests also use a
**test-only** mock adapter (`backend/tests/fakes`).
The running app has no fake provider: with no adapter configured, the
`/providers` endpoint returns an empty list and the UI says so.

| | OpenAI | Google Gemini |
|---|---|---|
| Text chat | Responses API (`openai` SDK), `store=false` | `streamGenerateContent` (`google-genai` SDK), `store=false` |
| Images / PDFs | `input_image` / `input_file` (base64 data URLs) | inline data parts |
| Default text models | `gpt-6.2-astra`, `gpt-6.2-sol`, `gpt-6-luna` | `gemini-4-hydrogen`, `gemini-4-carbon`, `gemini-3.5-flash-lite` |
| Voice model | `gpt-realtime-2.1` | `gemini-3.8-live` |
| Voice transport | WebRTC (audio + data channel) | WebSocket (JSON + base64 PCM) |
| Short-lived credential | client secret (`/realtime/client_secrets`) | single-use ephemeral token (`/v1beta/auth_tokens`) with locked config |
| Voices | 10 | 30 prebuilt voices |
| Speaking rate | 0.25–1.5 | not supported (control hidden) |
| End-user ID | `safety_identifier` (hashed user id) | no such field; nothing sent |

**Capability handling.** Each model reports what it can do (`ProviderCapabilities`),
and the app builds its options from that: the chat model picker lists only
`text_streaming` models, voice mode only `realtime_voice` models, and the voice
settings show voices, languages and a speed slider only when the selected model
reports them. Text and voice models are chosen separately (`default_*` and
`voice_*` preferences). A stale choice falls back to the server default, and an unknown
voice falls back to the model's default.

### Text chat streaming (phase 2)

```
Flutter ChatController ──WSS /api/v1/chat/ws──▶ ChatConnection ──▶ ChatService ──▶ AIProvider.stream_chat
        ▲  message.created / response.delta / ...           │ DB: user msg, assistant msg (streaming → final)
        └───────────────────────────────────────────────────┘
```

- **Why WebSocket, not SSE:** Dio on Flutter web cannot reliably stream an HTTP
  response body, while WebSockets work on every target. The socket also carries
  cancel and regenerate commands.
- **Auth:** the first frame carries the access token. On `token_expired`, the
  client refreshes once and reconnects. Each signed-in account gets its own socket.
- **Persistence:** the assistant row is created with `status=streaming` and
  finalised as `complete | error | cancelled` (partial text kept). No DB session
  is held while tokens stream.
- **Resilience:** a generation survives client disconnects. The client reconnects
  with backoff (1 s → 30 s) and reloads the conversation if it lost the
  connection mid-reply. Server shutdown cancels in-flight generations, which save
  their partial text.
- **Client rendering:** deltas are batched every 40 ms. Markdown is rendered by
  `core/widgets/markdown_view.dart` (GFM via `package:markdown`, code
  highlighting via `re_highlight`), themed with `material_ui`.
- **OpenAI adapter** (`ai_providers/openai_provider.py`): official SDK, Responses API,
  `store=false`, `safety_identifier` = a hash of the user id, and provider errors
  mapped to neutral codes. Raw provider messages are logged, never shown.

### Images and PDFs in chat (phase 5)

```
Composer ──POST /api/v1/attachments (multipart)──▶ AttachmentService ── sniff type, size, sha256 ──▶ AttachmentStorage (disk / volume)
   │            ◀── {id, kind, filename, …}  (pending)
   └─ message.send {content, attachment_ids} ──▶ ChatService: resolve model → check kinds vs capabilities → store message + link files
                                                   └─ history turns + files (newest first, ATTACHMENT_CONTEXT_MAX_BYTES) ──▶ provider
```

Verified on 2026-11-21 against OpenAI's images-vision and file-inputs guides, the model
pages, the `openai` SDK types, Google's image-understanding, document-processing and
file-input guides, and the `google-genai` SDK:

- **Accepted files:** PNG, JPEG, WEBP and PDF. These are the formats both providers
  document. GIF is left out (Gemini does not list it), as are HEIC/HEIF (OpenAI does not
  accept them). The type comes from the magic bytes, and the file name is cleaned.
- **OpenAI:** a user turn becomes `[{"type": "input_text"}, {"type": "input_image",
  "image_url": "data:<mime>;base64,…", "detail": "auto"}, {"type": "input_file",
  "filename", "file_data": "data:application/pdf;base64,…"}]`. PDFs are parsed into text
  plus page images, which needs an image-capable model. `gpt-6.2-astra`, `gpt-6.2-sol`
  and `gpt-6-luna` list "Input modalities: text, image". Limits: 50 MB for files per
  request, 512 MB total payload for images.
- **Gemini:** `Part(text)` first, then `Part.from_bytes(data, mime_type)` (inline data).
  The image guide puts the prompt before the image. Gemini 4 Hydrogen/Carbon and
  3.5 Flash-Lite list "Text, Image, Video, Audio, and PDF". The image guide gives
  **20 MB per inline request** (another page says 100 MB; the lower figure is used).
- **Budget:** files go inline as base64 (no provider-side file storage, so nothing to
  clean up there). Per file the cap is `ATTACHMENT_MAX_BYTES` (10 MB). All files sent
  in one request share `ATTACHMENT_CONTEXT_MAX_BYTES` (12 MB raw, about 16 MB base64),
  newest first. Older files beyond it become a note in that turn's text, so the model
  knows they existed.
- **Capabilities:** models report `image_input` / `pdf_input`. The composer offers only
  what the conversation's model reads. The server checks again before storing anything,
  and rejects with `attachments_not_supported` (uploads stay pending for a resend). If
  the model is changed later, earlier files it cannot read become text notes.
- **Privacy and safety:** files are owned per user, `nosniff` is set, and only images
  and PDFs are served. PDFs open outside the app through HMAC-signed links that are
  scoped to one file and expire after 5 minutes. Thumbnails are downloaded with the
  user's token. Deleting a message, a later turn or a conversation deletes the files.
  Unsent uploads expire after 24 hours.
- **Client:** `file_picker` (all platforms) for images and PDFs, and `image_picker` for
  the camera on Android and iOS (photos are scaled to 2048 px, JPEG quality 85).
  Uploads show progress and errors in chips. A failed send keeps its files for Retry.

### Realtime voice (phase 3)

```
Flutter VoiceSessionController
  └─ OpenAIRealtimeTransport ──POST /api/v1/voice/sessions──▶ VoiceService ──▶ OpenAI POST /v1/realtime/client_secrets
       │                       ◀── {endpoint, client_secret (≤120 s), voice, push_to_talk}
       ├─ WebRtcRealtimeLink: mic track + "oai-events" data channel
       │     SDP offer ──POST <endpoint> (Bearer client_secret, application/sdp)──▶ OpenAI /v1/realtime/calls
       │     ◀══════════════ audio (WebRTC) + JSON events (data channel) ══════════════▶
       └─ finished turns ──POST /api/v1/voice/sessions/{id}/transcripts──▶ messages (audio_metadata.source = "voice")
```

Verified on 2026-11-20 against OpenAI's realtime WebRTC, conversations and VAD
guides and the official SDK's generated types:

- **Credentials:** the backend calls `client.realtime.client_secrets.create(session=…,
  expires_after={"anchor": "created_at", "seconds": VOICE_TOKEN_TTL_SECONDS})` with
  the `OpenAI-Safety-Identifier` header. The session config is fixed **server-side**:
  `gpt-realtime-2.1`, instructions (system prompt, language hint, recent conversation
  text), voice, speed (clamped to 0.25–1.5), input transcription
  (`gpt-realtime-whisper`, ISO-639-1 language), and turn detection. The client
  cannot change the model or the prompt.
- **Audio path:** the SDP offer goes from the device straight to OpenAI on a
  separate HTTP client, so the app's own tokens never leave our backend. Audio never
  touches our server. A server relay is not needed for any current target, because
  `flutter_webrtc` covers Android, iOS, macOS, Windows, Linux and web.
- **Turn-taking:** hands-free mode uses `semantic_vad` with `create_response` and
  `interrupt_response`. Push-to-talk sets `turn_detection: null`. Pressing sends
  `input_audio_buffer.clear` (plus `response.cancel` and `output_audio_buffer.clear`
  if the assistant is talking). Releasing sends `input_audio_buffer.commit` and
  `response.create`. The microphone track is enabled only while the button
  (or Space) is held.
- **Interruption:** speaking over the assistant is handled by server VAD. The stop
  button sends `response.cancel` and `output_audio_buffer.clear`.
- **Events → state machine:** `OpenAIRealtimeProtocol` (pure Dart, unit-tested)
  maps `input_audio_buffer.speech_started/stopped`,
  `output_audio_buffer.started/stopped/cleared`, `response.created/done` and the
  transcript delta/done events onto the voice state machine (§4).
- **Transcripts in order:** `conversation.item.added` reserves a slot per item. A
  finished turn is saved only after every earlier item has finished, failed, or
  gone stale (15 s), so a late user transcript is still stored before the reply
  it triggered. Interrupted replies keep what was actually said.
- **Audio levels:** the orb follows WebRTC `audioLevel` stats: the microphone
  (`media-source`) while listening, playback (`inbound-rtp`) while speaking.
- **Resilience:** a dropped call is retried once with a fresh session in the same
  conversation (a realtime call cannot be resumed). Finished turns are flushed and
  the session is ended on close.
- **Permissions:** Android `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS`, iOS and macOS
  `NSMicrophoneUsageDescription`, and the macOS `com.apple.security.device.audio-input`
  entitlement. Browsers ask on first use (HTTPS or localhost only). A denied
  permission shows how to fix it.

### Realtime voice with Gemini Live (phase 4)

```
Flutter VoiceSessionController
  └─ GeminiLiveTransport ──POST /api/v1/voice/sessions──▶ VoiceService ──▶ Gemini POST /v1beta/auth_tokens
       │                    ◀── {endpoint (wss), client_secret = auth_tokens/…, input/output audio format, session end}
       ├─ RecordPcmCapture (package:record): 16 kHz 16-bit PCM from the microphone
       ├─ WebSocketLiveSocket ══ wss://…/BidiGenerateContentConstrained?access_token=… ══▶ Gemini Live
       │     setup ▶ ◀ setupComplete; realtimeInput.audio ▶; ◀ serverContent (24 kHz PCM, transcripts)
       ├─ StreamPcmPlayback (package:mp_audio_stream): plays the reply as it arrives
       └─ finished turns ──POST /api/v1/voice/sessions/{id}/transcripts──▶ messages
```

Verified on 2026-11-21 against Google's Live API guides (ephemeral tokens,
capabilities, WebSocket get-started), the models page and the `google-genai` SDK 3.6.1
types and request converters:

- **Credentials:** `client.aio.auth_tokens.create(config=CreateAuthTokenConfig(uses=1,
  new_session_expire_time=now+VOICE_TOKEN_TTL_SECONDS, expire_time=now+VOICE_SESSION_MAX_SECONDS,
  live_connect_constraints=LiveConnectConstraints(model, config)))`. Without
  `lock_additional_fields`, the whole configuration is locked: model, system
  instruction, voice, input/output transcription, turn detection, session
  resumption and sliding-window context compression. Ephemeral tokens work only with
  `v1beta` and are a preview feature. The SDK warns about this, and the warning is
  filtered.
- **Wire format:** the first client message is `setup` (`models/gemini-3.8-live`,
  `responseModalities: ["AUDIO"]`, `sessionResumption`). Microphone audio is sent as
  `realtimeInput.audio` (`audio/pcm;rate=16000`, base64). The server sends JSON in
  **binary** frames. `GeminiLiveProtocol.decode` accepts text and bytes; on the web,
  `web_socket` delivers binary frames as `Uint8List`.
- **Turn-taking:** hands-free uses the server's automatic activity detection. Barge-in
  arrives as `serverContent.interrupted`: playback is cleared, the exchange is saved up
  to that point, and the interrupting speech starts a new one. Push-to-talk disables
  detection in the token; the button sends `activityStart` / `activityEnd`. Mute
  sends `audioStreamEnd`. The Live API has no "cancel reply" message, so the stop
  button discards the rest of the reply on the device.
- **Transcripts:** `inputTranscription` / `outputTranscription` fragments are
  collected per exchange and saved at `turnComplete`, user first. Item ids are `u<n>` /
  `a<n>`, so uploads are idempotent.
- **Speaking state and levels:** the transport keeps a playback timeline from the PCM
  it queued (24 kHz, 2 bytes per sample). It drives `assistantAudioStarted/Finished`
  and the orb level: RMS of the chunk playing now, or of the microphone. Native-audio
  models pick the language themselves, so the user's language goes into the
  instructions.
- **Long sessions:** a connection lasts about 10 minutes. On `goAway` the transport
  opens a new socket with the latest `sessionResumptionUpdate.newHandle` and the same
  token, then drops the old one. On an unexpected drop it resumes the same way
  (`VoiceConnectionLost` → `VoiceConnected`). If resuming is impossible, it starts one
  fresh session in the same conversation.
- **Audio packages:** `record` (`startStream`, `AudioEncoder.pcm16bits`; on Linux it
  needs `parecord`) and `mp_audio_stream` (miniaudio on native platforms, Web Audio
  AudioWorklet on the web). Both build their native code with the app (`ffiPlugin` or
  platform plugin), so `flutter test` needs no C compiler. `flutter_soloud` was
  rejected for this reason: its build hook compiles C++ on the host.

Permanent provider API keys never leave the backend.

## 4. Voice session state machine

`apps/flutter_app/lib/domain/voice/voice_session_state.dart` implements a pure,
unit-tested state machine. The orb/waveform renders from this state plus live audio
levels; it never animates on a timer by itself.

```
disconnected ──connect──▶ connecting ──connected──▶ idle
idle ──userSpeechStarted──▶ listening ──userSpeechStopped──▶ processing
processing ──assistantAudioStarted──▶ speaking ──assistantAudioFinished──▶ idle
speaking ──userSpeechStarted (barge-in)──▶ interrupted ──▶ listening
processing ──responseFinished (no audio / cancelled)──▶ idle
any ──connectionLost──▶ reconnecting ──connected──▶ idle | ──gaveUp──▶ disconnected
any ──failure──▶ error ──reset──▶ disconnected
```

`sessionConfigured` records push-to-talk mode and the conversation the session
saves to. Transcript updates carrying a provider `itemId` are updated in place.

## 5. Data model

```
users 1──* conversations 1──* messages
users 1──1 user_preferences          (default text model, voice model, voice, mode, audio settings)
users 1──* refresh_tokens            (rotating, hashed, revocable)
users 1──* voice_sessions *──1 conversations   (provider, model, voice, token expiry, ended_at; no secrets stored)
users 1──* conversation_attachments  (pending until sent: conversation_id/message_id null)
conversations 1──* conversation_attachments *──0..1 messages   (bytes on disk under storage_key, sha256 recorded)
ai_provider_settings                 (server-wide provider/model enablement; keys stay in env)
```

- All primary keys are UUIDs; all timestamps are timezone-aware UTC.
- `messages` stores role, content, status, provider/model, token usage, audio
  metadata (JSON), and an `extra` JSON for provider-specific metadata.
- Types are portable (`Uuid`, `JSON`, non-native enums) so the same Alembic
  migrations run on PostgreSQL (production) and SQLite (local dev/tests).

## 6. Security

- Passwords: Argon2id (`argon2-cffi`).
- Auth: short-lived JWT access tokens (default 15 min) and opaque refresh tokens
  (default 30 days) that are stored hashed, rotated on every refresh, and revoked
  on logout. Reusing an old refresh token revokes all of the user's sessions.
- Every request body is validated by Pydantic; errors use one JSON envelope.
- Rate limiting: fixed window per IP for auth endpoints, per user for the API;
  Redis-backed when `REDIS_URL` is set, in-process otherwise.
- Tokens are stored on device with `flutter_secure_storage`.
- Production: TLS terminated at Nginx (HTTPS/WSS), strict CORS allowlist,
  `APP_ENV=production` refuses to start without a strong `JWT_SECRET`.
- Phase 6 review, all controls and known limitations: [security.md](security.md).

### Performance (phase 6)

| Where | What | Effect |
|---|---|---|
| Web build | `--web-content-hash`, Nginx caching (`immutable` for hashed files, `no-cache` for `index.html`/bootstrap), precompressed `.gz` | Repeat visits download only changed files. The first load transfers about 3.3 MB, about 10 MB uncompressed (measured: main.dart.js 4.3 → 1.1 MB, CanvasKit 5.5 → 2.1 MB) |
| Web build | CanvasKit and fonts served locally (`--no-web-resources-cdn`) | No third-party round trips at start-up |
| Nginx → API | Upstream keep-alive (the `Connection` header is only set for WebSocket upgrades), gzip for JSON except token responses | Fewer TCP handshakes per request, smaller conversation lists |
| Chat replies | Only the newest `CHAT_HISTORY_MAX_MESSAGES` (200) messages are read per reply, through the `(conversation_id, seq)` index | Reply start-up cost no longer grows with the length of a conversation |
| Rate limiter | Redis calls fail fast (0.5 s, one retry) | A Redis outage no longer stalls requests for about 20 s each |
| Database | Pool size per worker configurable, connections recycled every 30 min, pre-ping | Sized to PostgreSQL's connection limit; survives database restarts |
| App | Image thumbnails decoded at display size (`ResizeImage`) | The thumbnail of a 12-megapixel photo uses 0.3 to 3 MB of image memory, depending on screen density, instead of about 48 MB |
| App (existing) | Streaming deltas batched per 40 ms, Markdown parsed once per change, lazy `ListView.builder` lists | Smooth streaming for long replies |

## 7. Client navigation

| Route | Screen |
|---|---|
| `/login`, `/register` | Auth |
| `/chat` | New conversation (empty state) |
| `/chat/:conversationId` | Conversation |
| `/voice` | Full-screen voice mode |
| `/settings` | Appearance, account, server, voice settings |

Wide windows (≥ 900 px) show a persistent sidebar; narrow ones use a drawer.
Desktop shortcuts: `Ctrl/Cmd+N` new chat, `Ctrl/Cmd+K` search, `Ctrl/Cmd+B`
toggle the sidebar, `Enter` send, `Shift+Enter` new line.

## 8. Phase status

| Phase | Scope | Status |
|---|---|---|
| 1 | Foundation: monorepo, backend, DB, auth, conversations, Flutter shell & UI, Docker | Done: 64 backend + 49 Flutter tests; verified end-to-end on Flutter web |
| 2 | Text chat with the first provider, streaming, error handling | Done: OpenAI Responses API over WebSocket; 94 backend + 71 Flutter tests |
| 3 | Realtime voice, VAD, interruption, visualization | Done: OpenAI Realtime over WebRTC (hands-free + push-to-talk); 110 backend + 95 Flutter tests. Live audio with the real API is not yet verified here (needs an API key and a microphone) |
| 4 | Second provider, model selection, capability handling | Done: Google Gemini (text via `google-genai`, voice via Gemini Live over WebSocket), separate text/voice model choice, capability-driven options; 132 backend + 121 Flutter tests. Verified end to end against local stand-in servers; real Gemini audio not yet verified here (needs a key and a microphone) |
| 5 | Image/PDF uploads, multimodal | Done: PNG/JPEG/WEBP/PDF attachments (upload, camera on mobile, thumbnails, signed PDF links), sent to OpenAI (`input_image`/`input_file`) and Gemini (inline data) within a request budget, capability-checked on both sides; 145 backend + 129 Flutter tests. Verified end to end against local stand-in servers; real model answers about images not yet verified here (needs API keys) |
| 6 | Optimization, security review, release builds | Done: security review with 8 fixes ([security.md](security.md)), performance work (above), production Docker stack with HTTPS and the web app ([deployment.md](deployment.md)), CI with coverage gate, dependency audit and an end-to-end deployment test, build workflows for Android, Windows, Linux, macOS, iOS and web, tagged releases with GHCR images; 152 backend (96 % coverage) + 135 Flutter tests. Verified locally: backend and Flutter suites, production web build under the production CSP in a browser. Not run here (no Docker, Android SDK or C++ toolchain on this PC): the Docker images, Nginx configs and platform builds, which CI builds and checks on the first push |
