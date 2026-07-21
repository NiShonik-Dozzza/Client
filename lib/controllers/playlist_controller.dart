import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/display_profile.dart';
import '../models/manifest.dart';
import '../models/playlist_item.dart';
import '../services/api_service.dart';
import '../services/app_logger.dart';
import '../services/app_paths.dart';
import '../services/config_service.dart';
import '../services/display_service.dart';
import '../services/device_store.dart';
import '../services/manifest_store.dart';
import '../services/media_cache_service.dart';
import '../services/storage_service.dart';
import '../services/trust_store.dart';
import '../services/update_installer.dart';
import '../services/update_service.dart';

enum DeviceSetupStage { booting, setupRequired, pendingApproval, ready }

/// Предложение доверять самоподписанному сертификату сервера (TOFU).
class TlsTrustPrompt {
  const TlsTrustPrompt({
    required this.host,
    required this.port,
    required this.fingerprintHex,
    required this.subject,
  });

  final String host;
  final int port;
  final String fingerprintHex;
  final String subject;

  String get displayFingerprint =>
      TrustStore.displayFingerprint(fingerprintHex);
}

/// Ожидающее подтверждения использование незашифрованного HTTP: сервер
/// доступен только по cleartext, оператор должен явно согласиться.
class CleartextHttpPrompt {
  const CleartextHttpPrompt({required this.host, required this.port});

  final String host;
  final int port;
}

/// Резолв адреса остановлен: выбранный кандидат — незашифрованный HTTP,
/// а согласия оператора ещё нет (см. [PlaylistController.pendingCleartextPrompt]).
class CleartextHttpPendingError implements Exception {
  @override
  String toString() => 'CleartextHttpPendingError';
}

class PlaylistController extends GetxController {
  String _clientVersion = 'efir-client';
  // Чистые version/build отдельно от витринной строки: панель сравнивает их
  // с релизом, и "efir-client 1.0.0+1" туда отправлять нельзя.
  String _appVersion = '';
  int _appBuild = 0;

  // Диагностика устройства для status screen.
  final Rxn<DateTime> lastHeartbeatAt = Rxn<DateTime>();
  final Rxn<DateTime> lastManifestSyncAt = Rxn<DateTime>();
  final RxBool lastHeartbeatOk = false.obs;
  final Rxn<DeviceHealth> serverHealth = Rxn<DeviceHealth>();

  /// Ожидающее подтверждения TLS-доверие (заполняется при ошибке сертификата).
  final Rxn<TlsTrustPrompt> pendingTlsPrompt = Rxn<TlsTrustPrompt>();

  /// Ожидающее подтверждения использование cleartext HTTP.
  final Rxn<CleartextHttpPrompt> pendingCleartextPrompt =
      Rxn<CleartextHttpPrompt>();

  /// Разовые согласия оператора на HTTP в рамках сессии (host:port).
  /// После успешного резолва база сохраняется с явным `http://` —
  /// дальше согласие несёт сама сохранённая схема.
  final Set<String> _cleartextConsents = <String>{};

  // Место хранения контента (медиа-кэш) и рантайм-диагностика носителя.
  final RxString storageLocation = ''.obs;
  final RxString storageWarning = ''.obs;
  final RxBool storageSlow = false.obs;
  final RxString lastStorageEvent = ''.obs;
  final Rxn<DateTime> lastStorageCheckAt = Rxn<DateTime>();
  final RxInt storageLatencyMs = 0.obs;

  final RxBool _isLoading = false.obs;
  final RxInt version = 0.obs;
  final Rx<DeviceSetupStage> _setupStage = DeviceSetupStage.booting.obs;
  final RxString _setupMessage = ''.obs;
  final RxString _serverAddress = ''.obs;
  final RxString _deviceDisplayName = ''.obs;
  final RxBool _setupBusy = false.obs;
  final RxBool _displayBusy = false.obs;
  final RxString _syncDiagnostics = ''.obs;
  final RxList<DeviceDisplayProfile> _availableDisplays =
      <DeviceDisplayProfile>[].obs;
  final RxString _selectedDisplayId = ''.obs;
  final RxString _activeDisplayId = ''.obs;
  final RxInt _localDisplayRotation = 0.obs;
  final RxBool isOfflineMode = false.obs;

  final RxList<PlaylistItem> localItems = <PlaylistItem>[].obs;

  final _config = ConfigService();
  final _displayService = DisplayService();
  final _deviceStore = DeviceStore();
  final _manifestStore = ManifestStore();
  final _storage = StorageService();
  late final MediaCacheService _cache;

  ApiService? _api;
  Manifest? _manifest;
  DeviceAuth? _auth;
  String _mediaRoot = '';
  String? _nowPlaying;

  Timer? _manifestTimer;
  Timer? _heartbeatTimer;
  Timer? _registrationPollTimer;
  Timer? _storageTimer;
  Timer? _updateTimer;
  final _updateService = UpdateService();
  bool _updateCycleInFlight = false;
  PreparedUpdate? _preparedUpdate;
  int _manifestFailures = 0;
  bool _manifestInFlight = false;
  Future<void> _prefetchChain = Future.value();
  final _rng = Random();

  static const Duration _manifestBaseInterval = Duration(seconds: 5);
  static const Duration _heartbeatInterval = Duration(seconds: 25);
  // Обновления — редкое событие; чаще опрашивать незачем, а лишний трафик на
  // сети из десятков экранов заметен.
  static const Duration _updateCheckInterval = Duration(minutes: 30);
  static const List<int> _manifestBackoffSeconds = [2, 5, 10, 20, 30];
  static const Duration _storageCheckInterval = Duration(seconds: 15);
  static const Duration _storageSlowThreshold = Duration(milliseconds: 1500);

  bool get isLoading => _isLoading.value;
  DeviceSetupStage get setupStage => _setupStage.value;
  String get setupMessage => _setupMessage.value;
  String get serverAddress => _serverAddress.value;
  String get deviceDisplayName => _deviceDisplayName.value;
  String get syncDiagnostics => _syncDiagnostics.value;
  bool get setupBusy => _setupBusy.value;
  bool get displayBusy => _displayBusy.value;
  bool get isReady => _setupStage.value == DeviceSetupStage.ready;
  bool get isPendingApproval =>
      _setupStage.value == DeviceSetupStage.pendingApproval;
  String get deviceId => _auth?.deviceId ?? '';
  Manifest? get manifest => _manifest;
  List<DeviceDisplayProfile> get availableDisplays =>
      _availableDisplays.toList(growable: false);
  String get selectedDisplayId => _selectedDisplayId.value;
  String get activeDisplayId => _activeDisplayId.value;
  int get localDisplayRotation => _localDisplayRotation.value;
  int get effectiveDisplayRotation => _normalizeRotation(
    _manifest?.display.rotation ?? _localDisplayRotation.value,
  );
  String get effectiveDisplayId {
    final remote = _manifest?.display.targetDisplayId.trim() ?? '';
    if (remote.isNotEmpty) {
      return remote;
    }
    return _selectedDisplayId.value;
  }

