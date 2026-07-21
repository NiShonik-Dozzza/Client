import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import 'app_http.dart';
import 'app_logger.dart';
import 'app_paths.dart';

/// Публичный ключ Ed25519 (base64 сырых 32 байт), которым подписаны сборки.
///
/// Это ЕДИНСТВЕННАЯ граница доверия для обновлений. Панель артефакт только
/// раздаёт: если сервер скомпрометирован, подпись всё равно не сойдётся и мы
/// ничего не поставим. Приватная половина живёт офлайн/в секретах CI и на
/// сервер никогда не попадает.
///
/// Задаётся при сборке: `--dart-define=EFIR_UPDATE_PUBLIC_KEY=<base64>`.
/// Пустой ключ = обновления через панель отключены (fail-closed): лучше не
/// обновляться вовсе, чем ставить непроверенный бинарь.
const String kUpdatePublicKeyBase64 = String.fromEnvironment(
  'EFIR_UPDATE_PUBLIC_KEY',
  defaultValue: '',
);

/// Что сервер предлагает поставить.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.size,
    required this.sha256,
    required this.signature,
    required this.downloadUrl,
    required this.mandatory,
    required this.releaseNotes,
    required this.installAllowedNow,
    required this.updateWindow,
  });

  final String version;
  final int buildNumber;
  final int size;
  final String sha256;
  final String signature;
  final String downloadUrl;
  final bool mandatory;
  final String releaseNotes;

  /// Скачивать можно всегда, ставить — только в окне: установка рвёт показ.
  final bool installAllowedNow;
  final String updateWindow;

  static UpdateInfo? fromJson(Map<String, dynamic> json) {
    if (json['available'] != true) return null;
    return UpdateInfo(
      version: (json['version'] as String?)?.trim() ?? '',
      buildNumber: _asInt(json['build_number']),
      size: _asInt(json['size']),
      sha256: ((json['sha256'] as String?) ?? '').trim().toLowerCase(),
      signature: (json['signature'] as String?)?.trim() ?? '',
      downloadUrl: (json['download_url'] as String?)?.trim() ?? '',
      mandatory: json['mandatory'] == true,
      releaseNotes: (json['release_notes'] as String?)?.trim() ?? '',
      installAllowedNow: json['install_allowed_now'] != false,
      updateWindow: (json['update_window'] as String?)?.trim() ?? '',
    );
  }

  String get fileName {
    final fromUrl = p.basename(Uri.parse(downloadUrl).path);
    final ext = p.extension(fromUrl);
    return 'efir-$version${ext.isEmpty ? _defaultExtension : ext}';
  }

  static String get _defaultExtension {
    if (Platform.isAndroid) return '.apk';
    if (Platform.isWindows) return '.exe';
    return '.tar.gz';
  }
}

/// Артефакт скачан и проверен, но ещё не установлен.
class PreparedUpdate {
  const PreparedUpdate(this.info, this.file);

  final UpdateInfo info;
  final File file;
}

class UpdateRejected implements Exception {
  UpdateRejected(this.reason);

  final String reason;

  @override
  String toString() => 'UpdateRejected: $reason';
}

