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
const Duration _videoPrepareLead = Duration(milliseconds: 450);
const Duration _videoPrepareWarmupTimeout = Duration(milliseconds: 2200);
const Duration _videoPrepareFrameThreshold = Duration(milliseconds: 48);
const Duration _videoRetireDelay = Duration(milliseconds: 180);

class _PreparedVideo {
  const _PreparedVideo({
    required this.playerIndex,
    required this.source,
    required this.mediaId,
    required this.sequence,
  });

  final int playerIndex;
  final String source;
  final int mediaId;
  final int sequence;
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
  Future<void>? _videoPlayerConfiguration;
  int _activeVideoIndex = 0;
  _PreparedVideo? _preparedVideo;
  int? _warmingVideoIndex;
  Timer? _prepareVideoTimer;
  int _prepareVideoSeq = 0;
  String? _activeVideoSource;
  int _playbackTraceSeq = 0;
  int _activePlaybackTraceId = 0;
  int _lastPlaybackTraceSecond = -1;
  bool _playbackTraceStallLogged = false;
  double _lastAppliedVideoVolume = -1;
  String _lastAppliedContentRevision = '';
  Worker? _controllerVersionWorker;

  // ===== ДОБАВЛЕНО: поддержка редактора =====
  bool _isEditorOpen = false; // Отслеживает открыт ли редактор
  // ==========================================

  Timer? _tick; // проверяем расписание
  Timer? _slotTimer; // точный переход на end_time
  Timer? _imageTimer;
  Timer? _debugTimer;
  Timer? _playbackTraceTimer;

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

  int get _standbyVideoIndex => _activeVideoIndex == 0 ? 1 : 0;

