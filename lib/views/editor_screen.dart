import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import '../controllers/playlist_controller.dart';
import '../models/playlist_item.dart';
import '../services/app_paths.dart';
import '../services/app_logger.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late List<PlaylistItem> _items;
  bool _isLoading = true;
  final _dateFormat = DateFormat("yyyy-MM-dd'T'HH:mm:ss");
  final _scrollController = ScrollController();
  int? _editingIndex;
  bool _isOfflineMode = false; // Локальное состояние для плавной анимации

  // Поля для нового элемента
  final _filenameCtrl = TextEditingController();
  DateTime _startDate = DateTime.now();
  DateTime? _stopDate;
  bool _loop = true;
  int _durationSeconds = 10;

  late final PlaylistController _controller;

  @override
  void initState() {
    super.initState();
    _controller = Get.find<PlaylistController>();

    // Следим за изменением режима в контроллере
    ever<bool>(_controller.isOfflineMode, (mode) {
      setState(() {
        _isOfflineMode = mode;
        _loadPlaylist(); // Перезагружаем при смене режима
      });
    });

    _isOfflineMode = _controller.isOfflineMode.value;
    _loadPlaylist();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _filenameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylist() async {
    setState(() {
      _items = List<PlaylistItem>.from(_controller.editorItems);
      _isLoading = false;
    });
  }

  Future<void> _pickAndCopyFile() async {
    if (!_isOfflineMode) {
      Get.snackbar('Режим "Только чтение"', 'Включите оффлайн-режим для редактирования', snackPosition: SnackPosition.BOTTOM);
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'avi', 'mkv', 'webm', 'jpg', 'jpeg', 'png', 'gif', 'webp'],
    );

    if (result == null || result.files.isEmpty) return;

    try {
      final platformFile = result.files.first;
      final sourcePath = platformFile.path;
      if (sourcePath == null) {
        Get.snackbar('Ошибка', 'Невозможно получить путь к файлу', snackPosition: SnackPosition.BOTTOM);
        return;
      }

      final sourceFile = File(sourcePath);
      final mediaDir = await AppPaths.mediaDir();
      final destFile = File('${mediaDir.path}/${platformFile.name}');

      if (await destFile.exists()) {
        final overwrite = await _showConfirmDialog(
          'Файл существует',
          'Файл ${platformFile.name} уже существует. Перезаписать?',
        );
        if (!overwrite) return;
      }

      await sourceFile.copy(destFile.path);
      await AppLogger.log('File copied to media folder: ${destFile.path}');

      // Автозаполнение имени файла
      setState(() {
        _filenameCtrl.text = platformFile.name;
      });

      Get.snackbar('Успех', 'Файл скопирован в медиапапку', snackPosition: SnackPosition.BOTTOM);
    } catch (e) {
      await AppLogger.log('File copy error: $e');
      Get.snackbar('Ошибка', 'Не удалось скопировать файл: $e', snackPosition: SnackPosition.BOTTOM);
    }
  }

  Future<bool> _showConfirmDialog(String title, String message) async {
    return await Get.dialog<bool>(
      AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('Да'),
          ),
        ],
      ),
      barrierDismissible: false,
    ) ?? false;
  }

  void _openItemForEdit(int index) {
    if (!_isOfflineMode) {
      Get.snackbar('Режим "Только чтение"', 'Включите оффлайн-режим для редактирования', snackPosition: SnackPosition.BOTTOM);
      return;
    }

    final item = _items[index];
    setState(() {
      _editingIndex = index;
      _filenameCtrl.text = item.filename;
      _startDate = item.startDate;
      _stopDate = item.stopDate;
      _loop = item.loop;
      _durationSeconds = item.durationSeconds;
    });
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _saveItem() {
    if (!_isOfflineMode) {
      Get.snackbar('Режим "Только чтение"', 'Включите оффлайн-режим для редактирования', snackPosition: SnackPosition.BOTTOM);
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final newItem = PlaylistItem(
      filename: _filenameCtrl.text.trim(),
      startDate: _startDate,
      stopDate: _stopDate,
      loop: _loop,
      durationSeconds: _durationSeconds,
    );

    setState(() {
      if (_editingIndex != null) {
        _items[_editingIndex!] = newItem;
        _editingIndex = null;
      } else {
        _items.add(newItem);
      }
      _clearForm();
    });

    Get.snackbar(
      _editingIndex != null ? 'Обновлено' : 'Добавлено',
      'Элемент сохранен в списке',
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  void _clearForm() {
    setState(() {
      _editingIndex = null;
      _filenameCtrl.clear();
      _startDate = DateTime.now();
      _stopDate = null;
      _loop = true;
      _durationSeconds = 10;
    });
  }

  void _deleteItem(int index) async {
    if (!_isOfflineMode) {
      Get.snackbar('Режим "Только чтение"', 'Включите оффлайн-режим для редактирования', snackPosition: SnackPosition.BOTTOM);
      return;
    }

    final confirm = await _showConfirmDialog(
      'Удалить элемент?',
      'Вы уверены, что хотите удалить ${_items[index].filename}?',
    );

    if (confirm) {
      setState(() {
        _items.removeAt(index);
      });
      Get.snackbar('Удалено', 'Элемент удален из списка', snackPosition: SnackPosition.BOTTOM);
    }
  }

  Future<void> _savePlaylist() async {
    if (!_isOfflineMode) {
      Get.snackbar('Режим "Только чтение"', 'Включите оффлайн-режим для сохранения', snackPosition: SnackPosition.BOTTOM);
      return;
    }

    try {
      // Сортируем по startDate перед сохранением
      _items.sort((a, b) => a.startDate.compareTo(b.startDate));

      // Обновляем локальные данные в контроллере
      _controller.localItems.assignAll(_items);

      // Сохраняем на диск
      await _controller.saveLocalPlaylist();

      await AppLogger.log('Playlist saved to: ${await AppPaths.playlistFile()}');
      Get.snackbar(
        'Успех',
        'Плейлист сохранен!\nПриложение вернется в режим воспроизведения через 2 секунды',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );

      // Автоматически закрываем через 2 секунды
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) Get.back();
      });
    } catch (e) {
      await AppLogger.log('Save playlist error: $e');
      Get.snackbar('Ошибка', 'Не удалось сохранить плейлист: $e', snackPosition: SnackPosition.BOTTOM);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Редактор плейлиста'),
        backgroundColor: Colors.blue.shade800,
        actions: [
          if (_isOfflineMode)
            IconButton(
              icon: const Icon(Icons.save, color: Colors.white),
              onPressed: _savePlaylist,
              tooltip: 'Сохранить плейлист (Ctrl+S)',
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _loadPlaylist,
            tooltip: 'Перезагрузить',
          ),
        ],
      ),
      body: Column(
        children: [
          // Переключатель режима
          Container(
            color: Colors.grey[200],
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Text('Онлайн-режим', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                Obx(() => Switch(
                  value: _controller.isOfflineMode.value,
                  onChanged: (value) {
                    // Подтверждение при включении оффлайн-режима
                    if (value) {
                      Get.dialog(
                        AlertDialog(
                          title: const Text('Аварийный оффлайн-режим'),
                          content: const Text(
                            'В этом режиме:\n• Панель работает без сервера\n• Все изменения сохраняются локально\n• После отключения режима данные НЕ синхронизируются с сервером\n\nВключить аварийный режим?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: Get.back,
                              child: const Text('Отмена'),
                            ),
                            TextButton(
                              onPressed: () {
                                Get.back();
                                _controller.isOfflineMode.value = true;
                              },
                              child: const Text('Включить', style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      );
                    } else {
                      // Подтверждение при отключении оффлайн-режима
                      Get.dialog(
                        AlertDialog(
                          title: const Text('Вернуться в онлайн-режим?'),
                          content: const Text(
                            'Все несохранённые изменения в локальном плейлисте будут потеряны!\nСерверный манифест будет загружен автоматически.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: Get.back,
                              child: const Text('Отмена'),
                            ),
                            TextButton(
                              onPressed: () {
                                Get.back();
                                _controller.isOfflineMode.value = false;
                              },
                              child: const Text('Подтвердить', style: TextStyle(color: Colors.green)),
                            ),
                          ],
                        ),
                      );
                    }
                  },
                  activeColor: Colors.red,
                  activeTrackColor: Colors.red.shade200,
                  inactiveThumbColor: Colors.green,
                  inactiveTrackColor: Colors.green.shade200,
                )),
                const SizedBox(width: 12),
                const Text('Оффлайн-режим (аварийный)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
              ],
            ),
          ),

          const Divider(height: 1),

          // Основной контент
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildContent(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Get.dialog(
            AlertDialog(
              title: const Text('Инструкция'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('🔹 Онлайн-режим (по умолчанию):'),
                    const Text('   • Данные приходят с сервера'),
                    const Text('   • Редактирование недоступно'),
                    const SizedBox(height: 12),
                    const Text('🔸 Оффлайн-режим (аварийный):'),
                    const Text('   • Работает без интернета/сервера'),
                    const Text('   • Полное редактирование плейлиста'),
                    const Text('   • Медиафайлы должны быть в папке media'),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        '❗ Внимание: при выходе из оффлайн-режима локальные изменения НЕ сохранятся на сервер!',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: Get.back,
                  child: const Text('Понятно'),
                ),
              ],
            ),
          );
        },
        icon: const Icon(Icons.help_outline),
        label: const Text('Помощь'),
      ),
    );
  }

  Widget _buildContent() {
    if (!_isOfflineMode) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud, size: 64, color: Colors.blue),
            const SizedBox(height: 16),
            const Text(
              'Онлайн-режим (только просмотр)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Текущий режим: ${_controller.manifest?.revision ?? "не загружен"}',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Get.dialog(
                  AlertDialog(
                    title: const Text('Информация'),
                    content: const Text(
                      'Для редактирования плейлиста:\n1. Переключитесь в оффлайн-режим (слайдер вверху)\n2. Добавьте/отредактируйте элементы\n3. Сохраните изменения\n4. После восстановления сервера — отключите оффлайн-режим',
                    ),
                    actions: [
                      TextButton(
                        onPressed: Get.back,
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              },
              icon: const Icon(Icons.info),
              label: const Text('Как редактировать?'),
            ),
          ],
        ),
      );
    }

    // Оффлайн-режим: обычный список элементов
    return Column(
      children: [
        Expanded(
          child: _items.isEmpty
              ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.playlist_add, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                const Text(
                  'Плейлист пуст',
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                Text(
                  'Добавьте первый элемент ниже',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ],
            ),
          )
              : ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(8),
            itemCount: _items.length,
            itemBuilder: (context, index) {
              final item = _items[index];
              final now = DateTime.now();
              final isActive = now.isAfter(item.startDate) &&
                  (item.stopDate == null || now.isBefore(item.stopDate!));

              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                color: isActive ? Colors.green.shade50 : null,
                elevation: 4,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  title: Text(
                    item.filename,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Начало: ${_dateFormat.format(item.startDate)}'),
                      if (item.stopDate != null)
                        Text('Окончание: ${_dateFormat.format(item.stopDate!)}'),
                      Text(
                        'Тип: ${item.isVideo ? "Видео" : item.isImage ? "Изображение" : "Неизвестно"} | Loop: ${item.loop ? "Да" : "Нет"}',
                      ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blue),
                        onPressed: () => _openItemForEdit(index),
                        tooltip: 'Редактировать',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteItem(index),
                        tooltip: 'Удалить',
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        // Форма редактирования (только в оффлайн-режиме)
        if (_isOfflineMode)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              border: Border(top: BorderSide(color: Colors.grey[300]!)),
            ),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _filenameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Имя файла*',
                            hintText: 'video.mp4 или image.jpg',
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) => v?.trim().isEmpty ?? true ? 'Обязательное поле' : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        onPressed: _pickAndCopyFile,
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Выбрать файл'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade700,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _buildDateTimeField(
                          label: 'Начало*',
                          initialDate: _startDate,
                          onSelected: (dt) {
                            if (dt != null) {
                              setState(() => _startDate = dt);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildDateTimeField(
                          label: 'Окончание',
                          initialDate: _stopDate,
                          onSelected: (dt) => setState(() => _stopDate = dt),
                          isOptional: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: _durationSeconds.toString(),
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Длительность (сек) для изображений',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) => setState(() => _durationSeconds = int.tryParse(v) ?? 10),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Зациклить',
                            border: OutlineInputBorder(),
                          ),
                          child: Switch(
                            value: _loop,
                            onChanged: (v) => setState(() => _loop = v),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _editingIndex != null ? _saveItem : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text(
                            'Обновить элемент',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _editingIndex == null ? _saveItem : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue.shade700,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text(
                            'Добавить элемент',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDateTimeField({
    required String label,
    required DateTime? initialDate,
    required Function(DateTime?) onSelected,
    bool isOptional = false,
  }) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: isOptional ? label : '$label*',
        border: const OutlineInputBorder(),
        suffixIcon: initialDate != null
            ? IconButton(
          icon: const Icon(Icons.clear, size: 18),
          onPressed: () => onSelected(null),
          padding: EdgeInsets.zero,
        )
            : null,
      ),
      child: InkWell(
        onTap: () async {
          final newDate = await _selectDateTime(context, initialDate ?? DateTime.now());
          if (newDate != null) {
            onSelected(newDate);
          }
        },
        child: Padding(
          padding: const EdgeInsets.only(left: 12.0),
          child: Text(
            initialDate == null
                ? 'Не задано'
                : DateFormat('dd.MM.yyyy HH:mm').format(initialDate!),
            style: TextStyle(
              color: initialDate == null ? Colors.grey : null,
            ),
          ),
        ),
      ),
    );
  }

  Future<DateTime?> _selectDateTime(BuildContext context, DateTime initialDate) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );

    if (date == null) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );

    if (time == null) return null;

    return DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
  }
}