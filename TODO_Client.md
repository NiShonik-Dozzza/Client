# TODO Client

Полный список того, что нужно довести для боевого запуска и дальнейшей эксплуатации клиентского player-приложения.

Формат: `[x]` — сделано, `[~]` — частично, `[ ]` — не сделано.
У открытых пунктов строка `→ Как:` — предлагаемое средство реализации.

## Audit 2026-06-12

Закрыто в этом цикле (сверено с кодом):
- [x] Hover-кнопка редактора убрана; вход только сервисными жестами: 3×Esc (desktop), 5 тапов или 5×Back (Android/TV), F2/Menu. PIN-гейт (пустой PIN допустим — осознанное решение).
- [x] Авто-закрытие редактора и PIN-диалога через 30 с бездействия.
- [x] Kiosk в release: Esc не выходит из fullscreen, double-tap не переключает.
- [x] Авто-подбор протокола/порта: пользователь вводит хост — пробуем https→http(→8088); явный порт — оба протокола на нём; явный https не понижаем. Фикс POST-301 за nginx.
- [x] Понятные ошибки подключения (TLS / DNS / timeout / нет соединения / HTTP-код).
- [x] Версия клиента из PackageInfo (вместо хардкода).
- [x] StatusScreen: device id, server url, online/offline, last heartbeat, revision, last manifest sync, кэш, версии клиента и сервера (включая build/revision).
- [x] Выбор места хранения контента (внутренняя память / флешка / диск) при настройке и в настройках; Windows/Linux/Android-тома.
- [x] Рантайм-монитор носителя: проба записи каждые 15 с (таймаут 4 с), авто-откат на внутреннюю при извлечении USB, авто-возврат, детект медленного носителя, события в лог и StatusScreen.
- [x] Настройки доступны после регистрации (⚙️ из редактора): сервер, хранилище, экран/поворот, PIN. Имя устройства — только из панели.
- [x] Редактор: горизонтальный таймлайн «Что дальше» (онлайн — слоты с временами, оффлайн — порядок плейлиста), превью изображений из кэша, плейлисты раскрываются в широкий блок.
- [x] Багфиксы: config затирал service_pin при смене сервера/дисплея; assets/media (.gitkeep) ломал сборку; pending-stage сбрасывался из настроек.
- [x] Библиотеки обновлены без подъёма SDK (media_kit 1.2.6, window_manager 0.5.1, intl 0.20.2). SDK ^3.9.2 / minSdk 23 не трогаем (старые Smart TV).

## Audit 2026-05-16 (история)

Клиент работает с device API (`register/request`, `register/status`, `manifest`, `heartbeat`, `media/{id}`), media качается с Bearer + sha256/size проверкой через `.download`, при 401/403/404 — сброс регистрации, есть manifest polling/heartbeat/prefetch/offline-mode, расширенные heartbeat-поля.

## P0. Обязательно до первого боевого запуска

### Безопасность устройства
- [x] Закрыть локальный редактор от обычного оператора (жесты + PIN + авто-закрытие).
- [x] Убрать свободный вход в editor (hover-кнопка удалена).
- [x] Service-mode = редактор за жестом/PIN; отдельный build-флаг не требуется (пустой PIN — выбор владельца).
- [x] Device token не светится в UI/логах (только булевы флаги; chmod 600 на Unix). Хранение plaintext — см. P1 secure storage.
- [x] Боевой HTTPS: клиент сам выбирает https-first.
- [~] Поведение при ошибке сертификата/MITM: недоверенный серт отклоняется Dart'ом по умолчанию, в UI — «ошибка TLS-сертификата». Не покрыто: самоподписанные/внутренний CA.
  → Как: настройка «доверенный CA (pem)» в service-настройках + `SecurityContext..setTrustedCertificatesBytes`; пиннинг по отпечатку как опция. Проверить на стенде с self-signed.

