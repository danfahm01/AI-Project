# Voice Assistant

A cross-platform AI assistant with text chat and real-time voice conversations. One Flutter codebase targets Android, iOS, Windows, macOS, Linux
and the web. A FastAPI backend handles accounts, conversation history and secure
access to AI providers (OpenAI Realtime and Google Gemini Live, behind a
provider-independent adapter).

> **Status: all six phases are complete.** Two providers, OpenAI and Google
> Gemini, sit behind one adapter interface.
>
> - **Text chat** streams over a WebSocket, with Markdown and code highlighting,
>   stop, regenerate and edit-and-resubmit. Replies come from OpenAI's Responses API
>   or from Gemini (`gemini-4-hydrogen` and others).
> - **Attachments:** images (PNG, JPEG, WEBP, or a camera photo on mobile) and PDFs
>   can be sent with a message. They appear as thumbnails or chips, and are passed to
>   models that can read them.
> - **Voice mode** talks directly to OpenAI Realtime (`gpt-realtime-2.1`, WebRTC) or
>   Gemini Live (`gemini-3.8-live`, WebSocket). It works hands-free with interruption
>   or push-to-talk, and live transcripts are saved to the conversation.
> - **Model choice:** text and voice models are chosen separately, and the app only
>   offers options the selected model supports.
> - **Security:** the backend only mints short-lived, single-session credentials.
>   A phase 6 review fixed 8 issues; see [docs/security.md](docs/security.md).
> - **Deployment:** a production Docker stack (HTTPS/WSS, the web app, Let's Encrypt)
>   and GitHub Actions that test the whole stack and build Android, Windows,
>   Linux, macOS, iOS and web releases. See [docs/deployment.md](docs/deployment.md).
>
> Set `OPENAI_API_KEY` and/or `GEMINI_API_KEY` in `.env`. Without a key, messages are
> still saved and the app says that no provider is configured. See
> [docs/architecture.md](docs/architecture.md#8-phase-status).

## Repository layout

```
apps/flutter_app/   Flutter client (Riverpod, GoRouter, Dio, Material 3 via material_ui)
backend/            FastAPI API, SQLAlchemy models, Alembic migrations, tests
infrastructure/     Nginx configs (dev + production template), web image, scripts
docs/               Architecture, setup, deployment, security, API, troubleshooting
docker-compose.yml       PostgreSQL + Redis + backend + Nginx (development, HTTP)
docker-compose.prod.yml  Production overlay: HTTPS/WSS, web app, Let's Encrypt
.github/            CI, app builds for every platform, releases, Dependabot
.env.example        Configuration template
```

## Quick start (local, no Docker)

Requirements: Python 3.12+ (3.14 tested), Flutter 3.50+, Git.

```powershell
# Backend
cd backend
python -m venv .venv
.venv\Scripts\pip install -r requirements-dev.txt
.venv\Scripts\alembic upgrade head
.venv\Scripts\uvicorn app.main:create_app --factory --reload --port 8000
```

```powershell
# App (in a second terminal)
cd apps/flutter_app
flutter pub get
flutter run -d chrome        # or: -d windows, -d <android device>
```

API docs: <http://localhost:8000/docs>. The full guide, including Docker,
Android and Windows builds, is in [docs/setup.md](docs/setup.md).

> **Windows:** keep the repository in a short path such as `C:\dev\voice-assistant`.
> Flutter's native-asset builds fail when paths exceed 260 characters; see
> [docs/troubleshooting.md](docs/troubleshooting.md).

## Tests

```powershell
cd backend;          .venv\Scripts\pytest -q --cov=app   # 152 tests (1 needs REDIS_TEST_URL), 96 % coverage
cd apps/flutter_app; flutter analyze; flutter test       # 135 tests
```

## Documentation

- [Architecture](docs/architecture.md): layers, provider adapters, voice state machine, data model, security
- [Setup](docs/setup.md): local, Docker, Android, Windows, iOS, macOS and Linux builds
- [Deployment](docs/deployment.md): production server, TLS, backups, releases
- [Security](docs/security.md): controls, phase 6 review, known limitations
- [API](docs/api.md): endpoints and error format
- [Troubleshooting](docs/troubleshooting.md)
