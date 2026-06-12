import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'controllers/playlist_controller.dart';
import 'views/setup_screen.dart';
import 'views/player_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await _configurePowerPolicy();
  await _configureAppWindow();
  _registerSignalHandlers();

  Get.put(PlaylistController(), permanent: true);

  runApp(const App());
}

/// Graceful shutdown при получении SIGTERM от systemd / watchdog.
/// Даёт GetX-контроллерам время на сохранение состояния перед выходом.
void _registerSignalHandlers() {
  if (kIsWeb) return;
  if (!Platform.isLinux && !Platform.isMacOS) return; // SIGTERM — только Unix

  ProcessSignal.sigterm.watch().listen((_) async {
    try {
      Get.find<PlaylistController>().onClose();
    } catch (_) {}
    exit(0);
  });
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return const PowerGuard(
      child: GetMaterialApp(
        debugShowCheckedModeBanner: false,
        home: WindowShell(child: RootScreen()),
      ),
    );
  }
}

Future<void> _configurePowerPolicy() async {
  if (!kIsWeb && (Platform.isAndroid || Platform.isWindows || Platform.isLinux)) {
    await WakelockPlus.enable();
  }
}

Future<void> _configureAppWindow() async {
  if (!kIsWeb && Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    return;
  }

  if (kIsWeb || !(Platform.isWindows || Platform.isLinux)) return;

  try {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      title: 'EFIR',
      backgroundColor: Colors.black,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      await _setDesktopFullscreen(true);
    });
  } catch (_) {
    // Fallback to the default desktop window if the plugin is unavailable.
  }
}

Future<void> _setDesktopFullscreen(bool enabled) async {
  if (kIsWeb || !(Platform.isWindows || Platform.isLinux)) return;

  if (enabled) {
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setFullScreen(true);
    return;
  }

  await windowManager.setFullScreen(false);
  await windowManager.setTitleBarStyle(
    TitleBarStyle.normal,
    windowButtonVisibility: true,
  );
  await windowManager.show();
  await windowManager.focus();
}

class WindowShell extends StatefulWidget {
  const WindowShell({super.key, required this.child});

  final Widget child;

  @override
  State<WindowShell> createState() => _WindowShellState();
}

class PowerGuard extends StatefulWidget {
  const PowerGuard({super.key, required this.child});

  final Widget child;

  @override
  State<PowerGuard> createState() => _PowerGuardState();
}

class _PowerGuardState extends State<PowerGuard> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reapplyPowerPolicy();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reapplyPowerPolicy();
    }
  }

  Future<void> _reapplyPowerPolicy() async {
    await _configurePowerPolicy();
    if (!kIsWeb && Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _WindowShellState extends State<WindowShell> {
  static const Duration _doubleTapWindow = Duration(milliseconds: 350);
  static const double _doubleTapMaxDistance = 24;

  final FocusNode _focusNode = FocusNode(debugLabel: 'window-shell');
  DateTime? _lastPointerDownAt;
  Offset? _lastPointerDownPosition;
  bool _toggleInProgress = false;

  bool get _supportsDesktopToggle =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!_supportsDesktopToggle || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // В release не выходим из fullscreen по Esc (kiosk) и не перехватываем
      // событие — оно нужно плееру для сервисного жеста (3×Esc → редактор).
      if (kReleaseMode) return KeyEventResult.ignored;
      _toggleFullscreen(enabled: false);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_supportsDesktopToggle) return;
    // В release double-tap не переключает fullscreen, чтобы экран нельзя было
    // случайно свернуть (kiosk).
    if (kReleaseMode) return;

    final now = DateTime.now();
    final lastAt = _lastPointerDownAt;
    final lastPosition = _lastPointerDownPosition;

    _lastPointerDownAt = now;
    _lastPointerDownPosition = event.position;

    if (lastAt == null || lastPosition == null) return;
    if (now.difference(lastAt) > _doubleTapWindow) return;

    final delta = event.position - lastPosition;
    if (delta.distance > _doubleTapMaxDistance) return;

    _lastPointerDownAt = null;
    _lastPointerDownPosition = null;
    _toggleFullscreen();
  }

  Future<void> _toggleFullscreen({bool? enabled}) async {
    if (!_supportsDesktopToggle || _toggleInProgress) return;
    _toggleInProgress = true;

    try {
      final isFullScreen = await windowManager.isFullScreen();
      final target = enabled ?? !isFullScreen;
      if (target == isFullScreen) return;

      await _setDesktopFullscreen(target);
    } catch (_) {
      // Ignore desktop window API failures and keep the app usable.
    } finally {
      _toggleInProgress = false;
      if (mounted) {
        _focusNode.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        child: widget.child,
      ),
    );
  }
}

class RootScreen extends StatelessWidget {
  const RootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<PlaylistController>();
    return Obx(() {
      switch (controller.setupStage) {
        case DeviceSetupStage.booting:
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        case DeviceSetupStage.ready:
          return const PlayerScreen();
        case DeviceSetupStage.setupRequired:
        case DeviceSetupStage.pendingApproval:
          return const SetupScreen();
      }
    });
  }
}
