import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart';

import '../models/manifest.dart';
import '../services/app_logger.dart';
import '../services/local_web_server.dart';

/// Показ HTML-страницы в WebView.
///
/// Длительность здесь не задана заранее: страница сама сообщает `efir.done()`,
/// когда показала всё. Поэтому в виджете обязательно есть сторож —
/// `maxDurationSec`. Без него одна сломанная строчка JS держала бы экран
/// навсегда, и починить это можно было бы только руками у самого экрана.
class HtmlView extends StatefulWidget {
  const HtmlView({
    super.key,
    required this.page,
    required this.bundleDir,
    required this.serverBase,
    required this.deviceId,
    required this.deviceToken,
    required this.onDone,
    this.onError,
    this.onStatus,
  });

  final ManifestHtmlPage page;
  final Directory bundleDir;
  final String serverBase;
  final String deviceId;
  final String deviceToken;

  /// Страница закончила показ — плеер листает дальше.
  final VoidCallback onDone;

  /// Страница не смогла показаться. Плеер должен пропустить слот, а не ждать.
  final void Function(String reason)? onError;

  /// События контракта для диагностики в панели: ready/progress/done/ceiling/
  /// error. Раньше они уходили только в лог устройства, и «почему на экране
  /// висит не то» было видно лишь с отладчиком у самого экрана.
  final void Function(String state, String detail)? onStatus;

  /// Умеет ли эта платформа показывать HTML.
  ///
  /// `webview_all` закрывает все наши цели: Android (System WebView), Windows
  /// (WebView2) и Linux (WebKitGTK). Проверка осталась не как заглушка «здесь
  /// не умеем», а как честный ответ для платформ, под которые мы не собираем и
  /// не проверяем, — там лучше показать текст, чем чёрный прямоугольник.
  static bool get isSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isLinux;

  @override
  State<HtmlView> createState() => _HtmlViewState();
}

class _HtmlViewState extends State<HtmlView> {
  final LocalWebServer _server = LocalWebServer();
  WebViewController? _controller;

  Timer? _maxDurationTimer;
  Timer? _readyTimer;
  Timer? _refreshTimer;
  DateTime? _shownAt;
  bool _finished = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    _maxDurationTimer?.cancel();
    _readyTimer?.cancel();
    _refreshTimer?.cancel();
    unawaited(_server.stop());
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      await _server.start(
        root: widget.bundleDir,
        serverBase: widget.serverBase,
        deviceId: widget.deviceId,
        deviceToken: widget.deviceToken,
        pageId: widget.page.id,
      );

      final controller = WebViewController();

      // Каждый шаг настройки — с await, каскад здесь недопустим. На WebView2
      // канал регистрируется скриптом «выполнить при создании документа»: если
      // навигация начнётся раньше, чем регистрация дойдёт до движка, у первой
      // же страницы не окажется window.EfirBridge — и она молча не сможет
      // сказать ни ready, ни done.
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(Colors.black);
      await controller.addJavaScriptChannel(
        'EfirBridge',
        onMessageReceived: _onBridgeMessage,
      );
      // Консоль страницы — в лог устройства.
      //
      // Без этого страница остаётся чёрным ящиком: она может ловить свои
      // ошибки сама (а хорошо написанная именно так и делает) и снаружи это
      // неотличимо от «данных просто нет». Диагностировать такое можно только
      // подключив отладчик к экрану в холле, то есть практически никак.
      await controller.setOnConsoleMessage((message) {
        // Шум не нужен: info и debug страница пишет для себя.
        if (message.level == JavaScriptLogLevel.error ||
            message.level == JavaScriptLogLevel.warning) {
          AppLogger.log('html console ${message.level.name}: ${message.message}');
        }
      });

      await controller.setNavigationDelegate(
        NavigationDelegate(
          // Страница живёт только внутри своего локального origin: клик по
          // внешней ссылке не должен увести экран в чужой сайт.
          onNavigationRequest: (request) {
            final entry = _server.entryUrl(widget.page.entryPath);
            return request.url.startsWith('http://${entry.host}:${entry.port}/')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            AppLogger.log('html page error: ${error.description}');
          },
        ),
      );

      await controller.loadRequest(_server.entryUrl(widget.page.entryPath));
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _shownAt = DateTime.now();
      });
      _startWatchdogs();
    } catch (e) {
      await AppLogger.log('html page boot failed: $e');
      _fail('не удалось открыть страницу');
    }
  }

  void _startWatchdogs() {
    // Потолок показа — единственная защита от страницы, которая никогда не
    // скажет done().
    _maxDurationTimer = Timer(
      Duration(seconds: widget.page.maxDurationSec),
      () {
        // Потолок — это не «done»: в панели важно различать «страница сама
        // закончила» и «её сняли по таймеру, потому что она не закончила».
        widget.onStatus?.call('ceiling', 'достигнут предел показа');
        _finish(reason: 'достигнут предел показа');
      },
    );

    // Не дождались ready — считаем, что страница не поднялась.
    _readyTimer = Timer(Duration(seconds: widget.page.readyTimeoutSec), () {
      if (_finished) return;
      AppLogger.log('html page did not report ready in ${widget.page.readyTimeoutSec}s');
    });

    final refresh = widget.page.refreshSec;
    if (refresh != null && refresh > 0) {
      _refreshTimer = Timer.periodic(Duration(seconds: refresh), (_) {
        _controller?.reload();
      });
    }
  }

  void _onBridgeMessage(JavaScriptMessage message) {
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (payload['kind']) {
      case 'ready':
        _readyTimer?.cancel();
        widget.onStatus?.call('ready', '');
        break;
      case 'done':
        widget.onStatus?.call('done', '');
        _finish(reason: 'страница сообщила done');
        break;
      case 'error':
        _fail('${payload['payload'] ?? 'ошибка страницы'}');
        break;
      case 'progress':
        // Прогресс уходит в лог и в панель: видно, что страница жива и листает.
        final progress = '${payload['payload'] ?? ''}';
        widget.onStatus?.call('progress', progress);
        AppLogger.log('html page progress: $progress');
        break;
    }
  }

  /// Завершение с учётом нижней границы: страница может отрапортовать done
  /// мгновенно, а человек у экрана не успеет ничего прочитать.
  void _finish({required String reason}) {
    if (_finished) return;
    final shownAt = _shownAt;
    final minimum = Duration(seconds: widget.page.minDurationSec);
    if (shownAt != null && minimum > Duration.zero) {
      final elapsed = DateTime.now().difference(shownAt);
      if (elapsed < minimum) {
        Timer(minimum - elapsed, () => _finish(reason: reason));
        return;
      }
    }
    _finished = true;
    AppLogger.log('html page finished: ${widget.page.name} ($reason)');
    widget.onDone();
  }

  void _fail(String reason) {
    if (_finished) return;
    _finished = true;
    widget.onStatus?.call('error', reason);
    if (mounted) setState(() => _error = reason);
    AppLogger.log('html page failed: ${widget.page.name} — $reason');
    final onError = widget.onError;
    if (onError != null) {
      onError(reason);
    } else {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!HtmlView.isSupported) {
      return _placeholder('HTML-страницы не поддерживаются на этой платформе');
    }
    if (_error.isNotEmpty) return _placeholder(_error);
    final controller = _controller;
    if (controller == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return WebViewWidget(controller: controller);
  }

  Widget _placeholder(String message) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 20),
          ),
        ),
      ),
    );
  }
}
