// lib/controllers/playlist_controller.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:get/get.dart';

import '../models/playlist_item.dart';
import '../services/app_logger.dart';
import '../services/app_paths.dart';

class PlaylistController extends GetxController {
  final RxList<PlaylistItem> _items = <PlaylistItem>[].obs;
  final RxBool _isLoading = false.obs;

  /// Увеличивается при каждом успешном reload — удобно для PlayerScreen (ever/worker)
  final RxInt version = 0.obs;

  DateTime? _lastDiskMtime;
  Timer? _watchTimer;

  List<PlaylistItem> get items => _items;
  bool get isLoading => _isLoading.value;

  @override
  void onInit() {
    super.onInit();
    loadPlaylist();
    _watchTimer = Timer.periodic(const Duration(seconds: 5), (_) => _maybeReloadFromDisk());
  }

  @override
  void onClose() {
    _watchTimer?.cancel();
    super.onClose();
  }

  Future<void> _maybeReloadFromDisk() async {
    try {
      final file = await AppPaths.playlistFile();
      if (!await file.exists()) return; // дискового плейлиста нет — не трогаем

      final stat = await file.stat();
      final mtime = stat.modified;

      if (_lastDiskMtime == null || mtime.isAfter(_lastDiskMtime!)) {
        await AppLogger.log('playlist.json changed → reload');
        await loadPlaylist();
      }
    } catch (e) {
      await AppLogger.log('playlist watcher error: $e');
    }
  }

  Future<void> loadPlaylist() async {
    _isLoading.value = true;

    try {
      final disk = await AppPaths.playlistFile();

      String jsonString;
      if (await disk.exists()) {
        jsonString = await disk.readAsString();
        _lastDiskMtime = (await disk.stat()).modified;
        await AppLogger.log('Playlist loaded from DISK: ${disk.path}');
      } else {
        jsonString = await rootBundle.loadString('assets/playlist.json');
        await AppLogger.log('Playlist loaded from ASSETS');
      }

      // Парсим
      final raw = (jsonDecode(jsonString) as List).cast<dynamic>();
      final parsed = raw
          .map((e) => PlaylistItem.fromJson((e as Map).cast<String, dynamic>()))
          .toList();

      // Сортируем по start_date
      parsed.sort((a, b) => a.startDate.compareTo(b.startDate));

      // Нормализуем stop_date:
      // если stop_date отсутствует, ставим равным следующему start_date
      final normalized = <PlaylistItem>[];
      for (int i = 0; i < parsed.length; i++) {
        final cur = parsed[i];
        DateTime? stop = cur.stopDate;

        if (stop == null && i + 1 < parsed.length) {
          stop = parsed[i + 1].startDate;
        }

        normalized.add(cur.copyWith(stopDate: stop));
      }

      _items.assignAll(normalized);
      version.value++;

      await AppLogger.log('Playlist items: ${_items.length}, version=${version.value}');
      for (final it in _items) {
        await AppLogger.log(' - ${it.filename} | ${it.startDate} -> ${it.stopDate} | loop=${it.loop}');
      }
    } catch (e) {
      _items.clear();
      await AppLogger.log('Playlist load error: $e');
    } finally {
      _isLoading.value = false;
    }
  }

  /// Элемент, который должен быть активен в момент now.
  /// Если есть перекрытия — берём самый “поздний” по startDate (приоритет последнего).
  PlaylistItem? currentItem(DateTime now) {
    final active = _items.where((i) => i.isActiveAt(now)).toList();
    if (active.isEmpty) return null;

    active.sort((a, b) => b.startDate.compareTo(a.startDate));
    return active.first;
  }
}
