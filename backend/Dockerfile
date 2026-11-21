# syntax=docker/dockerfile:1

FROM python:3.14-slim AS builder
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv && /opt/venv/bin/pip install -r requirements.txt

FROM python:3.14-slim AS runtime
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_ENV=production \
    # Worker processes (read by uvicorn). Each worker has its own DB pool.
    WEB_CONCURRENCY=2
RUN groupadd --system app && useradd --system --gid app --home-dir /app app
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app alembic.ini ./
COPY --chown=app:app alembic ./alembic
COPY --chown=app:app app ./app
COPY --chown=app:app docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh \
    # Attachment storage; docker compose mounts a volume here (it inherits this owner).
    && mkdir -p /app/data/attachments && chown -R app:app /app/data
USER app
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health/live', timeout=2)"
ENTRYPOINT ["./docker-entrypoint.sh"]
# - Proxy headers are trusted only from FORWARDED_ALLOW_IPS (docker compose sets it
#   for Nginx). Nginx overwrites X-Forwarded-For, so clients cannot spoof their IP.
# - --ws-max-size: chat frames are small (a message is at most 32,000 characters);
#   reject anything over 1 MiB instead of the 16 MiB default.
# - --timeout-graceful-shutdown: on deploy, in-flight replies get 20 s, then they
#   are saved as "cancelled" (keep it below the container stop timeout).
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--ws-max-size", "1048576", "--timeout-graceful-shutdown", "20", "--no-server-header"]
