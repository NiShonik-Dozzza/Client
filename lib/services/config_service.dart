import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'app_paths.dart';
import 'app_logger.dart';

class AppConfig {
  final String mediaRoot;
  final String apiBase;

  AppConfig({required this.mediaRoot, required this.apiBase});

  Map<String, dynamic> toJson() => {'media_root': mediaRoot, 'api_base': apiBase};

  static AppConfig defaults(String docsMediaDir) {
    return AppConfig(
      mediaRoot: docsMediaDir,
      apiBase: 'http://localhost:8000/api/v1',
    );
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
      final apiBase = (map['api_base'] as String?)?.trim();
      final cfg = AppConfig(
        mediaRoot: (mediaRoot == null || mediaRoot.isEmpty) ? defaultConfig.mediaRoot : mediaRoot,
        apiBase: (apiBase == null || apiBase.isEmpty) ? defaultConfig.apiBase : apiBase,
      );
      _cached = cfg;
      await AppLogger.log('Config loaded: media_root=${cfg.mediaRoot} api_base=${cfg.apiBase}');
      return cfg;
    } catch (e) {
      _cached = defaultConfig;
      await AppLogger.log('Config parse error, using defaults: $e');
      return defaultConfig;
    }
  }

  Future<void> setMediaRoot(String newRoot) async {
    final file = await AppPaths.configFile();
    final cfg = AppConfig(mediaRoot: newRoot, apiBase: _cached?.apiBase ?? AppConfig.defaults(newRoot).apiBase);
    await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
    _cached = cfg;
    await AppLogger.log('Config updated: media_root=$newRoot');
  }

  Future<void> setApiBase(String newBase) async {
    final file = await AppPaths.configFile();
    final cfg = AppConfig(mediaRoot: _cached?.mediaRoot ?? (await AppPaths.mediaDir()).path, apiBase: newBase);
    await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
    _cached = cfg;
    await AppLogger.log('Config updated: api_base=$newBase');
  }

  static String joinMedia(String mediaRoot, String filename) {
    return p.join(mediaRoot, p.basename(filename));
  }
}