### Установка и запуск на устройстве
- [x] Автозапуск: Linux — systemd unit (`deploy/linux/efir-client.service` + `install-service.sh`); Windows — `install-watchdog.ps1`.
- [x] Kiosk/fullscreen, который нельзя случайно свернуть (release).
- [x] Sleep/screensaver: wakelock + PowerGuard + immersive (Android).
- [x] Watchdog/restart-after-crash: systemd Restart= (Linux), watchdog.ps1 (Windows), SIGTERM graceful.
- [x] Installer: Inno Setup (Windows, авто-VC++ Runtime), tar.gz + install.sh (Linux), версии из git-тега (CI release.yml).
- [~] Подпись сборок: Android — signing config через key.properties/CI; Windows — не подписан.
  → Как: Windows — `signtool` + код-подпись сертификат (можно отложить до публичного распространения); Android — проверить, что release реально подписывается боевым ключом.

### Надёжность воспроизведения
- [ ] Длительные прогоны: сутки/неделя, переподключение сети, смена revision.
  → Как: чеклист на стенде + memory-watch (DevTools), искусственный обрыв сети/смена расписания в панели; авто-метрики из heartbeat (uptime поле).
- [~] Устойчивость к пустому манифесту / битому файлу / частичному файлу / недоступному серверу / истёкшему токену: обработчики есть (checksum, `.download`, offline-fallback, auth-reset).
  → Как: добить тестами (см. «Тесты») + ручной прогон каждого случая на стенде.
- [~] Очистка кэша: prune по манифесту есть; TTL — нет.
  → Как: в `.media_cache_index.json` хранить `last_used_ms` (обновлять при hit); в `pruneUnused` удалять файлы не из манифеста c last_used старше N суток (default 7).
- [ ] Нехватка места на диске.
  → Как: перед скачиванием сравнивать `media.size` со свободным местом (Linux/macOS — df, Windows — `GetDiskFreeSpaceExW` через пакет win32, Android — StatFs через MethodChannel); при нехватке — экстренный prune, скип с warning, поле `disk_free_bytes` в heartbeat.
- [x] Ограничение/ротация логов (5 МБ × 3).

### Диагностика и поддержка
- [x] Экран статуса устройства (StatusScreen).
- [ ] Экспорт диагностического пакета.
  → Как: кнопка в StatusScreen → zip (пакет `archive`): log.txt+ротации, config.json (без PIN), manifest.json, сводка StatusScreen в txt → сохранить в выбранную папку/на флешку.
- [~] Понятные коды ошибок: подключение — готово; registration/heartbeat — статусы есть, но без кодов.
  → Как: enum причин (network/tls/dns/rejected/expired/revoked/server_5xx) + код в setup-сообщении («E-REG-403»), таблица кодов в DEPLOY.md для поддержки.
- [~] Понятный экран ошибки «сервер недоступен / заявка отклонена»: текст в setup есть.
  → Как: выделенный полноэкранный state с иконкой/кодом/QR на FAQ вместо строки в карточке.

### Тесты и качество
- [ ] Автотесты: manifest parsing, cache validation, registration flow, playlist sequencing, offline fallback.
  → Как: `flutter_test`; `Manifest.fromJson` — golden-JSON фикстуры; `MediaCacheService` — `http.MockClient` (пакет http/testing) + temp dir, проверка checksum/retry/prune; `_serverCandidates`/`_normalizeServerAddress` вынести в чистые функции и покрыть таблицей кейсов; стейт-машина регистрации — мок ApiService.
- [ ] Smoke-тест запуска.
  → Как: widget-тест: pump `App()` с моками → RootScreen рендерится без исключений; позже `integration_test` на Windows-раннере CI.
- [ ] Стабильность на целевой платформе (старый Smart TV).
  → Как: ручной прогон: kiosk, пульт (5×Back), 4K видео, hwdec (`media_kit` лог).

### Android-специфика
- [~] `applicationId` = com.efir.client (выглядит боевым), TODO-комментарии в build.gradle.kts остались; kiosk на железе не проверен.
  → Как: убрать TODO-комментарии, прогнать на целевом TV: автозапуск после ребута (RECEIVE_BOOT_COMPLETED + launcher-режим), immersive, пульт.

## P1. Очень желательно сразу после запуска

### Управление устройством
- [ ] Удалённые команды с сервера: reload manifest / clear cache / restart app / reboot device.
  → Как: канал — ответ heartbeat (сейчас игнорируется): `{commands:[{id,type,payload}]}`, ACK списком `acked_command_ids` в следующем heartbeat. Restart: systemd `systemctl restart` (через polkit-правило) / Windows: выход с кодом — watchdog перезапустит. Reboot — `shutdown -r` с правами. Серверная половина — см. TODO_Server.
