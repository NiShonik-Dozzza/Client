import 'dart:convert';
import 'package:path/path.dart' as p;
import 'app_paths.dart';
import 'app_logger.dart';

class AppConfig {
  final String mediaRoot;
  final String serverUrl;

  AppConfig({required this.mediaRoot, required this.serverUrl});

  String get apiBase {
    if (serverUrl.isEmpty) return '';
    return '${_normalizeServerUrl(serverUrl)}/api/v1/device';
  }

  Map<String, dynamic> toJson() => {
    'media_root': mediaRoot,
    'server_url': serverUrl,
    if (serverUrl.isNotEmpty) 'api_base': apiBase,
  };

  static AppConfig defaults(String docsMediaDir) {
    return AppConfig(mediaRoot: docsMediaDir, serverUrl: '');
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
      final serverUrl = _extractServerUrl(
        (map['server_url'] as String?)?.trim(),
        (map['api_base'] as String?)?.trim(),
      );
      final cfg = AppConfig(
        mediaRoot: (mediaRoot == null || mediaRoot.isEmpty)
            ? defaultConfig.mediaRoot
            : mediaRoot,
        serverUrl: serverUrl,
      );
      _cached = cfg;
      await AppLogger.log(
        'Config loaded: media_root=${cfg.mediaRoot} server_url=${cfg.serverUrl} api_base=${cfg.apiBase}',
      );
      return cfg;
    } catch (e) {
      _cached = defaultConfig;
      await AppLogger.log('Config parse error, using defaults: $e');
      return defaultConfig;
    }
  }

  Future<void> setMediaRoot(String newRoot) async {
    final file = await AppPaths.configFile();
    final cfg = AppConfig(
      mediaRoot: newRoot,
      serverUrl: _cached?.serverUrl ?? AppConfig.defaults(newRoot).serverUrl,
    );
    await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
    _cached = cfg;
    await AppLogger.log('Config updated: media_root=$newRoot');
  }

  Future<void> setServerUrl(String newServerUrl) async {
    final file = await AppPaths.configFile();
    final normalized = _normalizeServerUrl(newServerUrl);
    final cfg = AppConfig(
      mediaRoot: _cached?.mediaRoot ?? (await AppPaths.mediaDir()).path,
      serverUrl: normalized,
    );
    await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
    _cached = cfg;
    await AppLogger.log('Config updated: server_url=$normalized');
  }

  Future<void> setApiBase(String newBase) async {
    await setServerUrl(_extractServerUrl('', newBase));
  }

  static String joinMedia(String mediaRoot, String filename) {
    return p.join(mediaRoot, p.basename(filename));
  }
}

String _extractServerUrl(String? serverUrl, String? apiBase) {
  final direct = _normalizeServerUrl(serverUrl ?? '');
  if (direct.isNotEmpty) return direct;
  final legacy = _normalizeServerUrl(apiBase ?? '');
  if (legacy.isEmpty) return '';
  final uri = Uri.tryParse(legacy);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return '';
  }
  return uri
      .replace(path: '', query: null, fragment: null)
      .toString()
      .replaceFirst(RegExp(r'/$'), '');
}

String _normalizeServerUrl(String value) {
  var normalized = value.trim();
  if (normalized.isEmpty) return '';
  if (!normalized.contains('://')) {
    normalized = 'http://$normalized';
  }
  final uri = Uri.tryParse(normalized);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return normalized.replaceFirst(RegExp(r'/+$'), '');
  }
  return uri
      .replace(path: '', query: null, fragment: null)
      .toString()
      .replaceFirst(RegExp(r'/$'), '');
}
