import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../controllers/playlist_controller.dart';
import '../models/manifest.dart';
import '../services/app_logger.dart';

enum _Mode { image, video, black }
enum _PlaybackContext { slotMedia, playlistItem }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;

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

  // completed на Windows может быть “шумным”, реагируем только если это видео и мы его ждём
  bool _expectVideoCompleted = false;

  // debug overlay
  bool _debug = true; // можешь поставить false по умолчанию

  Widget _buildImageView() {
    final imageKey = ValueKey(_imagePath);
    if (_imageIsFile) {
      return Image.file(
        File(_imagePath),
        key: imageKey,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, e, __) => const Center(
          child: Text('Ошибка загрузки изображения (file)', style: TextStyle(color: Colors.white)),
        ),
      );
    }
    return Image.asset(
      _imagePath,
      key: imageKey,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, e, __) => const Center(
        child: Text('Ошибка загрузки изображения (asset)', style: TextStyle(color: Colors.white)),
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    _player = Player();
    _videoController = VideoController(_player);

    _player.stream.error.listen((e) => unawaited(AppLogger.log('media_kit error: $e')));

    _player.stream.completed.listen((_) {
      if (_isDisposed) return;
      if (!_expectVideoCompleted) return;
      if (_mode != _Mode.video) return;

      _expectVideoCompleted = false;
      _onVideoCompleted();
    });

    // F12 — toggle debug overlay (на Windows удобно)
    HardwareKeyboard.instance.addHandler(_onKey);

    _boot();
  }

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.f12) {
      setState(() => _debug = !_debug);
      return true;
    }
    return false;
  }

  Future<void> _boot() async {
    try {
      final controller = Get.find<PlaylistController>();

      // реагируем на обновление манифеста
      ever<int>(controller.version, (_) => _applySchedule(force: true));

      setState(() => _initialized = true);

      await _applySchedule(force: true);

      _tick = Timer.periodic(const Duration(seconds: 1), (_) => _applySchedule());
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
    if (_isDisposed) return;

    final controller = Get.find<PlaylistController>();
    final now = DateTime.now();

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
      await _playMedia(media, context: _PlaybackContext.slotMedia, slotContext: nextSlot);
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

  Future<void> _stopEverything() async {
    _imageTimer?.cancel();
    _expectVideoCompleted = false;
    try {
      await _player.pause();
      await _player.setVolume(0);
      await _player.stop();
    } catch (_) {}
  }

  Future<void> _playMedia(
    ManifestMedia media, {
    required _PlaybackContext context,
    required ManifestItem slotContext,
  }) async {
    await _stopEverything();

    final controller = Get.find<PlaylistController>();
    final file = await controller.ensureMediaFile(media);
    if (file == null) {
      setState(() => _mode = _Mode.black);
      return;
    }
    if (!_isSameSlot(_currentSlot, slotContext)) return;

    _context = context;
    _currentMedia = media;

    if (media.isImage) {
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
      setState(() => _mode = _Mode.video);

      try {
        await _player.setVolume(100);
        await _player.open(Playlist([Media(file.path)]), play: true);
        _expectVideoCompleted = true;
        await AppLogger.log('PLAY VIDEO: ${media.safeBaseName} src=${file.path}');
      } catch (e) {
        _expectVideoCompleted = false;
        await AppLogger.log('VIDEO OPEN FAILED: ${media.safeBaseName} error=$e');
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
    if (_context == _PlaybackContext.playlistItem) {
      _onPlaylistItemCompleted();
      return;
    }

    final slot = _currentSlot;
    final media = _currentMedia;
    if (slot == null || media == null) return;

    if (slot.loopMode == ManifestLoopMode.fill && slot.isActiveAt(DateTime.now())) {
      try {
        _expectVideoCompleted = true;
        await _player.seek(Duration.zero);
        await _player.play();
        return;
      } catch (_) {
        await _playMedia(media, context: _PlaybackContext.slotMedia, slotContext: slot);
        return;
      }
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
      await _playMedia(media, context: _PlaybackContext.playlistItem, slotContext: slot);
      _precacheNextPlaylistImage(playlist, i);
      return;
    }

    setState(() => _mode = _Mode.black);
  }

  void _onPlaylistItemCompleted() {
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

  Future<void> _precacheNextPlaylistImage(ManifestPlaylist playlist, int fromIndex) async {
    if (!mounted) return;
    final controller = Get.find<PlaylistController>();
    for (int i = fromIndex + 1; i < playlist.items.length; i++) {
      final item = playlist.items[i];
      final media = controller.mediaById(item.mediaId);
      if (media == null || !media.isImage) continue;
      final file = await controller.ensureMediaFile(media);
      if (file == null || !mounted) return;
      await precacheImage(FileImage(file), context);
      return;
    }
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
            child: _mode == _Mode.image && _imagePath.isNotEmpty
                ? _buildImageView()
                : _mode == _Mode.video
                    ? Video(controller: _videoController, fit: BoxFit.contain)
                    : const SizedBox.shrink(),
          ),

          if (_debug)
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                color: Colors.black54,
                child: Text(
                  'now=${DateTime.now()}\n'
                      'mode=$_mode\n'
                      'slot=${slot == null ? "-" : slot.contentType.name}:${slot?.contentId}\n'
                      'start=${slot?.startTime}\n'
                      'stop=${slot?.endTime}\n'
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
    _player.dispose();
    super.dispose();
  }
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
