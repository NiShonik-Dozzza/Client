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
    if (Platform.isLinux) return _installLinux(artifact);
    if (!Platform.isAndroid) {
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

  /// Linux: распаковать новую версию рядом и переставить симлинк `current`.
  ///
  /// Root не нужен: `/opt/efir-client` принадлежит пользователю сервиса
  /// (см. packaging/linux/install.sh), а `systemd` с `Restart=always` поднимет
  /// нас заново уже по новому симлинку. Никакого root-хелпера, которому
  /// процесс пользователя диктовал бы, что выполнить, — а значит и повышения
  /// привилегий через него.
  static Future<InstallResult> _installLinux(File artifact) async {
    final root = _linuxInstallRoot();
    if (root == null) {
      return const InstallResult(
        InstallOutcome.unsupported,
        'unexpected install layout: expected <root>/versions/<version>/efir',
      );
    }

    final version = _linuxVersionFromArtifact(artifact);
    final versionsDir = Directory('$root/versions');
    final target = Directory('${versionsDir.path}/$version');
    final staging = Directory('$root/.staging-$version');

    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);

      // tar есть на любом Linux — тянуть ради этого пакет-архиватор незачем.
      final result = await Process.run('tar', [
        '-xzf',
        artifact.path,
        '-C',
        staging.path,
        '--no-same-owner',
      ]);
      if (result.exitCode != 0) {
        throw Exception('tar failed (${result.exitCode}): ${result.stderr}');
      }

      // В архиве один каталог верхнего уровня (efir-client_<ver>_linux_amd64).
      final entries = await staging.list(followLinks: false).toList();
      final unpacked = entries.whereType<Directory>().toList();
      final payload = unpacked.length == 1 ? unpacked.first : staging;
      if (!await File('${payload.path}/efir').exists()) {
        throw Exception('archive has no efir binary');
      }

      if (await target.exists()) await target.delete(recursive: true);
      await target.parent.create(recursive: true);
      await payload.rename(target.path);
      await staging.delete(recursive: true);
      await Process.run('chmod', ['755', '${target.path}/efir']);

      final previous = await _linuxCurrentTarget(root);
      // rename(2) поверх существующего симлинка атомарен: current никогда не
      // указывает в никуда, даже если нас убьют посреди обновления.
      final pending = Link('$root/.current.new');
      if (await pending.exists()) await pending.delete();
      await pending.create(target.path);
      await pending.rename('$root/current');

      await _linuxPruneVersions(versionsDir, keep: {target.path, previous});
      await AppLogger.log('linux update installed: $version -> ${target.path}');

      // systemd (Restart=always) поднимет нас уже по новому симлинку.
      exit(0);
    } catch (e) {
      await AppLogger.log('linux install failed: $e');
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {
        // Мусор в .staging-* не критичен: следующая попытка его перезапишет.
      }
      return InstallResult(InstallOutcome.failed, '$e');
    }
  }

  /// Корень установки по расположению текущего бинарника:
  /// `<root>/versions/<version>/efir` -> `<root>`.
  static String? _linuxInstallRoot() =>
      linuxInstallRootFor(Platform.resolvedExecutable);

  /// Разбор пути отдельно от файловой системы — чтобы его можно было проверить
  /// тестом, а не только на живом экране.
  static String? linuxInstallRootFor(String executablePath) {
    final parts = executablePath.split('/');
    if (parts.length < 4) return null;
    // …/versions/<version>/efir
    if (parts[parts.length - 3] != 'versions') return null;
    return parts.sublist(0, parts.length - 3).join('/');
  }

  static Future<String?> _linuxCurrentTarget(String root) async {
    try {
      final link = Link('$root/current');
      if (await link.exists()) return await link.target();
    } catch (_) {
      // Симлинка нет или он битый — просто нечего сохранять для отката.
    }
    return null;
  }

  /// Держим текущую и предыдущую версии: место на экранах не бесконечное,
  /// но откат одним переставленным симлинком должен оставаться возможен.
  static Future<void> _linuxPruneVersions(
    Directory versionsDir, {
    required Set<String?> keep,
  }) async {
    try {
      await for (final entry in versionsDir.list(followLinks: false)) {
        if (entry is! Directory) continue;
        if (keep.contains(entry.path)) continue;
        await entry.delete(recursive: true);
      }
    } catch (e) {
      await AppLogger.log('linux version prune failed: $e');
    }
  }

  static String _linuxVersionFromArtifact(File artifact) =>
      linuxVersionFromFileName(artifact.uri.pathSegments.last);

  /// `efir-1.2.0.tar.gz` -> `1.2.0`. Без версии в имени каталог получил бы
  /// непредсказуемое имя, поэтому запасной вариант — метка времени.
  static String linuxVersionFromFileName(String name) {
    final match = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(name);
    return match?.group(1) ?? DateTime.now().millisecondsSinceEpoch.toString();
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
