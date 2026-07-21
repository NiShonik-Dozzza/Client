#!/usr/bin/env bash
# Устанавливает EFIR Client на любой Linux с systemd.
#
# Использование:
#   tar xzf efir-client_*_linux_amd64.tar.gz
#   cd efir-client_*
#   sudo ./install.sh [пользователь]         # по умолчанию: kiosk
#
# Работает на: Ubuntu, Debian, Fedora, Arch, openSUSE и любом systemd-дистрибутиве.
# Требования: systemd, пользователь с graphical session (X11 или Wayland).

set -euo pipefail

INSTALL_DIR="/opt/efir-client"
SERVICE_NAME="efir-client"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_USER="${1:-${EFIR_USER:-kiosk}}"

# Раскладка версий: $INSTALL_DIR/versions/<версия> + симлинк current.
# Так обновление из панели обходится без root: каталог принадлежит APP_USER,
# приложение само распаковывает новую версию рядом и переставляет симлинк.
# Плоская установка потребовала бы права на /opt, то есть sudo на каждое
# обновление — на экране, к которому никто не подходит, это тупик.
VERSIONS_DIR="$INSTALL_DIR/versions"
VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "0.0.0")"
VERSION_DIR="$VERSIONS_DIR/$VERSION"

# --- Проверки ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите с sudo:"
    echo "  sudo ./install.sh $APP_USER"
    exit 1
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
    echo "Пользователь '$APP_USER' не найден."
    echo "Создайте его:"
    echo "  sudo useradd -m -s /bin/bash $APP_USER"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd не найден — установка сервиса невозможна."
    echo "Скопируйте файлы вручную: cp -r . $INSTALL_DIR"
    exit 1
fi

echo "=== Установка EFIR Client ==="
echo "Пользователь: $APP_USER"
echo "Путь:         $INSTALL_DIR"
echo ""

# --- Копирование файлов ---
rm -rf "$VERSION_DIR"
mkdir -p "$VERSION_DIR"
cp -r "$SCRIPT_DIR"/. "$VERSION_DIR/"
chmod 755 "$VERSION_DIR/efir"

# Симлинк переставляем атомарно (ln -T во временное имя + mv): при обрыве
# посреди операции current остаётся целым, а не висит в никуда.
ln -sfnT "$VERSION_DIR" "$INSTALL_DIR/.current.new"
mv -Tf "$INSTALL_DIR/.current.new" "$INSTALL_DIR/current"

chown -R "$APP_USER:$APP_USER" "$INSTALL_DIR"

# --- Systemd user service ---
USER_HOME=$(getent passwd "$APP_USER" | cut -d: -f6)
SERVICE_DIR="$USER_HOME/.config/systemd/user"
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_DIR/$SERVICE_NAME.service" <<EOF
[Unit]
Description=EFIR Digital Signage Client
After=graphical-session.target network-online.target
Wants=graphical-session.target network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/current/efir
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=10
PassEnvironment=DISPLAY XAUTHORITY WAYLAND_DISPLAY XDG_RUNTIME_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical-session.target
EOF

chown -R "$APP_USER:$APP_USER" "$USER_HOME/.config"

# --- Включить linger (сервис стартует без активной сессии) ---
loginctl enable-linger "$APP_USER" 2>/dev/null || true

# --- Активировать сервис ---
su - "$APP_USER" -c "
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    systemctl --user daemon-reload
    systemctl --user enable $SERVICE_NAME.service
    systemctl --user start  $SERVICE_NAME.service 2>/dev/null || true
" || true

echo ""
echo "=== Готово ==="
echo ""
echo "EFIR Client установлен. Сервис запустится автоматически при входе $APP_USER."
echo ""
echo "Управление (от имени $APP_USER или через su):"
echo "  systemctl --user status  $SERVICE_NAME"
echo "  systemctl --user restart $SERVICE_NAME"
echo "  journalctl --user -u     $SERVICE_NAME -f"
echo ""
echo "Удаление:"
echo "  sudo rm -rf $INSTALL_DIR"
echo "  su - $APP_USER -c 'systemctl --user disable --now $SERVICE_NAME'"
