// lib/views/player_screen.dart
import 'dart:io';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../controllers/playlist_controller.dart';
import '../models/playlist_item.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late Player _player;
  late VideoController _videoController;
  List<PlaylistItem> _activeItems = [];
  int _currentIndex = 0;
  bool _initialized = false;
  bool _isDisposed = false; // ← ДОБАВЬ ЭТУ СТРОКУ

  @override
  void initState() {
    super.initState();
    _player = Player();
    _player.stream.error.listen((error) {
      debugPrint('❌ ОШИБКА воспроизведения: $error');
    });

    _player.stream.buffering.listen((buffering) {
      debugPrint('🔄 Буферизация: $buffering');
    });

    _player.stream.playing.listen((playing) {
      debugPrint('▶️ Воспроизведение: $playing');
    });

    _player.stream.completed.listen((_) {
      debugPrint('✅ Видео завершено');
    });
    _videoController = VideoController(_player); // ← принимает Player
    _loadActiveItems();
  }

  Future<void> _loadActiveItems() async {
    final controller = Get.find<PlaylistController>();
    final items = controller.activeItems;

    if (items.isEmpty) {
      setState(() {
        _activeItems = [];
      });
      return;
    }

    final resolvedItems = await _resolveMediaPaths(items);

    setState(() {
      _activeItems = resolvedItems;
      _currentIndex = 0;
      _initialized = true;
    });

    if (_activeItems.isNotEmpty) {
      _playItem(0);
    }
  }

  Future<List<PlaylistItem>> _resolveMediaPaths(List<PlaylistItem> items) async {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      return items;
    }

    final cacheDir = await getTemporaryDirectory();
    final List<PlaylistItem> resolved = [];

    for (var item in items) {
      final fileName = path.basename(item.filename);
      final targetPath = path.join(cacheDir.path, fileName);

      if (!await File(targetPath).exists()) {
        final data = await rootBundle.load(item.fullPath);
        await File(targetPath).writeAsBytes(data.buffer.asUint8List());
      }
      debugPrint('Копируем из assets: ${item.fullPath} → $targetPath');
      debugPrint('Файл существует: ${await File(targetPath).exists()}');

      resolved.add(
        PlaylistItem(
          filename: targetPath,
          startDate: item.startDate,
          loop: item.loop,
        ),
      );
    }

    return resolved;
  }

  Future<void> _playItem(int index) async {
    if (_isDisposed) return;
    if (_activeItems.isEmpty) return;

    if (index >= _activeItems.length) {
      if (_activeItems.any((item) => item.loop)) {
        index = 0;
      } else {
        return;
      }
    }

    setState(() {
      _currentIndex = index;
    });

    final item = _activeItems[index];

    if (item.isImage) {
      // Если предыдущий элемент был видео — сбросить плеер
      if (_activeItems.isNotEmpty && _currentIndex > 0) {
        final prev = _activeItems[_currentIndex - 1];
        if (prev.isVideo) {
          _player.stop(); // ← остановить воспроизведение
          // Можно даже временно уничтожить и создать новый Player, но это избыточно
        }
      }
      Future.delayed(const Duration(seconds: 5), () {
        if (!_isDisposed) _nextItem();
      });
    } else if (item.isVideo) {
      // 🔥 Проверяем, что файл существует
      final file = File(item.filename);
      if (!await file.exists()) {
        debugPrint('❌ Файл не найден: ${file.path}');
        if (!_isDisposed) _nextItem();
        return;
      }

      // 🔥 Используем Playlist даже для одного файла — ОБЯЗАТЕЛЬНО
      final playlist = Playlist([
        Media(item.filename), // ← Просто путь, НЕ URI!
      ]);

      try {
        await _player.open(playlist, play: false);
        await _player.seek(Duration.zero);
        if (!_isDisposed) {
          await _player.play();
        }
      } catch (e) {
        debugPrint('❌ Ошибка воспроизведения: $e');
        if (!_isDisposed) _nextItem();
      }

      // Подписка на завершение
      _player.stream.completed.listen((_) {
        if (!_isDisposed) {
          debugPrint('✅ Видео завершено: ${item.filename}');
          _nextItem();
        }
      });
    }
  }

  void _nextItem() {
    final currentItem = _activeItems[_currentIndex];
    if (currentItem.loop) {
      _playItem((_currentIndex + 1) % _activeItems.length);
    } else {
      _playItem(_currentIndex + 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_activeItems.isEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.schedule, size: 64, color: Colors.white70),
              SizedBox(height: 16),
              Text(
                'Нет активных медиа-элементов',
                style: TextStyle(color: Colors.white70, fontSize: 18),
              ),
            ],
          ),
        ),
      );
    }

    final item = _activeItems[_currentIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (item.isImage)
            Image.file(
              File(item.filename),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => const Center(
                child: Text('Ошибка загрузки изображения', style: TextStyle(color: Colors.white)),
              ),
            )
          else
          // ✅ НЕТ параметра controls — они отключены по умолчанию
            Video(
              controller: _videoController,
              fit: BoxFit.contain,
            ),
          Positioned(
            top: 24,
            left: 16,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Get.back(),
                padding: const EdgeInsets.all(8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _isDisposed = true; // ← Установи перед dispose
    _player.dispose();
    super.dispose();
  }
}