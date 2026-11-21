# Deployment

This guide puts the backend and the web app on a server with Docker Compose,
behind HTTPS. The mobile and desktop apps then connect to that server. Local
development is in [setup.md](setup.md), and the security design is in
[security.md](security.md).

## 1. What runs where

```
 Browser / Android / iOS / Windows / macOS / Linux app
        │  HTTPS + WSS only (port 80 just redirects and answers ACME challenges)
        ▼
 nginx  (web image: infrastructure/docker/web.Dockerfile)
   ├─ /            Flutter web app (static, content-hashed, gzip, CSP)
   ├─ /api/        → backend   (REST, rate limited at the edge)
   ├─ /api/v1/chat/ws → backend (WebSocket, 1 h idle timeout)
   └─ /health/     → backend
        ▼
 backend (uvicorn, WEB_CONCURRENCY workers; image: backend/Dockerfile)
   ├─ PostgreSQL 17   (volume postgres-data)
   ├─ Redis 7.4       (rate-limit counters only, no persistence)
   └─ attachments     (volume attachments-data)

 Voice audio goes from the app straight to OpenAI / Google with a short-lived
 credential that the backend mints. The permanent API keys never leave the backend.
```

| File | Purpose |
|---|---|
| `docker-compose.yml` | Development stack (plain HTTP). It is also the base for production |
| `docker-compose.prod.yml` | Production overlay: HTTPS, web app, `APP_ENV=production`, Let's Encrypt helper |
| `infrastructure/nginx/templates/default.conf.template` | Production server blocks (TLS, redirect) |
| `infrastructure/nginx/snippets/` | Shared by development and production: API proxy, web app caching, security headers |
| `infrastructure/scripts/make-dev-cert.sh` | Self-signed certificate for local trials and CI |
| `backend/scripts/smoke_test.py` | Checks a running deployment end to end |

## 2. Requirements

- A Linux server with Docker Engine and **Docker Compose 2.24 or newer**
  (`docker compose version`). The production overlay uses `!override`.
- A domain name whose DNS `A` (and optionally `AAAA`) record points at the server.
  Ports 80 and 443 must be open.
- Building the web image compiles the Flutter app and needs several GB of RAM. On
  a small server, let GitHub Actions build the images and pull them instead
  (section 9).

## 3. Configuration (`.env`)

```bash
cp .env.example .env
python3 -c "import secrets; print(secrets.token_urlsafe(64))"   # → JWT_SECRET
python3 -c "import secrets; print(secrets.token_urlsafe(32))"   # → POSTGRES_PASSWORD
```

| Variable | Production value |
|---|---|
| `SERVER_NAME` | Your domain, e.g. `assistant.example.com` |
| `JWT_SECRET` | 32+ random characters (required; the backend refuses to start otherwise) |
| `POSTGRES_PASSWORD` | A random password (not `change-me`) |
| `OPENAI_API_KEY` / `GEMINI_API_KEY` | At least one, for AI replies and voice |
| `CORS_ORIGINS` | Empty, unless another web front end on a different origin uses the API (then `https://` origins only) |
| `TLS_CERTIFICATE`, `TLS_CERTIFICATE_KEY` | Only for Let's Encrypt (section 4a) |
| `WEB_CONCURRENCY` | API worker processes (default 2). See section 8 |

`docker-compose.prod.yml` sets `APP_ENV=production`, `CORS_ALLOW_LOCALHOST=false`
and `ENABLE_API_DOCS=false` itself. In production the backend refuses to start
with a weak `JWT_SECRET`, `http://` or `*` CORS origins, or a non-HTTPS
`OPENAI_BASE_URL` / `GEMINI_BASE_URL`.

## 4. TLS certificate

Nginx needs a certificate before it starts. Pick one option.

### 4a. Let's Encrypt (recommended)

```bash
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"

# 1. First certificate. Nothing may listen on port 80 yet: certbot answers the challenge itself.
$COMPOSE run --rm --service-ports certbot certonly --standalone -d assistant.example.com -m you@example.com
```

Certbot asks you to accept the Let's Encrypt terms. Then add this to `.env`:

```
TLS_CERTIFICATE=/etc/letsencrypt/live/assistant.example.com/fullchain.pem
TLS_CERTIFICATE_KEY=/etc/letsencrypt/live/assistant.example.com/privkey.pem
```

Renewal runs while Nginx is up, through `/.well-known/acme-challenge/` on port
80. Schedule it daily, for example with `crontab -e`:

```
17 3 * * * cd /srv/voice-assistant && docker compose -f docker-compose.yml -f docker-compose.prod.yml run --rm certbot renew --webroot -w /var/www/certbot --quiet && docker compose -f docker-compose.yml -f docker-compose.prod.yml exec nginx nginx -s reload
```

### 4b. Your own certificate

Put the full chain and the key in `infrastructure/certs/` as `fullchain.pem` and
`privkey.pem`, or point `TLS_CERT_DIR` at the folder that holds them. The folder
is git-ignored.

### 4c. Local trial (self-signed)

```bash
sh infrastructure/scripts/make-dev-cert.sh localhost   # Git Bash on Windows
# .env: SERVER_NAME=localhost
```

Browsers warn about this certificate. Never use it on a public server.

