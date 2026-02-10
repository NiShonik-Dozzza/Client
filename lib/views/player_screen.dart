// lib/views/player_screen.dart
import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as path;

import '../controllers/playlist_controller.dart';
import '../models/playlist_item.dart';

enum _Mode { image, video, none }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // ✅ ТВОЯ ПАПКА С ЛОКАЛЬНЫМИ МЕДИА НА WINDOWS
  static const String windowsMediaDir =
      r'C:\Users\NNGASU\Desktop\Client-main\assets\media';

  late final Player _player;
  late final VideoController _videoController;

  List<PlaylistItem> _activeItems = [];
  int _currentIndex = 0;

  bool _initialized = false;
  bool _isDisposed = false;

  Timer? _imageTimer;

  _Mode _mode = _Mode.none;

  // Для картинки:
  bool _imageIsFile = false;
  String _imagePathOrAsset = '';

  // ✅ ВАЖНО:
  // completed может прилетать от stop()/reset. Реагируем на completed
  // только если мы реально запустили видео и ожидаем его конец.
  bool _expectVideoCompletion = false;

  // “Токен” текущего проигрывания, чтобы старые события не ломали очередь.
  int _playSeq = 0;
  int _currentVideoSeq = -1;

  @override
  void initState() {
    super.initState();

    _player = Player();
    _videoController = VideoController(_player);

    _player.stream.error.listen((e) => debugPrint('❌ media_kit error: $e'));

    _player.stream.completed.listen((_) {
      debugPrint(
        '✅ completed (expect=$_expectVideoCompletion, mode=$_mode, seq=$_currentVideoSeq)',
      );

      // Игнорируем “левые” completed (stop/reset/и т.д.)
      if (!_expectVideoCompletion) return;
      if (_mode != _Mode.video) return;

      // Чтобы не было дублей
      _expectVideoCompletion = false;

      if (!_isDisposed) _nextItem();
    });

    _loadActiveItems();
  }

  Future<void> _loadActiveItems() async {
    try {
      final controller = Get.find<PlaylistController>();

      // Плейлист может грузиться в onInit контроллера,
      // но на всякий случай дождёмся.
      if (controller.items.isEmpty) {
        await controller.loadPlaylist();
      }
      while (controller.isLoading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      final items = controller.activeItems;

      setState(() {
        _activeItems = items;
        _currentIndex = 0;
        _initialized = true;
      });

      if (_activeItems.isNotEmpty) {
        await _playItem(0);
      }
    } catch (e) {
      debugPrint('❌ _loadActiveItems error: $e');
      setState(() {
        _activeItems = [];
        _initialized = true;
      });
    }
  }

  bool _isAbsPath(String p) {
    if (p.startsWith('/')) return true;
    if (p.length >= 3 && p[1] == ':' && (p[2] == '\\' || p[2] == '/')) return true;
    return false;
  }

  Future<String?> _resolveDiskPathIfAny(String filename) async {
    final name = path.basename(filename);

    if (_isAbsPath(filename)) {
      final f = File(filename);
      if (await f.exists()) return f.path;
      return null;
    }

    if (!kIsWeb && Platform.isWindows) {
      final p = path.join(windowsMediaDir, name);
      final f = File(p);
      if (await f.exists()) return f.path;
      return null;
    }

    return null;
  }

  Future<void> _playItem(int index) async {
    if (_isDisposed) return;
    if (_activeItems.isEmpty) return;

    _imageTimer?.cancel();

    if (index >= _activeItems.length) index = 0;
    if (index < 0) index = 0;

    // Новый токен запуска
    final int seq = ++_playSeq;

    setState(() {
      _currentIndex = index;
      _mode = _Mode.none;
      _imageIsFile = false;
      _imagePathOrAsset = '';
    });

    final item = _activeItems[_currentIndex];
    final name = path.basename(item.filename);

    debugPrint('▶️ PLAY seq=$seq idx=$_currentIndex file=${item.filename} (name=$name)');

    // Любой переход в новый item сбрасывает ожидание video completed
    _expectVideoCompletion = false;
    _currentVideoSeq = -1;

    if (item.isImage) {
      // Глушим звук и останавливаем видео (completed от stop будет проигнорирован)
      try {
        await _player.pause();
        await _player.setVolume(0);
        await _player.stop();
      } catch (_) {}

      final diskPath = await _resolveDiskPathIfAny(item.filename);
      if (diskPath != null) {
        debugPrint('🖼 IMAGE source = FILE: $diskPath');
        setState(() {
          _mode = _Mode.image;
          _imageIsFile = true;
          _imagePathOrAsset = diskPath;
        });
      } else {
        debugPrint('🖼 IMAGE source = ASSET: ${item.fullPath}');
        setState(() {
          _mode = _Mode.image;
          _imageIsFile = false;
          _imagePathOrAsset = item.fullPath;
        });
      }

      _imageTimer = Timer(Duration(seconds: item.durationSeconds), () {
        if (!_isDisposed) _nextItem();
      });
      return;
    }

    if (item.isVideo) {
      // На видео включаем звук обратно
      try {
        await _player.setVolume(100);
      } catch (_) {}

      // ВАЖНО: stop делаем ДО того, как начнём “ожидать completed”
      try {
        await _player.stop();
      } catch (_) {}

      setState(() {
        _mode = _Mode.video;
      });

      // 1) Пытаемся открыть файл с диска
      final diskPath = await _resolveDiskPathIfAny(item.filename);
      if (diskPath != null) {
        try {
          debugPrint('🎬 VIDEO source = FILE: $diskPath');

          await _player.open(Playlist([Media(diskPath)]), play: true);

          // ✅ Только ПОСЛЕ успешного open/play начинаем ждать completed
          _currentVideoSeq = seq;
          _expectVideoCompletion = true;

          return;
        } catch (e) {
          debugPrint('❌ video open (disk) failed: $e');
        }
      } else {
        debugPrint('⚠️ video not found on disk: $name');
      }

      // 2) fallback на asset
      final assetUri = 'asset:///${item.fullPath}';
      try {
        debugPrint('🎬 VIDEO source = ASSET: $assetUri');

        await _player.open(Playlist([Media(assetUri)]), play: true);

        _currentVideoSeq = seq;
        _expectVideoCompletion = true;

        return;
      } catch (e) {
        debugPrint('❌ video open (asset) failed: $e');
      }

      debugPrint('⚠️ skip video: ${item.filename}');
      if (!_isDisposed) _nextItem();
      return;
    }

    debugPrint('⚠️ unsupported file type: ${item.filename}');
    _nextItem();
  }

  void _nextItem() {
    if (_activeItems.isEmpty) return;

    final current = _activeItems[_currentIndex];

    // loop=true -> повтор текущего
    // loop=false -> следующий
    if (current.loop) {
      _playItem(_currentIndex);
    } else {
      _playItem(_currentIndex + 1);
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

    if (_activeItems.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'Нет активных медиа-элементов',
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
        ),
      );
    }

    final item = _activeItems[_currentIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_mode == _Mode.image)
            _imageIsFile
                ? Image.file(
              File(_imagePathOrAsset),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) {
                debugPrint('❌ IMAGE FILE LOAD ERROR: $error');
                Future.microtask(() {
                  if (!_isDisposed) _nextItem();
                });
                return const Center(
                  child: Text(
                    'Ошибка загрузки изображения (file)',
                    style: TextStyle(color: Colors.white),
                  ),
                );
              },
            )
                : Image.asset(
              _imagePathOrAsset,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) {
                debugPrint('❌ IMAGE ASSET LOAD ERROR: $error');
                Future.microtask(() {
                  if (!_isDisposed) _nextItem();
                });
                return const Center(
                  child: Text(
                    'Ошибка загрузки изображения (asset)',
                    style: TextStyle(color: Colors.white),
                  ),
                );
              },
            )
          else
            Video(
              controller: _videoController,
              fit: BoxFit.contain,
            ),

          Positioned(
            left: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: Colors.black54,
              child: Text(
                '${_currentIndex + 1}/${_activeItems.length} • ${item.filename}\n'
                    'mode=$_mode expect=$_expectVideoCompletion seq=$_currentVideoSeq',
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
    _imageTimer?.cancel();
    _player.dispose();
    super.dispose();
  }
}
