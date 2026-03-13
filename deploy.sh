#!/usr/bin/env bash
set -euo pipefail

# Deploy Flutter web build to remote host.
# Usage examples:
#   ./deploy.sh
#   SSH_USER=deploy REMOTE_DIR=/var/www/client ./deploy.sh
#   REMOTE_DOCKER_COMPOSE_DIR=/opt/client ./deploy.sh
#   REMOTE_SYSTEMD_SERVICE=client-web ./deploy.sh

HOST="${HOST:-10.0.0.81}"
SSH_USER="${SSH_USER:-dozzka}"
SSH_PORT="${SSH_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-/var/www/client}"
BUILD_DIR="${BUILD_DIR:-build/web}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"

# Optional remote run strategy:
# 1) If REMOTE_DOCKER_COMPOSE_DIR is set -> run `docker compose up -d` there
# 2) Else if REMOTE_SYSTEMD_SERVICE is set -> restart systemd service
# 3) Else only upload build artifacts
REMOTE_DOCKER_COMPOSE_DIR="${REMOTE_DOCKER_COMPOSE_DIR:-}"
REMOTE_SYSTEMD_SERVICE="${REMOTE_SYSTEMD_SERVICE:-}"

SSH_OPTS=(
  "-p" "$SSH_PORT"
  "-o" "BatchMode=yes"
  "-o" "PreferredAuthentications=publickey"
  "-o" "PasswordAuthentication=no"
  "-o" "IdentitiesOnly=yes"
  "-i" "$SSH_KEY_PATH"
)
TARGET="${SSH_USER}@${HOST}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

require_cmd flutter
require_cmd ssh
require_cmd scp

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "Error: SSH key not found: $SSH_KEY_PATH" >&2
  exit 1
fi

echo "==> Building Flutter web"
flutter pub get
flutter build web --release

if [[ ! -d "$BUILD_DIR" ]]; then
  echo "Error: build output not found: $BUILD_DIR" >&2
  exit 1
fi

echo "==> Uploading to ${TARGET}:${REMOTE_DIR}"
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p '$REMOTE_DIR'"
scp "${SSH_OPTS[@]}" -r "$BUILD_DIR"/* "$TARGET:$REMOTE_DIR/"

if [[ -n "$REMOTE_DOCKER_COMPOSE_DIR" ]]; then
  echo "==> Starting remote stack via docker compose in $REMOTE_DOCKER_COMPOSE_DIR"
  ssh "${SSH_OPTS[@]}" "$TARGET" "cd '$REMOTE_DOCKER_COMPOSE_DIR' && docker compose up -d"
elif [[ -n "$REMOTE_SYSTEMD_SERVICE" ]]; then
  echo "==> Restarting remote service: $REMOTE_SYSTEMD_SERVICE"
  ssh "${SSH_OPTS[@]}" "$TARGET" "sudo systemctl restart '$REMOTE_SYSTEMD_SERVICE' && sudo systemctl status '$REMOTE_SYSTEMD_SERVICE' --no-pager -l"
else
  echo "==> Upload completed. Remote restart step skipped (no service configured)."
fi

echo "==> Deploy finished"
