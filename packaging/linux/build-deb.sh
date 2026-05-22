#!/usr/bin/env bash
# Собирает .deb пакет из Flutter Linux release build.
#
# Использование:
#   flutter build linux --release        # сначала собрать приложение
#   bash packaging/linux/build-deb.sh    # потом упаковать
#
# Результат: packaging/linux/output/efir-client_1.0.0_amd64.deb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Версия из pubspec.yaml (строка вида "version: 1.0.0+1" → "1.0.0")
VERSION=$(grep '^version:' "$REPO_ROOT/pubspec.yaml" | sed 's/version: //;s/+.*//' | tr -d '[:space:]')
PKG_NAME="efir-client"
ARCH="amd64"
PKG_FULL="${PKG_NAME}_${VERSION}_${ARCH}"

FLUTTER_BUILD="$REPO_ROOT/build/linux/x64/release/bundle"
STAGING="$SCRIPT_DIR/staging/$PKG_FULL"
OUTPUT_DIR="$SCRIPT_DIR/output"

echo "=== Сборка пакета $PKG_FULL ==="

# --- Проверки ---
if [ ! -d "$FLUTTER_BUILD" ]; then
    echo "ERROR: Flutter build не найден: $FLUTTER_BUILD"
    echo "Сначала выполните: flutter build linux --release"
    exit 1
fi

if ! command -v dpkg-deb &>/dev/null; then
    echo "ERROR: dpkg-deb не найден. Установите: sudo apt install dpkg"
    exit 1
fi

# --- Подготовка staging-директории ---
rm -rf "$STAGING"
mkdir -p "$STAGING/DEBIAN"
mkdir -p "$STAGING/opt/efir-client"
mkdir -p "$STAGING/usr/lib/systemd/user"

# --- Файлы приложения ---
cp -r "$FLUTTER_BUILD/"* "$STAGING/opt/efir-client/"
chmod 755 "$STAGING/opt/efir-client/efir"

# --- systemd service file ---
cp "$REPO_ROOT/deploy/linux/efir-client.service" \
   "$STAGING/usr/lib/systemd/user/efir-client.service"

# Обновить путь в service file под /opt/efir-client/efir
sed -i 's|ExecStart=.*|ExecStart=/opt/efir-client/efir|' \
    "$STAGING/usr/lib/systemd/user/efir-client.service"

# --- debian/control с актуальной версией ---
sed "s/^Version: .*/Version: $VERSION/" \
    "$SCRIPT_DIR/debian/control" > "$STAGING/DEBIAN/control"

# --- Сопроводительные скрипты ---
cp "$SCRIPT_DIR/debian/postinst" "$STAGING/DEBIAN/postinst"
cp "$SCRIPT_DIR/debian/prerm"    "$STAGING/DEBIAN/prerm"
chmod 755 "$STAGING/DEBIAN/postinst" "$STAGING/DEBIAN/prerm"

# --- Размер пакета (для control файла) ---
INSTALLED_SIZE=$(du -sk "$STAGING/opt" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >> "$STAGING/DEBIAN/control"

# --- Собрать .deb ---
mkdir -p "$OUTPUT_DIR"
dpkg-deb --build --root-owner-group "$STAGING" "$OUTPUT_DIR/${PKG_FULL}.deb"

echo ""
echo "Готово: $OUTPUT_DIR/${PKG_FULL}.deb"
echo ""
echo "Установка на целевом устройстве:"
echo "  sudo EFIR_USER=kiosk dpkg -i ${PKG_FULL}.deb"
