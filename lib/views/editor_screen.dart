import 'dart:async';
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
  bool _modeToggleBusy = false;
  Worker? _offlineModeWorker;
  Timer? _statusTimer;
  String? _statusMessage;
  Color _statusColor = Colors.blue.shade700;
  IconData _statusIcon = Icons.info_outline;
  bool _serverBusy = false;

  // Поля для нового элемента
  final _filenameCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();
  DateTime _startDate = DateTime.now();
  DateTime? _stopDate;
  bool _loop = true;
  int _durationSeconds = 10;

  late final PlaylistController _controller;

  @override
  void initState() {
    super.initState();
    _controller = Get.find<PlaylistController>();
    _serverCtrl.text = _controller.serverAddress;

    // Следим за изменением режима в контроллере
    _offlineModeWorker = ever<bool>(_controller.isOfflineMode, (mode) {
      setState(() {
        _isOfflineMode = mode;
      });
      _loadPlaylist();
    });

    _isOfflineMode = _controller.isOfflineMode.value;
    _loadPlaylist();
  }

  @override
  void dispose() {
    _offlineModeWorker?.dispose();
    _statusTimer?.cancel();
    _scrollController.dispose();
    _filenameCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylist() async {
    if (_isOfflineMode) {
      await _controller.refreshLocalPlaylist();
    }
    final items = List<PlaylistItem>.from(_controller.editorItems);
    if (!mounted) return;
    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  Future<void> _toggleOfflineMode(bool value) async {
    if (_modeToggleBusy) return;
    setState(() {
      _modeToggleBusy = true;
    });
    try {
      if (value) {
        await _controller.enableOfflineMode();
        _showStatus(
          'Аварийный оффлайн-режим включён.',
          color: Colors.red.shade700,
          icon: Icons.warning_amber_rounded,
        );
      } else {
        await _controller.disableOfflineMode();
        _showStatus(
          'Онлайн-режим восстановлен, серверный манифест обновляется.',
          color: Colors.green.shade700,
          icon: Icons.cloud_done_outlined,
        );
      }
    } catch (e) {
      await AppLogger.log('Offline mode toggle error: $e');
      _showStatus(
        'Не удалось переключить режим: $e',
        color: Colors.red.shade700,
        icon: Icons.error_outline,
        duration: const Duration(seconds: 5),
      );
    } finally {
      if (mounted) {
        setState(() {
          _modeToggleBusy = false;
        });
      }
    }
  }

  void _showStatus(
    String message, {
    Color? color,
    IconData? icon,
    Duration duration = const Duration(seconds: 3),
  }) {
    _statusTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _statusColor = color ?? Colors.blue.shade700;
      _statusIcon = icon ?? Icons.info_outline;
    });
    _statusTimer = Timer(duration, () {
      if (!mounted) return;
      setState(() {
        _statusMessage = null;
      });
    });
  }

  Future<void> _changeServerOnline() async {
    if (_serverBusy) return;
    setState(() {
      _serverBusy = true;
    });
    try {
      final ok = await _controller.rebindServer(_serverCtrl.text);
      if (!mounted) return;
      if (ok) {
        _showStatus(
          _controller.setupMessage,
          color: Colors.green.shade700,
          icon: Icons.cloud_done_outlined,
          duration: const Duration(seconds: 4),
        );
        if (!_controller.isReady) {
          Get.back<void>();
        }
      }
    } catch (e) {
      _showStatus(
        'Не удалось сменить сервер: $e',
        color: Colors.red.shade700,
        icon: Icons.error_outline,
        duration: const Duration(seconds: 5),
      );
    } finally {
      if (mounted) {
        setState(() {
          _serverBusy = false;
        });
      }
    }
  }

  Future<void> _pickAndCopyFile() async {
    if (!_isOfflineMode) {
      _showStatus(
        'Включите аварийный оффлайн-режим для редактирования.',
        color: Colors.orange.shade700,
        icon: Icons.lock_outline,
      );
      return;
    }

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'mp4',
        'mov',
        'avi',
        'mkv',
        'webm',
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
      ],
    );

    if (result == null || result.files.isEmpty) return;

    try {
      final platformFile = result.files.first;
      final sourcePath = platformFile.path;
      if (sourcePath == null) {
        _showStatus(
          'Невозможно получить путь к выбранному файлу.',
          color: Colors.red.shade700,
          icon: Icons.error_outline,
        );
        return;
      }

      final sourceFile = File(sourcePath);
      final mediaDir = await AppPaths.mediaDir();
      final destFile = File('${mediaDir.path}/${platformFile.name}');
      final sourceAbsolute = sourceFile.absolute.path;
      final destAbsolute = destFile.absolute.path;
      final destinationExists = await destFile.exists();
      final usedExistingFile =
          sourceAbsolute == destAbsolute || destinationExists;

      if (sourceAbsolute == destAbsolute) {
        await AppLogger.log('Using existing local media file: $destAbsolute');
      } else if (destinationExists) {
        await AppLogger.log(
          'Using existing media file without overwrite: $destAbsolute',
        );
      } else {
        await sourceFile.copy(destFile.path);
        await AppLogger.log('File copied to media folder: ${destFile.path}');
      }

      // Автозаполнение имени файла
      setState(() {
        _filenameCtrl.text = platformFile.name;
      });

      _showStatus(
        usedExistingFile
            ? 'Файл уже есть в локальной медиапапке. Можно сразу добавлять элемент в плейлист.'
            : 'Файл скопирован в локальную медиапапку.',
        color: Colors.green.shade700,
        icon: Icons.check_circle_outline,
      );
    } catch (e) {
      await AppLogger.log('File copy error: $e');
      _showStatus(
        'Не удалось скопировать файл: $e',
        color: Colors.red.shade700,
        icon: Icons.error_outline,
        duration: const Duration(seconds: 5),
      );
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
        ) ??
        false;
  }

  void _openItemForEdit(int index) {
    if (!_isOfflineMode) {
      _showStatus(
        'Редактирование доступно только в аварийном оффлайн-режиме.',
        color: Colors.orange.shade700,
        icon: Icons.lock_outline,
      );
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
      _showStatus(
        'Сначала включите аварийный оффлайн-режим.',
        color: Colors.orange.shade700,
        icon: Icons.lock_outline,
      );
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final wasEditing = _editingIndex != null;
    final newItem = PlaylistItem(
      filename: _filenameCtrl.text.trim(),
      startDate: _startDate,
      stopDate: _stopDate,
      loop: _loop,
      durationSeconds: _durationSeconds,
    );

    setState(() {
      if (wasEditing) {
        _items[_editingIndex!] = newItem;
        _editingIndex = null;
      } else {
        _items.add(newItem);
      }
      _filenameCtrl.clear();
      _startDate = DateTime.now();
      _stopDate = null;
      _loop = true;
      _durationSeconds = 10;
    });

    _showStatus(
      wasEditing
          ? 'Элемент обновлён в локальном списке.'
          : 'Элемент добавлен в локальный список.',
      color: Colors.green.shade700,
      icon: Icons.check_circle_outline,
    );
  }

  void _deleteItem(int index) async {
    if (!_isOfflineMode) {
      _showStatus(
        'Удаление доступно только в аварийном оффлайн-режиме.',
        color: Colors.orange.shade700,
        icon: Icons.lock_outline,
      );
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
      _showStatus(
        'Элемент удалён из локального списка.',
        color: Colors.green.shade700,
        icon: Icons.delete_outline,
      );
    }
  }

  Future<void> _savePlaylist() async {
    if (!_isOfflineMode) {
      _showStatus(
        'Сохранение локального плейлиста доступно только в аварийном режиме.',
        color: Colors.orange.shade700,
        icon: Icons.lock_outline,
      );
      return;
    }

    try {
      await _controller.saveLocalPlaylist(_items);

      await AppLogger.log(
        'Playlist saved to: ${await AppPaths.playlistFile()}',
      );
      _showStatus(
        'Аварийный плейлист сохранён. Возвращаемся к воспроизведению.',
        color: Colors.green.shade700,
        icon: Icons.save_outlined,
        duration: const Duration(milliseconds: 900),
      );

      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) Get.back();
      });
    } catch (e) {
      await AppLogger.log('Save playlist error: $e');
      _showStatus(
        'Не удалось сохранить плейлист: $e',
        color: Colors.red.shade700,
        icon: Icons.error_outline,
        duration: const Duration(seconds: 5),
      );
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
          if (_statusMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: _statusColor.withValues(alpha: 0.12),
              child: Row(
                children: [
                  Icon(_statusIcon, color: _statusColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _statusMessage!,
                      style: TextStyle(
                        color: _statusColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _statusMessage = null),
                    icon: Icon(Icons.close, color: _statusColor),
                    tooltip: 'Закрыть сообщение',
                  ),
                ],
              ),
            ),
          // Переключатель режима
          Container(
            color: Colors.grey[200],
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Онлайн-режим',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Obx(
                  () => Switch(
                    value: _controller.isOfflineMode.value,
                    onChanged: _modeToggleBusy
                        ? null
                        : (value) {
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
                                      onPressed: () async {
                                        Get.back();
                                        await _toggleOfflineMode(true);
                                      },
                                      child: const Text(
                                        'Включить',
                                        style: TextStyle(color: Colors.red),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            } else {
                              // Подтверждение при отключении оффлайн-режима
                              Get.dialog(
                                AlertDialog(
                                  title: const Text(
                                    'Вернуться в онлайн-режим?',
                                  ),
                                  content: const Text(
                                    'Все несохранённые изменения в локальном плейлисте будут потеряны!\nСерверный манифест будет загружен автоматически.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: Get.back,
                                      child: const Text('Отмена'),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        Get.back();
                                        await _toggleOfflineMode(false);
                                      },
                                      child: const Text(
                                        'Подтвердить',
                                        style: TextStyle(color: Colors.green),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }
                          },
                    activeThumbColor: Colors.red,
                    activeTrackColor: Colors.red.shade200,
                    inactiveThumbColor: Colors.green,
                    inactiveTrackColor: Colors.green.shade200,
                  ),
                ),
                const Text(
                  'Оффлайн-режим (аварийный)',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
              ],
            ),
          ),

          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Сервер устройства',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _serverCtrl,
                        enabled: !_serverBusy,
                        decoration: const InputDecoration(
                          labelText: 'Адрес сервера',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _serverBusy ? null : _changeServerOnline,
                      icon: _serverBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync_alt),
                      label: const Text('Сменить'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'После смены сервера устройство заново проходит регистрацию на новом контуре.',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                ),
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
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: Get.back, child: const Text('Понятно')),
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
                      TextButton(onPressed: Get.back, child: const Text('OK')),
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
                      const Icon(
                        Icons.playlist_add,
                        size: 64,
                        color: Colors.grey,
                      ),
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
                    final isActive =
                        now.isAfter(item.startDate) &&
                        (item.stopDate == null || now.isBefore(item.stopDate!));

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: isActive ? Colors.green.shade50 : null,
                      elevation: 4,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        title: Text(
                          item.filename,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Начало: ${_dateFormat.format(item.startDate)}',
                            ),
                            if (item.stopDate != null)
                              Text(
                                'Окончание: ${_dateFormat.format(item.stopDate!)}',
                              ),
                            Text(
                              'Тип: ${item.isVideo
                                  ? "Видео"
                                  : item.isImage
                                  ? "Изображение"
                                  : "Неизвестно"} | Loop: ${item.loop ? "Да" : "Нет"}',
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 720;
                final spacing = compact ? 12.0 : 16.0;

                return Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      compact
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildFilenameField(),
                                SizedBox(height: spacing),
                                _buildPickFileButton(fullWidth: true),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(child: _buildFilenameField()),
                                SizedBox(width: spacing),
                                _buildPickFileButton(),
                              ],
                            ),
                      SizedBox(height: spacing),
                      compact
                          ? Column(
                              children: [
                                _buildDateTimeField(
                                  label: 'Начало*',
                                  initialDate: _startDate,
                                  onSelected: (dt) {
                                    if (dt != null) {
                                      setState(() => _startDate = dt);
                                    }
                                  },
                                ),
                                SizedBox(height: spacing),
                                _buildDateTimeField(
                                  label: 'Окончание',
                                  initialDate: _stopDate,
                                  onSelected: (dt) =>
                                      setState(() => _stopDate = dt),
                                  isOptional: true,
                                ),
                              ],
                            )
                          : Row(
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
                                SizedBox(width: spacing),
                                Expanded(
                                  child: _buildDateTimeField(
                                    label: 'Окончание',
                                    initialDate: _stopDate,
                                    onSelected: (dt) =>
                                        setState(() => _stopDate = dt),
                                    isOptional: true,
                                  ),
                                ),
                              ],
                            ),
                      SizedBox(height: spacing),
                      compact
                          ? Column(
                              children: [
                                _buildDurationField(),
                                SizedBox(height: spacing),
                                _buildLoopField(),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(child: _buildDurationField()),
                                SizedBox(width: spacing),
                                Expanded(child: _buildLoopField()),
                              ],
                            ),
                      SizedBox(height: spacing),
                      compact
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildUpdateButton(),
                                SizedBox(height: spacing),
                                _buildAddButton(),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(child: _buildUpdateButton()),
                                SizedBox(width: 12),
                                Expanded(child: _buildAddButton()),
                              ],
                            ),
                    ],
                  ),
                );
              },
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
          final newDate = await _selectDateTime(
            context,
            initialDate ?? DateTime.now(),
          );
          if (newDate != null) {
            onSelected(newDate);
          }
        },
        child: Padding(
          padding: const EdgeInsets.only(left: 12.0),
          child: Text(
            initialDate == null
                ? 'Не задано'
                : DateFormat('dd.MM.yyyy HH:mm').format(initialDate),
            style: TextStyle(color: initialDate == null ? Colors.grey : null),
          ),
        ),
      ),
    );
  }

  Widget _buildFilenameField() {
    return TextFormField(
      controller: _filenameCtrl,
      decoration: const InputDecoration(
        labelText: 'Имя файла*',
        hintText: 'video.mp4 или image.jpg',
        border: OutlineInputBorder(),
      ),
      validator: (v) => v?.trim().isEmpty ?? true ? 'Обязательное поле' : null,
    );
  }

  Widget _buildPickFileButton({bool fullWidth = false}) {
    final button = ElevatedButton.icon(
      onPressed: _pickAndCopyFile,
      icon: const Icon(Icons.upload_file),
      label: const Text('Выбрать файл'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
    if (!fullWidth) {
      return button;
    }
    return SizedBox(width: double.infinity, child: button);
  }

  Widget _buildDurationField() {
    return TextFormField(
      initialValue: _durationSeconds.toString(),
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'Длительность (сек) для изображений',
        border: OutlineInputBorder(),
      ),
      onChanged: (v) =>
          setState(() => _durationSeconds = int.tryParse(v) ?? 10),
    );
  }

  Widget _buildLoopField() {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Зациклить',
        border: OutlineInputBorder(),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Switch(
          value: _loop,
          onChanged: (v) => setState(() => _loop = v),
        ),
      ),
    );
  }

  Widget _buildUpdateButton() {
    return ElevatedButton(
      onPressed: _editingIndex != null ? _saveItem : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.green.shade700,
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
      child: const Text(
        'Обновить элемент',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildAddButton() {
    return ElevatedButton(
      onPressed: _editingIndex == null ? _saveItem : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blue.shade700,
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
      child: const Text(
        'Добавить элемент',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  Future<DateTime?> _selectDateTime(
    BuildContext context,
    DateTime initialDate,
  ) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );

    if (date == null) return null;
    if (!context.mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );

    if (time == null) return null;

    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }
}
