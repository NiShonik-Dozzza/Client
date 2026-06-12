import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'app_paths.dart';

/// Результат пробы носителя: доступность, задержка I/O и причина ошибки.
class StorageProbe {
  const StorageProbe({required this.ok, required this.latency, this.error});

  final bool ok;
  final Duration latency;
  final String? error;
}

/// Доступный том для хранения медиа-кэша (внутренняя память или внешний носитель).
class StorageVolume {
  const StorageVolume({
    required this.mediaPath,
    required this.label,
    required this.isInternal,
    required this.isRemovable,
    this.freeBytes,
  });

  /// Конкретная папка для медиа на этом томе (куда будет писаться кэш).
  final String mediaPath;
  final String label;
  final bool isInternal;
  final bool isRemovable;

  /// Свободное место в байтах; null — если определить не удалось.
  final int? freeBytes;
}

/// Обнаружение и валидация мест хранения контента на разных платформах.
///
/// Внешняя запись без спец-разрешений:
/// - Android: app-specific external dirs (`getExternalStorageDirectories`) —
///   включают SD/USB-тома, доступны для записи без runtime-permission;
/// - Windows: корни доступных дисков (`X:\efir_media`);
/// - Linux: примонтированные носители под `/media`, `/run/media`, `/mnt`.
class StorageService {
  /// Лёгкий путь к внутренней памяти (без подсчёта свободного места).
  Future<String> internalMediaPath() async => (await AppPaths.mediaDir()).path;

  /// Внутренняя память приложения (значение по умолчанию).
  Future<StorageVolume> internalVolume() async {
    final dir = await AppPaths.mediaDir();
    return StorageVolume(
      mediaPath: dir.path,
      label: 'Внутренняя память',
      isInternal: true,
      isRemovable: false,
      freeBytes: await _freeBytes(dir.path),
    );
  }

  /// Список томов: внутренняя память первой, затем внешние носители.
  Future<List<StorageVolume>> listVolumes() async {
    final volumes = <StorageVolume>[await internalVolume()];
    try {
      if (Platform.isAndroid) {
        volumes.addAll(await _androidExternalVolumes());
      } else if (Platform.isWindows) {
        volumes.addAll(await _windowsVolumes());
      } else if (Platform.isLinux) {
        volumes.addAll(await _linuxVolumes());
      }
    } catch (e) {
      await AppLogger.log('storage volume scan error: $e');
    }
    return volumes;
  }

  /// Проверяет, что путь существует/создаётся и доступен для записи.
  Future<bool> isWritable(String mediaPath) async =>
      (await probe(mediaPath)).ok;

  /// Проба носителя с замером задержки и таймаутом. Таймаут защищает от
  /// зависания на медленном/отвалившемся носителе (USB вынули во время записи).
  Future<StorageProbe> probe(
    String mediaPath, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final sw = Stopwatch()..start();
    if (mediaPath.trim().isEmpty) {
      return StorageProbe(ok: false, latency: sw.elapsed, error: 'empty path');
    }
    try {
      final ok = await _writeProbe(mediaPath).timeout(timeout);
      sw.stop();
      return StorageProbe(ok: ok, latency: sw.elapsed);
    } on TimeoutException {
      sw.stop();
      await AppLogger.log('storage probe timeout: $mediaPath (${sw.elapsedMilliseconds}ms)');
      return StorageProbe(ok: false, latency: sw.elapsed, error: 'timeout');
    } catch (e) {
      sw.stop();
      await AppLogger.log('storage probe failed: $mediaPath ($e)');
      return StorageProbe(ok: false, latency: sw.elapsed, error: '$e');
    }
  }

  Future<bool> _writeProbe(String mediaPath) async {
    final dir = Directory(mediaPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final probe = File(p.join(dir.path, '.efir_write_probe'));
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return true;
  }

  Future<List<StorageVolume>> _androidExternalVolumes() async {
    final dirs = await getExternalStorageDirectories() ?? const [];
    final out = <StorageVolume>[];
    for (var i = 0; i < dirs.length; i++) {
      // dirs[0] — primary emulated storage (по сути внутренняя), пропускаем.
      if (i == 0) continue;
      final mediaPath = p.join(dirs[i].path, 'media');
      out.add(
        StorageVolume(
          mediaPath: mediaPath,
          label: 'Внешний носитель $i',
          isInternal: false,
          isRemovable: true,
          freeBytes: await _freeBytes(dirs[i].path),
        ),
      );
    }
    return out;
  }

  Future<List<StorageVolume>> _windowsVolumes() async {
    final out = <StorageVolume>[];
    for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final letter = String.fromCharCode(c);
      final root = '$letter:\\';
      if (!await Directory(root).exists()) continue;
      out.add(
        StorageVolume(
          mediaPath: p.join(root, 'efir_media'),
          label: 'Диск $letter:',
          isInternal: false,
          isRemovable: letter != 'C', // эвристика: системный C: не съёмный
          freeBytes: await _freeBytes(root),
        ),
      );
    }
    return out;
  }

  Future<List<StorageVolume>> _linuxVolumes() async {
    final out = <StorageVolume>[];
    final user = Platform.environment['USER'] ?? '';
    final bases = <String>['/media/$user', '/run/media/$user', '/media', '/mnt'];
    final seen = <String>{};
    for (final base in bases) {
      final baseDir = Directory(base);
      if (!await baseDir.exists()) continue;
      await for (final entry in baseDir.list(followLinks: false)) {
        if (entry is! Directory || !seen.add(entry.path)) continue;
        out.add(
          StorageVolume(
            mediaPath: p.join(entry.path, 'efir_media'),
            label: p.basename(entry.path),
            isInternal: false,
            isRemovable: true,
            freeBytes: await _freeBytes(entry.path),
          ),
        );
      }
    }
    return out;
  }

  /// Best-effort свободное место. Linux/macOS — через `df`; иначе null
  /// (точные цифры для Windows/Android — отдельным этапом).
  Future<int?> _freeBytes(String path) async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        final res = await Process.run('df', ['-kP', path]);
        if (res.exitCode != 0) return null;
        final lines = (res.stdout as String).trim().split('\n');
        if (lines.length < 2) return null;
        final cols = lines.last.trim().split(RegExp(r'\s+'));
        // df -kP: Filesystem 1024-blocks Used Available Capacity Mounted-on
        if (cols.length < 4) return null;
        final availKb = int.tryParse(cols[3]);
        return availKb == null ? null : availKb * 1024;
      }
    } catch (_) {
      // df недоступен — молча возвращаем null
    }
    return null;
  }
}