  bool get audioMuted => _manifest?.playback.audioMuted ?? true;
  int get masterVolume =>
      (_manifest?.playback.masterVolume ?? 0).clamp(0, 100).toInt();
  String get currentRevision => _manifest?.revision ?? '';
  List<ManifestItem> get items => _manifest?.items ?? [];
  List<PlaylistItem> get editorItems => localItems.toList();
  bool get hasServicePin => _config.cached?.hasServicePin ?? false;
  bool verifyServicePin(String entered) => _config.verifyServicePin(entered);
  String get clientVersion => _clientVersion;
  String get mediaRoot => _mediaRoot;
  String get configuredStorage => _config.cached?.mediaRoot ?? '';
  Future<MediaCacheDiagnostics> cacheDiagnostics() =>
      _cache.diagnostics(_manifest, _mediaRoot);

  Future<List<StorageVolume>> listStorageVolumes() => _storage.listVolumes();

  /// Применяет место хранения с проверкой записи. Если выбранный носитель
  /// недоступен (вынули USB) — откат на внутреннюю память + предупреждение,
  /// при этом выбор пользователя в конфиге НЕ перезаписываем (вернётся при
  /// следующем подключении носителя).
  Future<void> _applyMediaRoot(String desired) async {
    if (await _storage.isWritable(desired)) {
      _mediaRoot = desired;
      storageLocation.value = desired;
      storageWarning.value = '';
      return;
    }
    final internal = await _storage.internalVolume();
    _mediaRoot = internal.mediaPath;
    storageLocation.value = internal.mediaPath;
    storageWarning.value =
        'Выбранный носитель недоступен — контент сохраняется во внутреннюю память.';
    await AppLogger.log(
      'storage fallback to internal: desired=$desired actual=${internal.mediaPath}',
    );
  }

  /// Меняет место хранения контента: проверяет запись, сохраняет в конфиг,
  /// перенаправляет префетч в новую папку.
  Future<bool> setStorageLocation(String mediaPath) async {
    if (!await _storage.isWritable(mediaPath)) {
      storageWarning.value = 'Носитель недоступен для записи.';
      return false;
    }
    await _config.setMediaRoot(mediaPath);
    _mediaRoot = mediaPath;
    storageLocation.value = mediaPath;
    storageWarning.value = '';
    await AppLogger.log('storage location set: $mediaPath');
    final manifest = _manifest;
    if (manifest != null) {
      _prefetchMedia(manifest);
    }
    version.value++;
    return true;
  }

  void _startStorageMonitor() {
    _storageTimer?.cancel();
    _storageTimer = Timer.periodic(
      _storageCheckInterval,
      (_) => _checkStorageHealth(),
    );
  }

  /// Рантайм-контроль носителя:
  /// - носитель пропал (вынули USB) → откат на внутреннюю память + событие;
  /// - носитель вернулся → возврат на него + перекачка контента;
  /// - носитель отвечает медленно → флаг storageSlow + предупреждение.
  /// Всё пишется в лог (`storage event: ...`) и видно в StatusScreen.
  Future<void> _checkStorageHealth() async {
    final desired = _config.cached?.mediaRoot ?? _mediaRoot;
    final internalPath = await _storage.internalMediaPath();
    final result = await _storage.probe(desired);
    lastStorageCheckAt.value = DateTime.now();
    storageLatencyMs.value = result.latency.inMilliseconds;

    if (!result.ok) {
      storageSlow.value = false;
      // Если работали именно на этом (теперь недоступном) носителе — откат.
      if (_mediaRoot == desired && desired != internalPath) {
        _mediaRoot = internalPath;
        storageLocation.value = internalPath;
        lastStorageEvent.value =
            'removed ${DateTime.now().toIso8601String()} (${result.error})';
        await AppLogger.log(
          'storage event: removed desired=$desired error=${result.error} -> internal=$internalPath',
        );
        final manifest = _manifest;
        if (manifest != null) _prefetchMedia(manifest);
      }
      storageWarning.value = desired == internalPath
          ? 'Внутренняя память недоступна для записи (${result.error}).'
          : 'Выбранный носитель недоступен (${result.error}) — контент во внутренней памяти.';
      return;
    }

    final slow = result.latency >= _storageSlowThreshold;
    storageSlow.value = slow;

    // Были на откате, а выбранный носитель вернулся — возвращаемся на него.
    if (_mediaRoot != desired) {
      _mediaRoot = desired;
      storageLocation.value = desired;
      lastStorageEvent.value =
          'restored ${DateTime.now().toIso8601String()} (${result.latency.inMilliseconds}ms)';
      await AppLogger.log(
        'storage event: restored desired=$desired latency=${result.latency.inMilliseconds}ms',
      );
      final manifest = _manifest;
      if (manifest != null) _prefetchMedia(manifest);
    }

    storageWarning.value = slow
        ? 'Носитель отвечает медленно (${result.latency.inMilliseconds} мс) — возможны задержки контента.'
        : '';
  }

  @override
  void onInit() {
    super.onInit();
    _boot();
  }

  @override
  void onClose() {
    _manifestTimer?.cancel();
    _heartbeatTimer?.cancel();
    _registrationPollTimer?.cancel();
    _storageTimer?.cancel();
    _updateTimer?.cancel();
    super.onClose();
  }