- [ ] Maintenance mode удалённо.
  → Как: флаг в манифесте `control.maintenance: true` → клиент показывает заставку «обслуживание», не играет контент.
- [ ] Удалённое отключение локального service-mode.
  → Как: `control.service_mode_locked: true` в манифесте → жесты игнорируются.

### Воспроизведение и UX
- [~] Fallback при отсутствии валидного контента: чёрный экран есть.
  → Как: политика per-screen из манифеста: `idle_policy: black|logo|clock` + asset логотипа; см. ROADMAP «Пустой экран».
- [ ] Экран «нет контента» вместо пустоты — часть idle_policy (выше).
- [x] Переходы видео/изображений без мерцания (двойной плеер, warmup, gapless).
- [ ] Защита от рассинхронизации времени.
  → Как: при manifest/health сравнивать заголовок `Date` сервера с локальным временем; drift > 60 с → warning в StatusScreen + поле `clock_drift_sec` в heartbeat (панель подсветит).
- [ ] Проверка timezone.
  → Как: сравнивать `manifest.timezone` с локальной TZ, расхождение — в диагностику.

### Сеть и обновления
- [~] Retry-стратегия с лимитами: manifest/media — backoff с джиттером есть; heartbeat — без retry.
  → Как: heartbeat не ретраить (следующий через 25 с само), но добавить счётчик подряд-неудач в StatusScreen.
- [x] Фоновая проверка доступности без спама в логах (manifest backoff + unchanged-логирование).
- [ ] Безопасный механизм обновления клиента.
  → Как (MVP): `min_client_version` + `update_url` в манифесте → экран «требуется обновление» с инструкцией; (полный) Windows — скачать installer и запустить `/VERYSILENT`, Linux — обновление пакета через install.sh, Android — prompt на APK (или MDM). Как у Anthias/Yodeck: плеер сам тянет свой апдейт по расписанию вне эфирного времени.
- [ ] Отображение доступной новой версии — в StatusScreen из того же `min_client_version`/`latest_version`.

### Локальные данные
- [ ] Secure storage для токена.
  → Как: `flutter_secure_storage` (Android Keystore / Windows DPAPI / Linux libsecret), прозрачная миграция из device.json при первом запуске.
- [x] Recovery битых JSON: config → defaults, device/manifest → null + лог (деградация без падения); атомарная запись device.json (tmp+rename).
  → Доделать: атомарную запись (tmp+rename) для config.json и manifest.json по образцу device_store.
- [ ] Формализованная структура локальных файлов и миграции.
  → Как: `schema_version` в config.json + миграционная цепочка при load.

## P2. Развитие продукта

### Наблюдаемость
- [~] Телеметрия: heartbeat-поля есть (version/network/cache/failures/display).
  → Добавить: uptime, clock_drift, disk_free, storage_warning.
- [ ] Crash-reporting.
  → Как: `sentry_flutter` → self-hosted Sentry или GlitchTip (on-prem, бесплатно) в docker-compose сервера.
- [x] Локальная страница диагностики (StatusScreen).

### Контент на устройстве
- [x] Просмотр кэша/диска (StatusScreen: размер, количество, путь, носитель).
- [ ] Ручная очистка кэша.
  → Как: кнопка в настройках → подтверждение → удалить media_* + индекс → prefetch заново.
- [ ] Приоритеты prefetch.
  → Как: качать в порядке startTime ближайших слотов (sort перед prefetch), лимит параллельности 1–2.

### Платформенное
- [x] Инструкции и артефакты Windows/Linux (DEPLOY.md, installer, CI из git-тега).
- [ ] Аппаратное ускорение на целевом железе.
  → Как: проверить `hwdec` в логах mpv на TV/слабом ПК; при проблемах — `VideoControllerConfiguration(enableHardwareAcceleration:)`.

## Критерий «клиент готов к production»

P0 закрыт: editor защищён (✓), приложение устойчиво неделями (прогоны — осталось), автозапуск и watchdog (✓), кэш/offline проверены тестами (осталось), диагностика без ручного дебага (✓). Главные хвосты: **тесты, TTL+диск, экспорт логов, прогон на железе**.

Будущие фичи (виджеты, презентации, музыка, стримы, питание, idle-экран) — см. [ROADMAP.md](ROADMAP.md).
