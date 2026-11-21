#!/bin/sh
# Self-signed TLS certificate for trying the production stack locally and for CI.
# Browsers show a warning for it: never use it on a public server (use Let's
# Encrypt or your own certificate, see docs/deployment.md).
#
#   sh infrastructure/scripts/make-dev-cert.sh [hostname]   # default: localhost
#
# Writes infrastructure/certs/fullchain.pem and privkey.pem (git-ignored), the
# default TLS_CERT_DIR of docker-compose.prod.yml. Needs openssl (included with
# Git for Windows: run it from Git Bash).
set -eu

name="${1:-localhost}"
dir="$(cd "$(dirname "$0")/.." && pwd)/certs"
mkdir -p "$dir"

# Git Bash would otherwise rewrite "/CN=..." into a Windows path (file paths are
# still converted). Ignored on Linux and macOS.
MSYS2_ARG_CONV_EXCL="/CN=" openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=$name" \
    -addext "subjectAltName=DNS:$name,DNS:localhost,IP:127.0.0.1" \
    -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem"
chmod 600 "$dir/privkey.pem"

echo "Wrote $dir/fullchain.pem and $dir/privkey.pem (valid 30 days, CN=$name)"
