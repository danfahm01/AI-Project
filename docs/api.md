# API

Base path: `/api/v1`. Interactive OpenAPI docs are served at `/docs` (disable
with `ENABLE_API_DOCS=false`). All bodies are JSON; unknown fields are rejected.

## Authentication

Send the access token as `Authorization: Bearer <access_token>`. Access tokens
last 15 minutes. Exchange the refresh token for a new pair at `/auth/refresh`;
every refresh **rotates** the refresh token, and presenting an old one revokes
the whole session (the client serialises refreshes for this reason).

| Method | Path | Body | Result |
|---|---|---|---|
| POST | `/auth/register` | `email`, `password` (8–128), `display_name` | 201 `{user, tokens}` |
| POST | `/auth/login` | `email`, `password` | 200 `{user, tokens}` |
| POST | `/auth/refresh` | `refresh_token` | 200 `{access_token, refresh_token, token_type, expires_in}` |
| POST | `/auth/logout` | `refresh_token` | 204 (always) |

Auth endpoints are rate limited per IP (`RATE_LIMIT_AUTH_PER_MINUTE`).

## Users

| Method | Path | Notes |
|---|---|---|
| GET | `/users/me` | Profile |
| PATCH | `/users/me` | `{display_name}` |
| GET | `/users/me/preferences` | Theme, default text model, voice model, voice mode, voice, language, speaking rate, audio processing |
| PATCH | `/users/me/preferences` | Partial update; `null` clears optional fields |

Text and voice models are chosen separately: `default_provider`/`default_model` for
new chats, `voice_provider`/`voice_model` for voice mode. A choice that is no longer
available falls back to the server default. `voice_name` is provider-specific; an
unknown voice falls back to the model's default voice.

## Conversations and messages

| Method | Path | Notes |
|---|---|---|
| GET | `/conversations?q=&limit=&cursor=` | Newest activity first; `q` searches titles and message text; cursor pagination |
| POST | `/conversations` | `{title?, provider?, model?}` |
| GET | `/conversations/{id}` | |
| PATCH | `/conversations/{id}` | Rename or change model: `{title?, provider?, model?}` |
| DELETE | `/conversations/{id}` | Deletes its messages too |
| GET | `/conversations/{id}/messages` | Ordered by `seq` |
| POST | `/conversations/{id}/messages` | `{content}`. Creates a **user** message. The first message titles a new conversation |
| PATCH | `/messages/{id}` | Edit a user message; later messages are removed (`removed_message_ids`) |
| DELETE | `/messages/{id}` | |

Message fields: `id, conversation_id, seq, role, content, status, provider, model,
usage{input_tokens, output_tokens, total_tokens}, audio_metadata, metadata,
created_at, updated_at, edited_at`. All timestamps are UTC ISO 8601.

Authenticated endpoints are rate limited per user (`RATE_LIMIT_API_PER_MINUTE`).
Other users' resources return 404, so their existence is never revealed.

## Attachments (images and PDFs)

Files are uploaded first and then sent with a chat message by id. Only **PNG,
JPEG, WEBP and PDF** are accepted. The type is detected from the file's bytes,
never from its name or the declared content type.

| Method | Path | Notes |
|---|---|---|
| POST | `/attachments` | `multipart/form-data` with a `file` field. 201 attachment (pending). Rate limited per user (`RATE_LIMIT_UPLOADS_PER_MINUTE`) |
| GET | `/attachments/{id}` | Metadata |
| GET | `/attachments/{id}/content` | The file (Bearer auth), for thumbnails |
| POST | `/attachments/{id}/link` | `{path, expires_at}`: a signed download path, relative to `/api/v1`, valid for `ATTACHMENT_LINK_TTL_SECONDS` |
| GET | `/attachments/{id}/download?expires=&signature=` | The file without auth (HMAC-signed, expiring), e.g. to open a PDF in the system viewer |
| DELETE | `/attachments/{id}` | Remove an upload that was not sent (409 `attachment_in_use` once sent) |

