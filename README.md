# Panel Client

Клиент‑плеер для цифровых экранов. Получает расписание с сервера, загружает медиа заранее и воспроизводит локально.

## Требования

- Flutter stable
- Linux / Windows / macOS

## Запуск

```bash
flutter pub get
flutter run -d linux
```

## Привязка к серверу

После первого запуска создаётся конфиг:

```
Documents/panel/config.json
```

Пример:

```json
{
  "media_root": "/home/user/Documents/panel/media",
  "api_base": "http://<server-ip>:8000/api/v1"
}
```

Обязательно:
- `api_base` должен быть доступен клиенту.
- На сервере должен быть правильно настроен `S3_PUBLIC_ENDPOINT`.

## Локальные файлы

```
Documents/panel/
├── config.json
├── device.json
├── manifest.json
├── log.txt
└── media/
```

## Как работает клиент

- **Регистрация**:
  - `POST /api/v1/screens/register`
  - при 404 на heartbeat — регистрация повторяется автоматически.

- **Heartbeat**:
  - `POST /api/v1/screens/heartbeat`
  - отправляет `now_playing` в формате `media:<id>` или `playlist:<id>`.

- **Манифест**:
  - `GET /api/v1/manifest?device_id=...`
  - клиент обновляется по `revision`.

- **Предзагрузка**:
  - сервер отдаёт `prefetch_seconds`.
  - клиент загружает только контент, который начнётся в ближайшие `prefetch_seconds`.

## Debug overlay

`F12` — включить/выключить отладку.

## Типичный сценарий

1. Запустить сервер.
2. В `config.json` прописать `api_base`.
3. Запустить клиента — экран появится в веб‑панели и начнёт получать расписание.
