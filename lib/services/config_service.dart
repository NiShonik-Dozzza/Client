import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'app_paths.dart';
import 'app_logger.dart';

class AppConfig {
  final String mediaRoot;
  final String serverUrl;
  final String selectedDisplayId;
  final int displayRotation;

  /// PIN хранится только как `sha256:<salt-hex>:<hash-hex>`, не в открытом виде.
  /// Это защита от случайного чтения config.json, а не криптостойкое хранение:
  /// короткий цифровой PIN подбирается оффлайн, но гейт здесь — физический доступ.
  final String servicePinHash;

  AppConfig({
    required this.mediaRoot,
    required this.serverUrl,
    required this.selectedDisplayId,
    required this.displayRotation,
    this.servicePinHash = '',
  });

  bool get hasServicePin => servicePinHash.isNotEmpty;

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
    if (servicePinHash.isNotEmpty) 'service_pin_hash': servicePinHash,
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
      var servicePinHash = (map['service_pin_hash'] as String?)?.trim() ?? '';
      final legacyPlaintextPin = (map['service_pin'] as String?)?.trim() ?? '';
      final migratedPin = servicePinHash.isEmpty && legacyPlaintextPin.isNotEmpty;
      if (migratedPin) {
        servicePinHash = hashServicePin(legacyPlaintextPin);
      }
      final cfg = AppConfig(
        mediaRoot: (mediaRoot == null || mediaRoot.isEmpty)
            ? defaultConfig.mediaRoot
            : mediaRoot,
        serverUrl: serverUrl,
        selectedDisplayId: selectedDisplayId,
        displayRotation: displayRotation,
        servicePinHash: servicePinHash,
      );
      _cached = cfg;
      if (migratedPin || map.containsKey('service_pin')) {
        // Немедленно перезаписываем config без plaintext-ключа service_pin.
        await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
        await AppLogger.log('Config: service pin migrated to hashed storage');
      }
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
    final current = _cached ?? await load();
    final cfg = AppConfig(
      mediaRoot: newRoot,
      serverUrl: current.serverUrl,
      selectedDisplayId: current.selectedDisplayId,
      displayRotation: current.displayRotation,
      servicePinHash: current.servicePinHash,
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
      servicePinHash: _cached?.servicePinHash ?? '',
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
    final trimmed = pin.trim();
    final cfg = AppConfig(
      mediaRoot: current.mediaRoot,
      serverUrl: current.serverUrl,
      selectedDisplayId: current.selectedDisplayId,
      displayRotation: current.displayRotation,
      servicePinHash: trimmed.isEmpty ? '' : hashServicePin(trimmed),
    );
    await file.writeAsString(jsonEncode(cfg.toJson()), flush: true);
    _cached = cfg;
    await AppLogger.log('Config updated: service_pin=${trimmed.isEmpty ? "cleared" : "set"}');
  }

  bool verifyServicePin(String entered) {
    final stored = _cached?.servicePinHash ?? '';
    if (stored.isEmpty) return true;
    return verifyServicePinHash(stored, entered.trim());
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
      servicePinHash: current.servicePinHash,
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

final _pinSaltRandom = Random.secure();

/// `sha256:<salt-hex>:<hash-hex>`, где hash = sha256(utf8(saltHex + pin)).
String hashServicePin(String pin) {
  final saltHex = List<int>.generate(16, (_) => _pinSaltRandom.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final digest = sha256.convert(utf8.encode(saltHex + pin));
  return 'sha256:$saltHex:$digest';
}

bool verifyServicePinHash(String stored, String entered) {
  final parts = stored.split(':');
  if (parts.length != 3 || parts[0] != 'sha256') return false;
  final expected = parts[2].toLowerCase();
  final actual = sha256.convert(utf8.encode(parts[1] + entered)).toString();
  // Сравнение без раннего выхода (константное по времени для равных длин).
  if (expected.length != actual.length) return false;
  var diff = 0;
  for (var i = 0; i < expected.length; i++) {
    diff |= expected.codeUnitAt(i) ^ actual.codeUnitAt(i);
  }
  return diff == 0;
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