/// Проверка, скачивание и верификация обновлений клиента.
///
/// Установку сервис НЕ делает: она платформозависима и требует прав
/// (Device Owner на Android, задача SYSTEM на Windows, systemd на Linux).
/// Здесь заканчивается общая часть — проверенный файл и статус `ready`
/// в панели, откуда оператор видит, что экран готов.
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? AppHttp.client();

  final http.Client _client;

  static final _algorithm = Ed25519();

  /// Есть ли вообще смысл спрашивать сервер: без вшитого ключа мы всё равно
  /// ничего не поставим.
  static bool get isEnabled => kUpdatePublicKeyBase64.trim().isNotEmpty;

  /// Платформа в терминах сервера.
  static String get platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }

  /// Архитектура в терминах сервера. Важно для Android: на дешёвых TV
  /// стоит 32-битная система, туда идёт только armv7.
  static String get arch {
    switch (Abi.current()) {
      case Abi.androidArm64:
      case Abi.linuxArm64:
      case Abi.macosArm64:
        return 'arm64';
      case Abi.androidArm:
      case Abi.linuxArm:
        return 'armv7';
      default:
        return 'x64';
    }
  }

  static Future<({String version, int build})> currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return (version: info.version, build: int.tryParse(info.buildNumber) ?? 0);
    } catch (_) {
      return (version: '', build: 0);
    }
  }

  Future<Directory> _updatesDir() async {
    final root = await AppPaths.rootDir();
    final dir = Directory(p.join(root.path, 'updates'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<UpdateInfo?> check({
    required String serverBase,
    required String deviceId,
    required String token,
  }) async {
    if (!isEnabled) return null;
    final uri = Uri.parse(
      '$serverBase/api/v1/device/update/check',
    ).replace(queryParameters: {'device_id': deviceId});
    final response = await _client.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw Exception('update check failed: ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final info = UpdateInfo.fromJson(decoded);
    if (info == null) return null;

    // Сервер обязан прислать и хеш, и подпись. Пустое поле — либо баг, либо
    // подмена ответа: в обоих случаях ставить нечего.
    if (info.sha256.length != 64 || info.signature.isEmpty) {
      throw UpdateRejected('release has no usable sha256/signature');
    }
    return info;
  }

  Future<void> reportStatus({
    required String serverBase,
    required String deviceId,
    required String token,
    required String state,
    String? version,
    String? error,
  }) async {
    try {
      await _client.post(
        Uri.parse('$serverBase/api/v1/device/update/status'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'device_id': deviceId,
          'state': state,
          if (version != null && version.isNotEmpty) 'version': version,
          if (error != null && error.isNotEmpty) 'error': _shorten(error),
        }),
      );
    } catch (e) {
      // Статус — телеметрия для панели. Его потеря не должна ломать обновление.
      await AppLogger.log('update status report failed: $e');
    }
  }

  /// Скачивает артефакт и проверяет его. Возвращает файл только если сошлись
  /// И размер, И sha256, И подпись.
  Future<PreparedUpdate> download(
    UpdateInfo info, {
    required String token,
    void Function(int received, int total)? onProgress,
  }) async {
    if (!isEnabled) {
      throw UpdateRejected('update public key is not embedded in this build');
    }

    final dir = await _updatesDir();
    final target = File(p.join(dir.path, info.fileName));
    final temp = File('${target.path}.download');
    if (await temp.exists()) await temp.delete();

    final request = http.Request('GET', Uri.parse(info.downloadUrl));
    request.headers['Authorization'] = 'Bearer $token';
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('update download failed: ${response.statusCode}');
    }

    final sink = temp.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        // Обрываем раздутый ответ, не дожидаясь конца: место на экране
        // ограничено, а размер нам сервер уже назвал.
        if (info.size > 0 && received > info.size) {
          throw UpdateRejected('artifact is larger than announced');
        }
        sink.add(chunk);
        onProgress?.call(received, info.size);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    try {
      await _verify(temp, info);
    } catch (_) {
      await temp.delete();
      rethrow;
    }

    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
    await AppLogger.log(
      'update verified: ${info.version} (${info.buildNumber}) ${target.path}',
    );
    return PreparedUpdate(info, target);
  }

  Future<void> _verify(File file, UpdateInfo info) async {
    final stat = await file.stat();
    if (info.size > 0 && stat.size != info.size) {
      throw UpdateRejected('size mismatch: ${stat.size} != ${info.size}');
    }

    final digest = await sha256.bind(file.openRead()).first;
    final digestHex = digest.toString().toLowerCase();
    if (digestHex != info.sha256) {
      throw UpdateRejected('sha256 mismatch');
    }

    // Подписан именно хеш — так подписант работает с коротким значением,
    // а связь с содержимым обеспечена проверкой sha256 выше.
    final verified = await _algorithm.verify(
      _hexToBytes(digestHex),
      signature: Signature(
        base64Decode(info.signature),
        publicKey: SimplePublicKey(
          base64Decode(kUpdatePublicKeyBase64.trim()),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!verified) {
      throw UpdateRejected('signature does not match the trusted key');
    }
  }

  /// Убирает всё, кроме только что подготовленного файла: артефакты большие,
  /// а место на экранах маленькое.
  Future<void> cleanup({File? keep}) async {
    try {
      final dir = await _updatesDir();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (keep != null && p.equals(entity.path, keep.path)) continue;
        await entity.delete();
      }
    } catch (e) {
      await AppLogger.log('update cleanup failed: $e');
    }
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  static String _shorten(String value) =>
      value.length <= 500 ? value : value.substring(0, 500);
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}
