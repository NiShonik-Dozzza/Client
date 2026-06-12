import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import '../controllers/playlist_controller.dart';
import '../models/manifest.dart';
import '../models/playlist_item.dart';
import '../services/app_paths.dart';
import '../services/app_logger.dart';
import 'status_screen.dart';
import 'setup_screen.dart';

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

  // Авто-закрытие редактора, если оператор оставил его открытым без действий.
  static const Duration _inactivityTimeout = Duration(seconds: 30);
  Timer? _inactivityTimer;

  // Периодическое обновление таймлайна (времена слотов / текущий элемент).
  Timer? _timelineTimer;

  // Превью (миниатюры) для таймлайна: онлайн — по mediaId, оффлайн — по имени файла.
  final Map<int, String> _previewByMediaId = {};
  final Map<String, String> _previewByFilename = {};

  late final PlaylistController _controller;

  @override
  void initState() {
    super.initState();
    _controller = Get.find<PlaylistController>();

    _offlineModeWorker = ever<bool>(_controller.isOfflineMode, (mode) {
      setState(() {
        _isOfflineMode = mode;
      });
      _loadPlaylist();
    });

    _isOfflineMode = _controller.isOfflineMode.value;
    _loadPlaylist();
    _resetInactivityTimer();
    _timelineTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_resolvePreviews());
    });
  }

  @override
  void dispose() {
    _offlineModeWorker?.dispose();
    _statusTimer?.cancel();
    _inactivityTimer?.cancel();
    _timelineTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Перезапускает таймер бездействия. Вызывается при любом действии оператора.
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(_inactivityTimeout, _onInactivityTimeout);
  }

  void _onInactivityTimeout() {
    if (!mounted) return;
    unawaited(AppLogger.log('Editor auto-closed: inactivity timeout'));
    Get.back();
  }

  /// Открывает read-only диагностику. На время просмотра ставим таймер
  /// бездействия редактора на паузу, по возврату — перезапускаем.
  Future<void> _openStatus() async {
    _inactivityTimer?.cancel();
    await Get.to(() => const StatusScreen());
    if (mounted) _resetInactivityTimer();
  }

  /// Настройки устройства (как первичная конфигурация, но без регистрации,
  /// имя — read-only). На время — пауза авто-закрытия редактора.
  Future<void> _openSettings() async {
    _inactivityTimer?.cancel();
    await Get.to(() => const SetupScreen(settingsMode: true));
    if (mounted) _resetInactivityTimer();
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
    unawaited(_resolvePreviews());
  }

  /// Разрешает пути к закэшированным изображениям для миниатюр таймлайна
  /// (видео получают плейсхолдер — извлечение кадра слишком тяжело для списка).
  Future<void> _resolvePreviews() async {
    var changed = false;
    if (_isOfflineMode) {
      final dir = await AppPaths.mediaDir();
      for (final item in _items) {
        if (!item.isImage || _previewByFilename.containsKey(item.filename)) {
          continue;
        }
        final path = '${dir.path}/${item.baseName}';
        if (await File(path).exists()) {
          _previewByFilename[item.filename] = path;
          changed = true;
        }
      }
    } else {
      final manifest = _controller.manifest;
      if (manifest != null) {
        final now = DateTime.now();
        final mediaIds = <int>{};
        for (final item in manifest.items.where(
          (i) => i.endTime.isAfter(now),
        )) {
          if (item.contentType == ManifestContentType.media) {
            mediaIds.add(item.contentId);
          } else {
            final pl = manifest.playlistById(item.contentId);
            if (pl != null) {
              for (final pi in pl.items) {
                mediaIds.add(pi.mediaId);
              }
            }
          }
        }
        for (final id in mediaIds) {
          if (_previewByMediaId.containsKey(id)) continue;
          final media = manifest.mediaById(id);
          if (media == null || !media.isImage) continue;
          final path = await _controller.cachedMediaPath(media);
          if (path != null) {
            _previewByMediaId[id] = path;
            changed = true;
          }
        }
      }
    }
    if (changed && mounted) setState(() {});
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
    // Любое действие (касание, прокрутка, клавиша/D-pad) сбрасывает таймер
    // бездействия, по которому редактор сам закрывается и возвращает плеер.
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, __) {
        _resetInactivityTimer();
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _resetInactivityTimer(),
        onPointerMove: (_) => _resetInactivityTimer(),
        onPointerSignal: (_) => _resetInactivityTimer(),
        child: Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('Воспроизведение'),
        actions: [
          if (_isOfflineMode && _dirty)
            IconButton(
              icon: Icon(Icons.save, color: Colors.green.shade700),
              onPressed: _savePlaylist,
              tooltip: 'Сохранить плейлист',
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
            tooltip: 'Настройки устройства',
          ),
          IconButton(
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: _openStatus,
            tooltip: 'Диагностика устройства',
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
        ),
      ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTimeline(),
        Expanded(
          child: _isOfflineMode ? _buildOfflineModeList() : _buildOnlineHint(),
        ),
      ],
    );
  }

  /// Горизонтальный таймлайн «что дальше воспроизводится».
  /// Онлайн — слоты манифеста с временами; оффлайн — порядок локального плейлиста.
  Widget _buildTimeline() {
    final entries = _isOfflineMode
        ? _offlineTimelineEntries()
        : _onlineTimelineEntries();
    final caption = _isOfflineMode
        ? 'Резервный плейлист (по кругу)'
        : 'Ревизия: ${_controller.manifest?.revision ?? '—'}';

    return Container(
      height: 210,
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.timeline, size: 18, color: Color(0xFF1F2533)),
              const SizedBox(width: 8),
              const Text(
                'Что дальше',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Color(0xFF1F2533),
                ),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  caption,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      _isOfflineMode
                          ? 'Резервный плейлист пуст'
                          : 'Нет запланированного контента',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, i) =>
                        _TimelineCard(entry: entries[i]),
                  ),
          ),
        ],
      ),
    );
  }

  List<_TimelineEntry> _onlineTimelineEntries() {
    final manifest = _controller.manifest;
    if (manifest == null) return const [];
    final now = DateTime.now();
    final timeFmt = DateFormat('HH:mm');
    final upcoming =
        manifest.items.where((item) => item.endTime.isAfter(now)).toList()
          ..sort((a, b) => a.startTime.compareTo(b.startTime));

    return upcoming.take(20).map((item) {
      final slotTime =
          '${timeFmt.format(item.startTime)}–${timeFmt.format(item.endTime)}';
      if (item.contentType == ManifestContentType.media) {
        final media = manifest.mediaById(item.contentId);
        final isVideo = media?.isVideo ?? false;
        return _TimelineEntry(
          title: media?.safeBaseName ?? 'Медиа #${item.contentId}',
          icon: isVideo ? Icons.movie_outlined : Icons.image_outlined,
          timeLabel: slotTime,
          isCurrent: item.isActiveAt(now),
          isVideo: isVideo,
          previewPath: media != null ? _previewByMediaId[media.id] : null,
        );
      }
      // Плейлист — раскрываем в широкий блок с вложенными элементами.
      final playlist = manifest.playlistById(item.contentId);
      final children = <_TimelineEntry>[];
      if (playlist != null) {
        for (final pi in playlist.items) {
          final media = manifest.mediaById(pi.mediaId);
          final isVideo = media?.isVideo ?? false;
          children.add(
            _TimelineEntry(
              title: media?.safeBaseName ?? 'Медиа #${pi.mediaId}',
              icon: isVideo ? Icons.movie_outlined : Icons.image_outlined,
              timeLabel: '${pi.durationSec} c',
              isCurrent: false,
              isVideo: isVideo,
              previewPath: media != null ? _previewByMediaId[media.id] : null,
            ),
          );
        }
      }
      return _TimelineEntry(
        title: (playlist?.name.isNotEmpty ?? false)
            ? playlist!.name
            : 'Плейлист #${item.contentId}',
        icon: Icons.playlist_play,
        timeLabel: slotTime,
        isCurrent: item.isActiveAt(now),
        children: children,
      );
    }).toList();
  }

  List<_TimelineEntry> _offlineTimelineEntries() {
    return _items
        .map(
          (item) => _TimelineEntry(
            title: item.baseName,
            icon: item.isVideo ? Icons.movie_outlined : Icons.image_outlined,
            timeLabel: item.isVideo ? 'видео' : '${item.durationSeconds} c',
            isCurrent: false,
            isVideo: item.isVideo,
            previewPath: _previewByFilename[item.filename],
          ),
        )
        .toList();
  }

  Widget _buildOnlineHint() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_done, size: 64, color: Colors.blue.shade200),
          const SizedBox(height: 12),
          const Text(
            'Управление через сервер',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            'Контент и расписание задаются в панели управления.',
            style: TextStyle(color: Colors.grey.shade600),
          ),
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

