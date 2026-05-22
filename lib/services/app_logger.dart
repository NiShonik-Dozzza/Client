import 'dart:io';
import 'package:flutter/foundation.dart';
import 'app_paths.dart';

class AppLogger {
  static const int _maxLogBytes = 5 * 1024 * 1024; // 5 MB
  static const int _keepRotations = 2;

  static final DateTime _startedAt = DateTime.now();
  static Future<void> _writeQueue = Future.value();

  static Future<void> log(String message) {
    final now = DateTime.now();
    final elapsed = now.difference(_startedAt);
    final line =
        '[${now.toIso8601String()}][+${_formatElapsed(elapsed)}] $message\n';
    debugPrint(line.trimRight());
    _writeQueue = _writeQueue
        .then((_) async {
          try {
            final file = await AppPaths.logFile();
            await _rotateIfNeeded(file);
            await file.writeAsString(line, mode: FileMode.append);
          } catch (_) {
            // если лог не пишется — не падаем
          }
        })
        .catchError((_) {});
    return Future.value();
  }

  static Future<void> _rotateIfNeeded(File logFile) async {
    if (!await logFile.exists()) return;
    final size = await logFile.length();
    if (size < _maxLogBytes) return;

    // Сдвигаем старые ротации: .2 удаляем, .1 → .2, текущий → .1
    for (var i = _keepRotations; i >= 1; i--) {
      final old = File('${logFile.path}.$i');
      if (await old.exists()) {
        if (i == _keepRotations) {
          await old.delete();
        } else {
          await old.rename('${logFile.path}.${i + 1}');
        }
      }
    }
    await logFile.rename('${logFile.path}.1');
  }

  static String _formatElapsed(Duration value) {
    final hours = value.inHours.toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    final milliseconds = (value.inMilliseconds % 1000).toString().padLeft(
      3,
      '0',
    );
    return '$hours:$minutes:$seconds.$milliseconds';
  }
}
