#!/usr/bin/env bash
# Собирает универсальный Linux-архив из Flutter release build.
#
# Использование:
#   flutter build linux --release
#   bash packaging/linux/build-tar.sh
#
# Результат: packaging/linux/output/efir-client_1.0.0_linux_amd64.tar.gz
# Установка: tar xzf *.tar.gz && sudo ./*linux*/install.sh kiosk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# В CI версия передаётся через переменную окружения EFIR_VERSION (из git tag).
# При локальной сборке берётся из pubspec.yaml.
VERSION="${EFIR_VERSION:-$(grep '^version:' "$REPO_ROOT/pubspec.yaml" | sed 's/version: //;s/+.*//' | tr -d '[:space:]')}"
ARCH="amd64"
PKG_NAME="efir-client_${VERSION}_linux_${ARCH}"
FLUTTER_BUILD="$REPO_ROOT/build/linux/x64/release/bundle"
OUTPUT_DIR="$SCRIPT_DIR/output"
STAGING="$SCRIPT_DIR/staging/$PKG_NAME"

echo "=== Сборка архива $PKG_NAME ==="

if [ ! -d "$FLUTTER_BUILD" ]; then
    echo "ERROR: Flutter build не найден: $FLUTTER_BUILD"
    echo "Сначала выполните: flutter build linux --release"
    exit 1
fi

# --- Подготовка ---
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Файлы приложения
cp -r "$FLUTTER_BUILD"/. "$STAGING/"
chmod 755 "$STAGING/efir"

# Скрипт установки (войдёт в архив)
cp "$SCRIPT_DIR/install.sh" "$STAGING/"
chmod 755 "$STAGING/install.sh"

# Версия внутри архива: её читает и install.sh, и автообновление — по имени
# каталога определять ненадёжно, оно зависит от того, как распаковали.
echo "$VERSION" > "$STAGING/VERSION"

# --- Упаковка ---
mkdir -p "$OUTPUT_DIR"
tar -czf "$OUTPUT_DIR/${PKG_NAME}.tar.gz" \
    -C "$SCRIPT_DIR/staging" \
    "$PKG_NAME"

echo ""
echo "Готово: $OUTPUT_DIR/${PKG_NAME}.tar.gz"
echo ""
echo "Установка на целевом устройстве:"
echo "  tar xzf ${PKG_NAME}.tar.gz"
echo "  sudo ./${PKG_NAME}/install.sh kiosk"
