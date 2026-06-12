import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'app_paths.dart';

/// Хранилище доверенных самоподписанных сертификатов (TOFU-пиннинг).
///
/// dart:io на Android не доверяет пользовательским CA из системного
/// хранилища, поэтому доверие локальному CA стенда (efir.local) живёт
/// внутри приложения: оператор один раз подтверждает отпечаток сертификата,
/// дальше соединения с этим host:port принимаются только с тем же сертификатом.
/// Валидные (публичные) сертификаты проходят обычную проверку и сюда не попадают.
class TrustStore {
  TrustStore._();

  static final TrustStore instance = TrustStore._();

  /// host:port (lowercase) → sha256 DER сертификата (hex lowercase).
  final Map<String, String> _pinned = {};
  bool _loaded = false;

  static String fingerprintOf(X509Certificate cert) =>
      sha256.convert(cert.der).toString();

  /// Отпечаток для отображения оператору: AB:CD:EF:…
  static String displayFingerprint(String hex) {
    final upper = hex.toUpperCase();
    final parts = <String>[];
    for (var i = 0; i + 2 <= upper.length; i += 2) {
      parts.add(upper.substring(i, i + 2));
    }
    return parts.join(':');
  }

  static String _key(String host, int port) => '${host.toLowerCase()}:$port';

  Future<File> _file() async {
    final dir = await AppPaths.rootDir();
    return File(p.join(dir.path, 'trust.json'));
  }

  /// Загружает пины в память. Вызывать до создания HTTP-клиентов:
  /// badCertificateCallback синхронный и читает только память.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map) {
        raw.forEach((key, value) {
          if (key is String && value is String) {
            _pinned[key.toLowerCase()] = value.toLowerCase();
          }
        });
      }
    } catch (e) {
      await AppLogger.log('TrustStore load error (ignored): $e');
    }
  }

  /// Синхронная проверка для badCertificateCallback.
  bool isTrusted(X509Certificate cert, String host, int port) {
    final expected = _pinned[_key(host, port)];
    if (expected == null) return false;
    return fingerprintOf(cert) == expected;
  }

  String? pinnedFingerprint(String host, int port) => _pinned[_key(host, port)];

  Future<void> trust(String host, int port, String fingerprintHex) async {
    _pinned[_key(host, port)] = fingerprintHex.toLowerCase();
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(_pinned), flush: true);
      await AppLogger.log(
        'TrustStore: pinned $host:$port ${displayFingerprint(fingerprintHex)}',
      );
    } catch (e) {
      await AppLogger.log('TrustStore save error: $e');
    }
  }
}
