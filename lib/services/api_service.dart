import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/manifest.dart';
import '../services/device_store.dart';

class ApiException implements Exception {
  final int statusCode;
  final String body;

  ApiException(this.statusCode, this.body);

  @override
  String toString() => 'ApiException($statusCode): $body';
}

class ApiService {
  ApiService({required String apiBase, http.Client? client})
      : _apiBase = apiBase.trim(),
        _client = client ?? http.Client();

  final http.Client _client;
  String _apiBase;

  void updateApiBase(String apiBase) {
    _apiBase = apiBase.trim();
  }

  Future<DeviceAuth> register({required String deviceId, String? name}) async {
    final uri = _buildUri('/screens/register');
    final payload = <String, dynamic>{
      'device_id': deviceId,
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
    };

    final resp = await _client.post(
      uri,
      headers: _headers(),
      body: jsonEncode(payload),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ApiException(resp.statusCode, resp.body);
    }

    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return DeviceAuth.fromJson(map);
  }

  Future<Manifest> fetchManifest({required String deviceId, String? token}) async {
    final uri = _buildUri('/manifest', {'device_id': deviceId});
    final resp = await _client.get(uri, headers: _headers(token: token));

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ApiException(resp.statusCode, resp.body);
    }

    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return Manifest.fromJson(map);
  }

  Future<void> heartbeat({
    required String deviceId,
    required String currentRevision,
    required String? nowPlaying,
    String? token,
  }) async {
    final uri = _buildUri('/screens/heartbeat');
    final payload = <String, dynamic>{
      'device_id': deviceId,
      'current_revision_str': currentRevision,
      'now_playing': nowPlaying ?? '',
    };

    final resp = await _client.post(
      uri,
      headers: _headers(token: token),
      body: jsonEncode(payload),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ApiException(resp.statusCode, resp.body);
    }
  }

  Uri _buildUri(String path, [Map<String, String>? query]) {
    final base = _apiBase.endsWith('/') ? _apiBase.substring(0, _apiBase.length - 1) : _apiBase;
    final p = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$p');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Map<String, String> _headers({String? token}) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }
}