Attachment fields: `id, kind ("image"|"pdf"), filename, content_type, size_bytes,
conversation_id, message_id, created_at`. Files are served with their detected type,
`X-Content-Type-Options: nosniff` and an RFC 6266 `Content-Disposition`. Messages
include their `attachments`.

- **Lifecycle:** uploads are *pending* until sent. Unsent uploads older than
  `ATTACHMENT_PENDING_TTL_HOURS` are removed on the user's next upload. Deleting a
  message or a conversation, or editing an earlier message (which drops later
  turns), deletes the files of the removed messages.
- **Errors:** 413 `attachment_too_large` (over `ATTACHMENT_MAX_BYTES`), 415
  `attachment_type_not_supported`, 400 `attachment_empty`, 404 `attachment_not_found`,
  404 `attachment_link_invalid` (bad or expired signature).

## Streaming chat (WebSocket)

`ws(s)://<host>/api/v1/chat/ws`. Replies are generated and streamed over this
socket; REST stays the source of truth for history.

**Authentication:** the first frame must be `{"type": "auth", "token": "<access token>"}`
within 10 s. The reply is `{"type": "auth.ok"}` or `{"type": "auth.failed", "error": {...}}`,
followed by close code `4401`. Tokens are never put in the URL.

**Client → server**

| Frame | Effect |
|---|---|
| `{"type": "message.send", "request_id", "conversation_id", "content", "attachment_ids"?}` | Store the user message (text, attachments or both; up to `ATTACHMENTS_PER_MESSAGE` pending uploads) and generate a reply |
| `{"type": "response.regenerate", "request_id", "conversation_id"}` | Replace the last reply (or answer the last user message, e.g. after an edit) |
| `{"type": "response.cancel", "request_id"}` | Stop generating; the partial reply is kept with status `cancelled` |
| `{"type": "ping"}` | `{"type": "pong"}` (clients send one every 25 s) |

Attachments are checked **before** anything is stored. If one is unknown or already
sent (`attachment_not_found`), there are too many (`too_many_attachments`), they are too
large together (`attachments_too_large`), or the conversation's model cannot read them
(`attachments_not_supported`, e.g. "GPT-6 Luna cannot read PDF documents"), the reply
is `response.failed` with `message: null` and no `message.created`. The uploads stay
pending, so the client can switch model and resend.

One generation at a time per connection (`busy` otherwise). Generations count
against `RATE_LIMIT_CHAT_PER_MINUTE`. A generation keeps running if the client
disconnects, and the client reloads the conversation after reconnecting.

**Server → client** (every event carries `request_id` and `conversation_id`)

| Event | Payload |
|---|---|
| `message.created` | `message`: the stored user message |
| `message.deleted` | `message_id`: the reply replaced by a regenerate |
| `conversation.updated` | `conversation`, `title_changed` |
| `response.started` | `message`: assistant message, `status: "streaming"`, empty content |
| `response.delta` | `message_id`, `delta` (text to append) |
| `response.completed` | `message`: final content, `usage`, provider and model |
| `response.cancelled` | `message`: partial content, `status: "cancelled"` |
| `response.failed` | `message` (status `error`, or `null` if no reply was created) and `error` |
| `error` | Rejected command: `invalid_command`, `busy`, `rate_limited` |

