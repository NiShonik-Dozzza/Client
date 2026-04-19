import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../controllers/playlist_controller.dart';
import '../models/manifest.dart';
import '../services/app_logger.dart';
import '../views/editor_screen.dart'; // ← ДОБАВЛЕНО: импорт редактора
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import '../models/playlist_item.dart';
import '../services/config_service.dart';

enum _Mode { image, video, black }

enum _PlaybackContext { slotMedia, playlistItem }

class _PreparedVideo {
  const _PreparedVideo({
    required this.playerIndex,
    required this.source,
    required this.mediaId,
  });

  final int playerIndex;
  final String source;
  final int mediaId;
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static final DateFormat _debugTimeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

  late final List<Player> _players;
  late final List<VideoController> _videoControllers;
  int _activeVideoIndex = 0;
  _PreparedVideo? _preparedVideo;

  // ===== ДОБАВЛЕНО: поддержка редактора =====
  bool _isEditorOpen = false; // Отслеживает открыт ли редактор
  bool _showEditorButton = false; // Состояние видимости кнопки
  // ==========================================

  Timer? _tick; // проверяем расписание
  Timer? _slotTimer; // точный переход на end_time
  Timer? _imageTimer;
  Timer? _debugTimer;

  bool _initialized = false;
  bool _isDisposed = false;

  ManifestItem? _currentSlot;
  ManifestMedia? _currentMedia;
  ManifestPlaylist? _currentPlaylist;
  ManifestPlaylistItem? _currentPlaylistItem;
  int _playlistIndex = 0;
  _PlaybackContext? _context;
  _Mode _mode = _Mode.black;

  bool _imageIsFile = false;
  String _imagePath = '';

  // completed на Windows может быть "шумным", реагируем только если это видео и мы его ждём
  bool _expectVideoCompleted = false;

  // debug overlay
  bool _debug = false; // скрыт по умолчанию

  VideoController get _activeVideoController =>
      _videoControllers[_activeVideoIndex];
  int get _standbyVideoIndex => _activeVideoIndex == 0 ? 1 : 0;
  Player get _standbyPlayer => _players[_standbyVideoIndex];

