# Деплой клиента EFIR

## Linux (Ubuntu / Debian)

### Быстрая установка

```bash
# 1. Собрать архив (или скачать с GitHub Releases)
flutter build linux --release
bash packaging/linux/build-tar.sh
# → packaging/linux/output/efir-client_1.0.0_linux_amd64.tar.gz

# 2. Скопировать на устройство
scp packaging/linux/output/*.tar.gz kiosk@192.168.1.100:~

# 3. На устройстве — распаковать и установить
ssh kiosk@192.168.1.100
tar xzf efir-client_*.tar.gz
sudo ./efir-client_*/install.sh kiosk
```

### Автологин пользователя kiosk

На Ubuntu с GDM:
```bash
# /etc/gdm3/custom.conf
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=kiosk
```

На системах с LightDM (`/etc/lightdm/lightdm.conf`):
```ini
[Seat:*]
autologin-user=kiosk
autologin-user-timeout=0
```

### Управление сервисом

```bash
systemctl --user status  efir-client    # состояние
systemctl --user restart efir-client    # перезапуск
journalctl --user -u     efir-client -f # логи в реальном времени
```

---

## Windows

### Быстрая установка

```powershell
# 1. Собрать приложение
flutter build windows --release

# 2. Скопировать build\windows\x64\runner\Release\ → C:\Program Files\EFIR\

# 3. Установить watchdog (с правами администратора)
Set-ExecutionPolicy Bypass -Scope Process -Force
.\deploy\windows\install-watchdog.ps1 -AppPath "C:\Program Files\EFIR\efir.exe"
```

### Автологин на Windows

`regedit` → `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`:
- `AutoAdminLogon` = `1`
- `DefaultUserName` = имя пользователя
- `DefaultPassword` = пароль

### Управление watchdog

```powershell
# Статус
Get-ScheduledTask -TaskName 'EFIR-Watchdog'

# Лог watchdog
Get-Content "$env:APPDATA\efir\watchdog.log" -Tail 50

# Удалить
Unregister-ScheduledTask -TaskName 'EFIR-Watchdog' -Confirm:$false
```

---

## Android / Android TV

Для Android вотчдог реализован через `wakelock_plus` (система не усыпляет экран).

Для полного watchdog с автоперезапуском — рекомендуется:
- Enroll устройство как **Device Owner** (ADB команда)
- Или использовать MDM-решение (например, Scalefusion, Hexnode)

Для Android TV — установить APK:
```bash
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## Проверка после установки

1. EFIR должен появиться в TV-лаунчере (Android TV) или в автозагрузке (Linux/Windows)
2. Принудительно убейте процесс — watchdog/systemd должны поднять его за 5-10 секунд
3. Перезагрузите устройство — EFIR должен стартовать без вмешательства
