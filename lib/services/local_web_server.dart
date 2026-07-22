import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_http.dart';
import 'app_logger.dart';

/// Локальный HTTP-сервер, из которого WebView грузит HTML-страницу.
///
/// Почему не `file://`: страница с файловой схемой в Android WebView способна
/// читать соседние файлы, а рядом лежит `device.json` с Bearer-токеном
/// устройства и `trust.json` с пинами сертификатов. Отдавая страницу по
/// `http://127.0.0.1`, мы получаем нормальный origin, к которому применимы CSP
/// и обычные правила браузера.
///
/// Слушаем только петлю, порт выбирает система, а путь начинается со
/// случайного токена — чтобы соседнее приложение на устройстве не могло
/// наугад постучаться и вытянуть бандл или воспользоваться прокси данных.
class LocalWebServer {
  LocalWebServer({http.Client? client}) : _client = client ?? AppHttp.client();

  final http.Client _client;
  HttpServer? _server;
  Directory? _root;
  String _token = '';

  /// Доступ к панели для прокси данных. Токен устройства страница НЕ ВИДИТ:
  /// его подставляет этот сервер уже после того, как запрос ушёл из WebView.
  String _serverBase = '';
  String _deviceId = '';
  String _deviceToken = '';
  int _pageId = 0;

  bool get isRunning => _server != null;

  /// Адрес точки входа страницы.
  Uri entryUrl(String entryPath) {
    final server = _server;
    if (server == null) throw StateError('local web server is not running');
    final safeEntry = entryPath.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    return Uri.parse('http://127.0.0.1:${server.port}/$_token/$safeEntry');
  }

  Future<void> start({
    required Directory root,
    required String serverBase,
    required String deviceId,
    required String deviceToken,
    required int pageId,
  }) async {
    await stop();
    _root = root;
    _serverBase = serverBase;
    _deviceId = deviceId;
    _deviceToken = deviceToken;
    _pageId = pageId;
    _token = _randomToken();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    _server = server;
    server.listen(_handle, onError: (Object e) => AppLogger.log('local server error: $e'));
    await AppLogger.log('local html server on 127.0.0.1:${server.port}');
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
  }

  static String _randomToken() {
    final rng = Random.secure();
    return List.generate(24, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      // Ничего, кроме чтения, странице не нужно.
      if (request.method != 'GET' && request.method != 'HEAD') {
        await _fail(request, HttpStatus.methodNotAllowed);
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.isEmpty || segments.first != _token) {
        // Без токена — как будто ничего и нет: чужому процессу не за что
        // зацепиться, даже зная порт.
        await _fail(request, HttpStatus.notFound);
        return;
      }

      final rest = segments.skip(1).toList();
      if (rest.isNotEmpty && rest.first == '__efir') {
        await _handleBridge(request, rest.skip(1).toList());
        return;
      }
      await _serveFile(request, rest);
    } catch (e) {
      await AppLogger.log('local server request failed: $e');
      await _fail(request, HttpStatus.internalServerError);
    }
  }

  // --------------------------------------------------------------- статика
  Future<void> _serveFile(HttpRequest request, List<String> parts) async {
    final root = _root;
    if (root == null) {
      await _fail(request, HttpStatus.notFound);
      return;
    }

    final relative = parts.isEmpty ? 'index.html' : parts.join('/');
    if (relative.contains('..')) {
      await _fail(request, HttpStatus.forbidden);
      return;
    }

    final file = File(p.join(root.path, relative));
    // Сверяем уже разрешённый путь: символическая ссылка внутри бандла могла бы
    // увести за его пределы, а проверка по строке этого не увидит.
    final resolved = p.normalize(file.absolute.path);
    final rootPath = p.normalize(root.absolute.path);
    if (!p.isWithin(rootPath, resolved)) {
      await _fail(request, HttpStatus.forbidden);
      return;
    }
    if (!await file.exists()) {
      await _fail(request, HttpStatus.notFound);
      return;
    }

    _applySecurityHeaders(request.response);
    request.response.headers.contentType = _contentTypeFor(relative);
    request.response.headers.set('Cache-Control', 'no-store');
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  /// CSP запрещает странице ходить куда-либо, кроме собственного origin.
  /// Данные она получает только через `/__efir/data`, то есть через панель.
  void _applySecurityHeaders(HttpResponse response) {
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'self'; "
      "script-src 'self' 'unsafe-inline'; "
      "style-src 'self' 'unsafe-inline'; "
      "img-src 'self' data: blob:; "
      "font-src 'self' data:; "
      "connect-src 'self'; "
      "frame-ancestors 'none'; "
      "base-uri 'none'; "
      "form-action 'none'",
    );
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Referrer-Policy', 'no-referrer');
  }

