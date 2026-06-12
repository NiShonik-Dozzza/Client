import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/playlist_controller.dart';
import '../services/media_cache_service.dart';

/// Read-only экран диагностики устройства для сервисного инженера.
/// Открывается из редактора (тот уже за service-gate).
class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  PlaylistController get _controller => Get.find<PlaylistController>();

  static final DateFormat _timeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

  MediaCacheDiagnostics? _cache;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await _controller.refreshServerHealth();
    final cache = await _controller.cacheDiagnostics();
    if (!mounted) return;
    setState(() {
      _cache = cache;
      _refreshing = false;
    });
  }

  String _formatTime(DateTime? value) {
    if (value == null) return '—';
    final local = value.toLocal();
    final ago = DateTime.now().difference(local);
    return '${_timeFormat.format(local)}  (${_formatAgo(ago)})';
  }

  String _formatAgo(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} с назад';
    if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
    if (d.inHours < 24) return '${d.inHours} ч назад';
    return '${d.inDays} дн назад';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(1)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('Диагностика устройства'),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: Obx(() {
        final cache = _cache;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Section('Устройство', [
              _Row('Имя', _controller.deviceDisplayName),
              _Row('Device ID', _controller.deviceId, selectable: true),
              _Row('Версия клиента', _controller.clientVersion),
            ]),
            _Section('Подключение', [
              _Row('Адрес сервера', _controller.serverAddress, selectable: true),
              _StatusRow(
                'Состояние',
                _controller.isOfflineMode.value
                    ? 'Аварийный оффлайн-режим'
                    : (_controller.lastHeartbeatOk.value ? 'Online' : 'Нет связи'),
                ok: !_controller.isOfflineMode.value &&
                    _controller.lastHeartbeatOk.value,
              ),
              _Row('Последний heartbeat',
                  _formatTime(_controller.lastHeartbeatAt.value)),
              if (_controller.pinnedServerFingerprint() != null)
                _Row('Сертификат (закреплён)',
                    _controller.pinnedServerFingerprint()!,
                    selectable: true),
            ]),
            _Section('Контент', [
              _Row('Текущая ревизия',
                  _controller.currentRevision.isEmpty
                      ? '—'
                      : _controller.currentRevision),
              _Row('Последняя синхронизация manifest',
                  _formatTime(_controller.lastManifestSyncAt.value)),
            ]),
            _Section('Кэш медиа', [
              _Row('Файлов в кэше',
                  cache == null ? '…' : '${cache.cachedMediaCount}'),
              _Row('Размер кэша',
                  cache == null ? '…' : _formatBytes(cache.cacheSizeBytes)),
              _Row('Ошибок загрузки',
                  cache == null ? '…' : '${cache.downloadFailures}'),
            ]),
            _Section('Хранилище', [
              _StatusRow(
                'Состояние носителя',
                _controller.storageWarning.value.isNotEmpty
                    ? _controller.storageWarning.value
                    : 'Норма',
                ok: _controller.storageWarning.value.isEmpty &&
                    !_controller.storageSlow.value,
              ),
              _Row('Текущая папка',
                  _emptyDash(_controller.storageLocation.value),
                  selectable: true),
              _Row('Выбрано в настройках',
                  _emptyDash(_controller.configuredStorage), selectable: true),
              _Row('Задержка I/O',
                  _controller.storageLatencyMs.value > 0
                      ? '${_controller.storageLatencyMs.value} мс'
                      : '—'),
              _Row('Последняя проверка',
                  _formatTime(_controller.lastStorageCheckAt.value)),
              _Row('Последнее событие',
                  _emptyDash(_controller.lastStorageEvent.value)),
            ]),
            _Section('Сервер', [
              _Row('Имя', _controller.serverHealth.value?.name ?? '—'),
              _Row('Версия', _controller.serverHealth.value?.version ?? '—'),
              _Row('Build', _emptyDash(_controller.serverHealth.value?.build)),
              _Row('Revision',
                  _emptyDash(_controller.serverHealth.value?.revision),
                  selectable: true),
              _Row('Часовой пояс',
                  _emptyDash(_controller.serverHealth.value?.timezone)),
            ]),
          ],
        );
      }),
    );
  }

  String _emptyDash(String? value) =>
      (value == null || value.trim().isEmpty) ? '—' : value;
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.rows);

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD8DFEA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Color(0xFF1F2533),
            ),
          ),
          const SizedBox(height: 12),
          ...rows,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.selectable = false});

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final valueStyle = const TextStyle(
      fontWeight: FontWeight.w600,
      color: Color(0xFF1F2533),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF5F6B84)),
            ),
          ),
          Expanded(
            child: selectable
                ? SelectableText(value, style: valueStyle)
                : Text(value, style: valueStyle),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow(this.label, this.value, {required this.ok});

  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? Colors.green.shade700 : Colors.red.shade700;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 220,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF5F6B84)),
            ),
          ),
          Icon(ok ? Icons.circle : Icons.error_outline, size: 12, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontWeight: FontWeight.w700, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
