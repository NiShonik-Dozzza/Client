#!/usr/bin/env bash
# Устанавливает EFIR Client как systemd user-сервис с автоперезапуском.
# Запускать от имени пользователя который будет запускать приложение (НЕ от root).
#
# Использование:
#   chmod +x install-service.sh
#   ./install-service.sh /путь/к/efir
#
# После установки:
#   systemctl --user status efir-client
#   journalctl --user -u efir-client -f

set -euo pipefail

# Симлинк current, а не конкретная версия: его переставляет автообновление.
APP_BINARY="${1:-/opt/efir-client/current/efir}"
SERVICE_NAME="efir-client"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/$SERVICE_NAME.service"

# --- Проверки ---
if [ ! -f "$APP_BINARY" ]; then
    echo "ERROR: Бинарник не найден: $APP_BINARY"
    echo "Укажите путь явно: $0 /path/to/efir"
    exit 1
fi

if [ ! -x "$APP_BINARY" ]; then
    echo "ERROR: Файл не имеет права на выполнение: $APP_BINARY"
    echo "Выполните: chmod +x $APP_BINARY"
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: Не запускайте от root. Используйте пользователя kiosk."
    exit 1
fi

# --- Установка ---
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=EFIR Digital Signage Client
After=graphical-session.target network-online.target
Wants=graphical-session.target network-online.target

[Service]
Type=simple
ExecStart=$APP_BINARY
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

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME.service"
systemctl --user start  "$SERVICE_NAME.service"

# Чтобы user-сервисы запускались БЕЗ активной сессии (при reboot без автологина)
# нужен linger. Включаем если доступен loginctl.
if command -v loginctl &>/dev/null; then
    loginctl enable-linger "$(whoami)" 2>/dev/null || true
fi

echo ""
echo "Сервис установлен и запущен."
echo ""
echo "Полезные команды:"
echo "  Статус:    systemctl --user status $SERVICE_NAME"
echo "  Логи:      journalctl --user -u $SERVICE_NAME -f"
echo "  Стоп:      systemctl --user stop $SERVICE_NAME"
echo "  Удалить:   systemctl --user disable --now $SERVICE_NAME && rm $SERVICE_FILE"