/// Запись таймлайна «что дальше воспроизводится».
/// Если [children] не null — это плейлист, раскрываемый в широкий блок.
class _TimelineEntry {
  const _TimelineEntry({
    required this.title,
    required this.icon,
    required this.timeLabel,
    required this.isCurrent,
    this.isVideo = false,
    this.previewPath,
    this.children,
  });

  final String title;
  final IconData icon;
  final String timeLabel;
  final bool isCurrent;
  final bool isVideo;
  final String? previewPath;
  final List<_TimelineEntry>? children;
}

const _accentColor = Color(0xFF3167E3);
const _mutedColor = Color(0xFF5F6B84);
const _borderColor = Color(0xFFD8DFEA);

Widget _nowBadge() => Container(
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
  decoration: BoxDecoration(
    color: _accentColor,
    borderRadius: BorderRadius.circular(8),
  ),
  child: const Text(
    'Сейчас',
    style: TextStyle(
      color: Colors.white,
      fontSize: 10,
      fontWeight: FontWeight.w700,
    ),
  ),
);

/// Миниатюра: реальное изображение из кэша или плейсхолдер с иконкой типа.
Widget _timelineThumb(_TimelineEntry entry, {double radius = 8}) {
  final placeholder = Container(
    color: const Color(0xFFEFF2F7),
    alignment: Alignment.center,
    child: Icon(entry.icon, color: const Color(0xFF9AA7BD)),
  );
  Widget inner = placeholder;
  if (entry.previewPath != null) {
    inner = Image.file(
      File(entry.previewPath!),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => placeholder,
    );
  }
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: SizedBox.expand(child: inner),
  );
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.entry});

  final _TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    if (entry.children != null) {
      return _PlaylistTimelineCard(entry: entry);
    }
    final accent = entry.isCurrent ? _accentColor : _borderColor;
    return Container(
      width: 150,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: entry.isCurrent ? const Color(0xFFF4F8FF) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent, width: entry.isCurrent ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _timelineThumb(entry),
                if (entry.isCurrent)
                  Positioned(top: 6, left: 6, child: _nowBadge()),
                if (entry.isVideo)
                  const Positioned(
                    right: 6,
                    bottom: 6,
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            entry.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: Color(0xFF1F2533),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            entry.timeLabel,
            style: const TextStyle(fontSize: 12, color: _mutedColor),
          ),
        ],
      ),
    );
  }
}