  Widget _buildImageView() {
    final imageKey = ValueKey(_imagePath);
    if (_imageIsFile) {
      return SizedBox.expand(
        child: Image.file(
          File(_imagePath),
          key: imageKey,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, e, __) => const Center(
            child: Text(
              'Ошибка загрузки изображения (file)',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      );
    }
    return SizedBox.expand(
      child: Image.asset(
        _imagePath,
        key: imageKey,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, e, __) => const Center(
          child: Text(
            'Ошибка загрузки изображения (asset)',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    _players = [Player(), Player()];
    _videoControllers = _players
        .map(VideoController.new)
        .toList(growable: false);

    for (var i = 0; i < _players.length; i++) {
      _players[i].stream.error.listen(
        (e) => unawaited(AppLogger.log('media_kit[$i] error: $e')),
      );

      _players[i].stream.completed.listen((_) {
        if (_isDisposed) return;
        if (i != _activeVideoIndex) return;
        if (!_expectVideoCompleted) return;
        if (_mode != _Mode.video) return;

        _expectVideoCompleted = false;
        _onVideoCompleted();
      });
    }

    // F12 — toggle debug overlay, F2 — открыть редактор
    HardwareKeyboard.instance.addHandler(_onKey);

    _boot();
  }

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) {
      // F12: переключить отладку
      if (e.logicalKey == LogicalKeyboardKey.f12) {
        setState(() => _debug = !_debug);
        return true;
      }

      // F2: открыть редактор (только если не открыт)
      if (!_isEditorOpen && e.logicalKey == LogicalKeyboardKey.f2) {
        _openEditor();
        return true;
      }
    }
    return false;
  }

  // ===== ДОБАВЛЕНО: методы для работы с редактором =====
  void _openEditor() async {
    await _pausePlayerForEditor();
    Get.to(() => const EditorScreen())?.then((_) {
      if (!_isDisposed && mounted) {
        _resumePlayerAfterEditor();
      }
    });
  }

  Future<void> _pausePlayerForEditor() async {
    if (_isEditorOpen) return;
    _isEditorOpen = true;

    _tick?.cancel();
    _slotTimer?.cancel();
    _imageTimer?.cancel();
    _expectVideoCompleted = false;

    await _stopEverything();

    if (mounted) {
      setState(() {
        _mode = _Mode.black;
        _currentSlot = null;
        _currentMedia = null;
        _currentPlaylist = null;
        _currentPlaylistItem = null;
      });
    }
  }

  void _resumePlayerAfterEditor() {
    if (!_isEditorOpen) return;
    _isEditorOpen = false;

    // Восстанавливаем таймер и применяем расписание
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _applySchedule());
    _applySchedule(force: true);
  }
  // ======================================================

  Future<void> _boot() async {
    try {
      final controller = Get.find<PlaylistController>();

      // реагируем на обновление манифеста
      ever<int>(controller.version, (_) => _applySchedule(force: true));

      setState(() => _initialized = true);

      await _applySchedule(force: true);

      _tick = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _applySchedule(),
      );
      _debugTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_isDisposed || !_debug) return;
        setState(() {});
      });
    } catch (e) {
      await AppLogger.log('boot error: $e');
      setState(() => _initialized = true);
    }
  }

  Future<void> _applySchedule({bool force = false}) async {
    if (_isDisposed || _isEditorOpen) return;

    final controller = Get.find<PlaylistController>();
    final now = DateTime.now();

    // ===== ИСПРАВЛЕНО: учитываем оффлайн-режим =====
    if (controller.isOfflineMode.value) {
      // Оффлайн-режим: используем локальный плейлист
      await _applyOfflineSchedule(now, controller, force);
      return;
    }

    // Онлайн-режим: используем манифест (старый код)
    final nextSlot = controller.currentSlot(now);

    if (nextSlot == null) {
      if (_currentSlot != null) {
        await _stopEverything();
        setState(() {
          _currentSlot = null;
          _currentMedia = null;
          _currentPlaylist = null;
          _currentPlaylistItem = null;
          _playlistIndex = 0;
          _mode = _Mode.black;
        });
        await controller.updateNowPlaying(null);
      }
      return;
    }

    final same = !force && _isSameSlot(_currentSlot, nextSlot);
    if (same) return;

    _currentSlot = nextSlot;
    _currentMedia = null;
    _currentPlaylist = null;
    _currentPlaylistItem = null;
    _playlistIndex = 0;

    _slotTimer?.cancel();
    final dur = nextSlot.endTime.difference(now);
    if (!dur.isNegative) {
      _slotTimer = Timer(dur, () => _applySchedule(force: true));
    }

    await controller.updateNowPlaying(_nowPlayingFor(nextSlot));

    if (nextSlot.contentType == ManifestContentType.media) {
      final media = controller.mediaById(nextSlot.contentId);
      if (media == null) {
        await AppLogger.log('media not found: id=${nextSlot.contentId}');
        setState(() => _mode = _Mode.black);
        return;
      }
      await _playMedia(
        media,
        context: _PlaybackContext.slotMedia,
        slotContext: nextSlot,
      );
      return;
    }

    final playlist = controller.playlistById(nextSlot.contentId);
    if (playlist == null || playlist.items.isEmpty) {
      await AppLogger.log('playlist not found/empty: id=${nextSlot.contentId}');
      setState(() => _mode = _Mode.black);
      return;
    }

    _currentPlaylist = playlist;
    await _playPlaylistIndex(0);
  }

  // ===== НОВЫЙ МЕТОД: обработка оффлайн-режима =====
  Future<void> _applyOfflineSchedule(
    DateTime now,
    PlaylistController controller,
    bool force,
  ) async {
    final nextItem = controller.currentOfflineItem(now);

    if (nextItem == null) {
      if (_currentSlot != null || _currentMedia != null) {
        await _stopEverything();
        setState(() {
          _currentSlot = null;
          _currentMedia = null;
          _currentPlaylist = null;
          _currentPlaylistItem = null;
          _playlistIndex = 0;
          _mode = _Mode.black;
        });
      }
      return;
    }

    // Проверяем, тот же ли элемент
    final same =
        !force &&
        _currentSlot == null &&
        _currentMedia == null &&
        _lastOfflineItem != null &&
        _lastOfflineItem!.filename == nextItem.filename &&
        _lastOfflineItem!.startDate == nextItem.startDate &&
        _lastOfflineItem!.stopDate == nextItem.stopDate;

    if (same) return;

    _lastOfflineItem = nextItem;

    // Останавливаем текущее воспроизведение
    await _stopEverything();

    // Сбрасываем таймеры серверного режима
    _slotTimer?.cancel();
    _imageTimer?.cancel();

    // Ставим таймер на окончание элемента
    if (nextItem.stopDate != null) {
      final dur = nextItem.stopDate!.difference(now);
      if (!dur.isNegative) {
        _slotTimer = Timer(dur, () => _applySchedule(force: true));
      }
    }

    // Воспроизводим элемент
    await _playOfflineItem(nextItem);
  }

  PlaylistItem? _lastOfflineItem;

  Future<void> _playOfflineItem(PlaylistItem item) async {
    final controller = Get.find<PlaylistController>(); // ← ДОБАВЛЕНО

    final cfg = await ConfigService().load();
    final mediaRoot = cfg.mediaRoot;

    if (item.isImage) {
      await _stopEverything();
      final diskPath = await _getLocalMediaPath(mediaRoot, item.filename);
      setState(() {
        _mode = _Mode.image;
        _imageIsFile = diskPath != null;
        _imagePath = diskPath ?? 'assets/media/${item.filename}';
      });

      // Если не зациклено, ставим таймер на длительность показа
      if (!item.loop) {
        final now = DateTime.now();
        final left = item.stopDate?.difference(now);
        final showFor = Duration(seconds: item.durationSeconds);
        final dur = (left == null)
            ? showFor
            : (showFor < left ? showFor : left);

        _imageTimer = Timer(dur, () {
          if (_isDisposed || !controller.isOfflineMode.value) return;
          setState(() => _mode = _Mode.black);
        });
      }

      await AppLogger.log(
        'OFFLINE: SHOW IMAGE: ${item.filename} (loop=${item.loop})',
      );
      return;
    }

    if (item.isVideo) {
      final diskPath = await _getLocalMediaPath(mediaRoot, item.filename);
      final src = diskPath ?? 'asset:///assets/media/${item.filename}';

      try {
        setState(() => _mode = _Mode.video);
        await _playVideoSource(src, loopSingle: item.loop);

        await AppLogger.log(
          'OFFLINE: PLAY VIDEO: ${item.filename} src=$src (loop=${item.loop})',
        );
      } catch (e) {
        _expectVideoCompleted = false;
        await AppLogger.log(
          'OFFLINE: VIDEO OPEN FAILED: ${item.filename} error=$e',
        );
        setState(() => _mode = _Mode.black);
      }
      return;
    }

    setState(() => _mode = _Mode.black);
    await AppLogger.log('OFFLINE: UNSUPPORTED: ${item.filename}');
  }

  Future<String?> _getLocalMediaPath(String mediaRoot, String filename) async {
    if (kIsWeb) return null;

    final name = p.basename(filename);

    // Если абсолютный путь
    if (p.isAbsolute(filename)) {
      final f = File(filename);
      return (await f.exists()) ? f.path : null;
    }

    final full = ConfigService.joinMedia(mediaRoot, name);
    final f = File(full);
    return (await f.exists()) ? f.path : null;
  }
  // ===== КОНЕЦ НОВОГО МЕТОДА =====

  Future<void> _clearPreparedVideo() async {
    _preparedVideo = null;
    try {
      await _standbyPlayer.pause();
      await _standbyPlayer.setPlaylistMode(PlaylistMode.none);
      await _standbyPlayer.setVolume(0);
      await _standbyPlayer.stop();
    } catch (_) {}
  }

  Future<void> _openVideoOnPlayer(
    int playerIndex,
    String source, {
    required bool play,
    required PlaylistMode playlistMode,
  }) async {
    final player = _players[playerIndex];
    await player.setPlaylistMode(playlistMode);
    await player.setVolume(play ? 100 : 0);
    await player.open(Playlist([Media(source)]), play: play);
    if (!play) {
      await player.seek(Duration.zero);
      await player.pause();
    }
  }

  Future<bool> _activatePreparedVideoIfMatches(
    String source, {
    required bool loopSingle,
  }) async {
    final prepared = _preparedVideo;
    if (prepared == null || prepared.source != source) {
      return false;
    }

    final previousActive = _activeVideoIndex;
    _activeVideoIndex = prepared.playerIndex;
    _preparedVideo = null;

    await _players[_activeVideoIndex].setPlaylistMode(
      loopSingle ? PlaylistMode.single : PlaylistMode.none,
    );
    await _players[_activeVideoIndex].setVolume(100);
    await _players[_activeVideoIndex].play();

    try {
      await _players[previousActive].pause();
      await _players[previousActive].setVolume(0);
      await _players[previousActive].stop();
    } catch (_) {}

    _expectVideoCompleted = !loopSingle;
    if (mounted) {
      setState(() => _mode = _Mode.video);
    }
    return true;
  }

  Future<void> _playVideoSource(
    String source, {
    required bool loopSingle,
  }) async {
    final activated = await _activatePreparedVideoIfMatches(
      source,
      loopSingle: loopSingle,
    );
    if (activated) {
      return;
    }

    await _clearPreparedVideo();
    await _openVideoOnPlayer(
      _activeVideoIndex,
      source,
      play: true,
      playlistMode: loopSingle ? PlaylistMode.single : PlaylistMode.none,
    );
    _expectVideoCompleted = !loopSingle;
  }

  Future<void> _prepareVideoOnStandby(String source, int mediaId) async {
    final prepared = _preparedVideo;
    if (prepared != null && prepared.source == source) {
      return;
    }

    await _clearPreparedVideo();
    await _openVideoOnPlayer(
      _standbyVideoIndex,
      source,
      play: false,
      playlistMode: PlaylistMode.none,
    );
    _preparedVideo = _PreparedVideo(
      playerIndex: _standbyVideoIndex,
      source: source,
      mediaId: mediaId,
    );
  }

  Future<void> _stopEverything() async {
    _imageTimer?.cancel();
    _expectVideoCompleted = false;
    _preparedVideo = null;
    for (final player in _players) {
      try {
        await player.pause();
        await player.setPlaylistMode(PlaylistMode.none);
        await player.setVolume(0);
        await player.stop();
      } catch (_) {}
    }
  }

  Future<void> _playMedia(
    ManifestMedia media, {
    required _PlaybackContext context,
    required ManifestItem slotContext,
  }) async {
    final controller = Get.find<PlaylistController>();
    final file = await controller.ensureMediaFile(media);
    if (file == null) {
      await _stopEverything();
      setState(() => _mode = _Mode.black);
      return;
    }
    if (!_isSameSlot(_currentSlot, slotContext)) return;

    _context = context;
    _currentMedia = media;

    if (media.isImage) {
      await _stopEverything();
      setState(() {
        _mode = _Mode.image;
        _imageIsFile = true;
        _imagePath = file.path;
      });

      if (context == _PlaybackContext.playlistItem) {
        _armPlaylistImageTimer();
      }

      await AppLogger.log('SHOW IMAGE: ${media.safeBaseName}');
      return;
    }

    if (media.isVideo) {
      try {
        setState(() => _mode = _Mode.video);
        await _playVideoSource(
          file.path,
          loopSingle:
              context == _PlaybackContext.slotMedia &&
              slotContext.loopMode == ManifestLoopMode.fill,
        );
        await AppLogger.log(
          'PLAY VIDEO: ${media.safeBaseName} src=${file.path}',
        );
      } catch (e) {
        _expectVideoCompleted = false;
        await AppLogger.log(
          'VIDEO OPEN FAILED: ${media.safeBaseName} error=$e',
        );
        setState(() => _mode = _Mode.black);
      }
      return;
    }

    setState(() => _mode = _Mode.black);
    await AppLogger.log('UNSUPPORTED: ${media.safeBaseName}');
  }

  void _armPlaylistImageTimer() {
    final item = _currentPlaylistItem;
    if (item == null) return;

    final slot = _currentSlot;
    if (slot == null) return;

    final now = DateTime.now();
    var duration = Duration(seconds: item.durationSec);
    final left = slot.endTime.difference(now);
    if (left.isNegative || left == Duration.zero) {
      _applySchedule(force: true);
      return;
    }
    if (left < duration) {
      duration = left;
    }

    _imageTimer?.cancel();
    _imageTimer = Timer(duration, _onPlaylistItemCompleted);
  }

  Future<void> _onVideoCompleted() async {
    final controller = Get.find<PlaylistController>();

    // В оффлайн-режиме обрабатываем по-другому
    if (controller.isOfflineMode.value) {
      final item = _lastOfflineItem;
      if (item == null) return;

      // Если не зациклен - чёрный экран
      if (!item.loop) {
        setState(() => _mode = _Mode.black);
        return;
      }

      // Если зациклен и ещё в пределах времени - перезапускаем
      final now = DateTime.now();
      final stillInWindow = item.stopDate == null
          ? true
          : now.isBefore(item.stopDate!);
      if (stillInWindow) {
        await _playOfflineItem(item);
      } else {
        setState(() => _mode = _Mode.black);
        _applySchedule(force: true);
      }
      return;
    }

    // Онлайн-режим (старый код)
    if (_context == _PlaybackContext.playlistItem) {
      _onPlaylistItemCompleted();
      return;
    }

    final slot = _currentSlot;
    final media = _currentMedia;
    if (slot == null || media == null) return;

    if (slot.loopMode == ManifestLoopMode.fill &&
        slot.isActiveAt(DateTime.now())) {
      await _playMedia(
        media,
        context: _PlaybackContext.slotMedia,
        slotContext: slot,
      );
      return;
    }
    setState(() => _mode = _Mode.black);
  }

  Future<void> _playPlaylistIndex(int index) async {
    final playlist = _currentPlaylist;
    if (playlist == null || playlist.items.isEmpty) return;

    final controller = Get.find<PlaylistController>();

    for (int i = index; i < playlist.items.length; i++) {
      final item = playlist.items[i];
      final media = controller.mediaById(item.mediaId);
      if (media == null) {
        await AppLogger.log('playlist media missing: media_id=${item.mediaId}');
        continue;
      }

      _playlistIndex = i;
      _currentPlaylistItem = item;
      final slot = _currentSlot;
      if (slot == null) return;
      await _playMedia(
        media,
        context: _PlaybackContext.playlistItem,
        slotContext: slot,
      );
      _prepareUpcomingPlayback(playlist, i);
      return;
    }

    setState(() => _mode = _Mode.black);
  }

  void _onPlaylistItemCompleted() {
    final controller = Get.find<PlaylistController>();

    // В оффлайн-режиме обрабатываем по-другому
    if (controller.isOfflineMode.value) {
      final item = _lastOfflineItem;
      if (item == null) return;

      final now = DateTime.now();

      // Если элемент ещё активен и зациклен - перезапускаем
      if (item.loop &&
          (item.stopDate == null || now.isBefore(item.stopDate!))) {
        _playOfflineItem(item);
      } else {
        // Иначе переходим к следующему элементу или чёрному экрану
        _applySchedule(force: true);
      }
      return;
    }

    // Онлайн-режим (старый код)
    final slot = _currentSlot;
    final playlist = _currentPlaylist;
    if (slot == null || playlist == null) return;

    if (!slot.isActiveAt(DateTime.now())) {
      _applySchedule(force: true);
      return;
    }

    var nextIndex = _playlistIndex + 1;
    if (nextIndex >= playlist.items.length) {
      if (slot.loopMode == ManifestLoopMode.fill) {
        nextIndex = 0;
      } else {
        setState(() => _mode = _Mode.black);
        return;
      }
    }

    _playPlaylistIndex(nextIndex);
  }

  Future<void> _prepareUpcomingPlayback(
    ManifestPlaylist playlist,
    int fromIndex,
  ) async {
    if (!mounted) return;
    final controller = Get.find<PlaylistController>();
    final slot = _currentSlot;
    if (slot == null) return;

    var nextIndex = fromIndex + 1;
    if (nextIndex >= playlist.items.length) {
      if (slot.loopMode != ManifestLoopMode.fill) {
        await _clearPreparedVideo();
        return;
      }
      nextIndex = 0;
    }

    final item = playlist.items[nextIndex];
    final media = controller.mediaById(item.mediaId);
    if (media == null) {
      await _clearPreparedVideo();
      return;
    }

    if (media.isImage) {
      await _clearPreparedVideo();
      final file = await controller.ensureMediaFile(media);
      if (file == null || !mounted) return;
      await precacheImage(FileImage(file), context);
      return;
    }

    if (media.isVideo) {
      final file = await controller.ensureMediaFile(media);
      if (file == null) {
        await _clearPreparedVideo();
        return;
      }
      await _prepareVideoOnStandby(file.path, media.id);
      return;
    }

    await _clearPreparedVideo();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final slot = _currentSlot;
    final controller = Get.find<PlaylistController>();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            layoutBuilder: (currentChild, previousChildren) => Stack(
              fit: StackFit.expand,
              children: [
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            ),
            child: _mode == _Mode.image && _imagePath.isNotEmpty
                ? _buildImageView()
                : _mode == _Mode.video
                ? SizedBox.expand(
                    child: Video(
                      key: ValueKey('video-$_activeVideoIndex'),
                      controller: _activeVideoController,
                      fit: BoxFit.contain,
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // ===== ДОБАВЛЕНО: кнопка редактора при наведении мыши =====
          // Новый исправленный код:
          Positioned(
            top: 0,
            left: 0,
            width: 150, // Увеличим область для захвата
            height: 150,
            child: MouseRegion(
              onEnter: (_) => setState(() => _showEditorButton = true),
              onExit: (_) => setState(() => _showEditorButton = false),
              child: Stack(
                children: [
                  // Невидимая область для отладки (можно временно раскомментировать)
                  // Container(color: Colors.red.withOpacity(0.1)),

                  // Кнопка редактора
                  if (_showEditorButton && !_isEditorOpen)
                    Positioned(
                      top: 20,
                      left: 20,
                      child: FloatingActionButton(
                        onPressed: _openEditor,
                        backgroundColor: Colors.red.shade700,
                        elevation: 8,
                        tooltip: 'Открыть редактор (F2)',
                        child: const Icon(
                          Icons.edit,
                          size: 30,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ============================================================
          if (_debug)
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                color: Colors.black54,
                child: Text(
                  'now=${_formatDebugTime(DateTime.now())}\n'
                  'mode=$_mode\n'
                  'slot=${slot == null ? "-" : slot.contentType.name}:${slot?.contentId}\n'
                  'manifest=${controller.currentRevision} items=${controller.items.length}\n'
                  'sync=${controller.syncDiagnostics}\n'
                  'start=${_formatDebugTime(slot?.startTime)}\n'
                  'stop=${_formatDebugTime(slot?.endTime)}\n'
                  'loop=${slot?.loopMode.name}\n'
                  'priority=${slot?.priority}\n'
                  'playlistIndex=$_playlistIndex\n'
                  'media=${_currentMedia?.id ?? "-"}\n'
                  'expectCompleted=$_expectVideoCompleted\n'
                  'imgIsFile=$_imageIsFile\n'
                  'imgPath=$_imagePath',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _tick?.cancel();
    _slotTimer?.cancel();
    _imageTimer?.cancel();
    _debugTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    for (final player in _players) {
      player.dispose();
    }
    super.dispose();
  }
}

String _formatDebugTime(DateTime? value) {
  if (value == null) return '-';
  return _PlayerScreenState._debugTimeFormat.format(value.toLocal());
}

bool _isSameSlot(ManifestItem? a, ManifestItem b) {
  if (a == null) return false;
  return a.contentId == b.contentId &&
      a.contentType == b.contentType &&
      a.startTime == b.startTime &&
      a.endTime == b.endTime &&
      a.priority == b.priority;
}

String _nowPlayingFor(ManifestItem slot) {
  return slot.contentType == ManifestContentType.playlist
      ? 'playlist:${slot.contentId}'
      : 'media:${slot.contentId}';
}
