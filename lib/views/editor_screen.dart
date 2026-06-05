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
  late List<PlaylistItem> _items;
  bool _isLoading = true;
  bool _dirty = false;
  final _scrollController = ScrollController();
  bool _isOfflineMode = false;
  bool _modeToggleBusy = false;
  Worker? _offlineModeWorker;
  Timer? _statusTimer;
  String? _statusMessage;
  Color _statusColor = Colors.blue.shade700;
  IconData _statusIcon = Icons.info_outline;
  bool _serverBusy = false;
  final _serverCtrl = TextEditingController();

  late final PlaylistController _controller;

  @override
  void initState() {
    super.initState();
    _controller = Get.find<PlaylistController>();
    _serverCtrl.text = _controller.serverAddress;

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
      _dirty = false;
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
      unawaited(AppLogger.log('Offline mode toggle error: $e'));
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

  Future<void> _pickAndAddFiles() async {
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
      allowMultiple: true,
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

    int added = 0;
    int skipped = 0;

    for (final platformFile in result.files) {
      try {
        final sourcePath = platformFile.path;
        if (sourcePath == null) {
          skipped++;
          continue;
        }

        final sourceFile = File(sourcePath);
        final mediaDir = await AppPaths.mediaDir();
        final destFile = File('${mediaDir.path}/${platformFile.name}');
        final sourceAbsolute = sourceFile.absolute.path;
        final destAbsolute = destFile.absolute.path;
        final destinationExists = await destFile.exists();

        if (sourceAbsolute == destAbsolute) {
          unawaited(AppLogger.log('Using existing local media file: $destAbsolute'));
        } else if (destinationExists) {
          unawaited(AppLogger.log('Using existing media file without overwrite: $destAbsolute'));
        } else {
          await sourceFile.copy(destFile.path);
          unawaited(AppLogger.log('File copied to media folder: ${destFile.path}'));
        }

        setState(() {
          _items.add(PlaylistItem.alwaysActive(filename: platformFile.name));
          _dirty = true;
        });
        added++;
      } catch (e) {
        unawaited(AppLogger.log('File copy error (${platformFile.name}): $e'));
        skipped++;
      }
    }

    if (added > 0) {
      await _persist();
    }

    if (added > 0 && skipped == 0) {
      _showStatus(
        added == 1
            ? 'Файл добавлен и сохранён.'
            : '$added файлов добавлено и сохранено.',
        color: Colors.green.shade700,
        icon: Icons.check_circle_outline,
      );
    } else if (added > 0) {
      _showStatus(
        '$added добавлено, $skipped не удалось скопировать.',
        color: Colors.orange.shade700,
        icon: Icons.warning_amber_rounded,
        duration: const Duration(seconds: 5),
      );
    } else {
      _showStatus(
        'Не удалось скопировать ни один файл.',
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
      'Вы уверены, что хотите удалить ${_items[index].baseName}?',
    );

    if (confirm) {
      setState(() {
        _items.removeAt(index);
        _dirty = true;
      });
      await _persist();
      _showStatus(
        'Элемент удалён.',
        color: Colors.green.shade700,
        icon: Icons.delete_outline,
      );
    }
  }

  Future<void> _openEditDialog(int index) async {
    if (!_isOfflineMode) {
      _showStatus(
        'Редактирование доступно только в аварийном оффлайн-режиме.',
        color: Colors.orange.shade700,
        icon: Icons.lock_outline,
      );
      return;
    }

    final result = await Get.dialog<PlaylistItem>(
      _ItemEditDialog(item: _items[index]),
      barrierDismissible: false,
    );

    if (result != null) {
      setState(() {
        _items[index] = result;
        _dirty = true;
      });
      await _persist();
      _showStatus(
        'Элемент обновлён.',
        color: Colors.green.shade700,
        icon: Icons.check_circle_outline,
      );
    }
  }

  /// Тихое автосохранение после любого изменения — чтобы добавленные файлы
  /// не терялись при выходе из редактора кнопкой «назад».
  /// После сохранения пере-считываем список из контроллера, чтобы порядок
  /// в редакторе совпадал с порядком воспроизведения (нормализация + сортировка).
  Future<void> _persist() async {
    try {
      await _controller.saveLocalPlaylist(_items);
      if (!mounted) return;
      setState(() {
        _items = List<PlaylistItem>.from(_controller.editorItems);
        _dirty = false;
      });
    } catch (e) {
      unawaited(AppLogger.log('Auto-save error: $e'));
      _showStatus(
        'Не удалось сохранить изменения: $e',
        color: Colors.red.shade700,
        icon: Icons.error_outline,
        duration: const Duration(seconds: 5),
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

      unawaited(AppLogger.log(
        'Playlist saved to: ${await AppPaths.playlistFile()}',
      ));
      setState(() => _dirty = false);
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
      unawaited(AppLogger.log('Save playlist error: $e'));
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
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('Резервный плейлист'),
        actions: [
          if (_isOfflineMode && _dirty)
            IconButton(
              icon: Icon(Icons.save, color: Colors.green.shade700),
              onPressed: _savePlaylist,
              tooltip: 'Сохранить плейлист',
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadPlaylist,
            tooltip: 'Перезагрузить',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildModeBar(),
          _buildServerSection(),
          if (_statusMessage != null) _buildStatusBanner(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildContent(),
          ),
        ],
      ),
      floatingActionButton: _isOfflineMode
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('Добавить файлы'),
              onPressed: _pickAndAddFiles,
            )
          : null,
    );
  }

  Widget _buildModeBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: _isOfflineMode ? Colors.orange.shade50 : Colors.green.shade50,
      child: Row(
        children: [
          Icon(
            _isOfflineMode ? Icons.wifi_off : Icons.cloud_done,
            color: _isOfflineMode ? Colors.orange.shade800 : Colors.green.shade800,
          ),
          const SizedBox(width: 8),
          Text(
            _isOfflineMode ? 'Аварийный оффлайн-режим' : 'Онлайн-режим',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: _isOfflineMode ? Colors.orange.shade800 : Colors.green.shade800,
            ),
          ),
          const Spacer(),
          if (_modeToggleBusy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Switch(
              value: _isOfflineMode,
              activeThumbColor: Colors.orange,
              activeTrackColor: Colors.orange.shade200,
              onChanged: (v) {
                if (v) {
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
            ),
        ],
      ),
    );
  }

  Widget _buildServerSection() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _serverCtrl,
              enabled: !_serverBusy,
              decoration: const InputDecoration(
                labelText: 'Адрес сервера',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
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
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
            tooltip: 'Закрыть',
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (!_isOfflineMode) {
      return _buildOnlineModeView();
    }
    return _buildOfflineModeList();
  }

  Widget _buildOnlineModeView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud, size: 72, color: Colors.blue.shade200),
          const SizedBox(height: 16),
          const Text(
            'Управление через сервер',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Ревизия: ${_controller.manifest?.revision ?? '—'}',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 15),
          ),
          const SizedBox(height: 24),
          if (_items.isNotEmpty) ...[
            Text(
              'Текущие элементы (только просмотр):',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                itemCount: _items.length,
                itemBuilder: (context, i) {
                  final item = _items[i];
                  return Opacity(
                    opacity: 0.55,
                    child: Card(
                      elevation: 0,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          item.isVideo ? Icons.movie_outlined : Icons.image_outlined,
                          size: 20,
                          color: Colors.grey,
                        ),
                        title: Text(
                          item.baseName,
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOfflineModeList() {
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.playlist_add, size: 72, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Плейлист пуст',
              style: TextStyle(fontSize: 20, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text(
              'Нажмите «Добавить файлы» чтобы начать',
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    final now = DateTime.now();
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 8, bottom: 88),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          elevation: 1,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: CircleAvatar(
              backgroundColor:
                  item.isVideo ? Colors.blue.shade50 : Colors.purple.shade50,
              child: Icon(
                item.isVideo ? Icons.movie_outlined : Icons.image_outlined,
                color: item.isVideo ? Colors.blue.shade700 : Colors.purple.shade700,
              ),
            ),
            title: Text(
              item.baseName,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: _buildItemSubtitle(item, now),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.isActiveAt(now))
                  const Icon(Icons.circle, color: Colors.green, size: 10),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _openEditDialog(index),
                  tooltip: 'Редактировать',
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
                  onPressed: () => _deleteItem(index),
                  tooltip: 'Удалить',
                ),
              ],
            ),
            onTap: () => _openEditDialog(index),
          ),
        );
      },
    );
  }

  Widget _buildItemSubtitle(PlaylistItem item, DateTime now) {
    final dateFormat = DateFormat('dd.MM.yyyy');

    if (item.isAlwaysActive) {
      return Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Text(
              'Всегда активен',
              style: TextStyle(
                color: Colors.blue.shade700,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );
    }

    if (now.isBefore(item.startDate)) {
      return Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Text(
              'Начало ${dateFormat.format(item.startDate)}',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );
    }

    if (item.stopDate != null && !now.isBefore(item.stopDate!)) {
      return Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Text(
              'Завершён',
              style: TextStyle(
                color: Colors.red.shade700,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );
    }

    // Active now with a stop date
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.green.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green.shade200),
          ),
          child: Text(
            item.stopDate != null
                ? 'Активен до ${dateFormat.format(item.stopDate!)}'
                : 'Активен',
            style: TextStyle(
              color: Colors.green.shade700,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Edit dialog
// ---------------------------------------------------------------------------

class _ItemEditDialog extends StatefulWidget {
  const _ItemEditDialog({required this.item});
  final PlaylistItem item;

  @override
  State<_ItemEditDialog> createState() => _ItemEditDialogState();
}

class _ItemEditDialogState extends State<_ItemEditDialog> {
  late bool _loop;
  late int _durationSeconds;
  late bool _alwaysActive;
  late DateTime _startDate;
  late DateTime? _stopDate;

  final _durationCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loop = widget.item.loop;
    _durationSeconds = widget.item.durationSeconds;
    _alwaysActive = widget.item.isAlwaysActive;
    _startDate = widget.item.startDate;
    _stopDate = widget.item.stopDate;
    _durationCtrl.text = _durationSeconds.toString();
  }

  @override
  void dispose() {
    _durationCtrl.dispose();
    super.dispose();
  }

  Future<DateTime?> _selectDateTime(DateTime initialDate) async {
    final firstDate = DateTime(2020);
    final lastDate = DateTime(2035);
    // Sentinel «всегда активен» (2000-01-01) и любые значения вне диапазона
    // ломают showDatePicker (assert initialDate >= firstDate). Подставляем «сейчас».
    var seed = initialDate;
    if (seed.isBefore(firstDate)) seed = DateTime.now();
    if (seed.isAfter(lastDate)) seed = lastDate;

    final date = await showDatePicker(
      context: context,
      initialDate: seed,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (date == null) return null;
    if (!mounted) return null;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(seed),
    );
    if (time == null) return null;

    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  void _save() {
    final result = PlaylistItem(
      filename: widget.item.filename,
      startDate: _alwaysActive ? DateTime(2000, 1, 1) : _startDate,
      stopDate: _alwaysActive ? null : _stopDate,
      loop: _loop,
      durationSeconds: _durationSeconds,
    );
    Get.back<PlaylistItem>(result: result);
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');

    return AlertDialog(
      title: Text(
        widget.item.baseName,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Loop toggle
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Зациклить'),
                value: _loop,
                onChanged: (v) => setState(() => _loop = v),
              ),

              // Duration field (for images)
              if (widget.item.isImage) ...[
                const SizedBox(height: 4),
                TextField(
                  controller: _durationCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Длительность показа (сек)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) =>
                      setState(() => _durationSeconds = int.tryParse(v) ?? 10),
                ),
              ],

              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 4),

              // Always active toggle
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Всегда активен'),
                subtitle: const Text('Без расписания, воспроизводится всегда'),
                value: _alwaysActive,
                onChanged: (v) => setState(() {
                  _alwaysActive = v;
                  // При выключении заменяем sentinel-дату (2000-01-01) на «сейчас»,
                  // чтобы поля и пикер показывали корректное значение.
                  if (!v && _startDate.year < 2010) {
                    _startDate = DateTime.now();
                  }
                }),
              ),

              // Date fields (only when not always active)
              if (!_alwaysActive) ...[
                const SizedBox(height: 8),
                _DatePickerTile(
                  label: 'Начало',
                  value: _startDate,
                  dateFormat: dateFormat,
                  onTap: () async {
                    final dt = await _selectDateTime(_startDate);
                    if (dt != null) setState(() => _startDate = dt);
                  },
                  onClear: null, // start date is required
                ),
                const SizedBox(height: 8),
                _DatePickerTile(
                  label: 'Окончание (не обязательно)',
                  value: _stopDate,
                  dateFormat: dateFormat,
                  onTap: () async {
                    final dt = await _selectDateTime(
                      _stopDate ?? _startDate.add(const Duration(hours: 1)),
                    );
                    if (dt != null) setState(() => _stopDate = dt);
                  },
                  onClear: () => setState(() => _stopDate = null),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back<PlaylistItem>(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Helper tile for date picking inside dialog
// ---------------------------------------------------------------------------

class _DatePickerTile extends StatelessWidget {
  const _DatePickerTile({
    required this.label,
    required this.value,
    required this.dateFormat,
    required this.onTap,
    required this.onClear,
  });

  final String label;
  final DateTime? value;
  final DateFormat dateFormat;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: (value != null && onClear != null)
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: onClear,
                  padding: EdgeInsets.zero,
                )
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(
            value == null ? 'Не задано' : dateFormat.format(value!),
            style: TextStyle(
              color: value == null ? Colors.grey.shade500 : null,
            ),
          ),
        ),
      ),
    );
  }
}
