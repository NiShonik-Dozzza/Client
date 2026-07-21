import 'package:efir/services/update_installer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Разбор путей Linux-установки. Ошибиться тут легко, а заметно станет только
/// на живом экране, который после обновления не поднимется.
void main() {
  group('linuxInstallRootFor', () {
    test('раскладка versions/<версия>/efir', () {
      expect(
        UpdateInstaller.linuxInstallRootFor(
          '/opt/efir-client/versions/1.2.0/efir',
        ),
        '/opt/efir-client',
      );
    });

    test('нестандартный корень тоже поддержан', () {
      expect(
        UpdateInstaller.linuxInstallRootFor('/srv/efir/versions/0.9.1/efir'),
        '/srv/efir',
      );
    });

    test('плоская установка не опознаётся — обновлять вслепую нельзя', () {
      expect(UpdateInstaller.linuxInstallRootFor('/opt/efir-client/efir'), isNull);
      expect(UpdateInstaller.linuxInstallRootFor('/usr/bin/efir'), isNull);
      expect(UpdateInstaller.linuxInstallRootFor('efir'), isNull);
    });
  });

  group('linuxVersionFromFileName', () {
    test('версия из имени артефакта', () {
      expect(UpdateInstaller.linuxVersionFromFileName('efir-1.2.0.tar.gz'), '1.2.0');
      expect(
        UpdateInstaller.linuxVersionFromFileName('efir-client_10.0.3_linux_amd64.tar.gz'),
        '10.0.3',
      );
    });

    test('без версии в имени — запасное уникальное имя, а не пустая строка', () {
      final fallback = UpdateInstaller.linuxVersionFromFileName('efir.tar.gz');
      expect(fallback, isNotEmpty);
      expect(int.tryParse(fallback), isNotNull);
    });
  });
}
