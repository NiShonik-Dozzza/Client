import 'dart:io';

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Чем закончилась попытка установки.
enum InstallOutcome {
  /// Установка запущена и система её приняла. Приложение сейчас перезапустится
  /// (или уже заменено) — дальше делать нечего.
  started,

  /// Требуется человек у экрана: устройство не Device Owner. Панель покажет
  /// `ready`, чтобы оператор знал, что доехало, но само не встало.
  needsConfirmation,

  /// Платформа пока не умеет ставить обновление сама.
  unsupported,

  failed,
}

class InstallResult {
  const InstallResult(this.outcome, [this.message = '']);

  final InstallOutcome outcome;
  final String message;

  bool get isTerminalFailure =>
      outcome == InstallOutcome.failed || outcome == InstallOutcome.unsupported;
}

/// Установка скачанного и **уже проверенного** артефакта.
///
/// Сюда попадает только файл, у которого сошлись размер, sha256 и подпись
/// (см. [UpdateService]). Установщик сам ничего не проверяет — и не должен:
/// одна проверка в одном месте лучше двух разных.
class UpdateInstaller {
  static const _channel = MethodChannel('efir/update_installer');

  /// Умеет ли эта платформа ставить обновление без человека.
  static Future<bool> canInstallSilently() async {
    if (Platform.isAndroid) return isDeviceOwner();
    return false;
  }

  /// Android: провижинилось ли устройство как Device Owner. Включается только
  /// на свежесброшенном устройстве без аккаунтов — задним числом никак.
  static Future<bool> isDeviceOwner() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isDeviceOwner') ?? false;
    } on PlatformException catch (e) {
      await AppLogger.log('device owner check failed: $e');
      return false;
    }
  }

  static Future<InstallResult> install(File artifact) async {
    if (!Platform.isAndroid) {
      // Windows (scheduled task) и Linux (systemd path-unit) — следующим шагом.
      return const InstallResult(
        InstallOutcome.unsupported,
        'automatic install is not implemented for this platform yet',
      );
    }

    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('install', {
        'path': artifact.path,
      });
      final status = (raw?['status'] as String?) ?? 'failed';
      final message = (raw?['message'] as String?) ?? '';
      await AppLogger.log('update install result: $status $message');
      switch (status) {
        case 'success':
          return InstallResult(InstallOutcome.started, message);
        case 'needs_confirmation':
          return InstallResult(InstallOutcome.needsConfirmation, message);
        default:
          return InstallResult(InstallOutcome.failed, message);
      }
    } on PlatformException catch (e) {
      await AppLogger.log('update install failed: ${e.code} ${e.message}');
      return InstallResult(InstallOutcome.failed, e.message ?? e.code);
    }
  }
}
