import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../models/playlist_item.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _videoController;

  List<PlaylistItem> _items = [];
  int _index = 0;

  // Таймер для показа изображений
  Timer? _imageTimer;

  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _player = Player();
    _videoController = VideoController(_player);

    // Логи ошибок (полезно на устройствах)
    _player.stream.error.listen((e) => debugPrint('media_kit error: $e'));
    _player.stream.completed.listen((_) => _onVideoCompleted());

    _boot();
  }

  Future<void> _boot() async {
    try {
      // На всякий случай поддерживаем fullscreen даже если ОС попыталась вернуть панели
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

      final playlist = await _loadPlaylist();
      final active = _filterActive(playlist);

      if (active.isEmpty) {
        setState(() {
          _items = [];
          _ready = true;
          _error = 'Плейлист пуст или нет активных элементов по start_date';
        });
        return;
      }

      setState(() {
        _items = active;
        _index = 0;
        _ready = true;
        _error = null;
      });

      await _playCurrent();
    } catch (e) {
      setState(() {
        _ready = true;
        _error = 'Ошибка запуска плеера: $e';
      });
    }
  }

  /// 1) Пытаемся прочитать playlist.json из Documents.
  /// 2) Если его нет — читаем из assets (дефолтный).
  Future<List<PlaylistItem>> _loadPlaylist() async {
    final docs = await getApplicationDocumentsDirectory();
    final file = File('${docs.path}/playlist.json');

    String jsonString;
    if (await file.exists()) {
      jsonString = await file.readAsString();
      debugPrint('playlist loaded from Documents: ${file.path}');
    } else {
      jsonString = await rootBundle.loadString('assets/playlist.json');
      debugPrint('playlist loaded from assets');
    }

    final list = (json.decode(jsonString) as List)
        .cast<Map<String, dynamic>>()
        .map(PlaylistItem.fromJson)
        .toList();

    return list;
  }

  /// Оставляем только элементы, у которых startDate <= сейчас.
  List<PlaylistItem> _filterActive(List<PlaylistItem> items) {
    final now = DateTime.now();
    final active = items.where((i) => !i.startDate.isAfter(now)).toList();

    // Чтобы воспроизведение было предсказуемым — сортируем по startDate, затем по имени файла
    active.sort((a, b) {
      final d = a.startDate.compareTo(b.startDate);
      if (d != 0) return d;
      return a.filename.compareTo(b.filename);
    });

    return active;
  }

  Future<void> _playCurrent() async {
    _imageTimer?.cancel();

    if (_items.isEmpty) return;

    final item = _items[_index];

    // Вычисляем реальный источник (Documents/media или assets/media)
    final source = await _resolveMedia(item.filename);

    if (item.isVideo) {
      // Видео: открываем и играем
      await _player.open(source, play: true);
      return;
    }

    if (item.isImage) {
      // Картинка: просто показываем в UI, а переключение таймером
      setState(() {}); // чтобы UI обновился и показал картинку

      _imageTimer = Timer(Duration(seconds: item.durationSeconds), () {
        _nextOrLoop(item);
      });
      return;
    }

    // Неизвестный формат — пропускаем
    debugPrint('Unsupported media type: ${item.filename}');
    _nextOrLoop(item);
  }

  /// Если файл есть в Documents/media — берём его.
  /// Иначе — используем asset:///assets/media/<filename>
  Future<Media> _resolveMedia(String filename) async {
    final docs = await getApplicationDocumentsDirectory();
    final diskPath = '${docs.path}/media/$filename';
    final diskFile = File(diskPath);

    if (await diskFile.exists()) {
      return Media(diskFile.path);
    }

    // media_kit понимает asset:///...
    return Media('asset:///assets/media/$filename');
  }

  void _onVideoCompleted() {
    if (_items.isEmpty) return;
    final item = _items[_index];
    _nextOrLoop(item);
  }

  void _nextOrLoop(PlaylistItem item) {
    if (!mounted) return;

    if (item.loop) {
      // Повтор текущего элемента
      _playCurrent();
      return;
    }

    // Следующий
    _index = (_index + 1) % _items.length;
    _playCurrent();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // На паузе — стопаем видео, чтобы не “жрало” ресурсы
    if (state == AppLifecycleState.paused) {
      _player.pause();
    }

    // При возвращении — снова fullscreen, и продолжаем
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _player.play();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _imageTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'Нет элементов для воспроизведения',
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    final item = _items[_index];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Основной контент
          if (item.isVideo)
            Video(
              controller: _videoController,
              fit: BoxFit.cover,
            )
          else if (item.isImage)
            FutureBuilder<Media>(
              future: _resolveMedia(item.filename),
              builder: (context, snapshot) {
                // Для картинок нам нужен путь: если это файл — показываем File, если asset — показываем Asset.
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final m = snapshot.data!;
                final uri = m.uri;

                if (uri.startsWith('asset:///')) {
                  // asset:///assets/media/x.jpg -> assets/media/x.jpg
                  final assetPath = uri.replaceFirst('asset:///', '');
                  return Image.asset(assetPath, fit: BoxFit.cover);
                } else {
                  return Image.file(File(uri), fit: BoxFit.cover);
                }
              },
            )
          else
            const Center(
              child: Text(
                'Неподдерживаемый тип файла',
                style: TextStyle(color: Colors.white),
              ),
            ),

          // (Опционально) скрытая зона для отладки/управления (можно убрать полностью)
          // В киоске обычно жесты не нужны, но на этапе разработки удобно:
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: true, // чтобы не мешать “чистому экрану”
              child: Container(
                padding: const EdgeInsets.all(8),
                color: Colors.black.withOpacity(0.0), // 0.0 = полностью прозрачно
                child: Text(
                  '${_index + 1}/${_items.length} • ${item.filename}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