  String _formatTc(Duration? value) {
    if (value == null) return '--:--:--.---';
    final abs = value.abs();
    final hours = abs.inHours.toString().padLeft(2, '0');
    final minutes = (abs.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (abs.inSeconds % 60).toString().padLeft(2, '0');
    final milliseconds = (abs.inMilliseconds % 1000).toString().padLeft(3, '0');
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

  double get _effectiveVideoVolume {
    final controller = Get.find<PlaylistController>();
    if (controller.audioMuted) {
      return 0;
    }
    return controller.masterVolume.toDouble();
  }

  Future<void> _syncActiveVideoVolume() async {
    if (_mode != _Mode.video) {
      _lastAppliedVideoVolume = -1;
      return;
    }
    final targetVolume = _effectiveVideoVolume;
    if (_lastAppliedVideoVolume == targetVolume) {
      return;
    }
    try {
      await _players[_activeVideoIndex].setVolume(targetVolume);
      _lastAppliedVideoVolume = targetVolume;
    } catch (_) {}
  }

  void _resetPlayerTraceState(int playerIndex) {
    _playerLastErrors[playerIndex] = null;
    _playerPositions[playerIndex] = Duration.zero;
    _playerDurations[playerIndex] = Duration.zero;
    _playerBuffers[playerIndex] = Duration.zero;
    _playerWidths[playerIndex] = null;
    _playerHeights[playerIndex] = null;
    _lastObservedPositions[playerIndex] = Duration.zero;
    _playerLastProgressAt[playerIndex] = DateTime.now();
  }

  bool _playerHasRenderableFrame(int playerIndex) {
    final hasSize =
        (_playerWidths[playerIndex] ?? 0) > 0 ||
        (_playerHeights[playerIndex] ?? 0) > 0;
    if (!hasSize) return false;

    return _playerPositions[playerIndex] >= _videoPrepareFrameThreshold ||
        _playerBuffers[playerIndex] > Duration.zero ||
        (_playerPlaying[playerIndex] && !_playerBuffering[playerIndex]);
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

  Player _createVideoPlayer() {
    return Player(
      configuration: const PlayerConfiguration(
        title: 'EFIR Player',
        osc: false,
      ),
    );
  }

  String _preferredHwdec() {
    if (kIsWeb) return 'no';
    if (Platform.isAndroid) return 'auto-safe';
    return 'auto';
  }

  VideoController _createVideoController(Player player) {
    return VideoController(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: _preferredHwdec(),
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: true,
      ),
    );
  }

  Future<void> _configureVideoPlayer(Player player) async {
    if (kIsWeb) return;

    final platform = player.platform;
    if (platform == null) return;

    final options = <String, String>{
      'hwdec': _preferredHwdec(),
      'vd-lavc-threads': '0',
      'vd-lavc-dr': 'yes',
      'hwdec-extra-frames': '64',
      'cache': 'yes',
      'demuxer-max-bytes': '268435456',
      'demuxer-max-back-bytes': '67108864',
      'demuxer-thread': 'yes',
      'framedrop': 'decoder+vo',
      'vd-lavc-fast': 'yes',
      'vd-lavc-skiploopfilter': 'nonkey',
      'scale': 'bilinear',
      'dscale': 'bilinear',
      'cscale': 'bilinear',
      'correct-downscaling': 'no',
      'deband': 'no',
      'interpolation': 'no',
    };

    for (final entry in options.entries) {
      try {
        await (platform as dynamic).setProperty(entry.key, entry.value);
      } catch (e) {
        unawaited(
          AppLogger.log(
            'media_kit option skipped: ${entry.key}=${entry.value} error=$e',
          ),
        );
      }
    }

    unawaited(
      AppLogger.log(
        'media_kit configured: hwdec=${_preferredHwdec()} vd-lavc-threads=0 cache=yes framedrop=decoder+vo',
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    _players = [_createVideoPlayer(), _createVideoPlayer()];
    _videoControllers = _players
        .map(_createVideoController)
        .toList(growable: false);
    _videoPlayerConfiguration = Future.wait(
      _players.map(_configureVideoPlayer),
    );
    unawaited(_videoPlayerConfiguration!);
    _playerBuffering = List<bool>.filled(
      _players.length,
      false,
      growable: false,
    );
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
              'media_kit[$i] playing=$value trace=$_activePlaybackTraceId source=${_sourceLabel(i == _activeVideoIndex ? _activeVideoSource : null)} tc=${_tcLabel(_playerPositions[i], _playerDurations[i])}',
            ),
          );
        }
      });
      _players[i].stream.position.listen((value) {
        final previous = _lastObservedPositions[i];
        if (value > previous) {
          _playerLastProgressAt[i] = DateTime.now();
          if (i == _activeVideoIndex) {
            _playbackTraceStallLogged = false;
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
              'media_kit[$i] buffering=$value trace=$_activePlaybackTraceId source=${_sourceLabel(i == _activeVideoIndex ? _activeVideoSource : null)} tc=${_tcLabel(_playerPositions[i], _playerDurations[i])} buffer=${_formatTc(_playerBuffers[i])}',
            ),
          );
        }
      });
      _players[i].stream.videoParams.listen((value) {
        final size = value.dw != null && value.dh != null
            ? '${value.dw}x${value.dh}'
            : '${value.w ?? "-"}x${value.h ?? "-"}';
        if (i == _activeVideoIndex && (value.w != null || value.dw != null)) {
          unawaited(
            AppLogger.log(
              'media_kit[$i] video-params trace=$_activePlaybackTraceId source=${_sourceLabel(_activeVideoSource)} size=$size pix=${value.pixelformat ?? "-"} hw_pix=${value.hwPixelformat ?? "-"}',
            ),
          );
        }
      });
      _players[i].stream.track.listen((value) {
        final video = value.video;
        if (i == _activeVideoIndex && video.id != 'auto') {
          unawaited(
            AppLogger.log(
              'media_kit[$i] video-track trace=$_activePlaybackTraceId codec=${video.codec ?? "-"} decoder=${video.decoder ?? "-"} size=${video.w ?? "-"}x${video.h ?? "-"} fps=${video.fps ?? "-"}',
            ),
          );
        }
      });
      _players[i].stream.error.listen((e) {
        _playerLastErrors[i] = e;
        unawaited(AppLogger.log('media_kit[$i] error: $e'));
      });

      _players[i].stream.completed.listen((completed) {
        unawaited(
          AppLogger.log(
            'media_kit[$i] completed=$completed trace=$_activePlaybackTraceId source=${_sourceLabel(i == _activeVideoIndex ? _activeVideoSource : null)} tc=${_tcLabel(_playerPositions[i], _playerDurations[i])}',
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

  // Сервисные жесты входа в редактор: серия быстрых нажатий/тапов.
  static const Duration _serviceGestureWindow = Duration(milliseconds: 600);
  int _backPressCount = 0; // Android/TV пульт: 5×Back
  DateTime? _lastBackPressAt;
  int _escPressCount = 0; // Desktop: 3×Esc
  DateTime? _lastEscPressAt;
  int _tapCount = 0; // Touch: серия тапов по экрану
  DateTime? _lastTapAt;

  /// Считает быстрые тапы по экрану; по достижении порога открывает редактор.
  /// Для тач-устройств без клавиатуры/пульта.
  void _handleServiceTap() {
    if (_isEditorOpen) return;
    final now = DateTime.now();
    final last = _lastTapAt;
    if (last != null && now.difference(last) < _serviceGestureWindow) {
      _tapCount++;
    } else {
      _tapCount = 1;
    }
    _lastTapAt = now;
    if (_tapCount >= 5) {
      _tapCount = 0;
      _openEditor();
    }
  }

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) {
      // F12 / Settings: переключить отладку
      if (e.logicalKey == LogicalKeyboardKey.f12 ||
          e.logicalKey == LogicalKeyboardKey.settings) {
        setState(() => _debug = !_debug);
        return true;
      }

      // F2 / Menu: открыть редактор (десктоп клавиши)
      if (!_isEditorOpen && e.logicalKey == LogicalKeyboardKey.f2) {
        _openEditor();
        return true;
      }

      // Android TV remote: кнопка Menu открывает сервисный редактор
      if (!_isEditorOpen && e.logicalKey == LogicalKeyboardKey.contextMenu) {
        _openEditor();
        return true;
      }

      // Desktop: 3 быстрых нажатия Esc → сервисный редактор.
      // (PIN добавляет второй уровень. В release Esc не сворачивает fullscreen,
      //  поэтому серия нажатий не трогает окно — см. WindowShell в main.dart.)
      if (e.logicalKey == LogicalKeyboardKey.escape) {
        final now = DateTime.now();
        final last = _lastEscPressAt;
        if (last != null && now.difference(last) < _serviceGestureWindow) {
          _escPressCount++;
        } else {
          _escPressCount = 1;
        }
        _lastEscPressAt = now;
        if (_escPressCount >= 3 && !_isEditorOpen) {
          _escPressCount = 0;
          _openEditor();
          return true;
        }
        return false;
      }

      // Android TV remote: 5 быстрых нажатий Back → сервисный редактор
      // (защита от случайного открытия; PIN добавляет второй уровень).
      if (e.logicalKey == LogicalKeyboardKey.goBack) {
        final now = DateTime.now();
        final last = _lastBackPressAt;
        if (last != null && now.difference(last) < _serviceGestureWindow) {
          _backPressCount++;
        } else {
          _backPressCount = 1;
        }
        _lastBackPressAt = now;

        if (_backPressCount >= 5 && !_isEditorOpen) {
          _backPressCount = 0;
          _openEditor();
          return true;
        }
        // Не перехватываем — позволяем Flutter обработать Back стандартно
        return false;
      }
    }
    return false;
  }

  Future<bool> _checkPinIfRequired() async {
    final pin = Get.find<PlaylistController>().servicePin;
    if (pin.isEmpty) return true;
    final entered = await Get.dialog<String>(
      const _PinDialog(),
      barrierDismissible: false,
    );
    return entered == pin;
  }

  // ===== ДОБАВЛЕНО: методы для работы с редактором =====
  void _openEditor() async {
    if (!await _checkPinIfRequired()) return;
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

    // Сбрасываем сигнатуру оффлайн-очереди: после правок в редакторе она
    // перестроится с нуля (resume вызывает _applySchedule(force: true)).
    _offlineSignature = '';

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
      await controller.applyEffectiveDisplaySelection(force: true);

      // реагируем на обновление манифеста
      _controllerVersionWorker = ever<int>(controller.version, (_) {
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
    await controller.applyEffectiveDisplaySelection();
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
    final currentContentRevision = controller.manifest?.contentRevision ?? '';
    final contentChangedWithinSlot =
        force &&
        currentContentRevision.isNotEmpty &&
        currentContentRevision != _lastAppliedContentRevision;
    if (sameLogical) {
      if (contentChangedWithinSlot) {
        await AppLogger.log(
          'schedule content revision changed within active slot: old=$_lastAppliedContentRevision new=$currentContentRevision slot=${_slotLabel(nextSlot)}',
        );
      } else {
        final previousSlot = _currentSlot;
        _currentSlot = nextSlot;
        if (nextSlot.contentType == ManifestContentType.playlist &&
            _currentPlaylist?.id == nextSlot.contentId) {
          _currentPlaylist = controller.playlistById(nextSlot.contentId);
        } else if (nextSlot.contentType == ManifestContentType.media &&
            _currentMedia?.id == nextSlot.contentId) {
          _currentMedia =
              controller.mediaById(nextSlot.contentId) ?? _currentMedia;
        }

        _slotTimer?.cancel();
        final updatedDuration = nextSlot.endTime.difference(now);
        if (!updatedDuration.isNegative) {
          _slotTimer = Timer(
            updatedDuration,
            () => _applySchedule(force: true),
          );
        }

        await AppLogger.log(
          'schedule keep active slot: force=$force from=${_slotLabel(previousSlot)} to=${_slotLabel(nextSlot)} media=${_mediaLabel(_currentMedia)} item=${_playlistItemLabel(_currentPlaylistItem)} source=${_sourceLabel(_activeVideoSource)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
        );

        if (mounted) {
          setState(() {});
        }
        await _syncActiveVideoVolume();
        return;
      }
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
    _lastAppliedContentRevision = currentContentRevision;

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
  // ===== Оффлайн-ротация: очередь активных элементов =====
  List<PlaylistItem> _offlineQueue = [];
  int _offlineIndex = 0;
  String _offlineSignature = '';
  PlaylistItem? _lastOfflineItem;

  /// Сигнатура набора активных элементов — чтобы перезапускать очередь только
  /// когда состав/расписание реально изменились, а не на каждом тике.
  String _offlineSignatureOf(List<PlaylistItem> items) {
    return items
        .map((e) =>
            '${e.filename}|${e.startDate.toIso8601String()}|${e.stopDate?.toIso8601String() ?? "-"}|${e.loop}|${e.durationSeconds}')
        .join(',');
  }

  Future<void> _applyOfflineSchedule(
    DateTime now,
    PlaylistController controller,
    bool force,
  ) async {
    final active = controller.activeOfflineItems(now);

    if (active.isEmpty) {
      if (_offlineQueue.isNotEmpty ||
          _currentSlot != null ||
          _currentMedia != null) {
        _offlineQueue = [];
        _offlineSignature = '';
        _lastOfflineItem = null;
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

    final signature = _offlineSignatureOf(active);

    // Набор не изменился — пусть текущий элемент доигрывает.
    if (!force && signature == _offlineSignature) {
      return;
    }

    await AppLogger.log(
      'offline schedule rebuild: force=$force count=${active.length} signature_changed=${signature != _offlineSignature}',
    );
    _offlineSignature = signature;
    _offlineQueue = active;
    await _playOfflineIndex(0);
  }

  /// Воспроизводит элемент очереди по индексу (с заворачиванием по кругу).
  Future<void> _playOfflineIndex(int index) async {
    if (_isDisposed || _isEditorOpen || _offlineQueue.isEmpty) return;
    _offlineIndex = index % _offlineQueue.length;
    final item = _offlineQueue[_offlineIndex];
    _lastOfflineItem = item;

    _slotTimer?.cancel();
    _imageTimer?.cancel();

    await AppLogger.log(
      'offline play index: $_offlineIndex/${_offlineQueue.length - 1} file=${item.filename} loop=${item.loop}',
    );
    await _playOfflineItem(item);
  }

  /// Переход к следующему элементу очереди. Перед переходом пере-вычисляет
  /// активный набор — истёкшие элементы выпадают, новые подхватываются.
  Future<void> _advanceOffline() async {
    if (_isDisposed || _isEditorOpen) return;
    final controller = Get.find<PlaylistController>();
    final active = controller.activeOfflineItems(DateTime.now());
    final signature = _offlineSignatureOf(active);

    if (signature != _offlineSignature) {
      _offlineSignature = signature;
      _offlineQueue = active;
      if (active.isEmpty) {
        _lastOfflineItem = null;
        await _stopEverything();
        setState(() => _mode = _Mode.black);
        return;
      }
      await _playOfflineIndex(0);
      return;
    }

    if (_offlineQueue.isEmpty) return;
    await _playOfflineIndex(_offlineIndex + 1);
  }

  Future<void> _playOfflineItem(PlaylistItem item) async {
    final controller = Get.find<PlaylistController>(); // ← ДОБАВЛЕНО

    final cfg = await ConfigService().load();
    final mediaRoot = cfg.mediaRoot;

    // В очереди из нескольких файлов каждый элемент проигрывается один раз,
    // затем — переход к следующему (очередь крутится по кругу). Одиночный
    // зацикленный элемент играет бесконечно.
    final isMulti = _offlineQueue.length > 1;

    if (item.isImage) {
      await _stopEverything();
      final diskPath = await _getLocalMediaPath(mediaRoot, item.filename);
      setState(() {
        _mode = _Mode.image;
        _imageIsFile = diskPath != null;
        _imagePath = diskPath ?? 'assets/media/${item.filename}';
      });

      // Картинку ограничиваем по времени, если: несколько файлов в очереди,
      // либо элемент не зациклен. Иначе (одна зацикленная картинка) — навсегда.
      if (isMulti || !item.loop) {
        final now = DateTime.now();
        final left = item.stopDate?.difference(now);
        final showFor = Duration(seconds: item.durationSeconds);
        final dur = (left == null)
            ? showFor
            : (showFor < left ? showFor : left);

        _imageTimer = Timer(dur, () {
          if (_isDisposed || !controller.isOfflineMode.value) return;
          if (_offlineQueue.length > 1) {
            unawaited(_advanceOffline());
          } else {
            setState(() => _mode = _Mode.black);
          }
        });
      }

      await AppLogger.log(
        'OFFLINE: SHOW IMAGE: ${item.filename} (loop=${item.loop} multi=$isMulti)',
      );
      return;
    }

    if (item.isVideo) {
      final diskPath = await _getLocalMediaPath(mediaRoot, item.filename);
      final src = diskPath ?? 'asset:///assets/media/${item.filename}';

      // Зацикливаем на уровне плеера только одиночное видео. В очереди из
      // нескольких — видео доигрывает и отдаёт управление для перехода дальше.
      final loopSingle = !isMulti && item.loop;

      try {
        await _playVideoSource(src, loopSingle: loopSingle);

        await AppLogger.log(
          'OFFLINE: PLAY VIDEO: ${item.filename} src=$src (loop=$loopSingle multi=$isMulti)',
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

  void _cancelPreparedVideo({bool stopPlayer = true}) {
    _prepareVideoTimer?.cancel();
    _prepareVideoTimer = null;
    _prepareVideoSeq++;
    final prepared = _preparedVideo;
    _preparedVideo = null;
    _warmingVideoIndex = null;
    if (mounted) setState(() {});
    if (stopPlayer && prepared != null) {
      unawaited(_stopPlayer(prepared.playerIndex));
    }
  }

  Future<void> _stopPlayer(int playerIndex) async {
    try {
      final player = _players[playerIndex];
      await player.pause();
      await player.setPlaylistMode(PlaylistMode.none);
      await player.setVolume(0);
      await player.stop();
    } catch (_) {}
  }

  Future<void> _waitForVideoWarmup(int playerIndex) async {
    bool timedOut = false;
    final hasFrame = Stream<void>.periodic(
      const Duration(milliseconds: 50),
    ).firstWhere((_) => _playerHasRenderableFrame(playerIndex));
    await hasFrame.timeout(_videoPrepareWarmupTimeout, onTimeout: () {
      timedOut = true;
    });
    if (timedOut) {
      unawaited(AppLogger.log(
        'video warmup timeout: player=$playerIndex timeout=${_videoPrepareWarmupTimeout.inMilliseconds}ms size=${_playerSizeLabel(playerIndex)} pos=${_formatTc(_playerPositions[playerIndex])} buf=${_playerBuffers[playerIndex].inMilliseconds}ms buffering=${_playerBuffering[playerIndex]}',
      ));
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  Future<void> _openVideoOnPlayer(
    int playerIndex,
    String source, {
    required bool play,
    required PlaylistMode playlistMode,
    double volume = 0,
  }) async {
    await _videoPlayerConfiguration;
    final player = _players[playerIndex];
    _resetPlayerTraceState(playerIndex);
    await player.setPlaylistMode(playlistMode);
    await player.setVolume(play ? volume : 0);
    await player.open(Playlist([Media(source)]), play: play);
    if (!play) {
      await player.pause();
    }
  }

  Future<void> _prepareVideoOnStandby(
    String source,
    int mediaId,
    int sequence,
  ) async {
    final existing = _preparedVideo;
    if (existing != null &&
        existing.source == source &&
        existing.sequence == sequence) {
      return;
    }

    final playerIndex = _standbyVideoIndex;
    _warmingVideoIndex = playerIndex;
    if (mounted) setState(() {});
    await AppLogger.log(
      'video prepare start: source=${_sourceLabel(source)} media_id=$mediaId standby_player=$playerIndex seq=$sequence',
    );
    await _stopPlayer(playerIndex);
    await _openVideoOnPlayer(
      playerIndex,
      source,
      play: true,
      playlistMode: PlaylistMode.none,
      volume: 0,
    );
    await _waitForVideoWarmup(playerIndex);
    if (_isDisposed || sequence != _prepareVideoSeq) {
      _warmingVideoIndex = null;
      await _stopPlayer(playerIndex);
      return;
    }
    try {
      await _players[playerIndex].pause();
    } catch (_) {}
    _preparedVideo = _PreparedVideo(
      playerIndex: playerIndex,
      source: source,
      mediaId: mediaId,
      sequence: sequence,
    );
    _warmingVideoIndex = null;
    await AppLogger.log(
      'video prepare ready: source=${_sourceLabel(source)} media_id=$mediaId standby_player=$playerIndex seq=$sequence size=${_playerSizeLabel(playerIndex)}',
    );
    if (mounted) setState(() {});
  }

  Future<void> _retirePlayer(int playerIndex) async {
    await Future<void>.delayed(_videoRetireDelay);
    if (_isDisposed || playerIndex == _activeVideoIndex) return;
    await _stopPlayer(playerIndex);
  }

  Future<void> _scheduleVideoPreparation(String source, int mediaId) async {
    _cancelPreparedVideo();
    final sequence = _prepareVideoSeq;
    if (_mode != _Mode.video) {
      await AppLogger.log(
        'video prepare immediate: source=${_sourceLabel(source)} media_id=$mediaId mode=${_mode.name} standby_player=$_standbyVideoIndex seq=$sequence',
      );
      await _prepareVideoOnStandby(source, mediaId, sequence);
      return;
    }

    final duration = _playerDurations[_activeVideoIndex];
    final position = _playerPositions[_activeVideoIndex];
    final remaining = duration > position ? duration - position : Duration.zero;
    final delay = duration <= Duration.zero || remaining <= _videoPrepareLead
        ? Duration.zero
        : remaining - _videoPrepareLead;

    await AppLogger.log(
      'video prepare scheduled: source=${_sourceLabel(source)} media_id=$mediaId delay=${delay.inMilliseconds}ms remaining=${remaining.inMilliseconds}ms active_player=$_activeVideoIndex standby_player=$_standbyVideoIndex seq=$sequence',
    );

    if (delay == Duration.zero) {
      await _prepareVideoOnStandby(source, mediaId, sequence);
      return;
    }

    _prepareVideoTimer = Timer(delay, () {
      unawaited(_prepareVideoOnStandby(source, mediaId, sequence));
    });
  }

  Future<void> _playVideoSource(
    String source, {
    required bool loopSingle,
  }) async {
    await AppLogger.log(
      'video source request: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} loop_single=$loopSingle active_player=$_activeVideoIndex',
    );

    final prepared = _preparedVideo;
    if (prepared != null && prepared.source == source) {
      final previousActive = _activeVideoIndex;
      _preparedVideo = null;
      _warmingVideoIndex = null;
      _prepareVideoTimer?.cancel();
      _prepareVideoTimer = null;
      _activeVideoIndex = prepared.playerIndex;
      _activeVideoSource = source;
      await _players[_activeVideoIndex].setPlaylistMode(
        loopSingle ? PlaylistMode.single : PlaylistMode.none,
      );
      await _players[_activeVideoIndex].setVolume(_effectiveVideoVolume);
      _lastAppliedVideoVolume = _effectiveVideoVolume;
      await _players[_activeVideoIndex].play();
      _expectVideoCompleted = !loopSingle;
      _startPlaybackTraceTimer();
      await AppLogger.log(
        'video activate prepared: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} player=$_activeVideoIndex prev_player=$previousActive loop_single=$loopSingle media_id=${prepared.mediaId}',
      );
      if (mounted) setState(() => _mode = _Mode.video);
      unawaited(_retirePlayer(previousActive));
      return;
    }

    _cancelPreparedVideo();

    if (_mode == _Mode.video && _activeVideoSource != null) {
      final previousActive = _activeVideoIndex;
      final nextPlayer = _standbyVideoIndex;
      _warmingVideoIndex = nextPlayer;
      if (mounted) setState(() {});
      await AppLogger.log(
        'video transition warmup: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} standby_player=$nextPlayer prev_player=$previousActive loop_single=$loopSingle',
      );
      await _stopPlayer(nextPlayer);
      await _openVideoOnPlayer(
        nextPlayer,
        source,
        play: true,
        playlistMode: loopSingle ? PlaylistMode.single : PlaylistMode.none,
        volume: 0,
      );
      await _waitForVideoWarmup(nextPlayer);
      if (_isDisposed) return;
      await _players[nextPlayer].setVolume(_effectiveVideoVolume);
      _lastAppliedVideoVolume = _effectiveVideoVolume;
      _activeVideoIndex = nextPlayer;
      _activeVideoSource = source;
      _warmingVideoIndex = null;
      _expectVideoCompleted = !loopSingle;
      _startPlaybackTraceTimer();
      await AppLogger.log(
        'video transition active: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} player=$_activeVideoIndex prev_player=$previousActive loop_single=$loopSingle size=${_playerSizeLabel(_activeVideoIndex)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
      );
      if (mounted) setState(() => _mode = _Mode.video);
      unawaited(_retirePlayer(previousActive));
      return;
    }

    await _openVideoOnPlayer(
      _activeVideoIndex,
      source,
      play: true,
      playlistMode: loopSingle ? PlaylistMode.single : PlaylistMode.none,
      volume: _effectiveVideoVolume,
    );
    await _waitForVideoWarmup(_activeVideoIndex);
    if (_isDisposed) return;
    _lastAppliedVideoVolume = _effectiveVideoVolume;
    _activeVideoSource = source;
    _expectVideoCompleted = !loopSingle;
    _startPlaybackTraceTimer();
    await AppLogger.log(
      'video active: trace=$_activePlaybackTraceId source=${_sourceLabel(source)} player=$_activeVideoIndex loop_single=$loopSingle size=${_playerSizeLabel(_activeVideoIndex)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
    );
    if (mounted) setState(() => _mode = _Mode.video);
  }

  Future<void> _stopEverything() async {
    _imageTimer?.cancel();
    _cancelPreparedVideo();
    _expectVideoCompleted = false;
    if (_mode == _Mode.video || _activeVideoSource != null) {
      await AppLogger.log(
        'stop playback: trace=$_activePlaybackTraceId active_source=${_sourceLabel(_activeVideoSource)} tc=${_tcLabel(_playerPositions[_activeVideoIndex], _playerDurations[_activeVideoIndex])}',
      );
    }
    _stopPlaybackTraceTimer();
    _activeVideoSource = null;
    _lastAppliedVideoVolume = -1;
    _lastAppliedContentRevision = '';
    for (var i = 0; i < _players.length; i++) {
      await _stopPlayer(i);
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
      _imageTimer?.cancel();
      _activePlaybackTraceId = ++_playbackTraceSeq;
      _lastPlaybackTraceSecond = -1;
      _playbackTraceStallLogged = false;
      await AppLogger.log(
        'playback trace start: trace=$_activePlaybackTraceId context=${context.name} slot=${_slotLabel(slotContext)} item=${_playlistItemLabel(_currentPlaylistItem)} media=${_mediaLabel(media)} file=${_sourceLabel(file.path)}',
      );
      try {
        await _playVideoSource(
          file.path,
          loopSingle:
              context == _PlaybackContext.slotMedia &&
              slotContext.loopMode == ManifestLoopMode.fill,
        );
        await AppLogger.log(
          'PLAY VIDEO: ${media.safeBaseName} trace=$_activePlaybackTraceId src=${file.path} slot=${_slotLabel(slotContext)} item=${_playlistItemLabel(_currentPlaylistItem)}',
        );
      } catch (e) {
        _expectVideoCompleted = false;
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
      // Несколько файлов в очереди — переходим к следующему по кругу.
      if (_offlineQueue.length > 1) {
        await _advanceOffline();
        return;
      }

      final item = _lastOfflineItem;
      if (item == null) return;

      // Одиночный незациклённый элемент — чёрный экран.
      if (!item.loop) {
        setState(() => _mode = _Mode.black);
        return;
      }

      // Одиночный зациклённый и ещё в пределах времени - перезапускаем.
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

    if (_context == _PlaybackContext.playlistItem) {
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
          'prepare upcoming skip: reached playlist end without loop playlist=${playlist.id}:${playlist.name}',
        );
        _cancelPreparedVideo();
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
      _cancelPreparedVideo();
      return;
    }

    if (media.isImage) {
      _cancelPreparedVideo();
      await AppLogger.log(
        'prepare upcoming image: item=${_playlistItemLabel(item)} media=${_mediaLabel(media)}',
      );
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
        return;
      }
      await AppLogger.log(
        'prepare upcoming video file ready: item=${_playlistItemLabel(item)} media=${_mediaLabel(media)} file=${_sourceLabel(file.path)}',
      );
      await _scheduleVideoPreparation(file.path, media.id);
      return;
    }

    _cancelPreparedVideo();
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
    final warmupVideoIndex = _preparedVideo?.playerIndex ?? _warmingVideoIndex;
    final rotationQuarterTurns =
        Get.find<PlaylistController>().effectiveDisplayRotation ~/ 90;
    final mediaSurface = Stack(
      fit: StackFit.expand,
      children: [
        if (_mode == _Mode.image && _imagePath.isNotEmpty) _buildImageView(),
        for (var i = 0; i < _videoControllers.length; i++)
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: _mode == _Mode.video && i == _activeVideoIndex
                    ? 1
                    : i == warmupVideoIndex
                    ? 0.001
                    : 0,
                child: RepaintBoundary(
                  child: Video(
                    controller: _videoControllers[i],
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    return Scaffold(
      backgroundColor: Colors.black,
      // Перехват серии тапов по экрану → вход в сервисный редактор
      // (для тач-устройств без клавиатуры/пульта). translucent не мешает плееру.
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _handleServiceTap(),
        child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: RotatedBox(
              quarterTurns: rotationQuarterTurns,
              child: mediaSurface,
            ),
          ),

          // Buffering indicator - small spinner in bottom-right when video is buffering
          if (_mode == _Mode.video && _playerBuffering[_activeVideoIndex])
            Positioned(
              right: 16,
              bottom: 16,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(10),
                child: const CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              ),
            ),
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
    _prepareVideoTimer?.cancel();
    _controllerVersionWorker?.dispose();
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

class _PinDialog extends StatefulWidget {
  const _PinDialog();

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  static const Duration _idleTimeout = Duration(seconds: 30);

  final _controller = TextEditingController();
  bool _obscure = true;
  String? _error;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    _resetIdle();
  }

  /// Сбрасывает таймер бездействия. По истечении 30 c без действий диалог
  /// сам закрывается (без результата — редактор не открывается).
  void _resetIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, () {
      if (mounted) Get.back<String>();
    });
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      _resetIdle();
      setState(() => _error = 'Введите PIN-код');
      return;
    }
    _idleTimer?.cancel();
    Get.back(result: value);
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _resetIdle(),
      child: AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_outline, size: 20),
          SizedBox(width: 8),
          Text('Сервисный доступ'),
        ],
      ),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Для входа в редактор введите PIN-код.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              obscureText: _obscure,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'PIN-код',
                border: const OutlineInputBorder(),
                errorText: _error,
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                _resetIdle();
                if (_error != null) setState(() => _error = null);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back<String>(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Войти'),
        ),
      ],
      ),
    );
  }
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
