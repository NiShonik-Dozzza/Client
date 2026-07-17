import 'dart:convert';
import 'dart:io';

import '../services/app_logger.dart';
import '../services/app_paths.dart';

class DeviceAuth {
  final String deviceId;
  final String token;
  final String? name;
  final String requestToken;

  DeviceAuth({
    required this.deviceId,
    required this.token,
    this.name,
    this.requestToken = '',
  });

  factory DeviceAuth.fromJson(Map<String, dynamic> json) {
    return DeviceAuth(
      deviceId: (json['device_id'] as String?)?.trim() ?? '',
      token: (json['token'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim(),
      requestToken: (json['request_token'] as String?)?.trim() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'token': token,
    if (name != null) 'name': name,
    if (requestToken.isNotEmpty) 'request_token': requestToken,
  };

  bool get hasToken => token.isNotEmpty;
  bool get hasPendingRequest => requestToken.isNotEmpty;

  DeviceAuth copyWith({
    String? deviceId,
    String? token,
    String? name,
    String? requestToken,
  }) {
    return DeviceAuth(
      deviceId: deviceId ?? this.deviceId,
      token: token ?? this.token,
      name: name ?? this.name,
      requestToken: requestToken ?? this.requestToken,
    );
  }
}

class DeviceStore {
  Future<DeviceAuth?> read() async {
    try {
      final file = await AppPaths.deviceFile();
      if (!await file.exists()) return null;
      await _protectDeviceFile(file);
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final auth = DeviceAuth.fromJson(map);
      if (auth.deviceId.isEmpty) return null;
      return auth;
    } catch (e) {
      await AppLogger.log('DeviceStore read error: $e');
      return null;
    }
  }

  Future<void> save(DeviceAuth auth) async {
    final file = await AppPaths.deviceFile();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(auth.toJson()), flush: true);
    await _protectDeviceFile(temp);
    if (await file.exists()) {
      await file.delete();
    }
    await temp.rename(file.path);
    await _protectDeviceFile(file);
  }

  /// Best-effort сужение прав на файл с токеном: только текущий пользователь
  /// (плюс SYSTEM на Windows). Сбой — не фатален (kiosk-сборки под
  /// нестандартными аккаунтами не должны падать из-за ACL).
  Future<void> _protectDeviceFile(File file) async {
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['600', file.path]);
      } else if (Platform.isWindows) {
        final user = Platform.environment['USERNAME'];
        if (user == null || user.isEmpty) return;
        await Process.run('icacls', [
          file.path,
          '/inheritance:r',
          '/grant:r',
          '$user:F',
          '/grant:r',
          'SYSTEM:F',
        ]);
      }
    } catch (e) {
      await AppLogger.log('DeviceStore file protect warning: $e');
    }
  }
}
