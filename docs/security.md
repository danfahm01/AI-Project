# Security

This document records how the system protects users and secrets, the results of
the phase 6 security review, and the known limitations. Operators should also
follow the checklist in [deployment.md](deployment.md#10-production-checklist).

## 1. Controls

| Area | Control | Where |
|---|---|---|
| AI provider keys | Only the backend holds `OPENAI_API_KEY` / `GEMINI_API_KEY`. Apps never receive them | `app/core/config.py`, `app/ai_providers/` |
| Voice credentials | OpenAI: an ephemeral client secret (default 120 s to connect). Gemini: a single-use ephemeral token whose model, instructions and voice are locked by the server, valid for `VOICE_SESSION_MAX_SECONDS` | `app/services/voice_service.py` |
| Passwords | Argon2id. Unknown e-mails take the same time as wrong passwords | `app/core/security.py` |
| Sessions | 15-minute JWT access tokens. 30-day refresh tokens are stored as hashes and rotated on every use; reusing an old one revokes the session family | `app/services/auth_service.py` |
| Transport | Production is HTTPS/WSS only: HTTP redirects, HSTS (2 years), TLS 1.2+ with AEAD ciphers. Android, iOS and macOS release builds refuse plain HTTP, and the release workflow refuses a non-HTTPS `API_BASE_URL` | `infrastructure/nginx/templates/`, `.github/workflows/build-apps.yml` |
| Production config | The backend refuses to start without a 32+ character `JWT_SECRET`, with localhost CORS, with `http://` or `*` CORS origins, or with a non-HTTPS provider base URL | `Settings._enforce_security` |
| Input | Pydantic schemas reject unknown fields and enforce lengths. WebSocket frames are limited to 1 MiB, uploads to `ATTACHMENT_MAX_BYTES`, and request bodies at the edge to 25 MB | `app/schemas/`, `backend/Dockerfile`, `snippets/http-common.conf` |
| Authorization | Every query is scoped to the signed-in user. Other users' resources return 404, so their existence is never revealed | repositories, services |
| Rate limits | Per IP for auth, per user for API, chat, voice sessions and uploads (Redis, shared by workers), plus an edge limit in Nginx | `app/api/deps.py`, `snippets/app-locations.conf` |
| Attachments | Type detected from the bytes (PNG, JPEG, WEBP, PDF only). Filenames sanitised, paths confined to the storage root. Downloads without a token need an HMAC-signed link that expires after 5 minutes | `app/services/attachment_service.py` |
| Response headers | API: `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store` (unless an endpoint sets its own). Web app: a strict Content-Security-Policy and a Permissions-Policy that allows only the microphone and camera | `app/core/middleware.py`, `snippets/static-headers.conf` |
| Model output | Rendered as Flutter widgets, never as HTML. Links open only for `http(s)` | `core/widgets/markdown_view.dart` |
| Client storage | Tokens are kept in `flutter_secure_storage`: Keychain, Android Keystore, libsecret and DPAPI on the native platforms; on the web, WebCrypto-encrypted browser storage | `core/storage/` |
| Privacy | Provider requests use `store=false`. OpenAI receives a hash of the user id, never an e-mail. Logs hold no bodies or tokens; uvicorn's access log, which would include query strings, is turned off | `chat_service.py`, `app/core/logging.py` |
| Containers | Non-root backend, read-only root filesystem, all capabilities dropped, `no-new-privileges`. Only Nginx publishes ports | `docker-compose.yml` |
| Supply chain | Pinned Python packages and `pubspec.lock`, official base images, `pip-audit` in CI, weekly Dependabot updates (pip, pub, Actions, Docker) | `.github/` |

## 2. Phase 6 review

The review covered the auth flow, tokens, the chat WebSocket, attachments,
provider and voice credentials, configuration, the Nginx edge, the containers,
client storage and dependencies. It used manual review, ruff's security rules
(`S`, from flake8-bandit), `pip-audit` (no known vulnerabilities on 2026-11-21) and
new tests.

| # | Finding | Impact | Fix | Checked by |
|---|---|---|---|---|
| 1 | Nginx appended the client's `X-Forwarded-For`, and uvicorn trusted every proxy (`*`). uvicorn then took the left-most address, which the client controls | Anyone could bypass the per-IP sign-in limit by sending a different forged address with each attempt, and so brute-force passwords | Nginx now **overwrites** `X-Forwarded-For` with the connecting address. Proxy trust moved to `FORWARDED_ALLOW_IPS`, set only in Compose, where the backend publishes no port | CI deployment job: `smoke_test.py --check-rate-limit` through Nginx. Locally: forged addresses defeated the limit on a direct connection to uvicorn, and the limit triggered after 10 attempts without them |
| 2 | redis-py defaults to 10 retries with backoff and 5 s timeouts | While Redis was down, every request stalled about 20 s before failing open, which is effectively an outage | 0.5 s timeouts and one immediate retry | `test_redis_outage_fails_open_quickly` (20 s before, 2 s now) |
| 3 | Without Nginx (direct or other proxies), API responses carried no cache or anti-sniffing headers | Shared caches or the browser could store personal data and tokens | The middleware adds `nosniff`, `DENY`, `no-referrer` and `no-store` by default | `test_security_headers_on_every_response` |
| 4 | Production accepted `http://` CORS origins and plain-HTTP provider base URLs | Keys sent in cleartext, or production pointed at a test server | Refused at start-up in production | `test_production_requires_https_origins_and_provider_urls` |
| 5 | WebSocket frames up to 16 MiB (uvicorn default) | Memory pressure from a few connections | `--ws-max-size 1048576` | Flags run locally with 2 workers |
| 6 | The web app loaded CanvasKit from a CDN and had no CSP | Third-party script dependency, and no second line of defence against XSS, which matters because web tokens live in browser storage | `--no-web-resources-cdn`, `--csp` (no `eval`), a strict CSP and Permissions-Policy | Production build served with the same headers in a browser: no CSP violations, no third-party requests, sign-in and streaming chat work |
| 7 | Containers ran with a writable root filesystem and default capabilities | Larger blast radius if the API process were compromised | `read_only`, `tmpfs /tmp`, `cap_drop: [ALL]`, `no-new-privileges` | CI deployment job (starts the production stack and runs the smoke test) |
| 8 | No Android release signing configuration | Release builds silently used the debug key | `key.properties` signing, with CI secrets. A warning is printed when it is missing | `build-apps.yml` |

Checked and found sound: refresh-token rotation and reuse detection,
timing-safe sign-in, no tokens in URLs (WebSocket auth is the first frame), the
attachment path-traversal guard, the signed-link HMAC with constant-time
comparison, provider error messages that are neutral and leak no keys, voice
tokens locked to the server's configuration, and no WebSocket CSRF (no cookies).

## 3. Known limitations

- **Accounts:** no e-mail verification, password reset, multi-factor
  authentication, or account deletion or data export yet. The smoke test
  therefore leaves its throwaway account in place.
- **Token lifetime:** a stolen access token works until it expires (15 minutes),
  because access tokens are not checked against a revocation list. Rotating
  `JWT_SECRET` signs everyone out.
- **Web storage:** an XSS bug would expose the web app's tokens. The CSP and
  widget-only rendering make that unlikely, but native apps keep tokens in
  hardware-backed stores.
- **Data at rest:** PostgreSQL data and attachments are not encrypted by the app.
  Use an encrypted disk or volume.
- **Unsigned desktop builds:** CI produces unsigned Windows and macOS builds, so
  the OS shows warnings. Sign and notarize them with your own certificates
  before distributing.
- **Image pinning:** base images are pinned by version tag, not by digest, and
  the optional certbot image uses `latest`. Dependabot proposes updates.
- **Direct provider connections:** in voice mode the device talks to OpenAI or
  Google directly, so the provider sees the user's IP address.
