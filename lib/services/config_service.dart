import 'dart:convert';
import 'package:path/path.dart' as p;
import 'app_paths.dart';
import 'app_logger.dart';

class AppConfig {
  final String mediaRoot;
  final String serverUrl;
  final String selectedDisplayId;
  final int displayRotation;
  final String servicePin;

  AppConfig({
    required this.mediaRoot,
    required this.serverUrl,
    required this.selectedDisplayId,
    required this.displayRotation,
    this.servicePin = '',
  });

  String get apiBase {
    if (serverUrl.isEmpty) return '';
    return '${_normalizeServerUrl(serverUrl)}/api/v1/device';
  }

  Map<String, dynamic> toJson() => {
    'media_root': mediaRoot,
    'server_url': serverUrl,
    if (selectedDisplayId.isNotEmpty) 'selected_display_id': selectedDisplayId,
    'display_rotation': displayRotation,
    if (serverUrl.isNotEmpty) 'api_base': apiBase,
    if (servicePin.isNotEmpty) 'service_pin': servicePin,
  };

  static AppConfig defaults(String docsMediaDir) {
    return AppConfig(
      mediaRoot: docsMediaDir,
      serverUrl: '',
      selectedDisplayId: '',
      displayRotation: 0,
    );
  }
}

class ConfigService {
  AppConfig? _cached;

  AppConfig? get cached => _cached;

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
      final selectedDisplayId =
          (map['selected_display_id'] as String?)?.trim() ?? '';
      final displayRotation = _normalizeRotation(
        _asInt(map['display_rotation']),
      );
      final servicePin = (map['service_pin'] as String?)?.trim() ?? '';
      final cfg = AppConfig(
        mediaRoot: (mediaRoot == null || mediaRoot.isEmpty)
            ? defaultConfig.mediaRoot
            : mediaRoot,
        serverUrl: serverUrl,
        selectedDisplayId: selectedDisplayId,
        displayRotation: displayRotation,
        servicePin: servicePin,
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
      selectedDisplayId:
          _cached?.selectedDisplayId ??
          AppConfig.defaults(newRoot).selectedDisplayId,
      displayRotation:
          _cached?.displayRotation ??
          AppConfig.defaults(newRoot).displayRotation,
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
      selectedDisplayId: _cached?.selectedDisplayId ?? '',
      displayRotation: _cached?.displayRotation ?? 0,
    );
    await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
    _cached = cfg;
    await AppLogger.log('Config updated: server_url=$normalized');
  }

  Future<void> setApiBase(String newBase) async {
    await setServerUrl(_extractServerUrl('', newBase));
  }

  Future<void> setServicePin(String pin) async {
    final file = await AppPaths.configFile();
    final current = _cached ?? await load();
    final cfg = AppConfig(
      mediaRoot: current.mediaRoot,
      serverUrl: current.serverUrl,
      selectedDisplayId: current.selectedDisplayId,
      displayRotation: current.displayRotation,
      servicePin: pin.trim(),
    );
    await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
    _cached = cfg;
    await AppLogger.log('Config updated: service_pin=${pin.isEmpty ? "cleared" : "set"}');
  }

  Future<void> setDisplayPreferences({
    String? selectedDisplayId,
    int? displayRotation,
  }) async {
    final file = await AppPaths.configFile();
    final current = _cached ?? await load();
    final cfg = AppConfig(
      mediaRoot: current.mediaRoot,
      serverUrl: current.serverUrl,
      selectedDisplayId: (selectedDisplayId ?? current.selectedDisplayId)
          .trim(),
      displayRotation: _normalizeRotation(
        displayRotation ?? current.displayRotation,
      ),
    );
    await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
    _cached = cfg;
    await AppLogger.log(
      'Config updated: selected_display_id=${cfg.selectedDisplayId} display_rotation=${cfg.displayRotation}',
    );
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

int _asInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

int _normalizeRotation(int value) {
  const allowed = <int>{0, 90, 180, 270};
  final normalized = value % 360;
  if (allowed.contains(normalized)) {
    return normalized;
  }
  return 0;
}
