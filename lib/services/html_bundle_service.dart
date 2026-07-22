import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'app_paths.dart';

/// Распаковка бандла HTML-страницы.
///
/// Бандл приезжает как обычное медиа (zip с проверенным sha256), поэтому
/// целостность уже подтверждена кэшем медиа. Здесь решается другая задача —
/// **безопасность распаковки**.
///
/// Запись вида `../../device.json` внутри архива (zip-slip) при наивной
/// распаковке перезапишет файл рядом с каталогом бандла, а там лежит Bearer
/// устройства. Сервер такие архивы уже отклоняет, но полагаться на это одно
/// нельзя: бандл мог прийти из бэкапа, от другой версии панели или с сервера,
/// который кто-то подменил. Проверяем сами.
class HtmlBundleService {
  /// Столько файлов и байт достаточно для страницы; больше — повод отказаться,
  /// а не занимать место на экране.
  static const int _maxEntries = 500;
  static const int _maxUnpackedBytes = 64 * 1024 * 1024;

  /// Каталог с распакованной версией. Имя — sha256 бандла, поэтому одна и та же
  /// версия распаковывается один раз, а новая не затирает работающую.
  static Future<Directory> bundleDir(String sha256) async {
    final root = await AppPaths.rootDir();
    return Directory(p.join(root.path, 'html', sha256));
  }

  /// Распаковывает архив, если он ещё не распакован. Возвращает каталог.
  static Future<Directory> ensureUnpacked(File archiveFile, String sha256) async {
    final target = await bundleDir(sha256);
    final marker = File(p.join(target.path, '.ready'));
    if (await marker.exists()) return target;

    // Распаковываем во временный каталог и переносим целиком: если процесс
    // умрёт на середине, наружу не попадёт полураспакованная страница.
    final staging = Directory('${target.path}.tmp');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    try {
      final archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());
      if (archive.files.length > _maxEntries) {
        throw HtmlBundleError('в архиве слишком много файлов: ${archive.files.length}');
      }

      var unpacked = 0;
      for (final entry in archive.files) {
        final safe = _safeRelativePath(entry.name);
        if (safe == null) {
          throw HtmlBundleError('небезопасный путь в архиве: ${entry.name}');
        }
        if (!entry.isFile) {
          await Directory(p.join(staging.path, safe)).create(recursive: true);
          continue;
        }
        unpacked += entry.size;
        if (unpacked > _maxUnpackedBytes) {
          throw HtmlBundleError('распакованный бандл больше допустимого');
        }
        final out = File(p.join(staging.path, safe));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(entry.content as List<int>, flush: true);
      }

      await marker.parent.create(recursive: true);
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
      await File(p.join(target.path, '.ready')).writeAsString(sha256);
      await AppLogger.log('html bundle unpacked: $sha256 (${archive.files.length} файлов)');
      return target;
    } catch (e) {
      if (await staging.exists()) {
        await staging.delete(recursive: true).catchError((_) => staging);
      }
      rethrow;
    }
  }

  /// Нормализованный относительный путь либо null, если запись небезопасна.
  ///
  /// Отдельная функция ради теста: именно здесь ловится zip-slip, и проверять
  /// это нужно на строках, а не на живой файловой системе.
  static String? safeRelativePath(String raw) => _safeRelativePath(raw);

  static String? _safeRelativePath(String raw) {
    final name = raw.replaceAll('\\', '/').trim();
    if (name.isEmpty) return null;
    if (name.startsWith('/')) return null;
    // `C:/x` и `C:x` — абсолютные пути Windows.
    if (RegExp(r'^[a-zA-Z]:').hasMatch(name)) return null;

    final parts = <String>[];
    for (final segment in name.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') return null; // выход за пределы каталога бандла
      parts.add(segment);
    }
    if (parts.isEmpty) return null;
    return parts.join('/');
  }

  /// Удаляет распакованные версии, кроме перечисленных: страницы обновляются,
  /// а место на экране не резиновое.
  static Future<void> prune(Set<String> keepSha256) async {
    try {
      final root = await AppPaths.rootDir();
      final dir = Directory(p.join(root.path, 'html'));
      if (!await dir.exists()) return;
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! Directory) continue;
        if (keepSha256.contains(p.basename(entry.path))) continue;
        await entry.delete(recursive: true);
      }
    } catch (e) {
      await AppLogger.log('html bundle prune failed: $e');
    }
  }
}

class HtmlBundleError implements Exception {
  HtmlBundleError(this.message);

  final String message;

  @override
  String toString() => 'HtmlBundleError: $message';
}
