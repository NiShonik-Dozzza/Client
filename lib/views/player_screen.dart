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

const Duration _scheduleBridgeTolerance = Duration(seconds: 2);
const Duration _playlistVideoDeadlineGrace = Duration(milliseconds: 250);

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
  late final List<bool> _playerBuffering;
  late final List<bool> _playerPlaying;
  late final List<Duration> _playerPositions;
  late final List<Duration> _playerDurations;
  late final List<Duration> _playerBuffers;
  late final List<int?> _playerWidths;
  late final List<int?> _playerHeights;
  late final List<String?> _playerLastErrors;
  late final List<Duration> _lastObservedPositions;
  late final List<DateTime?> _playerLastProgressAt;
  int _activeVideoIndex = 0;
  _PreparedVideo? _preparedVideo;
  String? _activeVideoSource;
  int _playbackTraceSeq = 0;
  int _activePlaybackTraceId = 0;
  int _lastPlaybackTraceSecond = -1;
  bool _playbackTraceStallLogged = false;

  // ===== ДОБАВЛЕНО: поддержка редактора =====
  bool _isEditorOpen = false; // Отслеживает открыт ли редактор
  bool _showEditorButton = false; // Состояние видимости кнопки
  // ==========================================

  Timer? _tick; // проверяем расписание
  Timer? _slotTimer; // точный переход на end_time
  Timer? _imageTimer;
  Timer? _debugTimer;
  Timer? _playbackTraceTimer;
  Timer? _playlistVideoDeadlineTimer;

  bool _initialized = false;
  bool _isDisposed = false;
  DateTime? _playlistVideoDeadlineAt;
  Duration? _playlistVideoDeadlineRequested;

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

  String _formatTc(Duration? value) {
    if (value == null) return '--:--:--.---';
    final abs = value.abs();
    final hours = abs.inHours.toString().padLeft(2, '0');
    final minutes = (abs.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (abs.inSeconds % 60).toString().padLeft(2, '0');
    final milliseconds =
        (abs.inMilliseconds % 1000).toString().padLeft(3, '0');
    final sign = value.isNegative ? '-' : '';
    return '$sign$hours:$minutes:$seconds.$milliseconds';
  }

  String _tcLabel(Duration? position, Duration? duration) {
    return '${_formatTc(position)}/${_formatTc(duration)}';
  }

  String _sourceLabel(String? source) {
    if (source == null || source.trim().isEmpty) return '-';
    final normalized = source.trim();
    final basename = p.basename(normalized);
    return basename.isNotEmpty ? basename : normalized;
  }

  String _slotLabel(ManifestItem? slot) {
    if (slot == null) return '-';
    return '${slot.contentType.name}:${slot.contentId} event=${slot.eventId ?? "-"}@${_formatDebugTime(slot.startTime)}..${_formatDebugTime(slot.endTime)} loop=${slot.loopMode.name} prio=${slot.priority}';
  }

  String _playlistItemLabel(ManifestPlaylistItem? item) {
    if (item == null) return '-';
    return 'item:${item.id} media=${item.mediaId} pos=${item.position} dur=${item.durationSec}s';
  }

  String _mediaLabel(ManifestMedia? media) {
    if (media == null) return '-';
    final type = media.isVideo
        ? 'video'
        : media.isImage
        ? 'image'
        : media.contentType;
    return '$type:${media.id}:${media.safeBaseName}';
  }

  String _playerSizeLabel(int playerIndex) {
    final width = _playerWidths[playerIndex];
    final height = _playerHeights[playerIndex];
    if (width == null || height == null) return '-';
    return '${width}x$height';
  }

  void _resetPlayerTraceState(int playerIndex) {
    _playerLastErrors[playerIndex] = null;
    _playerPositions[playerIndex] = Duration.zero;
    _playerDurations[playerIndex] = Duration.zero;
    _playerBuffers[playerIndex] = Duration.zero;
    _lastObservedPositions[playerIndex] = Duration.zero;
    _playerLastProgressAt[playerIndex] = DateTime.now();
  }

  void _startPlaybackTraceTimer() {
    _playbackTraceTimer?.cancel();
    _lastPlaybackTraceSecond = -1;
    _playbackTraceStallLogged = false;
    _playbackTraceTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _tickPlaybackTrace(),
    );
  }

  void _stopPlaybackTraceTimer() {
    _playbackTraceTimer?.cancel();
    _playbackTraceTimer = null;
    _activePlaybackTraceId = 0;
    _lastPlaybackTraceSecond = -1;
    _playbackTraceStallLogged = false;
  }

  void _tickPlaybackTrace() {
    if (_isDisposed || _mode != _Mode.video || _activePlaybackTraceId == 0) {
      return;
    }

    final playerIndex = _activeVideoIndex;
    final position = _playerPositions[playerIndex];
    final duration = _playerDurations[playerIndex];
    final buffer = _playerBuffers[playerIndex];
    final buffering = _playerBuffering[playerIndex];
    final playing = _playerPlaying[playerIndex];
    final source = _sourceLabel(_activeVideoSource);
    final timeBucket = position.inMilliseconds < 0
        ? -1
        : position.inMilliseconds ~/ 1000;

    if (timeBucket != _lastPlaybackTraceSecond) {
      _lastPlaybackTraceSecond = timeBucket;
      unawaited(
        AppLogger.log(
          'playback tick trace=$_activePlaybackTraceId source=$source tc=${_tcLabel(position, duration)} buffer=${_formatTc(buffer)} playing=$playing buffering=$buffering size=${_playerSizeLabel(playerIndex)} slot=${_slotLabel(_currentSlot)} item=${_playlistItemLabel(_currentPlaylistItem)}',
        ),
      );
    }

    final lastProgressAt = _playerLastProgressAt[playerIndex];
    if (lastProgressAt == null) return;

    final stalledFor = DateTime.now().difference(lastProgressAt);
    final remaining = duration > position ? duration - position : Duration.zero;
    final nearTail =
        duration > Duration.zero &&
        remaining <= const Duration(milliseconds: 1500);

    if ((playing || buffering) &&
        stalledFor >= const Duration(milliseconds: 1200) &&
        !_playbackTraceStallLogged) {
      _playbackTraceStallLogged = true;
      unawaited(
        AppLogger.log(
          'playback stall trace=$_activePlaybackTraceId source=$source tc=${_tcLabel(position, duration)} buffer=${_formatTc(buffer)} stalled=${stalledFor.inMilliseconds}ms playing=$playing buffering=$buffering near_tail=$nearTail size=${_playerSizeLabel(playerIndex)} error=${_playerLastErrors[playerIndex] ?? "-"}',
        ),
      );
      return;
    }

    if (stalledFor < const Duration(milliseconds: 500)) {
      _playbackTraceStallLogged = false;
    }
  }

  void _clearPlaylistVideoDeadline() {
    _playlistVideoDeadlineTimer?.cancel();
    _playlistVideoDeadlineTimer = null;
    _playlistVideoDeadlineAt = null;
    _playlistVideoDeadlineRequested = null;
  }

  Duration? _remainingPlaylistVideoDeadline() {
    final deadline = _playlistVideoDeadlineAt;
    if (deadline == null) return null;
    final remaining = deadline.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _schedulePlaylistVideoDeadline() {
    final item = _currentPlaylistItem;
    final slot = _currentSlot;
    if (_context != _PlaybackContext.playlistItem || item == null || slot == null) {
      _clearPlaylistVideoDeadline();
      return;
    }

    var duration = Duration(seconds: item.durationSec);
    final slotLeft = slot.endTime.difference(DateTime.now());
    if (slotLeft.isNegative || slotLeft == Duration.zero) {
      _clearPlaylistVideoDeadline();
      unawaited(_applySchedule(force: true));
      return;
    }
    if (slotLeft < duration) {
      duration = slotLeft;
    }

    _playlistVideoDeadlineTimer?.cancel();
    _playlistVideoDeadlineTimer = null;
    _playlistVideoDeadlineAt = null;
    _playlistVideoDeadlineRequested = duration;
    _tryArmPlaylistVideoDeadline(trigger: 'schedule');
  }

  void _tryArmPlaylistVideoDeadline({required String trigger}) {
    final requested = _playlistVideoDeadlineRequested;
    final item = _currentPlaylistItem;
    final slot = _currentSlot;
    if (requested == null ||
        _context != _PlaybackContext.playlistItem ||
        item == null ||
        slot == null) {
      return;
    }
    if (_playlistVideoDeadlineAt != null) return;
    if (!_playerPlaying[_activeVideoIndex] || _playerBuffering[_activeVideoIndex]) {
      return;
    }

    var duration = requested;
    final slotLeft = slot.endTime.difference(DateTime.now());
    if (slotLeft.isNegative || slotLeft == Duration.zero) {
      _clearPlaylistVideoDeadline();
      unawaited(_applySchedule(force: true));
      return;
    }
    if (slotLeft < duration) {
      duration = slotLeft;
    }

    _playlistVideoDeadlineAt = DateTime.now().add(duration);
    _playlistVideoDeadlineRequested = null;
    unawaited(
      AppLogger.log(
        'playlist video deadline armed: trace=$_activePlaybackTraceId trigger=$trigger duration=${duration.inMilliseconds}ms slot_left=${slotLeft.inMilliseconds}ms item=${_playlistItemLabel(item)} slot=${_slotLabel(slot)} media_tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
      ),
    );
    _playlistVideoDeadlineTimer = Timer(duration, () {
      if (_isDisposed || _context != _PlaybackContext.playlistItem) return;
      final remaining = _remainingPlaylistVideoDeadline() ?? Duration.zero;
      unawaited(
        AppLogger.log(
          'playlist video deadline fired: trace=$_activePlaybackTraceId remaining=${remaining.inMilliseconds}ms item=${_playlistItemLabel(_currentPlaylistItem)} source=${_sourceLabel(_activeVideoSource)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
        ),
      );
      _clearPlaylistVideoDeadline();
      _expectVideoCompleted = false;
      unawaited(_onPlaylistItemCompleted(reason: 'video-deadline'));
    });
  }

  Future<void> _restartPlaylistVideoWithinDeadline() async {
    final source = _activeVideoSource;
    if (source == null || _mode != _Mode.video) {
      await _onPlaylistItemCompleted(reason: 'video-restart-no-source');
      return;
    }

    final remaining = _remainingPlaylistVideoDeadline() ?? Duration.zero;
    await AppLogger.log(
      'playlist video restart: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} remaining=${remaining.inMilliseconds}ms tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
    );

    try {
      final player = _players[_activeVideoIndex];
      await player.seek(Duration.zero);
      await player.play();
      _expectVideoCompleted = true;
      _playerLastProgressAt[_activeVideoIndex] = DateTime.now();
      _playbackTraceStallLogged = false;
    } catch (e) {
      _expectVideoCompleted = false;
      await AppLogger.log(
        'playlist video restart failed: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} error=$e',
      );
      await _onPlaylistItemCompleted(reason: 'video-restart-failed');
    }
  }

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
    _playerBuffering = List<bool>.filled(_players.length, false, growable: false);
    _playerPlaying = List<bool>.filled(_players.length, false, growable: false);
    _playerPositions = List<Duration>.filled(
      _players.length,
      Duration.zero,
      growable: false,
    );
    _playerDurations = List<Duration>.filled(
      _players.length,
      Duration.zero,
      growable: false,
    );
    _playerBuffers = List<Duration>.filled(
      _players.length,
      Duration.zero,
      growable: false,
    );
    _playerWidths = List<int?>.filled(_players.length, null, growable: false);
    _playerHeights = List<int?>.filled(_players.length, null, growable: false);
    _playerLastErrors = List<String?>.filled(
      _players.length,
      null,
      growable: false,
    );
    _lastObservedPositions = List<Duration>.filled(
      _players.length,
      Duration.zero,
      growable: false,
    );
    _playerLastProgressAt = List<DateTime?>.filled(
      _players.length,
      null,
      growable: false,
    );

    for (var i = 0; i < _players.length; i++) {
      _players[i].stream.playing.listen((value) {
        _playerPlaying[i] = value;
        if (i == _activeVideoIndex || value) {
          unawaited(
            AppLogger.log(
              'media_kit[$i] playing=$value trace=$_activePlaybackTraceId source=${_sourceLabel(i == _activeVideoIndex ? _activeVideoSource : _preparedVideo?.source)} tc=${_tcLabel(_playerPositions[i], _playerDurations[i])}',
            ),
          );
        }
        if (i == _activeVideoIndex && value) {
          _tryArmPlaylistVideoDeadline(trigger: 'playing');
        }
      });
      _players[i].stream.position.listen((value) {
        final previous = _lastObservedPositions[i];
        if (value > previous) {
          _playerLastProgressAt[i] = DateTime.now();
          if (i == _activeVideoIndex) {
            _playbackTraceStallLogged = false;
            _tryArmPlaylistVideoDeadline(trigger: 'progress');
          }
        } else if (i == _activeVideoIndex &&
            value + const Duration(milliseconds: 450) < previous) {
          unawaited(
            AppLogger.log(
              'media_kit[$i] position-rewind trace=$_activePlaybackTraceId source=${_sourceLabel(_activeVideoSource)} from=${_formatTc(previous)} to=${_formatTc(value)}',
            ),
          );
        }
        _lastObservedPositions[i] = value;
        _playerPositions[i] = value;
      });
      _players[i].stream.duration.listen((value) {
        _playerDurations[i] = value;
      });
      _players[i].stream.buffer.listen((value) {
        _playerBuffers[i] = value;
      });
      _players[i].stream.width.listen((value) {
        _playerWidths[i] = value;
      });
      _players[i].stream.height.listen((value) {
        _playerHeights[i] = value;
      });
      _players[i].stream.buffering.listen((value) {
        _playerBuffering[i] = value;
        if (i == _activeVideoIndex || value) {
          unawaited(
            AppLogger.log(
              'media_kit[$i] buffering=$value trace=$_activePlaybackTraceId source=${_sourceLabel(i == _activeVideoIndex ? _activeVideoSource : _preparedVideo?.source)} tc=${_tcLabel(_playerPositions[i], _playerDurations[i])} buffer=${_formatTc(_playerBuffers[i])}',
            ),
          );
        }
        if (i == _activeVideoIndex && !value) {
          _tryArmPlaylistVideoDeadline(trigger: 'buffering-false');
        }
      });
      _players[i].stream.error.listen(
        (e) {
          _playerLastErrors[i] = e;
          unawaited(AppLogger.log('media_kit[$i] error: $e'));
        },
      );

      _players[i].stream.completed.listen((completed) {
        unawaited(
          AppLogger.log(
            'media_kit[$i] completed=$completed trace=$_activePlaybackTraceId source=${_sourceLabel(i == _activeVideoIndex ? _activeVideoSource : _preparedVideo?.source)} tc=${_tcLabel(_playerPositions[i], _playerDurations[i])}',
          ),
        );
        if (_isDisposed) return;
        if (i != _activeVideoIndex) return;
        if (!_expectVideoCompleted) return;
        if (_mode != _Mode.video) return;
        if (!completed) return;

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
    _clearPlaylistVideoDeadline();
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
      ever<int>(controller.version, (_) {
        unawaited(
          AppLogger.log(
            'schedule apply requested: revision=${controller.currentRevision} items=${controller.items.length} mode=${controller.isOfflineMode.value ? "offline" : "online"}',
          ),
        );
        _applySchedule(force: true);
      });

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
      final continuation = _findUpcomingContinuationSlot(controller, now);
      if (continuation != null) {
        _slotTimer?.cancel();
        final wait = continuation.startTime.difference(now);
        if (!wait.isNegative) {
          _slotTimer = Timer(wait, () => _applySchedule(force: true));
        }
        await AppLogger.log(
          'schedule bridge keep: force=$force from=${_slotLabel(_currentSlot)} to=${_slotLabel(continuation)} wait=${wait.inMilliseconds}ms media=${_mediaLabel(_currentMedia)} item=${_playlistItemLabel(_currentPlaylistItem)} source=${_sourceLabel(_activeVideoSource)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
        );
        if (mounted) {
          setState(() {});
        }
        return;
      }

      if (_currentSlot != null) {
        await AppLogger.log(
          'schedule clear: prev_slot=${_slotLabel(_currentSlot)} prev_media=${_mediaLabel(_currentMedia)} prev_item=${_playlistItemLabel(_currentPlaylistItem)}',
        );
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

    final exactSame = !force && _isSameSlot(_currentSlot, nextSlot);
    if (exactSame) return;

    final sameLogical = _isSameLogicalSlotAt(_currentSlot, nextSlot, now);
    if (sameLogical) {
      final previousSlot = _currentSlot;
      _currentSlot = nextSlot;
      if (nextSlot.contentType == ManifestContentType.playlist &&
          _currentPlaylist?.id == nextSlot.contentId) {
        _currentPlaylist = controller.playlistById(nextSlot.contentId);
      } else if (nextSlot.contentType == ManifestContentType.media &&
          _currentMedia?.id == nextSlot.contentId) {
        _currentMedia = controller.mediaById(nextSlot.contentId) ?? _currentMedia;
      }

      _slotTimer?.cancel();
      final updatedDuration = nextSlot.endTime.difference(now);
      if (!updatedDuration.isNegative) {
        _slotTimer = Timer(updatedDuration, () => _applySchedule(force: true));
      }

      await AppLogger.log(
        'schedule keep active slot: force=$force from=${_slotLabel(previousSlot)} to=${_slotLabel(nextSlot)} media=${_mediaLabel(_currentMedia)} item=${_playlistItemLabel(_currentPlaylistItem)} source=${_sourceLabel(_activeVideoSource)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
      );

      if (mounted) {
        setState(() {});
      }
      return;
    }

    await AppLogger.log(
      'schedule switch: force=$force from=${_slotLabel(_currentSlot)} to=${_slotLabel(nextSlot)} prev_media=${_mediaLabel(_currentMedia)} prev_item=${_playlistItemLabel(_currentPlaylistItem)} active_source=${_sourceLabel(_activeVideoSource)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
    );

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

  ManifestItem? _findUpcomingContinuationSlot(
    PlaylistController controller,
    DateTime now,
  ) {
    final currentSlot = _currentSlot;
    if (currentSlot == null) return null;

    ManifestItem? candidate;
    for (final item in controller.items) {
      if (!_isSameSlotIdentity(currentSlot, item)) continue;
      if (item.loopMode != currentSlot.loopMode ||
          item.priority != currentSlot.priority) {
        continue;
      }
      if (item.endTime.isBefore(now)) continue;

      final wait = item.startTime.difference(now);
      if (wait.isNegative || wait > _scheduleBridgeTolerance) continue;

      if (candidate == null || item.startTime.isBefore(candidate.startTime)) {
        candidate = item;
      }
    }
    return candidate;
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
    _resetPlayerTraceState(playerIndex);
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
    _activeVideoSource = source;
    _resetPlayerTraceState(_activeVideoIndex);

    await AppLogger.log(
      'video activate prepared: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} player=$_activeVideoIndex prev_player=$previousActive loop_single=$loopSingle prepared_media=${prepared.mediaId}',
    );

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
    _startPlaybackTraceTimer();
    await AppLogger.log(
      'video active: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} player=$_activeVideoIndex prepared=true loop_single=$loopSingle size=${_playerSizeLabel(_activeVideoIndex)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
    );
    if (mounted) {
      setState(() => _mode = _Mode.video);
    }
    return true;
  }

  Future<void> _playVideoSource(
    String source, {
    required bool loopSingle,
  }) async {
    await AppLogger.log(
      'video source request: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} loop_single=$loopSingle active_player=$_activeVideoIndex standby_player=$_standbyVideoIndex prepared_match=${_preparedVideo?.source == source}',
    );
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
    _activeVideoSource = source;
    _expectVideoCompleted = !loopSingle;
    _startPlaybackTraceTimer();
    await AppLogger.log(
      'video active: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} player=$_activeVideoIndex prepared=false loop_single=$loopSingle size=${_playerSizeLabel(_activeVideoIndex)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
    );
  }

  Future<void> _prepareVideoOnStandby(String source, int mediaId) async {
    final prepared = _preparedVideo;
    if (prepared != null && prepared.source == source) {
      await AppLogger.log(
        'video prepare skip: source=${_sourceLabel(source)} media_id=$mediaId standby_player=${prepared.playerIndex}',
      );
      return;
    }

    await AppLogger.log(
      'video prepare start: source=${_sourceLabel(source)} media_id=$mediaId standby_player=$_standbyVideoIndex',
    );
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
    await AppLogger.log(
      'video prepare ready: source=${_sourceLabel(source)} media_id=$mediaId standby_player=$_standbyVideoIndex',
    );
  }

  Future<void> _stopEverything() async {
    _imageTimer?.cancel();
    _clearPlaylistVideoDeadline();
    _expectVideoCompleted = false;
    if (_mode == _Mode.video ||
        _activeVideoSource != null ||
        _preparedVideo != null) {
      await AppLogger.log(
        'stop playback: trace=$_activePlaybackTraceId active_source=${_sourceLabel(_activeVideoSource)} prepared_source=${_sourceLabel(_preparedVideo?.source)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
      );
    }
    _stopPlaybackTraceTimer();
    _activeVideoSource = null;
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
      await AppLogger.log(
        'media file unavailable: context=${context.name} slot=${_slotLabel(slotContext)} item=${_playlistItemLabel(_currentPlaylistItem)} media=${_mediaLabel(media)}',
      );
      await _stopEverything();
      setState(() => _mode = _Mode.black);
      return;
    }
    if (!_matchesPlaybackSlot(_currentSlot, slotContext)) {
      await AppLogger.log(
        'play media aborted: slot changed expected=${_slotLabel(slotContext)} actual=${_slotLabel(_currentSlot)} media=${_mediaLabel(media)} file=${_sourceLabel(file.path)}',
      );
      return;
    }

    _context = context;
    _currentMedia = media;

    if (media.isImage) {
      await _stopEverything();
      _activePlaybackTraceId = ++_playbackTraceSeq;
      await AppLogger.log(
        'playback trace start: trace=$_activePlaybackTraceId context=${context.name} slot=${_slotLabel(slotContext)} item=${_playlistItemLabel(_currentPlaylistItem)} media=${_mediaLabel(media)} file=${_sourceLabel(file.path)}',
      );
      setState(() {
        _mode = _Mode.image;
        _imageIsFile = true;
        _imagePath = file.path;
      });

      if (context == _PlaybackContext.playlistItem) {
        _armPlaylistImageTimer();
      }

      await AppLogger.log(
        'SHOW IMAGE: ${media.safeBaseName} trace=$_activePlaybackTraceId slot=${_slotLabel(slotContext)} item=${_playlistItemLabel(_currentPlaylistItem)}',
      );
      return;
    }

    if (media.isVideo) {
      _activePlaybackTraceId = ++_playbackTraceSeq;
      _lastPlaybackTraceSecond = -1;
      _playbackTraceStallLogged = false;
      await AppLogger.log(
        'playback trace start: trace=$_activePlaybackTraceId context=${context.name} slot=${_slotLabel(slotContext)} item=${_playlistItemLabel(_currentPlaylistItem)} media=${_mediaLabel(media)} file=${_sourceLabel(file.path)}',
      );
      try {
        setState(() => _mode = _Mode.video);
        await _playVideoSource(
          file.path,
          loopSingle:
              context == _PlaybackContext.slotMedia &&
              slotContext.loopMode == ManifestLoopMode.fill,
        );
        await AppLogger.log(
          'PLAY VIDEO: ${media.safeBaseName} trace=$_activePlaybackTraceId src=${file.path} slot=${_slotLabel(slotContext)} item=${_playlistItemLabel(_currentPlaylistItem)}',
        );
        if (context == _PlaybackContext.playlistItem) {
          _schedulePlaylistVideoDeadline();
        } else {
          _clearPlaylistVideoDeadline();
        }
      } catch (e) {
        _expectVideoCompleted = false;
        _clearPlaylistVideoDeadline();
        await AppLogger.log(
          'VIDEO OPEN FAILED: ${media.safeBaseName} trace=$_activePlaybackTraceId error=$e',
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
    unawaited(
      AppLogger.log(
        'playlist image timer armed: trace=$_activePlaybackTraceId duration=${duration.inMilliseconds}ms slot_left=${left.inMilliseconds}ms item=${_playlistItemLabel(item)} slot=${_slotLabel(slot)}',
      ),
    );
    _imageTimer = Timer(
      duration,
      () => unawaited(_onPlaylistItemCompleted(reason: 'image-timer')),
    );
  }

  Future<void> _onVideoCompleted() async {
    final controller = Get.find<PlaylistController>();
    await AppLogger.log(
      'video completed handler: trace=$_activePlaybackTraceId context=${_context?.name ?? "-"} slot=${_slotLabel(_currentSlot)} item=${_playlistItemLabel(_currentPlaylistItem)} media=${_mediaLabel(_currentMedia)} source=${_sourceLabel(_activeVideoSource)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
    );

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
      final remaining = _remainingPlaylistVideoDeadline();
      if (remaining != null && remaining > _playlistVideoDeadlineGrace) {
        await AppLogger.log(
          'playlist video completed early: trace=$_activePlaybackTraceId remaining=${remaining.inMilliseconds}ms item=${_playlistItemLabel(_currentPlaylistItem)} source=${_sourceLabel(_activeVideoSource)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
        );
        await _restartPlaylistVideoWithinDeadline();
        return;
      }
      _clearPlaylistVideoDeadline();
      await _onPlaylistItemCompleted(reason: 'player-completed');
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

      await AppLogger.log(
        'playlist select: playlist=${playlist.id}:${playlist.name} index=$i/${playlist.items.length - 1} item=${_playlistItemLabel(item)} media=${_mediaLabel(media)} slot=${_slotLabel(_currentSlot)}',
      );
      _playlistIndex = i;
      _currentPlaylistItem = item;
      final slot = _currentSlot;
      if (slot == null) return;
      await _playMedia(
        media,
        context: _PlaybackContext.playlistItem,
        slotContext: slot,
      );
      unawaited(_prepareUpcomingPlayback(playlist, i));
      return;
    }

    setState(() => _mode = _Mode.black);
  }

  Future<void> _onPlaylistItemCompleted({String reason = 'unknown'}) async {
    final controller = Get.find<PlaylistController>();
    _clearPlaylistVideoDeadline();
    await AppLogger.log(
      'playlist item completed: trace=$_activePlaybackTraceId reason=$reason index=$_playlistIndex item=${_playlistItemLabel(_currentPlaylistItem)} media=${_mediaLabel(_currentMedia)} source=${_sourceLabel(_activeVideoSource)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
    );

    // В оффлайн-режиме обрабатываем по-другому
    if (controller.isOfflineMode.value) {
      final item = _lastOfflineItem;
      if (item == null) return;

      final now = DateTime.now();

      // Если элемент ещё активен и зациклен - перезапускаем
      if (item.loop &&
          (item.stopDate == null || now.isBefore(item.stopDate!))) {
        await _playOfflineItem(item);
      } else {
        // Иначе переходим к следующему элементу или чёрному экрану
        await _applySchedule(force: true);
      }
      return;
    }

    // Онлайн-режим (старый код)
    final slot = _currentSlot;
    final playlist = _currentPlaylist;
    if (slot == null || playlist == null) return;

    if (!slot.isActiveAt(DateTime.now())) {
      await AppLogger.log(
        'playlist item completed -> schedule reapply: trace=$_activePlaybackTraceId slot=${_slotLabel(slot)}',
      );
      await _applySchedule(force: true);
      return;
    }

    var nextIndex = _playlistIndex + 1;
    if (nextIndex >= playlist.items.length) {
      if (slot.loopMode == ManifestLoopMode.fill) {
        nextIndex = 0;
      } else {
        await AppLogger.log(
          'playlist end without loop: trace=$_activePlaybackTraceId slot=${_slotLabel(slot)}',
        );
        setState(() => _mode = _Mode.black);
        return;
      }
    }

    await AppLogger.log(
      'playlist advance: trace=$_activePlaybackTraceId next_index=$nextIndex slot=${_slotLabel(slot)}',
    );
    await _playPlaylistIndex(nextIndex);
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
        await AppLogger.log(
          'prepare upcoming clear: reached playlist end without loop playlist=${playlist.id}:${playlist.name}',
        );
        await _clearPreparedVideo();
        return;
      }
      nextIndex = 0;
    }

    final item = playlist.items[nextIndex];
    final media = controller.mediaById(item.mediaId);
    if (media == null) {
      await AppLogger.log(
        'prepare upcoming missing media: item=${_playlistItemLabel(item)} playlist=${playlist.id}:${playlist.name}',
      );
      await _clearPreparedVideo();
      return;
    }

    if (media.isImage) {
      await AppLogger.log(
        'prepare upcoming image: item=${_playlistItemLabel(item)} media=${_mediaLabel(media)}',
      );
      await _clearPreparedVideo();
      final file = await controller.ensureMediaFile(media);
      if (file == null || !mounted) return;
      await precacheImage(FileImage(file), context);
      await AppLogger.log(
        'prepare upcoming image ready: item=${_playlistItemLabel(item)} file=${_sourceLabel(file.path)}',
      );
      return;
    }

    if (media.isVideo) {
      final file = await controller.ensureMediaFile(media);
      if (file == null) {
        await AppLogger.log(
          'prepare upcoming video missing file: item=${_playlistItemLabel(item)} media=${_mediaLabel(media)}',
        );
        await _clearPreparedVideo();
        return;
      }
      await AppLogger.log(
        'prepare upcoming video: item=${_playlistItemLabel(item)} media=${_mediaLabel(media)} file=${_sourceLabel(file.path)}',
      );
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
                  'start=${_formatDebugTime(slot?.startTime)}\n'
                  'stop=${_formatDebugTime(slot?.endTime)}\n'
                  'loop=${slot?.loopMode.name}\n'
                  'priority=${slot?.priority}\n'
                  'playlistIndex=$_playlistIndex\n'
                  'media=${_currentMedia?.id ?? "-"}\n'
                  'trace=$_activePlaybackTraceId\n'
                  'source=${_sourceLabel(_activeVideoSource)}\n'
                  'tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}\n'
                  'buffer=${_formatTc(_playerBuffers[_activeVideoIndex])}\n'
                  'playing=${_playerPlaying[_activeVideoIndex]} buffering=${_playerBuffering[_activeVideoIndex]}\n'
                  'size=${_playerSizeLabel(_activeVideoIndex)}\n'
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
    _playbackTraceTimer?.cancel();
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
  return a.eventId == b.eventId &&
      a.contentId == b.contentId &&
      a.contentType == b.contentType &&
      a.startTime == b.startTime &&
      a.endTime == b.endTime &&
      a.loopMode == b.loopMode &&
      a.priority == b.priority;
}

bool _isSameSlotIdentity(ManifestItem? a, ManifestItem b) {
  if (a == null) return false;
  if (a.contentType != b.contentType) return false;
  if (a.eventId != null && b.eventId != null) {
    return a.eventId == b.eventId;
  }
  return a.contentId == b.contentId;
}

bool _matchesPlaybackSlot(ManifestItem? a, ManifestItem b) {
  if (_isSameSlot(a, b)) return true;
  if (!_isSameSlotIdentity(a, b)) return false;
  return a!.loopMode == b.loopMode && a.priority == b.priority;
}

bool _isSameLogicalSlotAt(ManifestItem? a, ManifestItem b, DateTime now) {
  if (!_matchesPlaybackSlot(a, b)) return false;
  return a!.isActiveAt(now) && b.isActiveAt(now);
}

String _nowPlayingFor(ManifestItem slot) {
  return slot.contentType == ManifestContentType.playlist
      ? 'playlist:${slot.contentId}'
      : 'media:${slot.contentId}';
}
