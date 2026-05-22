import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../models/display_profile.dart';
import 'app_logger.dart';

class DisplayService {
  Future<List<DeviceDisplayProfile>> getAvailableDisplays() async {
    if (_supportsDesktopDisplayRouting) {
      try {
        final displays = await screenRetriever.getAllDisplays();
        final primary = await screenRetriever.getPrimaryDisplay();
        final currentId = await _desktopCurrentDisplayId(displays);
        return displays
            .asMap()
            .entries
            .map(
              (entry) => _mapDesktopDisplay(
                entry.key,
                entry.value,
                primaryId: primary.id,
                currentId: currentId,
              ),
            )
            .toList(growable: false);
      } catch (e) {
        await AppLogger.log('display discovery fallback: $e');
      }
    }

    final views = PlatformDispatcher.instance.views;
    final view = views.isNotEmpty ? views.first : null;
    final physical = view?.physicalSize ?? const Size(1920, 1080);
    return [
      DeviceDisplayProfile(
        id: 'default-display',
        label: 'Display 1',
        width: physical.width.round(),
        height: physical.height.round(),
        isPrimary: true,
        isCurrent: true,
      ),
    ];
  }

  Future<void> applyTargetDisplay(String displayId) async {
    if (!_supportsDesktopDisplayRouting) {
      return;
    }

    try {
      final displays = await screenRetriever.getAllDisplays();
      Display? target;
      for (final display in displays) {
        if (display.id == displayId) {
          target = display;
          break;
        }
      }
      if (target == null) {
        return;
      }

      final position = target.visiblePosition ?? Offset.zero;
      final size = target.visibleSize ?? target.size;
      final bounds = Rect.fromLTWH(
        position.dx,
        position.dy,
        size.width,
        size.height,
      );

      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
      }
      await windowManager.setBounds(bounds);
      await windowManager.setFullScreen(true);
      await windowManager.focus();
    } catch (e) {
      await AppLogger.log('display apply failed: $e');
    }
  }

  bool get _supportsDesktopDisplayRouting =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  DeviceDisplayProfile _mapDesktopDisplay(
    int index,
    Display display, {
    required String primaryId,
    required String? currentId,
  }) {
    final scale = (display.scaleFactor ?? 1).toDouble();
    final physicalWidth = (display.size.width * scale).round();
    final physicalHeight = (display.size.height * scale).round();
    final fallbackLabel = 'Display ${index + 1}';

    return DeviceDisplayProfile(
      id: display.id,
      label: (display.name?.trim().isNotEmpty ?? false)
          ? display.name!.trim()
          : fallbackLabel,
      width: physicalWidth,
      height: physicalHeight,
      isPrimary: display.id == primaryId,
      isCurrent: display.id == currentId,
    );
  }

  Future<String?> _desktopCurrentDisplayId(List<Display> displays) async {
    if (displays.isEmpty) {
      return null;
    }
    try {
      final bounds = await windowManager.getBounds();
      final center = bounds.center;
      for (final display in displays) {
        final origin = display.visiblePosition ?? Offset.zero;
        final size = display.visibleSize ?? display.size;
        final rect = Rect.fromLTWH(
          origin.dx,
          origin.dy,
          size.width,
          size.height,
        );
        if (rect.contains(center)) {
          return display.id;
        }
      }
    } catch (e) {
      await AppLogger.log('display current lookup failed: $e');
    }
    return displays.first.id;
  }
}
