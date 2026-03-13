import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../models/manifest.dart';
import '../models/playlist_item.dart';
import '../services/api_service.dart';
import '../services/app_logger.dart';
import '../services/app_paths.dart';
import '../services/config_service.dart';
import '../services/device_store.dart';
import '../services/manifest_store.dart';
import '../services/media_cache_service.dart';

enum DeviceSetupStage { booting, setupRequired, pendingApproval, ready }

class PlaylistController extends GetxController {
  final RxBool _isLoading = false.obs;
  final RxInt version = 0.obs;
  final Rx<DeviceSetupStage> _setupStage = DeviceSetupStage.booting.obs;
  final RxString _setupMessage = ''.obs;
  final RxString _serverAddress = ''.obs;
  final RxString _deviceDisplayName = ''.obs;
  final RxBool _setupBusy = false.obs;
  final RxBool isOfflineMode = false.obs;

  final RxList<PlaylistItem> localItems = <PlaylistItem>[].obs;

  final _config = ConfigService();
  final _deviceStore = DeviceStore();
  final _manifestStore = ManifestStore();
  late final MediaCacheService _cache;

  ApiService? _api;
  Manifest? _manifest;
  DeviceAuth? _auth;
  String _mediaRoot = '';
  String? _nowPlaying;

  Timer? _manifestTimer;
  Timer? _heartbeatTimer;
  Timer? _registrationPollTimer;
  int _manifestFailures = 0;
  bool _manifestInFlight = false;
  final _rng = Random();

  static const Duration _manifestBaseInterval = Duration(seconds: 30);
  static const Duration _heartbeatInterval = Duration(seconds: 25);
  static const List<int> _manifestBackoffSeconds = [2, 5, 10, 20, 30];

  bool get isLoading => _isLoading.value;
  DeviceSetupStage get setupStage => _setupStage.value;
  String get setupMessage => _setupMessage.value;
  String get serverAddress => _serverAddress.value;
  String get deviceDisplayName => _deviceDisplayName.value;
  bool get setupBusy => _setupBusy.value;
  bool get isReady => _setupStage.value == DeviceSetupStage.ready;
  bool get isPendingApproval =>
      _setupStage.value == DeviceSetupStage.pendingApproval;
  String get deviceId => _auth?.deviceId ?? '';
  Manifest? get manifest => _manifest;
  String get currentRevision => _manifest?.revision ?? '';
  List<ManifestItem> get items => _manifest?.items ?? [];
  List<PlaylistItem> get editorItems => localItems.toList();

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
    super.onClose();
  }

  Future<void> _boot() async {
    _isLoading.value = true;
    try {
      final cfg = await _config.load();
      _mediaRoot = cfg.mediaRoot;
      _serverAddress.value = cfg.serverUrl;
      _api = ApiService(serverBase: cfg.serverUrl);
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
  }) async {
    final normalizedServer = _normalizeServerAddress(
      serverAddress ?? _serverAddress.value,
    );
    if (normalizedServer.isEmpty) {
      _setSetupRequired('Введите IP-адрес или доменное имя сервера.');
      return false;
    }

    _setupBusy.value = true;
    try {
      _serverAddress.value = normalizedServer;
      if (deviceName != null && deviceName.trim().isNotEmpty) {
        _deviceDisplayName.value = deviceName.trim();
      }
      _api?.updateServerBase(normalizedServer);
      final health = await _api!.health();
      await _config.setServerUrl(normalizedServer);
      _setSetupRequired(
        'Соединение установлено: ${health.name} ${health.version}, часовой пояс ${health.timezone}.',
      );
      return true;
    } catch (e) {
      await AppLogger.log('health check failed: $e');
      _setSetupRequired(_setupErrorMessage(e));
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

    final normalizedServer = _normalizeServerAddress(serverAddress);
    if (normalizedServer.isEmpty) {
      _setSetupRequired('Введите IP-адрес или доменное имя сервера.');
      return false;
    }

    _setupBusy.value = true;
    try {
      _serverAddress.value = normalizedServer;
      _deviceDisplayName.value = deviceName.trim().isNotEmpty
          ? deviceName.trim()
          : _deviceName();
      _api?.updateServerBase(normalizedServer);

      final health = await api.health();
      await _config.setServerUrl(normalizedServer);
      await AppLogger.log(
        'device health ok: name=${health.name} version=${health.version}',
      );

      final request = await api.requestRegistration(
        deviceId: auth.deviceId,
        name: _deviceDisplayName.value,
        clientVersion: 'panel-client 1.0.0+1',
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
      _setSetupRequired(_setupErrorMessage(e));
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
    await _fetchManifest();
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => _sendHeartbeat(),
    );
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
    final normalized =
        items
            .where((item) => item.filename.trim().isNotEmpty)
            .map(
              (item) => item.copyWith(
                filename: item.filename.trim(),
                durationSeconds: item.durationSeconds < 1
                    ? 1
                    : item.durationSeconds,
              ),
            )
            .toList()
          ..sort((a, b) => a.startDate.compareTo(b.startDate));
    return normalized;
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

    if (_manifestInFlight) return;
    _manifestInFlight = true;

    try {
      final manifest = await api.fetchManifest(
        deviceId: auth.deviceId,
        token: auth.token,
      );
      _manifestFailures = 0;
      if (_manifest?.revision == manifest.revision) return;

      _setManifest(manifest, source: 'api');
      await _manifestStore.save(manifest);
      _prefetchMedia(manifest);
    } on ApiException catch (e) {
      _manifestFailures++;
      await AppLogger.log('manifest fetch failed: $e');
      if (e.statusCode == 401 || e.statusCode == 404) {
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
    unawaited(
      AppLogger.log(
        'Manifest updated ($source): rev=${manifest.revision} items=${manifest.items.length}',
      ),
    );
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

    for (final id in ids) {
      final media = manifest.mediaById(id);
      if (media != null) {
        unawaited(ensureMediaFile(media));
      }
    }
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

  Future<void> _sendHeartbeat() async {
    if (isOfflineMode.value || !isReady) return;

    final api = _api;
    final auth = _auth;
    if (api == null || auth == null || !auth.hasToken) return;

    try {
      await api.heartbeat(
        deviceId: auth.deviceId,
        currentRevision: currentRevision,
        nowPlaying: _nowPlaying,
        token: auth.token,
      );
    } on ApiException catch (e) {
      await AppLogger.log('heartbeat failed: $e');
      if (e.statusCode == 401 || e.statusCode == 404) {
        await _handleAuthLoss('heartbeat ${e.statusCode}');
      }
    } catch (e) {
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

  String _setupErrorMessage(Object error) {
    if (error is TimeoutException) {
      return 'Сервер не ответил вовремя. Проверьте адрес и сеть, затем повторите попытку.';
    }
    if (error is SocketException) {
      return 'Не удалось подключиться к серверу. Проверьте адрес, порт и доступность сети.';
    }
    if (error is ApiException) {
      return 'Сервер ответил ошибкой ${error.statusCode}. Проверьте адрес и состояние сервера.';
    }
    return 'Не удалось подключиться к серверу. Проверьте адрес и маршрут.';
  }
}