Provider error codes are neutral and safe to show: `provider_not_available`,
`provider_auth_failed`, `provider_rate_limited`, `provider_model_unavailable`,
`provider_bad_request`, `provider_timeout`, `provider_unavailable`,
`provider_failed`, `provider_stream_interrupted`, `provider_content_blocked`
(the provider's safety system declined the request and produced no text).

A completed reply may carry `metadata.incomplete_reason`: `max_output_tokens`, or
`content_filter` when a provider stopped part-way for safety (the text so far is kept).

## Voice sessions

Realtime voice audio goes **directly** between the app and the AI provider over
WebRTC. The backend never sees the audio. It mints a short-lived client secret
and stores the transcripts. The permanent API key never leaves the server.

| Method | Path | Body | Result |
|---|---|---|---|
| POST | `/voice/sessions` | `{conversation_id?, provider?, model?}` | 201 session (below), `Cache-Control: no-store` |
| POST | `/voice/sessions/{id}/transcripts` | `{role: "user"\|"assistant", content, item_id?, duration_ms?}` | 200 the stored message |
| POST | `/voice/sessions/{id}/end` | | 204 |

Session fields: `id, conversation_id, provider, model, transport, endpoint,
client_secret, expires_at, voice, push_to_talk`, plus per transport:

| Transport | Provider | Extra fields | How the client connects |
|---|---|---|---|
| `webrtc` | OpenAI | `data_channel` | SDP offer to `endpoint` (see below) |
| `websocket` | Gemini | `input_audio_format` (`audio/pcm;rate=16000`), `output_sample_rate` (24000), `session_expires_at` | `endpoint?access_token=<client_secret>`, first message `setup` |

`expires_at` is the deadline to connect. For WebSocket sessions, `session_expires_at`
is when the token stops working, including reconnects with session resumption
(`VOICE_SESSION_MAX_SECONDS`).

- Without `provider`, the user's voice model preference is used, else the server
  default. Without `conversation_id`, a new conversation is created. Recent text from the
  conversation is given to the voice model as context (`VOICE_CONTEXT_MAX_CHARS`).
- Voice, speaking rate, language and hands-free versus push-to-talk come from the
  user's preferences. `push_to_talk: true` means server VAD is off: the client
  commits each turn itself.
- OpenAI: the client sends its SDP offer to `endpoint` with
  `Authorization: Bearer <client_secret>` and `Content-Type: application/sdp`,
  then exchanges provider events on the `data_channel`.
- Gemini: the token is single-use and its configuration (model, instructions,
  voice, transcription, turn detection) is locked by the server. The client streams
  microphone PCM and plays the 24 kHz PCM reply.
- Transcripts are idempotent per `item_id`, so retries never duplicate a message.
  They are accepted for 2 hours after the session started (`voice_session_expired`).
- Starting sessions is rate limited per user (`RATE_LIMIT_VOICE_SESSIONS_PER_MINUTE`).
- Provider failures return 502 with a neutral `provider_*` code. No conversation
  is created in that case.

## Providers

`GET /providers` returns the AI providers configured on this server with each
model's capabilities (`text_streaming`, `realtime_voice`, `server_vad`,
`interruption`, `image_input`, `pdf_input`, `voices`, `languages`,
`speaking_rate{min,max,default}`). OpenAI appears once `OPENAI_API_KEY` is set,
Google Gemini once `GEMINI_API_KEY` is set. Each provider's realtime model
(`OPENAI_REALTIME_MODEL`, `GEMINI_LIVE_MODEL`) is listed with `realtime_voice: true`
and `text_streaming: false`, so it is offered in voice mode, not in text chat.
`speaking_rate` is `null` for models without a rate setting (Gemini Live), and the
app then hides the speed control. `default_provider` follows `DEFAULT_AI_PROVIDER`.

## Health

`GET /health/live` (process up) and `GET /health/ready` (database and rate-limit
store reachable; 503 when degraded).

## Errors

Every error uses one envelope, and responses carry an `X-Request-ID` header:

```json
{
  "error": {
    "code": "conversation_not_found",
    "message": "Conversation not found",
    "details": null,
    "request_id": "9f2c..."
  }
}
```

| Status | Typical codes |
|---|---|
| 400 | `invalid_cursor`, `attachment_empty` |
| 413 | `attachment_too_large` |
| 415 | `attachment_type_not_supported` |
| 401 | `unauthorized`, `invalid_credentials`, `token_expired`, `invalid_token`, `refresh_token_revoked`, `refresh_token_expired` |
| 403 | `account_disabled`, `message_not_editable` |
| 404 | `not_found`, `conversation_not_found`, `message_not_found`, `provider_not_available`, `voice_session_not_found`, `attachment_not_found`, `attachment_link_invalid` |
| 409 | `email_taken`, `voice_session_expired`, `attachment_in_use` |
| 422 | `validation_error` (`details` lists `{loc, msg, type}`; submitted values are never echoed) |
| 429 | `rate_limited` (`Retry-After` header) |
| 500 | `internal_error` |
| 502 | `provider_*` (voice session could not be created with the AI provider) |