  Future<void> _boot() async {
    _isLoading.value = true;
    try {
      // Пины сертификатов должны быть в памяти до создания HTTP-клиентов:
      // badCertificateCallback синхронный.
      await TrustStore.instance.load();
      // Мы поднялись — значит обновление либо встало, либо провалилось.
      // В обоих случаях watchdog снова должен сторожить процесс.
      await UpdateInstaller.clearUpdateLock();
      await _loadClientVersion();
      final cfg = await _config.load();
      await _applyMediaRoot(cfg.mediaRoot);
      _startStorageMonitor();
      _serverAddress.value = cfg.serverUrl;
      _selectedDisplayId.value = cfg.selectedDisplayId;
      _localDisplayRotation.value = _normalizeRotation(cfg.displayRotation);
      _api = ApiService(serverBase: cfg.serverUrl);
      await _repairServerAddressIfNeeded();
      await refreshAvailableDisplays(applySelection: false);
      await applyEffectiveDisplaySelection(force: true);
      _cache = MediaCacheService(
        onForbidden: _fetchManifest,
        tokenProvider: () => _auth?.token,
      );

      _auth = await _deviceStore.read();
      _auth ??= DeviceAuth(
        deviceId: _generateDeviceId(),
        token: '',
        name: _deviceName(),
      );
      _deviceDisplayName.value = (_auth?.name?.trim().isNotEmpty ?? false)
          ? _auth!.name!
          : _deviceName();
      await _deviceStore.save(_auth!);
      await AppLogger.log(
        'boot state: server=${_serverAddress.value} device_id=${_auth?.deviceId ?? "-"} has_token=${_auth?.hasToken ?? false} has_pending=${_auth?.hasPendingRequest ?? false}',
      );

      final cachedManifest = await _manifestStore.read();
      if (cachedManifest != null) {
        _setManifest(cachedManifest, source: 'cache');
      }

      await _loadLocalPlaylist();

      if (_serverAddress.value.isEmpty) {
        _setSetupRequired(
          'Укажите адрес сервера и отправьте заявку на регистрацию.',
        );
      } else if (_auth?.hasToken ?? false) {
        _setupStage.value = DeviceSetupStage.ready;
        _setupMessage.value =
            'Устройство зарегистрировано и готово к синхронизации.';
        await _startOnlineSync();
      } else if (_auth?.hasPendingRequest ?? false) {
        _setPendingApproval(
          'Заявка уже отправлена. Ожидается подтверждение на сервере.',
        );
        await refreshRegistrationStatus();
      } else {
        _setSetupRequired(
          'Проверьте адрес сервера и отправьте заявку на регистрацию.',
        );
      }
    } catch (e) {
      await AppLogger.log('boot error: $e');
      await _loadLocalPlaylist();
      _setSetupRequired(
        'Не удалось инициализировать клиент. Проверьте настройки сервера.',
      );
    } finally {
      _isLoading.value = false;
    }
  }

  Future<bool> verifyServerConnection({
    String? serverAddress,
    String? deviceName,
    bool keepStage = false,
  }) async {
    // В режиме «Настройки» (устройство уже ready) не меняем setupStage —
    // иначе ready-экран выкинуло бы обратно в регистрацию.
    void showMessage(String message) {
      if (keepStage) {
        _setupMessage.value = message;
      } else {
        _setSetupRequired(message);
      }
    }

    final rawInput = (serverAddress ?? _serverAddress.value).trim();
    // Явный ввод `http://` — намерение оператора, диалог согласия не нужен.
    // Схему смотрим ДО нормализации: она сама подставляет http:// к голому хосту.
    final explicitHttp = rawInput.toLowerCase().startsWith('http://');
    final normalizedServer = _normalizeServerAddress(rawInput);
    if (normalizedServer.isEmpty) {
      showMessage('Введите IP-адрес или доменное имя сервера.');
      return false;
    }

    _setupBusy.value = true;
    try {
      final (resolvedServer, health) = await _resolveServerBaseWithHealth(
        normalizedServer,
        allowInsecureHttp: explicitHttp,
      );
      _serverAddress.value = resolvedServer;
      if (deviceName != null && deviceName.trim().isNotEmpty) {
        _deviceDisplayName.value = deviceName.trim();
      }
      _api?.updateServerBase(resolvedServer);
      await _config.setServerUrl(resolvedServer);
      showMessage(
        resolvedServer == normalizedServer
            ? 'Соединение установлено: ${health.name} ${health.version}, часовой пояс ${health.timezone}.'
            : 'Соединение установлено: ${health.name} ${health.version}, часовой пояс ${health.timezone}. Использую адрес $resolvedServer.',
      );
      return true;
    } catch (e) {
      await AppLogger.log('health check failed: $e');
      if (_isTlsError(e)) {
        await _prepareTlsPrompt(normalizedServer);
      }
      showMessage(
        'Не удалось подключиться к серверу: ${_describeServerError(e)}. '
        'Проверьте адрес и сеть.',
      );
      return false;
    } finally {
      _setupBusy.value = false;
    }
  }

  Future<bool> submitRegistrationRequest({
    required String serverAddress,
    required String deviceName,
  }) async {
    final auth = _auth;
    final api = _api;
    if (auth == null || api == null) return false;

    final rawInput = serverAddress.trim();
    final explicitHttp = rawInput.toLowerCase().startsWith('http://');
    final normalizedServer = _normalizeServerAddress(rawInput);
    if (normalizedServer.isEmpty) {
      _setSetupRequired('Введите IP-адрес или доменное имя сервера.');
      return false;
    }

    _setupBusy.value = true;
    try {
      final (resolvedServer, health) = await _resolveServerBaseWithHealth(
        normalizedServer,
        allowInsecureHttp: explicitHttp,
      );
      _serverAddress.value = resolvedServer;
      _deviceDisplayName.value = deviceName.trim().isNotEmpty
          ? deviceName.trim()
          : _deviceName();
      _api?.updateServerBase(resolvedServer);
      await _config.setServerUrl(resolvedServer);
      await AppLogger.log(
        'device health ok: name=${health.name} version=${health.version} server=$resolvedServer',
      );

      final request = await api.requestRegistration(
        deviceId: auth.deviceId,
        name: _deviceDisplayName.value,
        clientVersion: _clientVersion,
      );
      _auth = auth.copyWith(
        token: '',
        name: _deviceDisplayName.value,
        requestToken: request.requestToken,
      );
      await _deviceStore.save(_auth!);
      _setPendingApproval(
        request.message.isNotEmpty
            ? request.message
            : 'Заявка отправлена. Подтвердите устройство в панели управления.',
      );
      _scheduleRegistrationPoll(
        Duration(
          seconds: request.pollAfterSeconds > 0 ? request.pollAfterSeconds : 5,
        ),
      );
      return true;
    } catch (e) {
      await AppLogger.log('registration request failed: $e');
      if (_isTlsError(e)) {
        await _prepareTlsPrompt(normalizedServer);
      }
      _setSetupRequired(
        'Не удалось отправить заявку: ${_describeServerError(e)}.',
      );
      return false;
    } finally {
      _setupBusy.value = false;
    }
  }

