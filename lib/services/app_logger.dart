import 'dart:io';
import 'package:flutter/foundation.dart';
import 'app_paths.dart';

class AppLogger {
  static final DateTime _startedAt = DateTime.now();

  static Future<void> log(String message) async {
    final now = DateTime.now();
    final elapsed = now.difference(_startedAt);
    final line =
        '[${now.toIso8601String()}][+${_formatElapsed(elapsed)}] $message\n';
    debugPrint(line.trimRight());
    try {
      final file = await AppPaths.logFile();
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // если лог не пишется — не падаем
    }
  }

  static String _formatElapsed(Duration value) {
    final hours = value.inHours.toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    final milliseconds =
        (value.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$hours:$minutes:$seconds.$milliseconds';
  }
}
