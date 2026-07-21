import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/display_profile.dart';
import '../models/manifest.dart';
import 'app_http.dart';

class ApiException implements Exception {
  final int statusCode;
  final String body;

  ApiException(this.statusCode, this.body);

  @override
  String toString() => 'ApiException($statusCode): $body';
}

class DeviceHealth {
  final bool ok;
  final String name;
  final String version;
  final String build;
  final String revision;
  final String timezone;

  DeviceHealth({
    required this.ok,
    required this.name,
    required this.version,
    required this.build,
    required this.revision,
    required this.timezone,
  });

  factory DeviceHealth.fromJson(Map<String, dynamic> json) {
    return DeviceHealth(
      ok: json['ok'] == true,
      name: (json['name'] as String?)?.trim() ?? '',
      version: (json['version'] as String?)?.trim() ?? '',
      build: (json['build'] as String?)?.trim() ?? '',
      revision: (json['revision'] as String?)?.trim() ?? '',
      timezone: (json['timezone'] as String?)?.trim() ?? '',
    );
  }
}

class DeviceRegistrationRequestResult {
  final String deviceId;
  final String requestToken;
  final int pollAfterSeconds;
  final String message;

  DeviceRegistrationRequestResult({
    required this.deviceId,
    required this.requestToken,
    required this.pollAfterSeconds,
    required this.message,
  });

  factory DeviceRegistrationRequestResult.fromJson(Map<String, dynamic> json) {
    return DeviceRegistrationRequestResult(
      deviceId: (json['device_id'] as String?)?.trim() ?? '',
      requestToken: (json['request_token'] as String?)?.trim() ?? '',
      pollAfterSeconds: _asInt(json['poll_after_seconds'], 5),
      message: (json['message'] as String?)?.trim() ?? '',
    );
  }
}

class DeviceRegistrationStatus {
  final String deviceId;
  final String status;
  final int pollAfterSeconds;
  final String message;
  final String? token;
  final String? screenName;

  DeviceRegistrationStatus({
    required this.deviceId,
    required this.status,
    required this.pollAfterSeconds,
    required this.message,
    required this.token,
    required this.screenName,
  });

  factory DeviceRegistrationStatus.fromJson(Map<String, dynamic> json) {
    return DeviceRegistrationStatus(
      deviceId: (json['device_id'] as String?)?.trim() ?? '',
      status: (json['status'] as String?)?.trim().toLowerCase() ?? 'pending',
      pollAfterSeconds: _asInt(json['poll_after_seconds'], 5),
      message: (json['message'] as String?)?.trim() ?? '',
      token: (json['token'] as String?)?.trim(),
      screenName: (json['screen_name'] as String?)?.trim(),
    );
  }

  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';
  bool get isExpired => status == 'expired';
  bool get isRevoked => status == 'revoked';
}

class ApiService {
  ApiService({required String serverBase, http.Client? client})
    : _serverBase = _normalizeServerBase(serverBase),
      _client = client ?? AppHttp.client();

  final http.Client _client;
  String _serverBase;

  void updateServerBase(String serverBase) {
    _serverBase = _normalizeServerBase(serverBase);
  }

  Future<DeviceHealth> health() async {
    // Таймаут ограничивает пробу: при резолве адреса мы перебираем кандидаты
    // (https/http/порты), и недоступный кандидат не должен подвешивать UI.
    final resp = await _client
        .get(_buildUri('/api/v1/device/health'))
        .timeout(const Duration(seconds: 5));
    return DeviceHealth.fromJson(_decodeMap(resp));
  }

  Future<DeviceRegistrationRequestResult> requestRegistration({
    required String deviceId,
    String? name,
    String? clientVersion,
  }) async {
    final resp = await _client.post(
      _buildUri('/api/v1/device/register/request'),
      headers: _headers(),
      body: jsonEncode({
        'device_id': deviceId,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        if (clientVersion != null && clientVersion.trim().isNotEmpty)
          'client_version': clientVersion.trim(),
      }),
    );
    return DeviceRegistrationRequestResult.fromJson(_decodeMap(resp));
  }

  Future<DeviceRegistrationStatus> registrationStatus({
    required String deviceId,
    required String requestToken,
  }) async {
    final resp = await _client.get(
      _buildUri('/api/v1/device/register/status', {
        'device_id': deviceId,
        'request_token': requestToken,
      }),
      headers: _headers(),
    );
    return DeviceRegistrationStatus.fromJson(_decodeMap(resp));
  }

  Future<Manifest> fetchManifest({
    required String deviceId,
    String? token,
  }) async {
    final resp = await _client.get(
      _buildUri('/api/v1/device/manifest', {'device_id': deviceId}),
      headers: _headers(token: token),
    );
    return Manifest.fromJson(_decodeMap(resp));
  }

  Future<void> heartbeat({
    required String deviceId,
    required String currentRevision,
    required String? nowPlaying,
    required String clientVersion,
    required int clientBuild,
    required String platform,
    required String arch,
    required String networkState,
    required int cachedMediaCount,
    required int cacheSizeBytes,
    required int mediaDownloadFailures,
    required String activeDisplayId,
    required List<DeviceDisplayProfile> availableDisplays,
    String? token,
  }) async {
    final resp = await _client.post(
      _buildUri('/api/v1/device/heartbeat'),
      headers: _headers(token: token),
      body: jsonEncode({
        'device_id': deviceId,
        'current_revision_str': currentRevision,
        'now_playing': nowPlaying ?? '',
        'client_version': clientVersion,
        // Панель по ним подбирает артефакт обновления (apk arm64 / exe x64 / …).
        'client_build': clientBuild,
        'platform': platform,
        'arch': arch,
        'network_state': networkState,
        'cached_media_count': cachedMediaCount,
        'cache_size_bytes': cacheSizeBytes,
        'media_download_failures': mediaDownloadFailures,
        'active_display_id': activeDisplayId,
        'available_displays': availableDisplays
            .map((item) => item.toJson())
            .toList(),
      }),
    );
    _decodeMap(resp);
  }

  Uri _buildUri(String path, [Map<String, String>? query]) {
    if (_serverBase.isEmpty) {
      throw StateError('server base is empty');
    }
    final uri = Uri.parse('$_serverBase$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Map<String, dynamic> _decodeMap(http.Response resp) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ApiException(resp.statusCode, resp.body);
    }
    if (resp.body.trim().isEmpty) return <String, dynamic>{};
    return (jsonDecode(resp.body) as Map).cast<String, dynamic>();
  }

  Map<String, String> _headers({String? token}) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }
}

int _asInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

String _normalizeServerBase(String value) {
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
