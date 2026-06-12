import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'trust_store.dart';

/// Единая фабрика HTTP-клиентов приложения.
///
/// Все сетевые вызовы (health, регистрация, manifest, heartbeat, скачивание
/// медиа) идут через клиента с badCertificateCallback: цепочки, не прошедшие
/// системную проверку, принимаются только если сертификат закреплён
/// оператором в [TrustStore] (см. диалог доверия в настройке).
class AppHttp {
  static http.Client client() {
    if (kIsWeb) return http.Client();
    final inner = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (cert, host, port) =>
          TrustStore.instance.isTrusted(cert, host, port);
    return IOClient(inner);
  }
}
