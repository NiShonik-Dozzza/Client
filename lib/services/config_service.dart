import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'app_paths.dart';
import 'app_logger.dart';

class AppConfig {
  final String mediaRoot;

  AppConfig({required this.mediaRoot});

  Map<String, dynamic> toJson() => {'media_root': mediaRoot};

  static AppConfig defaults(String docsMediaDir) {
    return AppConfig(mediaRoot: docsMediaDir);
  }
}

class ConfigService {
  AppConfig? _cached;

  Future<AppConfig> load() async {
    if (_cached != null) return _cached!;
    final mediaDir = await AppPaths.mediaDir();
    final defaultConfig = AppConfig.defaults(mediaDir.path);

    final file = await AppPaths.configFile();
    if (!await file.exists()) {
      await file.writeAsString(jsonEncode(defaultConfig.toJson()), flush: true);
      _cached = defaultConfig;
      await AppLogger.log('Config created: ${file.path}');
      return defaultConfig;
    }

    try {
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final mediaRoot = (map['media_root'] as String?)?.trim();
      final cfg = AppConfig(mediaRoot: (mediaRoot == null || mediaRoot.isEmpty) ? defaultConfig.mediaRoot : mediaRoot);
      _cached = cfg;
      await AppLogger.log('Config loaded: media_root=${cfg.mediaRoot}');
      return cfg;
    } catch (e) {
      _cached = defaultConfig;
      await AppLogger.log('Config parse error, using defaults: $e');
      return defaultConfig;
    }
  }

  Future<void> setMediaRoot(String newRoot) async {
    final file = await AppPaths.configFile();
    final cfg = AppConfig(mediaRoot: newRoot);
    await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
    _cached = cfg;
    await AppLogger.log('Config updated: media_root=$newRoot');
  }

  static String joinMedia(String mediaRoot, String filename) {
    return p.join(mediaRoot, p.basename(filename));
  }
}
