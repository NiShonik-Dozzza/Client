import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../controllers/playlist_controller.dart';
import '../models/playlist_item.dart';
import '../services/app_logger.dart';
import '../services/config_service.dart';

enum _Mode { image, video, black }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;

  final _cfg = ConfigService();

  Timer? _tick;       // проверяем расписание
  Timer? _stopTimer;  // точный переход на stop_date
  Timer? _imageOnceTimer;

  bool _initialized = false;
  bool _isDisposed = false;

  PlaylistItem? _current;
  _Mode _mode = _Mode.black;

  // картинка
  bool _imageIsFile = false;
  String _imagePath = '';

  // completed на Windows может быть “шумным”, реагируем только если это видео и мы его ждём
  bool _expectVideoCompleted = false;

  // debug overlay
  bool _debug = true; // можешь поставить false по умолчанию

  @override
  void initState() {
    super.initState();

    _player = Player();
    _videoController = VideoController(_player);

    _player.stream.error.listen((e) => AppLogger.log('media_kit error: $e'));

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
      await _cfg.load();

      // реагируем на hot reload плейлиста
      ever<int>(controller.version, (_) => _applySchedule());

      setState(() => _initialized = true);

      await _applySchedule();

      _tick = Timer.periodic(const Duration(seconds: 1), (_) => _applySchedule());
    } catch (e) {
      await AppLogger.log('boot error: $e');
      setState(() => _initialized = true);
    }
  }

  Future<String?> _diskPathIfExists(String mediaRoot, String filename) async {
    if (kIsWeb) return null;

    final name = p.basename(filename);

    // если filename абсолютный — используем его
    if (p.isAbsolute(filename)) {
      final f = File(filename);
      return (await f.exists()) ? f.path : null;
    }

    final full = ConfigService.joinMedia(mediaRoot, name);
    final f = File(full);
    return (await f.exists()) ? f.path : null;
  }

  String _assetImagePath(String filename) => 'assets/media/${p.basename(filename)}';
  String _assetMediaUri(String filename) => 'asset:///assets/media/${p.basename(filename)}';

  Future<void> _applySchedule() async {
    if (_isDisposed) return;

    final controller = Get.find<PlaylistController>();
    final now = DateTime.now();

    final next = controller.currentItem(now);

    // нет активного элемента
    if (next == null) {
      if (_current != null) {
        await _stopEverything();
        setState(() {
          _current = null;
          _mode = _Mode.black;
        });
      }
      return;
    }

    // если тот же элемент — ничего не делаем
    final same = _current != null &&
        _current!.filename == next.filename &&
        _current!.startDate == next.startDate &&
        _current!.stopDate == next.stopDate;

    if (same) return;

    _current = next;

    // ставим таймер на stop_date (если есть)
    _stopTimer?.cancel();
    if (next.stopDate != null) {
      final dur = next.stopDate!.difference(now);
      if (!dur.isNegative) {
        _stopTimer = Timer(dur, () => _applySchedule());
      }
    }

    await _playCurrent(next);
  }

  Future<void> _stopEverything() async {
    _imageOnceTimer?.cancel();
    _expectVideoCompleted = false;
    try {
      await _player.pause();
      await _player.setVolume(0);
      await _player.stop();
    } catch (_) {}
  }

  Future<void> _playCurrent(PlaylistItem item) async {
    await _stopEverything();

    final cfg = await _cfg.load();
    final mediaRoot = cfg.mediaRoot;

    if (item.isImage) {
      final disk = await _diskPathIfExists(mediaRoot, item.filename);
      setState(() {
        _mode = _Mode.image;
        _imageIsFile = disk != null;
        _imagePath = disk ?? _assetImagePath(item.filename);
      });

      // loop=false: показать один раз durationSeconds, потом чёрный до смены расписания
      if (!item.loop) {
        final now = DateTime.now();
        final left = item.stopDate == null ? null : item.stopDate!.difference(now);
        final showFor = Duration(seconds: item.durationSeconds);
        final dur = (left == null) ? showFor : (showFor < left ? showFor : left);

        _imageOnceTimer = Timer(dur, () {
          if (_isDisposed) return;
          setState(() => _mode = _Mode.black);
        });
      }

      await AppLogger.log('SHOW IMAGE: ${item.filename} (loop=${item.loop})');
      return;
    }

    if (item.isVideo) {
      setState(() => _mode = _Mode.video);

      final disk = await _diskPathIfExists(mediaRoot, item.filename);
      final src = disk ?? _assetMediaUri(item.filename);

      try {
        await _player.setVolume(100);
        await _player.open(Playlist([Media(src)]), play: true);

        // ждём completed только после успешного open
        _expectVideoCompleted = true;

        await AppLogger.log('PLAY VIDEO: ${item.filename} src=$src (loop=${item.loop})');
      } catch (e) {
        _expectVideoCompleted = false;
        await AppLogger.log('VIDEO OPEN FAILED: ${item.filename} error=$e');
        setState(() => _mode = _Mode.black);
      }
      return;
    }

    // неизвестный формат
    setState(() => _mode = _Mode.black);
    await AppLogger.log('UNSUPPORTED: ${item.filename}');
  }

  void _onVideoCompleted() {
    final item = _current;
    if (item == null) return;

    // loop=false → после окончания видео чёрный экран до смены расписания
    if (!item.loop) {
      setState(() => _mode = _Mode.black);
      return;
    }

    // loop=true → если мы всё ещё внутри окна, перезапускаем
    final now = DateTime.now();
    final stillInWindow = item.stopDate == null ? true : now.isBefore(item.stopDate!);
    if (stillInWindow) {
      _playCurrent(item); // перезапуск этого же видео
    } else {
      setState(() => _mode = _Mode.black);
      _applySchedule();
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

    final item = _current;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_mode == _Mode.image && item != null)
            _imageIsFile
                ? Image.file(
              File(_imagePath),
              fit: BoxFit.contain,
              errorBuilder: (_, e, __) => const Center(
                child: Text('Ошибка загрузки изображения (file)', style: TextStyle(color: Colors.white)),
              ),
            )
                : Image.asset(
              _imagePath,
              fit: BoxFit.contain,
              errorBuilder: (_, e, __) => const Center(
                child: Text('Ошибка загрузки изображения (asset)', style: TextStyle(color: Colors.white)),
              ),
            )
          else if (_mode == _Mode.video)
            Video(controller: _videoController, fit: BoxFit.contain)
          else
            const SizedBox.shrink(),

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
                      'item=${item?.filename ?? "-"}\n'
                      'start=${item?.startDate}\n'
                      'stop=${item?.stopDate}\n'
                      'loop=${item?.loop}\n'
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
    _stopTimer?.cancel();
    _imageOnceTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _player.dispose();
    super.dispose();
  }
}