  Future<void> refreshRegistrationStatus() async {
    final auth = _auth;
    final api = _api;
    if (auth == null || api == null || !auth.hasPendingRequest) return;

    _registrationPollTimer?.cancel();
    _setupBusy.value = true;
    try {
      final status = await api.registrationStatus(
        deviceId: auth.deviceId,
        requestToken: auth.requestToken,
      );

      if (status.isApproved &&
          status.token != null &&
          status.token!.isNotEmpty) {
        _auth = auth.copyWith(
          token: status.token,
          requestToken: '',
          name: status.screenName ?? _deviceDisplayName.value,
        );
        _deviceDisplayName.value = _auth?.name ?? _deviceDisplayName.value;
        await _deviceStore.save(_auth!);
        _setupStage.value = DeviceSetupStage.ready;
        _setupMessage.value = 'Устройство подтверждено. Начинаю синхронизацию.';
        await _startOnlineSync();
        return;
      }

      if (status.isRejected) {
        _auth = auth.copyWith(token: '', requestToken: '');
        await _deviceStore.save(_auth!);
        _setSetupRequired(
          status.message.isNotEmpty
              ? 'Заявка отклонена: ${status.message}'
              : 'Заявка отклонена. Измените параметры и отправьте заново.',
        );
        return;
      }

      if (status.isExpired || status.isRevoked) {
        _auth = auth.copyWith(token: '', requestToken: '');
        await _deviceStore.save(_auth!);
        _setSetupRequired(
          status.message.isNotEmpty
              ? status.message
              : 'Заявка больше не действительна. Отправьте новую заявку на регистрацию.',
        );
        return;
      }

      _setPendingApproval(
        status.message.isNotEmpty
            ? status.message
            : 'Заявка отправлена. Ожидается подтверждение на сервере.',
      );
      _scheduleRegistrationPoll(
        Duration(
          seconds: status.pollAfterSeconds > 0 ? status.pollAfterSeconds : 5,
        ),
      );
    } on ApiException catch (e) {
      await AppLogger.log('registration status failed: $e');
      if (e.statusCode == 404 || e.statusCode == 409) {
        _auth = auth.copyWith(token: '', requestToken: '');
        await _deviceStore.save(_auth!);
        _setSetupRequired(
          e.statusCode == 409
              ? 'Токен подтверждения уже был выдан. Отправьте новую заявку на привязку.'
              : 'Заявка на привязку не найдена. Отправьте новую заявку.',
        );
        return;
      }
      _setPendingApproval(
        'Сервер временно недоступен. Повторю проверку автоматически.',
      );
      _scheduleRegistrationPoll(const Duration(seconds: 10));
    } catch (e) {
      await AppLogger.log('registration status failed: $e');
      _setPendingApproval(
        'Сервер временно недоступен. Повторю проверку автоматически.',
      );
      _scheduleRegistrationPoll(const Duration(seconds: 10));
    } finally {
      _setupBusy.value = false;
    }
  }

  Future<void> resetRegistrationFlow() async {
    _registrationPollTimer?.cancel();
    _manifestTimer?.cancel();
    _heartbeatTimer?.cancel();
    _updateTimer?.cancel();
    final auth = _auth;
    if (auth != null) {
      _auth = auth.copyWith(
        token: '',
        requestToken: '',
        name: _deviceDisplayName.value,
      );
      await _deviceStore.save(_auth!);
    }
    _setSetupRequired('Проверьте адрес сервера и отправьте новую заявку.');
  }

  void _setSetupRequired(String message) {
    _registrationPollTimer?.cancel();
    _setupStage.value = DeviceSetupStage.setupRequired;
    _setupMessage.value = message;
  }

  void _setPendingApproval(String message) {
    _setupStage.value = DeviceSetupStage.pendingApproval;
    _setupMessage.value = message;
  }