  static ContentType _contentTypeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.html':
      case '.htm':
        return ContentType.html;
      case '.css':
        return ContentType('text', 'css', charset: 'utf-8');
      case '.js':
        return ContentType('application', 'javascript', charset: 'utf-8');
      case '.json':
        return ContentType.json;
      case '.svg':
        return ContentType('image', 'svg+xml', charset: 'utf-8');
      case '.png':
        return ContentType('image', 'png');
      case '.jpg':
      case '.jpeg':
        return ContentType('image', 'jpeg');
      case '.webp':
        return ContentType('image', 'webp');
      case '.woff2':
        return ContentType('font', 'woff2');
      default:
        return ContentType.binary;
    }
  }

  // ----------------------------------------------------------------- мост
  Future<void> _handleBridge(HttpRequest request, List<String> parts) async {
    if (parts.isEmpty) {
      await _fail(request, HttpStatus.notFound);
      return;
    }
    if (parts.first == 'efir.js') {
      _applySecurityHeaders(request.response);
      request.response.headers.contentType =
          ContentType('application', 'javascript', charset: 'utf-8');
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.write(_bridgeScript());
      await request.response.close();
      return;
    }
    if (parts.first == 'data') {
      await _proxyData(request);
      return;
    }
    await _fail(request, HttpStatus.notFound);
  }

  /// Запрос данных уходит в панель с токеном устройства, который страница
  /// никогда не видит: подставляем его здесь.
  Future<void> _proxyData(HttpRequest request) async {
    final src = request.uri.queryParameters['src'] ?? '';
    final path = request.uri.queryParameters['path'] ?? '/';
    if (src.isEmpty || _serverBase.isEmpty || _deviceToken.isEmpty) {
      await _fail(request, HttpStatus.badRequest);
      return;
    }

    final target = Uri.parse('$_serverBase/api/v1/device/html/$_pageId/data').replace(
      queryParameters: {'device_id': _deviceId, 'src': src, 'path': path},
    );

    try {
      final response = await _client.get(
        target,
        headers: {'Authorization': 'Bearer $_deviceToken', 'Accept': 'application/json'},
      );
      _applySecurityHeaders(request.response);
      request.response.statusCode = response.statusCode;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.write(response.body);
      await request.response.close();
    } catch (e) {
      await AppLogger.log('html data proxy failed: $e');
      // Страница должна получить внятный отказ, а не зависнуть на ожидании.
      _applySecurityHeaders(request.response);
      request.response.statusCode = HttpStatus.badGateway;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'detail': 'data source unavailable'}));
      await request.response.close();
    }
  }

  /// Мост, который подключает страница: `<script src="/__efir/efir.js">`.
  ///
  /// Здесь же лежит контракт завершения — `efir.done()`. Основной канал до
  /// плеера — JS-канал WebView; смена `document.title` оставлена запасным
  /// путём для окружений без канала (например, обычный браузер при отладке
  /// страницы), чтобы автор страницы писал один и тот же код.
  String _bridgeScript() {
    return '''
(function () {
  'use strict';
  var base = '/$_token/__efir';

  function signal(kind, payload) {
    var message = JSON.stringify({ kind: kind, payload: payload === undefined ? '' : payload });
    if (window.EfirBridge && typeof window.EfirBridge.postMessage === 'function') {
      window.EfirBridge.postMessage(message);
      return;
    }
    document.title = '__efir:' + kind + ':' + (payload === undefined ? '' : payload);
  }

  window.efir = {
    ready: function () { signal('ready'); },
    done: function () { signal('done'); },
    progress: function (current, total) { signal('progress', current + '/' + total); },
    error: function (message) { signal('error', String(message || '').slice(0, 200)); },
    data: function (key, options) {
      var opts = options || {};
      var url = base + '/data?src=' + encodeURIComponent(key) +
        '&path=' + encodeURIComponent(opts.path || '/');
      return fetch(url, { headers: { Accept: 'application/json' } })
        .then(function (response) {
          if (!response.ok) throw new Error('data ' + response.status);
          return response.json();
        })
        .then(function (payload) { return payload.value; });
    }
  };
})();
''';
  }

  Future<void> _fail(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }
}
