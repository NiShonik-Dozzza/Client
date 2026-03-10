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
import '../services/config_service.dart';
import '../services/device_store.dart';
import '../services/manifest_store.dart';
import '../services/media_cache_service.dart';
import '../services/app_paths.dart';

class PlaylistController extends GetxController {
  final RxBool _isLoading = false.obs;
  final RxInt version = 0.obs;
  final RxBool isOfflineMode = false.obs; // <-- НОВОЕ: переключатель режима

  // Локальный плейлист (для оффлайн-режима)
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
  int _manifestFailures = 0;
  bool _manifestInFlight = false;
  final _rng = Random();

  static const Duration _manifestBaseInterval = Duration(seconds: 30);
  static const Duration _heartbeatInterval = Duration(seconds: 25);
  static const List<int> _manifestBackoffSeconds = [2, 5, 10, 20, 30];

  bool get isLoading => _isLoading.value;
  Manifest? get manifest => _manifest;
  String get currentRevision => _manifest?.revision ?? '';
  List<ManifestItem> get items => _manifest?.items ?? [];

  @override
  void onInit() {
    super.onInit();
    _boot();
  }

  @override
  void onClose() {
    _manifestTimer?.cancel();
    _heartbeatTimer?.cancel();
    super.onClose();
  }

  Future<void> _boot() async {
    _isLoading.value = true;
    try {
      final cfg = await _config.load();
      _mediaRoot = cfg.mediaRoot;
      _api = ApiService(apiBase: cfg.apiBase);
      _cache = MediaCacheService(onForbidden: _fetchManifest);

      _auth = await _deviceStore.read();
      _auth ??= DeviceAuth(deviceId: _generateDeviceId(), token: '', name: _deviceName());
      await _deviceStore.save(_auth!);

      await _registerIfNeeded();

      final cachedManifest = await _manifestStore.read();
      if (cachedManifest != null) {
        _setManifest(cachedManifest, source: 'cache');
      }

      // Загружаем локальный плейлист при старте (для аварийного режима)
      await _loadLocalPlaylist();

      await _fetchManifest();

      _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _sendHeartbeat());
    } catch (e) {
      await AppLogger.log('boot error: $e');
      // Даже при ошибке загружаем локальный плейлист для аварийного режима
      await _loadLocalPlaylist();
    } finally {
      _isLoading.value = false;
    }
  }

  // ===== ЛОКАЛЬНЫЙ РЕЖИМ (АВАРИЙНЫЙ) =====
  Future<void> _loadLocalPlaylist() async {
    try {
      final file = await AppPaths.playlistFile();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        localItems.assignAll((json as List).map((e) => PlaylistItem.fromJson(e)).toList());
        await AppLogger.log('Local playlist loaded: ${localItems.length} items');
      } else {
        // Создаём заглушку-плейлист если файла нет
        localItems.assignAll([
          PlaylistItem(
            filename: 'emergency.mp4',
            startDate: DateTime.now(),
            stopDate: DateTime.now().add(const Duration(hours: 24)),
            loop: true,
            durationSeconds: 10,
          )
        ]);
        await _saveLocalPlaylist(); // Сохраняем заглушку
        await AppLogger.log('Created emergency playlist stub');
      }
    } catch (e) {
      await AppLogger.log('Local playlist load error: $e');
      // Всегда обеспечиваем наличие хотя бы одного элемента
      if (localItems.isEmpty) {
        localItems.add(PlaylistItem(
          filename: 'emergency.mp4',
          startDate: DateTime.now(),
          stopDate: DateTime.now().add(const Duration(hours: 24)),
          loop: true,
          durationSeconds: 10,
        ));
      }
    }
  }

  Future<void> saveLocalPlaylist() async {
    await _saveLocalPlaylist();
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

  /// Получает текущий элемент для воспроизведения (с учётом режима)
  dynamic currentItem(DateTime now) {
    if (isOfflineMode.value) {
      // Оффлайн-режим: ищем активный элемент в локальном плейлисте
      return localItems.firstWhereOrNull(
            (item) => item.startDate.isBefore(now) && (item.stopDate == null || now.isBefore(item.stopDate!)),
      );
    } else {
      // Онлайн-режим: используем манифест
      return currentSlot(now);
    }
  }

  /// Совместимость для редактора: возвращает локальные элементы в оффлайн-режиме
  List<PlaylistItem> get editorItems => isOfflineMode.value ? localItems.toList() : [];

  /// Совместимость: заглушка для онлайн-режима, в оффлайн-режиме перезагружает локальный плейлист
  Future<void> loadPlaylist() async {
    if (isOfflineMode.value) {
      await _loadLocalPlaylist();
    } else {
      await _fetchManifest();
    }
  }
  // ===== КОНЕЦ ЛОКАЛЬНОГО РЕЖИМА =====

  Future<void> _registerIfNeeded({bool force = false}) async {
    final api = _api;
    final auth = _auth;
    if (api == null || auth == null) return;
    if (auth.hasToken && !force) return;

    try {
      final registered = await api.register(deviceId: auth.deviceId, name: auth.name ?? _deviceName());
      _auth = DeviceAuth(deviceId: registered.deviceId, token: registered.token, name: auth.name ?? registered.name);
      await _deviceStore.save(_auth!);
      await AppLogger.log('registered device_id=${_auth!.deviceId}');
    } catch (e) {
      await AppLogger.log('register failed: $e');
    }
  }

  Future<void> _fetchManifest() async {
    if (isOfflineMode.value) return; // В оффлайн-режиме не опрашиваем сервер

    final api = _api;
    final auth = _auth;
    if (api == null || auth == null) return;

    if (_manifestInFlight) return;
    _manifestInFlight = true;

    try {
      if (!auth.hasToken) {
        await _registerIfNeeded();
      }
      final refreshed = _auth;
      if (refreshed == null) return;

      final manifest = await api.fetchManifest(deviceId: refreshed.deviceId, token: refreshed.token);
      _manifestFailures = 0;
      if (_manifest?.revision == manifest.revision) return;

      _setManifest(manifest, source: 'api');
      await _manifestStore.save(manifest);
      _prefetchMedia(manifest);
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
    unawaited(AppLogger.log('Manifest updated ($source): rev=${manifest.revision} items=${manifest.items.length}'));
  }

  void _prefetchMedia(Manifest manifest) {
    if (isOfflineMode.value) return; // В оффлайн-режиме не префетчим

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
    if (isOfflineMode.value) return; // В оффлайн-режиме не отправляем статус

    if (_nowPlaying == nowPlaying) return;
    _nowPlaying = nowPlaying;
    unawaited(_sendHeartbeat());
  }

  void _scheduleManifestFetch() {
    if (isOfflineMode.value) return; // В оффлайн-режиме не планируем опрос

    _manifestTimer?.cancel();
    final delay = _manifestFailures == 0 ? _manifestBaseInterval : _backoffDelay(_manifestFailures);
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
    if (isOfflineMode.value) return; // В оффлайн-режиме не отправляем heartbeat

    final api = _api;
    final auth = _auth;
    if (api == null || auth == null) return;

    try {
      if (!auth.hasToken) {
        await _registerIfNeeded();
      }
      final refreshed = _auth;
      if (refreshed == null) return;

      await api.heartbeat(
        deviceId: refreshed.deviceId,
        currentRevision: currentRevision,
        nowPlaying: _nowPlaying,
        token: refreshed.token,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        await AppLogger.log('heartbeat 404 → re-register');
        await _registerIfNeeded(force: true);
        final refreshed = _auth;
        if (refreshed == null) return;
        try {
          await api.heartbeat(
            deviceId: refreshed.deviceId,
            currentRevision: currentRevision,
            nowPlaying: _nowPlaying,
            token: refreshed.token,
          );
          return;
        } catch (err) {
          await AppLogger.log('heartbeat retry failed: $err');
          return;
        }
      }
      await AppLogger.log('heartbeat failed: $e');
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

  Future<File?> ensureMediaFile(ManifestMedia media) => _cache.ensureMediaFile(media, _mediaRoot);

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
}