## 5. Start

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps
```

The backend applies database migrations when it starts (`RUN_MIGRATIONS=false`
turns this off). The first build takes a while because it fetches the Flutter SDK.

## 6. Verify

```bash
cd backend
pip install httpx==0.28.1 websockets==17.4      # or use the backend venv
python scripts/smoke_test.py --base-url https://assistant.example.com --web --http-url http://assistant.example.com
```

The script checks health, HSTS and the other security headers, the CSP and
caching of the web app, sign-up and sign-in, conversations, attachments with
signed links, and the chat WebSocket. Then it deletes what it created. It leaves
one `smoke-…@example.com` account behind, because the API has no account
deletion yet. Pass `--email` (with `SMOKE_TEST_PASSWORD`) to reuse one account.
`--chat` sends a real, billed message when a provider key is set.

Then open `https://assistant.example.com` and sign up.

## 7. Connect the apps

The web app on the server already uses the same origin. Build the other apps
against your domain. They must use HTTPS, because release builds on Android, iOS
and macOS refuse plain HTTP:

```bash
flutter build apk --release --split-per-abi --dart-define=API_BASE_URL=https://assistant.example.com
flutter build windows --release --dart-define=API_BASE_URL=https://assistant.example.com
```

Or let the release workflow build all of them (section 9). Platform details are
in [setup.md](setup.md#6-windows-desktop-build).

## 8. Operations

**Logs:** `docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f backend nginx`.
Every request is logged once with its `X-Request-ID`, which clients also receive.

**Health:** `/health/live` (process up) and `/health/ready` (database and Redis
reachable; 503 otherwise).

**Updates:**

```bash
git pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

The backend restarts with a 20-second grace period. A reply still streaming at
that moment is saved as "cancelled", and the apps reconnect on their own.

**Backups:** back up the database and the attachment files together.

```bash
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
$COMPOSE exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > backup-$(date +%F).dump
docker run --rm -v "$(basename "$PWD")_attachments-data:/data:ro" -v "$PWD:/backup" alpine \
  tar -czf /backup/attachments-$(date +%F).tar.gz -C /data .
```

To restore, stop the backend, run `pg_restore --clean -d <db>` inside the postgres
container, extract the tarball into the volume, and start again. Redis holds
nothing that needs a backup.

**Capacity:** every worker has its own database pool. Keep
`WEB_CONCURRENCY × (DATABASE_POOL_SIZE + DATABASE_MAX_OVERFLOW)` below PostgreSQL's
`max_connections` (100 by default). The defaults give 2 × 20 = 40. A reply mostly
waits on the AI provider, so one worker serves many concurrent chats. Add workers
when CPU, not the provider, is the limit.

**Behind a load balancer or CDN:** Nginx sets `X-Forwarded-For` to the address
that connects to it, which is the right choice when Nginx is the edge. If
another proxy sits in front, configure Nginx's `real_ip` module
(`set_real_ip_from <proxy range>; real_ip_header X-Forwarded-For;`) so rate limits
see the real client. Otherwise every user shares the proxy's limit.

**OpenAI-compatible gateway:** if `OPENAI_BASE_URL` points elsewhere, voice mode
in the browser connects to that host. Add it to `CSP_CONNECT_SRC` on the nginx
service, for example
`CSP_CONNECT_SRC=https://gateway.example.com wss://generativelanguage.googleapis.com`.

## 9. Releases with GitHub Actions

| Workflow | When | What |
|---|---|---|
| `ci.yml` | Every push and pull request | Backend lint, tests with ≥ 90 % coverage, PostgreSQL migrations, Redis tests, `pip-audit`. Flutter format, analyze, tests and production web build. Builds the **production stack** with a self-signed certificate and runs the smoke test over HTTPS/WSS |
| `build-apps.yml` | App changes, on demand, from releases | Android (APK per ABI + AAB), Windows (zip with the VC++ runtime), Linux (tar.gz), macOS (unsigned zip), iOS (compile check), web |
| `release.yml` | Tag `v1.2.3` | All apps against `API_BASE_URL`, images pushed to `ghcr.io/<owner>/<repo>/backend` and `/web`, GitHub release with the files |

One-time setup in the repository settings (*Settings → Secrets and variables → Actions*):

- **Variable** `API_BASE_URL` = `https://assistant.example.com`. Releases fail if it
  is missing or not HTTPS.
- **Secrets** for a Play-ready Android build (optional; without them the release APK and AAB
  are signed with a debug key):
  - `ANDROID_KEYSTORE_BASE64`: `base64 -w0 upload-keystore.jks` (PowerShell:
    `[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks"))`)
  - `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`

Release:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

To run released images instead of building on the server, add this to `.env`:
`BACKEND_IMAGE=ghcr.io/<owner>/<repo>/backend:1.0.0` and
`WEB_IMAGE=ghcr.io/<owner>/<repo>/web:1.0.0`. Then:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull backend nginx
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-build
```

GitHub Container Registry packages are private by default. Run `docker login ghcr.io`
on the server, or make the packages public.

## 10. Production checklist

- [ ] `.env`: strong `JWT_SECRET` and `POSTGRES_PASSWORD`, `SERVER_NAME`, a provider key
- [ ] Certificate installed, and renewal scheduled (Let's Encrypt)
- [ ] Only ports 80 and 443 reachable from the internet (PostgreSQL, Redis and the API publish no ports)
- [ ] `smoke_test.py --web --http-url …` passes against the public URL
- [ ] Database and attachment backups scheduled, and a restore tried once
- [ ] Apps built with `API_BASE_URL=https://…`; Android signed with your upload key
- [ ] Android `applicationId` and iOS/macOS bundle identifiers changed from `com.example…` before store submission
