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
    if (Platform.isWindows) return _installWindows(artifact);
    if (!Platform.isAndroid) {
      // Linux (systemd path-unit) — следующим шагом.
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

  /// Windows: тихий запуск Inno-инсталлятора от текущего пользователя.
  ///
  /// UAC здесь не всплывает, потому что клиент ставится в пользовательский
  /// каталог (`PrivilegesRequired=lowest` в efir-setup.iss). Установщик сам
  /// закроет приложение, заменит файлы и поднимет его обратно.
  static Future<InstallResult> _installWindows(File artifact) async {
    try {
      // Watchdog не должен поднять старую копию посреди замены файлов —
      // он бы залочил exe, и установка провалилась бы на ровном месте.
      await _writeUpdateLock();

      await Process.start(
        artifact.path,
        const [
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
        ],
        mode: ProcessStartMode.detached,
      );
      await AppLogger.log('windows installer started: ${artifact.path}');

      // Даём установщику подняться и отпускаем свои файлы: пока процесс жив,
      // заменить его же .exe нельзя.
      await Future<void>.delayed(const Duration(seconds: 3));
      exit(0);
    } catch (e) {
      await clearUpdateLock();
      await AppLogger.log('windows install failed: $e');
      return InstallResult(InstallOutcome.failed, '$e');
    }
  }

  static Future<File?> _lockFile() async {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    final dir = Directory('$appData\\efir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}\\update-in-progress');
  }

  static Future<void> _writeUpdateLock() async {
    final file = await _lockFile();
    await file?.writeAsString(DateTime.now().toIso8601String());
  }

  /// Снимает замок watchdog'а. Зовётся при старте приложения: если мы поднялись,
  /// обновление либо закончилось, либо провалилось — в обоих случаях watchdog
  /// снова должен работать. У самого замка есть и срок годности (15 минут),
  /// так что зависший установщик не выключает watchdog насовсем.
  static Future<void> clearUpdateLock() async {
    if (!Platform.isWindows) return;
    try {
      final file = await _lockFile();
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {
      // Замок протухнет сам — падать тут не из-за чего.
    }
  }
}
