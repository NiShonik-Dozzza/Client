import 'dart:convert';
import 'dart:io';

import 'package:efir/services/local_web_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Локальный сервер — это граница между произвольным JS на экране и
/// устройством. Проверяем ровно то, что эту границу держит.
void main() {
  late Directory bundle;
  late LocalWebServer server;

  setUp(() async {
    bundle = await Directory.systemTemp.createTemp('efir_bundle_');
    await File('${bundle.path}/index.html').writeAsString('<h1>Страница</h1>');
    await File('${bundle.path}/app.js').writeAsString('console.log(1)');
    final nested = Directory('${bundle.path}/assets')..createSync();
    await File('${nested.path}/style.css').writeAsString('body{}');
    // Файл ЗА пределами бандла — его страница не должна достать никаким путём.
    await File('${bundle.parent.path}/device.json').writeAsString('{"token":"секрет"}');

    server = LocalWebServer();
    await server.start(
      root: bundle,
      serverBase: 'https://panel.invalid',
      deviceId: 'dev1',
      deviceToken: 'device-secret-token',
      pageId: 7,
    );
  });

  tearDown(() async {
    await server.stop();
    if (await bundle.exists()) await bundle.delete(recursive: true);
  });

  Uri base() {
    final entry = server.entryUrl('index.html');
    return Uri.parse('${entry.scheme}://${entry.host}:${entry.port}');
  }

  String token() => server.entryUrl('index.html').pathSegments.first;

  test('страница отдаётся по адресу с токеном', () async {
    final response = await http.get(server.entryUrl('index.html'));
    expect(response.statusCode, 200);
    expect(response.body, contains('Страница'));
  });

  test('без токена сервера как будто нет', () async {
    // Соседнее приложение знает порт, но не знает токен — и не получает ничего.
    final response = await http.get(base().replace(path: '/index.html'));
    expect(response.statusCode, 404);

    final wrong = await http.get(base().replace(path: '/deadbeef/index.html'));
    expect(wrong.statusCode, 404);
  });

  test('за пределы каталога бандла выйти нельзя', () async {
    for (final attempt in [
      '/${token()}/../device.json',
      '/${token()}/assets/../../device.json',
      '/${token()}/%2e%2e/device.json',
    ]) {
      final response = await http.get(base().replace(path: attempt));
      expect(
        response.statusCode,
        anyOf(403, 404),
        reason: 'путь $attempt не должен отдавать файл рядом с бандлом',
      );
      expect(response.body, isNot(contains('секрет')));
    }
  });

  test('ответы несут CSP, запрещающий ходить наружу', () async {
    final response = await http.get(server.entryUrl('index.html'));
    final csp = response.headers['content-security-policy'] ?? '';
    // Страница ходит только к себе: данные — исключительно через панель.
    expect(csp, contains("default-src 'self'"));
    expect(csp, contains("connect-src 'self'"));
    expect(csp, contains("frame-ancestors 'none'"));
    expect(response.headers['x-content-type-options'], 'nosniff');
  });

  test('мост подключается к странице автоматически', () async {
    // Автор страницы не знает про случайный токен в пути, поэтому вписать
    // рабочую ссылку на мост он не может. Сервер делает это сам.
    final response = await http.get(server.entryUrl('index.html'));
    expect(response.statusCode, 200);
    expect(response.body, contains('/${token()}/__efir/efir.js'));
    expect(response.body, contains('Страница'), reason: 'разметка не должна теряться');
  });

  test('мост efir.js отдаётся и содержит контракт завершения', () async {
    final response = await http.get(base().replace(path: '/${token()}/__efir/efir.js'));
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], contains('javascript'));
    expect(response.body, contains('window.efir'));
    expect(response.body, contains('done'));
    // Токен устройства в мост не попадает — его подставляет сам сервер.
    expect(response.body, isNot(contains('device-secret-token')));
  });

  test('запись и другие методы отклоняются', () async {
    final response = await http.post(server.entryUrl('index.html'));
    expect(response.statusCode, 405);
  });

  test('прокси данных не отдаёт токен устройства странице', () async {
    // Панель недоступна (адрес invalid) — важно, что ответ внятный, а страница
    // не видит ни токена, ни адреса панели.
    final response = await http.get(
      base().replace(path: '/${token()}/__efir/data', queryParameters: {'src': 'k', 'path': '/x'}),
    );
    expect(response.statusCode, anyOf(502, 400));
    expect(response.body, isNot(contains('device-secret-token')));
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    expect(decoded['detail'], isNotNull);
  });

  test('прокси без ключа источника отклоняется', () async {
    final response = await http.get(base().replace(path: '/${token()}/__efir/data'));
    expect(response.statusCode, 400);
  });

  test('после остановки сервер не отвечает', () async {
    final url = server.entryUrl('index.html');
    await server.stop();
    await expectLater(http.get(url), throwsA(isA<SocketException>()));
  });
}
