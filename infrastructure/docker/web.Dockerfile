# syntax=docker/dockerfile:1
#
# Nginx + the Flutter web app: the production edge (TLS, API proxy, static app).
# Build context: the repository root (docker-compose.prod.yml does this).
#
#   docker build -f infrastructure/docker/web.Dockerfile -t voice-assistant-web .

# --- 1. Build the web app with the pinned Flutter SDK --------------------------------
FROM debian:trixie-slim AS app-build
ARG FLUTTER_VERSION=3.50.0
# "/" = the API is on the same origin as the page (this image proxies /api).
ARG API_BASE_URL=/

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home builder
USER builder
WORKDIR /home/builder

# The official SDK repository at the release tag CI uses.
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git flutter
ENV PATH="/home/builder/flutter/bin:${PATH}"
RUN flutter config --disable-analytics --no-cli-animations && flutter precache --web

WORKDIR /home/builder/app
# Dependencies first, so source changes reuse this layer.
COPY --chown=builder:builder apps/flutter_app/pubspec.yaml apps/flutter_app/pubspec.lock ./
RUN flutter pub get
COPY --chown=builder:builder apps/flutter_app/ ./
# --no-web-resources-cdn: CanvasKit is served from here (no third-party script host).
# --web-content-hash: hashed file names, cached forever by Nginx (app-locations.conf).
# --csp: no eval in the compiled JavaScript (matches the Content-Security-Policy).
RUN flutter build web --release --no-web-resources-cdn --web-content-hash --csp \
        --dart-define=API_BASE_URL="${API_BASE_URL}" \
    # Precompress for gzip_static (served when the browser accepts gzip).
    && find build/web -type f -size +1k \
        \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' -o -name '*.json' -o -name '*.html' \
           -o -name '*.css' -o -name '*.svg' -o -name '*.otf' -o -name '*.ttf' -o -name '*.txt' \) \
        -exec gzip -9 -k -n {} +

# --- 2. Nginx --------------------------------------------------------------------------
FROM nginx:1.30-alpine
RUN rm -rf /usr/share/nginx/html/* /etc/nginx/conf.d/default.conf
COPY infrastructure/nginx/snippets/ /etc/nginx/snippets/
COPY infrastructure/nginx/templates/ /etc/nginx/templates/
COPY --from=app-build /home/builder/app/build/web/ /usr/share/nginx/html/

# Rendered into /etc/nginx/conf.d/default.conf at start (only these variables).
ENV NGINX_ENVSUBST_FILTER="^(SERVER_NAME|TLS_CERTIFICATE|TLS_CERTIFICATE_KEY|CSP_CONNECT_SRC)" \
    SERVER_NAME=_ \
    TLS_CERTIFICATE=/etc/nginx/certs/fullchain.pem \
    TLS_CERTIFICATE_KEY=/etc/nginx/certs/privkey.pem \
    # Hosts the browser may reach directly in voice mode (OpenAI WebRTC, Gemini Live).
    CSP_CONNECT_SRC="https://api.openai.com wss://generativelanguage.googleapis.com"

EXPOSE 80 443
