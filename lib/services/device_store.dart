import 'dart:convert';

import '../services/app_logger.dart';
import '../services/app_paths.dart';

class DeviceAuth {
  final String deviceId;
  final String token;
  final String? name;

  DeviceAuth({required this.deviceId, required this.token, this.name});

  factory DeviceAuth.fromJson(Map<String, dynamic> json) {
    return DeviceAuth(
      deviceId: (json['device_id'] as String?)?.trim() ?? '',
      token: (json['token'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'token': token,
    if (name != null) 'name': name,
  };

  bool get hasToken => token.isNotEmpty;
}

class DeviceStore {
  Future<DeviceAuth?> read() async {
    try {
      final file = await AppPaths.deviceFile();
      if (!await file.exists()) return null;
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
    await file.writeAsString(jsonEncode(auth.toJson()), flush: true);
  }
}
