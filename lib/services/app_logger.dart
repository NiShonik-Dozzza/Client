import 'dart:io';
import 'package:flutter/foundation.dart';
import 'app_paths.dart';

class AppLogger {
  static Future<void> log(String message) async {
    final line = '[${DateTime.now().toIso8601String()}] $message\n';
    debugPrint(line.trimRight());
    try {
      final file = await AppPaths.logFile();
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // если лог не пишется — не падаем
    }
  }
}