/// Широкий блок плейлиста: имя слота + горизонтальная лента вложенных элементов.
class _PlaylistTimelineCard extends StatelessWidget {
  const _PlaylistTimelineCard({required this.entry});

  final _TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    final children = entry.children ?? const <_TimelineEntry>[];
    final accent = entry.isCurrent ? _accentColor : _borderColor;

    return Container(
      width: 320,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: entry.isCurrent ? const Color(0xFFF4F8FF) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent, width: entry.isCurrent ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.playlist_play,
                size: 18,
                color: entry.isCurrent ? _accentColor : _mutedColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: Color(0xFF1F2533),
                  ),
                ),
              ),
              if (entry.isCurrent) _nowBadge(),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${entry.timeLabel} · ${children.length} элем.',
            style: const TextStyle(fontSize: 12, color: _mutedColor),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: children.isEmpty
                ? const SizedBox.shrink()
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: children.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) => _PlaylistMini(entry: children[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistMini extends StatelessWidget {
  const _PlaylistMini({required this.entry});

  final _TimelineEntry entry;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _timelineThumb(entry, radius: 6),
                if (entry.isVideo)
                  const Positioned(
                    right: 2,
                    bottom: 2,
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9, color: _mutedColor),
          ),
        ],
      ),
    );
  }
}