  Future<void> _startOnlineSync() async {
    _registrationPollTimer?.cancel();
    _heartbeatTimer?.cancel();
    await AppLogger.log(
      'online sync start: device_id=${_auth?.deviceId ?? "-"} server=${_serverAddress.value} revision=$currentRevision',
    );
    await _fetchManifest();
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => _sendHeartbeat(),
    );
    _startUpdateChecks();
  }

  void _startUpdateChecks() {
    _updateTimer?.cancel();
    if (!UpdateService.isEnabled) return;
    _updateTimer = Timer.periodic(
      _updateCheckInterval,
      (_) => _runUpdateCycle(),
    );
    // Первая проверка сразу после старта: экран мог простоять выключенным,
    // пока раскатывали обновление.
    unawaited(_runUpdateCycle());
  }

  /// Проверить → скачать (с проверкой подписи) → поставить, если можно сейчас.
  ///
  /// Любая ошибка здесь не должна мешать показу контента: обновление —
  /// сервисная задача, а экран в первую очередь должен показывать.
  Future<void> _runUpdateCycle() async {
    if (_updateCycleInFlight) return;
    final auth = _auth;
    final server = _serverAddress.value;
    if (auth == null || !auth.hasToken || server.isEmpty) return;

    _updateCycleInFlight = true;
    try {
      final info = await _updateService.check(
        serverBase: server,
        deviceId: auth.deviceId,
        token: auth.token,
      );
      if (info == null) {
        _preparedUpdate = null;
        return;
      }

      var prepared = _preparedUpdate;
      if (prepared == null || prepared.info.sha256 != info.sha256) {
        await _updateService.reportStatus(
          serverBase: server,
          deviceId: auth.deviceId,
          token: auth.token,
          state: 'downloading',
          version: info.version,
        );
        prepared = await _updateService.download(info, token: auth.token);
        await _updateService.cleanup(keep: prepared.file);
        _preparedUpdate = prepared;
        await _updateService.reportStatus(
          serverBase: server,
          deviceId: auth.deviceId,
          token: auth.token,
          state: 'ready',
          version: info.version,
        );
      }

      // Скачивать можно всегда, ставить — только в окне: установка рвёт показ.
      if (!info.installAllowedNow) {
        await AppLogger.log(
          'update ${info.version} ready, waiting for window ${info.updateWindow}',
        );
        return;
      }

      await _updateService.reportStatus(
        serverBase: server,
        deviceId: auth.deviceId,
        token: auth.token,
        state: 'installing',
        version: info.version,
      );
      final result = await UpdateInstaller.install(prepared.file);
      switch (result.outcome) {
        case InstallOutcome.started:
          // Дальше нас заменят/перезапустят; статус подтвердит новая версия
          // своим heartbeat с новым client_build.
          break;
        case InstallOutcome.needsConfirmation:
        case InstallOutcome.unsupported:
          // Файл проверен и лежит на устройстве — в панели это `ready`,
          // чтобы оператор видел: доехало, но само не встанет.
          await _updateService.reportStatus(
            serverBase: server,
            deviceId: auth.deviceId,
            token: auth.token,
            state: 'ready',
            version: info.version,
          );
          break;
        case InstallOutcome.failed:
          await _updateService.reportStatus(
            serverBase: server,
            deviceId: auth.deviceId,
            token: auth.token,
            state: 'failed',
            version: info.version,
            error: result.message,
          );
          break;
      }
    } on UpdateRejected catch (e) {
      // Подпись/хеш не сошлись — это не сетевая неурядица, а сигнал.
      await AppLogger.log('update rejected: ${e.reason}');
      _preparedUpdate = null;
      await _updateService.reportStatus(
        serverBase: server,
        deviceId: auth.deviceId,
        token: auth.token,
        state: 'failed',
        error: e.reason,
      );
    } catch (e) {
      await AppLogger.log('update cycle failed: $e');
    } finally {
      _updateCycleInFlight = false;
    }
  }

  void _scheduleRegistrationPoll(Duration delay) {
    _registrationPollTimer?.cancel();
    _registrationPollTimer = Timer(delay, refreshRegistrationStatus);
  }

  Future<void> _handleAuthLoss(String reason) async {
    await AppLogger.log('device auth lost: $reason');
    await resetRegistrationFlow();
    _setupMessage.value =
        'Доступ устройства больше не действителен. Отправьте новую заявку на регистрацию.';
  }

  Future<void> _loadLocalPlaylist() async {
    try {
      final file = await AppPaths.playlistFile();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        localItems.assignAll(
          _normalizeLocalItems(
            (json as List).map((e) => PlaylistItem.fromJson(e)).toList(),
          ),
        );
        await AppLogger.log(
          'Local playlist loaded: ${localItems.length} items',
        );
      } else {
        localItems.clear();
        await AppLogger.log('Local playlist file not found, using empty list');
      }
    } catch (e) {
      await AppLogger.log('Local playlist load error: $e');
      localItems.clear();
    }
  }

  List<PlaylistItem> _normalizeLocalItems(List<PlaylistItem> items) {
    final normalized = items
        .where((item) => item.filename.trim().isNotEmpty)
        .map(
          (item) => item.copyWith(
            filename: item.filename.trim(),
            durationSeconds: item.durationSeconds < 1 ? 1 : item.durationSeconds,
          ),
        )
        .toList();

    // Стабильная сортировка по startDate: при равных датах (например, все
    // «всегда активные» элементы с 2000-01-01) сохраняется исходный порядок.
    // Dart List.sort не гарантирует стабильность, поэтому сортируем по паре
    // (startDate, исходный индекс).
    final indexed = normalized.asMap().entries.toList()
      ..sort((a, b) {
        final byDate = a.value.startDate.compareTo(b.value.startDate);
        return byDate != 0 ? byDate : a.key.compareTo(b.key);
      });
    return indexed.map((e) => e.value).toList();
  }

  Future<void> refreshLocalPlaylist() async {
    await _loadLocalPlaylist();
    version.value++;
  }

  Future<void> replaceLocalPlaylist(List<PlaylistItem> items) async {
    localItems.assignAll(_normalizeLocalItems(items));
    version.value++;
  }

  Future<void> saveLocalPlaylist([List<PlaylistItem>? items]) async {
    if (items != null) {
      await replaceLocalPlaylist(items);
    }
    await _saveLocalPlaylist();
    if (items == null) {
      version.value++;
    }
  }

  Future<void> _saveLocalPlaylist() async {
    try {
      final jsonList = localItems.map((item) => item.toJson()).toList();
      final jsonString = JsonEncoder.withIndent('  ').convert(jsonList);
      final file = await AppPaths.playlistFile();
      await file.writeAsString(jsonString);
      await AppLogger.log('Local playlist saved: ${file.path}');
    } catch (e) {
      await AppLogger.log('Local playlist save error: $e');
      rethrow;
    }
  }

  dynamic currentItem(DateTime now) {
    if (isOfflineMode.value) {
      return currentOfflineItem(now);
    }
    return currentSlot(now);
  }

  PlaylistItem? currentOfflineItem(DateTime now) {
    for (final item in localItems.reversed) {
      if (item.isActiveAt(now)) {
        return item;
      }
    }
    return null;
  }

  /// Все активные в момент [now] локальные элементы — в порядке списка.
  /// Используется для последовательной ротации в оффлайн-режиме.
  List<PlaylistItem> activeOfflineItems(DateTime now) {
    return localItems.where((item) => item.isActiveAt(now)).toList();
  }

  Future<void> loadPlaylist() async {
    if (isOfflineMode.value) {
      await refreshLocalPlaylist();
    } else {
      await _fetchManifest();
    }
  }

  Future<void> enableOfflineMode() async {
    if (isOfflineMode.value) return;
    await _loadLocalPlaylist();
    _manifestTimer?.cancel();
    isOfflineMode.value = true;
    version.value++;
    await AppLogger.log('Offline emergency mode enabled');
  }

  Future<void> disableOfflineMode() async {
    if (!isOfflineMode.value) return;
    isOfflineMode.value = false;
    version.value++;
    await AppLogger.log('Offline emergency mode disabled');
    if (isReady) {
      await _fetchManifest();
      unawaited(_sendHeartbeat());
    }
  }

  Future<void> _fetchManifest() async {
    if (isOfflineMode.value || !isReady) return;

    final api = _api;
    final auth = _auth;
    if (api == null || auth == null || !auth.hasToken) return;

    if (_manifestInFlight) {
      await AppLogger.log(
        'manifest fetch skipped: in_flight=true device_id=${auth.deviceId} revision=$currentRevision',
      );
      return;
    }
    _manifestInFlight = true;

    try {
      await AppLogger.log(
        'manifest fetch start: device_id=${auth.deviceId} revision=$currentRevision token_present=${auth.token.isNotEmpty}',
      );
      final manifest = await api.fetchManifest(
        deviceId: auth.deviceId,
        token: auth.token,
      );
      _manifestFailures = 0;
      lastManifestSyncAt.value = DateTime.now();
      final currentManifest = _manifest;
      if (currentManifest != null &&
          currentManifest.revision == manifest.revision) {
        await AppLogger.log(
          'manifest fetch unchanged: device_id=${auth.deviceId} revision=${manifest.revision} items=${manifest.items.length}',
        );
        return;
      }
      if (currentManifest != null &&
          _manifestSignature(currentManifest) == _manifestSignature(manifest)) {
        await AppLogger.log(
          'manifest fetch unchanged signature: device_id=${auth.deviceId} revision=${manifest.revision} items=${manifest.items.length}',
        );
        return;
      }

      _setManifest(
        manifest,
        source: currentManifest?.revision == manifest.revision
            ? 'api-refresh'
            : 'api',
      );
      if (manifest.items.isEmpty) {
        await AppLogger.log(
          'Manifest is empty: rev=${manifest.revision} media=${manifest.media.length} playlists=${manifest.playlists.length}',
        );
      }
      await _manifestStore.save(manifest);
      _prefetchMedia(manifest);
    } on ApiException catch (e) {
      _manifestFailures++;
      _syncDiagnostics.value = 'manifest error ${e.statusCode}';
      await AppLogger.log('manifest fetch failed: $e');
      if (e.statusCode == 401 || e.statusCode == 403 || e.statusCode == 404) {
        await _handleAuthLoss('manifest ${e.statusCode}');
      }
    } catch (e) {
      _manifestFailures++;
      await AppLogger.log('manifest fetch failed: $e');
    } finally {
      _manifestInFlight = false;
      _scheduleManifestFetch();
    }
  }

  void _setManifest(Manifest manifest, {required String source}) {
    _manifest = manifest;
    version.value++;
    _syncDiagnostics.value =
        'manifest=$source rev=${manifest.revision} items=${manifest.items.length} media=${manifest.media.length} playlists=${manifest.playlists.length}';
    unawaited(
      AppLogger.log(
        'Manifest updated ($source): rev=${manifest.revision} items=${manifest.items.length}',
      ),
    );
    unawaited(applyEffectiveDisplaySelection());
    _pruneCache(manifest);
  }

  void _pruneCache(Manifest manifest) {
    if (_mediaRoot.isEmpty) return;
    final neededIds = manifest.media.map((m) => m.id).toSet();
    unawaited(_cache.pruneUnused(neededIds, _mediaRoot));
  }

  void _prefetchMedia(Manifest manifest) {
    if (isOfflineMode.value || !isReady) return;

    final now = DateTime.now();
    final prefetch = Duration(seconds: manifest.prefetchSeconds);
    final horizon = now.add(prefetch);

    final ids = <int>{};
    for (final item in manifest.items) {
      if (item.endTime.isBefore(now)) continue;
      if (item.startTime.isAfter(horizon)) continue;

      if (item.contentType == ManifestContentType.media) {
        ids.add(item.contentId);
      } else {
        final playlist = manifest.playlistById(item.contentId);
        if (playlist == null) continue;
        for (final pItem in playlist.items) {
          ids.add(pItem.mediaId);
        }
      }
    }

    final mediaToPrefetch = ids
        .map(manifest.mediaById)
        .whereType<ManifestMedia>()
        .toList(growable: false);
    if (mediaToPrefetch.isEmpty) return;

    _prefetchChain = _prefetchChain.then((_) async {
      for (final media in mediaToPrefetch) {
        if (isOfflineMode.value || !isReady) return;
        await ensureMediaFile(media);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    });
    unawaited(_prefetchChain);
  }

  Future<void> updateNowPlaying(String? nowPlaying) async {
    if (isOfflineMode.value || !isReady) return;

    if (_nowPlaying == nowPlaying) return;
    _nowPlaying = nowPlaying;
    unawaited(_sendHeartbeat());
  }

  void _scheduleManifestFetch() {
    if (isOfflineMode.value || !isReady) return;

    _manifestTimer?.cancel();
    final delay = _manifestFailures == 0
        ? _manifestBaseInterval
        : _backoffDelay(_manifestFailures);
    _manifestTimer = Timer(delay, _fetchManifest);
  }

  Duration _backoffDelay(int failures) {
    final index = (failures - 1).clamp(0, _manifestBackoffSeconds.length - 1);
    final base = Duration(seconds: _manifestBackoffSeconds[index]);
    return _withJitter(base);
  }

  Duration _withJitter(Duration base) {
    final jitter = 0.8 + (_rng.nextDouble() * 0.4);
    final ms = (base.inMilliseconds * jitter).round();
    return Duration(milliseconds: ms < 500 ? 500 : ms);
  }

  String _manifestSignature(Manifest manifest) => jsonEncode(manifest.toJson());

  Future<void> _loadClientVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _clientVersion = 'efir-client ${info.version}+${info.buildNumber}';
      _appVersion = info.version;
      _appBuild = int.tryParse(info.buildNumber) ?? 0;
    } catch (e) {
      await AppLogger.log('client version load failed: $e');
    }
  }

  /// Запрашивает health сервера для status screen. Безопасно при ошибке.
  Future<void> refreshServerHealth() async {
    final api = _api;
    if (api == null) return;
    try {
      serverHealth.value = await api.health();
    } catch (e) {
      await AppLogger.log('server health refresh failed: $e');
    }
  }

  Future<void> _sendHeartbeat() async {
    if (isOfflineMode.value || !isReady) return;

    final api = _api;
    final auth = _auth;
    if (api == null || auth == null || !auth.hasToken) return;

    try {
      final cacheDiagnostics = await _cache.diagnostics(_manifest, _mediaRoot);
      await api.heartbeat(
        deviceId: auth.deviceId,
        currentRevision: currentRevision,
        nowPlaying: _nowPlaying,
        clientVersion: _appVersion.isNotEmpty ? _appVersion : _clientVersion,
        clientBuild: _appBuild,
        platform: UpdateService.platform,
        arch: UpdateService.arch,
        networkState: _manifestFailures == 0 ? 'online' : 'degraded',
        cachedMediaCount: cacheDiagnostics.cachedMediaCount,
        cacheSizeBytes: cacheDiagnostics.cacheSizeBytes,
        mediaDownloadFailures: cacheDiagnostics.downloadFailures,
        activeDisplayId: _activeDisplayId.value,
        availableDisplays: availableDisplays,
        token: auth.token,
      );
      lastHeartbeatAt.value = DateTime.now();
      lastHeartbeatOk.value = true;
    } on ApiException catch (e) {
      lastHeartbeatOk.value = false;
      await AppLogger.log('heartbeat failed: $e');
      _syncDiagnostics.value = 'heartbeat error ${e.statusCode}';
      if (e.statusCode == 401 || e.statusCode == 403 || e.statusCode == 404) {
        await _handleAuthLoss('heartbeat ${e.statusCode}');
      }
    } catch (e) {
      lastHeartbeatOk.value = false;
      await AppLogger.log('heartbeat failed: $e');
    }
  }

  ManifestItem? currentSlot(DateTime now) {
    final manifest = _manifest;
    if (manifest == null) return null;
    final active = manifest.items.where((i) => i.isActiveAt(now)).toList();
    if (active.isEmpty) return null;
    active.sort((a, b) {
      final prio = b.priority.compareTo(a.priority);
      if (prio != 0) return prio;
      return b.startTime.compareTo(a.startTime);
    });
    return active.first;
  }

  ManifestMedia? mediaById(int id) => _manifest?.mediaById(id);
  ManifestPlaylist? playlistById(int id) => _manifest?.playlistById(id);

  Future<File?> ensureMediaFile(ManifestMedia media) =>
      _cache.ensureMediaFile(media, _mediaRoot);

  /// Путь к закэшированному файлу медиа без скачивания (для превью в таймлайне).
  Future<String?> cachedMediaPath(ManifestMedia media) async =>
      (await _cache.cachedFile(media, _mediaRoot))?.path;

  String _deviceName() {
    if (kIsWeb) return 'web';
    return Platform.localHostname;
  }

  String _generateDeviceId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(10, (_) => rand.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    return 'dev_${DateTime.now().millisecondsSinceEpoch}_$token';
  }

  Future<void> _repairServerAddressIfNeeded() async {
    final current = _serverAddress.value;
    final uri = Uri.tryParse(_normalizeServerAddress(current));
    // Перепроверяем только голый http-хост без порта: его можно поднять до
    // https (боевой за nginx) или dev-порта. Явный https/порт не трогаем.
    if (uri == null || uri.host.isEmpty || uri.scheme != 'http' || uri.hasPort) {
      return;
    }

    try {
      // Сохранённая база уже имеет явную схему http:// (согласие оператора либо
      // его явный ввод) — фоновая перепроверка не должна показывать диалог.
      final (resolvedServer, _) = await _resolveServerBaseWithHealth(
        current,
        allowInsecureHttp: true,
      );
      if (resolvedServer == current) {
        return;
      }
      _serverAddress.value = resolvedServer;
      _api?.updateServerBase(resolvedServer);
      await _config.setServerUrl(resolvedServer);
      await AppLogger.log(
        'Server address auto-updated: $current -> $resolvedServer',
      );
    } catch (e) {
      await AppLogger.log('server address probe failed: $e');
    }
  }

  Future<(String, DeviceHealth)> _resolveServerBaseWithHealth(
    String raw, {
    bool allowInsecureHttp = false,
  }) async {
    final normalized = _normalizeServerAddress(raw);
    if (normalized.isEmpty) {
      throw StateError('server address is empty');
    }

    Object? lastError;
    StackTrace? lastStackTrace;
    for (final candidate in _serverCandidates(normalized)) {
      try {
        final health = await ApiService(serverBase: candidate).health();
        final uri = Uri.parse(candidate);
        if (uri.scheme == 'http' &&
            !allowInsecureHttp &&
            !_cleartextConsents.contains(_hostPortKey(uri))) {
          // Сервер отвечает только по cleartext: токен и медиа пойдут открытым
          // текстом. Не коммитим адрес без явного согласия оператора.
          pendingCleartextPrompt.value = CleartextHttpPrompt(
            host: uri.host,
            port: uri.hasPort ? uri.port : 80,
          );
          await AppLogger.log(
            'cleartext HTTP prompt: ${uri.host}:${uri.hasPort ? uri.port : 80}',
          );
          throw CleartextHttpPendingError();
        }
        return (candidate, health);
      } on CleartextHttpPendingError {
        rethrow;
      } catch (e, st) {
        lastError = e;
        lastStackTrace = st;
      }
    }

    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStackTrace!);
    }
    throw StateError('No server candidates to probe');
  }

  static String _hostPortKey(Uri uri) =>
      '${uri.host}:${uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80)}';

  /// Согласие оператора на cleartext HTTP: запомнить и забыть prompt.
  void acceptPendingCleartextHttp() {
    final prompt = pendingCleartextPrompt.value;
    if (prompt == null) return;
    _cleartextConsents.add('${prompt.host}:${prompt.port}');
    pendingCleartextPrompt.value = null;
  }

  void dismissCleartextPrompt() => pendingCleartextPrompt.value = null;

  /// Кандидаты для проб health при резолве адреса сервера.
  ///
  /// Пользователь вводит только хост (или хост:порт) — протокол подбираем сами.
  /// HTTPS пробуем первым: боевой сервер за nginx редиректит HTTP→HTTPS (301),
  /// а Dart `http` следует за редиректом только для GET — POST (регистрация/
  /// heartbeat) ловит 301. Зафиксировав базу как `https://...`, POST идёт
  /// напрямую. HTTP и dev-порт 8088 остаются фолбэком для LAN-стенда без TLS.
  /// Явный `https://` от пользователя не понижаем до http.
  List<String> _serverCandidates(String normalized) {
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return [normalized];
    }

    String strip(Uri u) => u.toString().replaceFirst(RegExp(r'/$'), '');
    final out = <String>[];
    void add(Uri u) {
      final value = strip(u);
      if (!out.contains(value)) out.add(value);
    }

    if (uri.scheme == 'https') {
      add(uri); // явный https уважаем, не понижаем
      return out;
    }

    if (uri.hasPort) {
      add(uri.replace(scheme: 'https')); // https на том же порту
      add(uri); // http на том же порту
    } else {
      add(uri.replace(scheme: 'https')); // https:443
      add(uri); // http:80
      add(uri.replace(port: 8088)); // http:8088 (dev/LAN)
    }
    return out;
  }

  bool _isTlsError(Object e) =>
      e is TlsException || e is HandshakeException;

  /// При TLS-ошибке достаёт сертификат https-кандидата и готовит prompt
  /// для подтверждения доверия оператором (UI покажет отпечаток).
  Future<void> _prepareTlsPrompt(String normalizedServer) async {
    try {
      final httpsCandidate = _serverCandidates(normalizedServer)
          .map(Uri.tryParse)
          .whereType<Uri>()
          .firstWhere((u) => u.scheme == 'https', orElse: () => Uri());
      if (httpsCandidate.host.isEmpty) return;
      final host = httpsCandidate.host;
      final port = httpsCandidate.hasPort ? httpsCandidate.port : 443;

      X509Certificate? captured;
      try {
        final socket = await SecureSocket.connect(
          host,
          port,
          timeout: const Duration(seconds: 5),
          onBadCertificate: (cert) {
            captured = cert;
            return false; // не подключаемся — только снимаем сертификат
          },
        );
        await socket.close(); // цепочка оказалась валидной — доверие не нужно
        return;
      } catch (_) {
        // ожидаемо: handshake отклонён нашим onBadCertificate
      }
      final cert = captured;
      if (cert == null) return;

      pendingTlsPrompt.value = TlsTrustPrompt(
        host: host,
        port: port,
        fingerprintHex: TrustStore.fingerprintOf(cert),
        subject: cert.subject,
      );
      await AppLogger.log(
        'TLS trust prompt: $host:$port subject=${cert.subject}',
      );
    } catch (e) {
      await AppLogger.log('TLS probe failed: $e');
    }
  }

  /// Подтверждение доверия оператором: закрепить отпечаток и забыть prompt.
  Future<void> acceptPendingTlsTrust() async {
    final prompt = pendingTlsPrompt.value;
    if (prompt == null) return;
    await TrustStore.instance.trust(
      prompt.host,
      prompt.port,
      prompt.fingerprintHex,
    );
    pendingTlsPrompt.value = null;
  }

  void dismissTlsPrompt() => pendingTlsPrompt.value = null;

  /// Закреплённый отпечаток для текущего сервера (для диагностики).
  String? pinnedServerFingerprint() {
    final uri = Uri.tryParse(_serverAddress.value);
    if (uri == null || uri.host.isEmpty || uri.scheme != 'https') return null;
    final fp = TrustStore.instance.pinnedFingerprint(
      uri.host,
      uri.hasPort ? uri.port : 443,
    );
    return fp == null ? null : TrustStore.displayFingerprint(fp);
  }

  /// Человекочитаемая причина сетевой ошибки для setup-сообщений.
  String _describeServerError(Object e) {
    if (e is CleartextHttpPendingError) {
      return 'сервер доступен только по незащищённому HTTP — требуется подтверждение';
    }
    if (e is TimeoutException) return 'сервер не ответил вовремя';
    if (e is TlsException) return 'ошибка TLS-сертификата сервера';
    if (e is SocketException) {
      final msg = (e.osError?.message ?? e.message).toLowerCase();
      if (msg.contains('lookup') || msg.contains('resolve')) {
        return 'имя сервера не разрешается (DNS)';
      }
      return 'нет соединения с сервером';
    }
    if (e is ApiException) return 'сервер вернул ошибку ${e.statusCode}';
    return 'неизвестная ошибка';
  }

  String _normalizeServerAddress(String raw) {
    var normalized = raw.trim();
    if (normalized.isEmpty) return '';
    if (!normalized.contains('://')) {
      normalized = 'http://$normalized';
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return normalized.replaceFirst(RegExp(r'/+$'), '');
    }
    return uri
        .replace(path: '', query: null, fragment: null)
        .toString()
        .replaceFirst(RegExp(r'/$'), '');
  }

  Future<void> refreshAvailableDisplays({bool applySelection = true}) async {
    _displayBusy.value = true;
    try {
      final displays = await _displayService.getAvailableDisplays();
      final desired = _selectedDisplayId.value;
      final fallback = _resolveAvailableDisplay(displays, desired);
      _availableDisplays.assignAll(
        displays
            .map(
              (display) => display.copyWith(
                isCurrent: fallback != null && display.id == fallback.id,
              ),
            )
            .toList(growable: false),
      );
      if (desired.isEmpty && fallback != null) {
        _selectedDisplayId.value = fallback.id;
        await _config.setDisplayPreferences(selectedDisplayId: fallback.id);
      }
      if (applySelection) {
        await applyEffectiveDisplaySelection();
      }
    } finally {
      _displayBusy.value = false;
    }
  }

  Future<void> updateLocalDisplayPreferences({
    String? selectedDisplayId,
    int? rotation,
  }) async {
    if (selectedDisplayId != null) {
      _selectedDisplayId.value = selectedDisplayId.trim();
    }
    if (rotation != null) {
      _localDisplayRotation.value = _normalizeRotation(rotation);
    }
    await _config.setDisplayPreferences(
      selectedDisplayId: _selectedDisplayId.value,
      displayRotation: _localDisplayRotation.value,
    );
    await applyEffectiveDisplaySelection(force: true);
    version.value++;
  }

  Future<void> setServicePin(String pin) async {
    await _config.setServicePin(pin);
  }

  Future<void> applyEffectiveDisplaySelection({bool force = false}) async {
    final displays = _availableDisplays.toList(growable: false);
    if (displays.isEmpty) {
      _activeDisplayId.value = '';
      return;
    }

    final fallback = _resolveAvailableDisplay(displays, effectiveDisplayId);
    if (fallback == null) {
      _activeDisplayId.value = '';
      return;
    }

    final shouldApply = force || _activeDisplayId.value != fallback.id;
    if (shouldApply) {
      await _displayService.applyTargetDisplay(fallback.id);
    }
    _activeDisplayId.value = fallback.id;
    _availableDisplays.assignAll(
      displays
          .map(
            (display) => display.copyWith(isCurrent: display.id == fallback.id),
          )
          .toList(growable: false),
    );
  }

  Future<bool> rebindServer(String rawServerAddress) async {
    final rawInput = rawServerAddress.trim();
    final explicitHttp = rawInput.toLowerCase().startsWith('http://');
    final normalizedServer = _normalizeServerAddress(rawInput);
    if (normalizedServer.isEmpty) {
      _setSetupRequired('Введите адрес сервера.');
      return false;
    }

    _setupBusy.value = true;
    try {
      final (resolvedServer, _) = await _resolveServerBaseWithHealth(
        normalizedServer,
        allowInsecureHttp: explicitHttp,
      );
      final current = _normalizeServerAddress(_serverAddress.value);
      _serverAddress.value = resolvedServer;
      _api?.updateServerBase(resolvedServer);
      await _config.setServerUrl(resolvedServer);

      if (resolvedServer == current) {
        _setupMessage.value =
            'Адрес сервера обновлен. Текущая регистрация остается действительной.';
        return true;
      }

      _registrationPollTimer?.cancel();
      _manifestTimer?.cancel();
      _heartbeatTimer?.cancel();
      final auth = _auth;
      if (auth != null) {
        _auth = auth.copyWith(
          token: '',
          requestToken: '',
          name: _deviceDisplayName.value,
        );
        await _deviceStore.save(_auth!);
      }
      _manifestFailures = 0;
      _setSetupRequired(
        'Сервер изменен. Отправьте новую заявку на регистрацию устройства.',
      );
      return true;
    } catch (e) {
      await AppLogger.log('server rebind failed: $e');
      _setSetupRequired(
        'Не удалось подключиться к новому серверу. Проверьте адрес и повторите.',
      );
      return false;
    } finally {
      _setupBusy.value = false;
    }
  }

  DeviceDisplayProfile? _resolveAvailableDisplay(
    List<DeviceDisplayProfile> displays,
    String preferredId,
  ) {
    if (displays.isEmpty) {
      return null;
    }
    final normalized = preferredId.trim();
    if (normalized.isNotEmpty) {
      for (final display in displays) {
        if (display.id == normalized) {
          return display;
        }
      }
    }
    for (final display in displays) {
      if (display.isCurrent) {
        return display;
      }
    }
    for (final display in displays) {
      if (display.isPrimary) {
        return display;
      }
    }
    return displays.first;
  }

  int _normalizeRotation(int value) {
    const allowed = <int>{0, 90, 180, 270};
    final normalized = value % 360;
    return allowed.contains(normalized) ? normalized : 0;
  }
}
