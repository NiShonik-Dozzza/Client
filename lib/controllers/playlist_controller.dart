// lib/controllers/playlist_controller.dart
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get/get.dart';
import 'package:flutter/foundation.dart';
import '../models/playlist_item.dart';

class PlaylistController extends GetxController {
  final RxList<PlaylistItem> _items = <PlaylistItem>[].obs;
  final RxBool _isLoading = false.obs;

  List<PlaylistItem> get items => _items;
  bool get isLoading => _isLoading.value;

  // Только активные элементы (дата начала <= текущей)
  List<PlaylistItem> get activeItems => _items
      .where((item) => DateTime.now().isAfter(item.startDate) ||
      DateTime.now().isAtSameMomentAs(item.startDate))
      .toList();

  @override
  void onInit() {
    loadPlaylist();
    super.onInit();
  }

  Future<void> loadPlaylist() async {
    try {
      _isLoading.value = true;
      final jsonString = await rootBundle.loadString('assets/playlist.json');
      debugPrint('Загружен playlist.json: $jsonString'); // ← сюда выводится содержимое
      final jsonList = json.decode(jsonString) as List;
      _items.assignAll(
        jsonList.map((e) => PlaylistItem.fromJson(e)).toList(),
      );
    } catch (e) {
      print('Ошибка загрузки плейлиста: $e');
    } finally {
      _isLoading.value = false;
    }
  }

  void addItem(PlaylistItem item) {
    _items.add(item);
    savePlaylist();
  }

  void removeItem(int index) {
    _items.removeAt(index);
    savePlaylist();
  }

  // В демо-режиме мы не можем перезаписать assets, но в реальном приложении:
  // — сохраним в DocumentsDirectory
  // — или отправим на сервер
  Future<void> savePlaylist() async {
    // В assets НЕЛЬЗЯ писать! Это только для чтения.
    // В продакшене используй path_provider.
    // Для демо — просто покажем в логе.
    final jsonList = _items.map((item) => item.toJson()).toList();
    debugPrint('Сохраняем плейлист (в проде — в файл):\n${JsonEncoder.withIndent('  ').convert(jsonList)}');
  }
}