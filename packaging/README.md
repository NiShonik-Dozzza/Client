# Упаковка и дистрибуция EFIR Client

## Как выпустить релиз

```bash
# 1. Обновите версию в pubspec.yaml (например: 1.2.0+3)
# 2. Закоммитьте и создайте тег
git add pubspec.yaml
git commit -m "release: v1.2.0"
git tag v1.2.0
git push origin main --tags
```

GitHub Actions автоматически:
- Соберёт `.exe` installer для Windows на `windows-latest`
- Соберёт `.deb` пакет для Linux на `ubuntu-22.04`
- Соберёт подписанный `.apk` для Android/Android TV
- Создаст черновик GitHub Release со всеми файлами

Зайдите в **Releases → Drafts**, проверьте и опубликуйте.

---

## GitHub Secrets (обязательно настроить)

В Settings → Secrets and variables → Actions:

| Secret | Описание |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | Keystore в base64: `base64 -w0 efir-release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Пароль keystore |
| `ANDROID_KEY_ALIAS` | Alias ключа (обычно `efir`) |
| `ANDROID_KEY_PASSWORD` | Пароль ключа |

Если секреты не заданы — Android APK будет подписан debug-ключом (для тестирования).

---

## Локальная сборка вручную

### Windows installer
```powershell
# Установить Inno Setup: https://jrsoftware.org/isdl.php
flutter build windows --release
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" packaging\windows\efir-setup.iss
# → packaging\windows\Output\efir-setup-1.0.0-windows-x64.exe
```

### Linux (универсальный архив)
```bash
flutter build linux --release
bash packaging/linux/build-tar.sh
# → packaging/linux/output/efir-client_1.0.0_linux_amd64.tar.gz
```

### Android APK
```bash
# Создать keystore (один раз):
keytool -genkey -v -keystore android/app/efir-release.jks \
        -keyalg RSA -keysize 2048 -validity 10000 -alias efir

# Скопировать пример конфига:
cp android/key.properties.example android/key.properties
# Заполнить android/key.properties

# Собрать:
flutter build apk --release --target-platform android-arm64 --split-per-abi
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

---

## Итоговые артефакты

| Платформа | Файл | Установка |
|---|---|---|
| Windows 10/11 | `efir-setup-X.Y.Z-windows-x64.exe` | Запустить обычным пользователем — ставится в его профиль, watchdog регистрируется автоматически. Права администратора нужны один раз и только если в системе нет Visual C++ Runtime |
| Linux (любой дистрибутив) | `efir-client_X.Y.Z_linux_amd64.tar.gz` | `tar xzf *.tar.gz && sudo ./*linux*/install.sh kiosk` |
| Android / Android TV | `efir-X.Y.Z-android-arm64.apk` | `adb install -r *.apk` или через MDM |
