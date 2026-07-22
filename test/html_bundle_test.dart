import 'package:efir/services/html_bundle_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Разбор путей внутри архива страницы.
///
/// Бандл распаковывается рядом с `device.json`, где лежит Bearer устройства,
/// поэтому запись `../../device.json` в архиве — это перезапись токена.
/// Сервер такие архивы отклоняет, но клиент обязан проверять сам: бандл мог
/// прийти из бэкапа или с подменённого сервера.
void main() {
  group('safeRelativePath', () {
    test('обычные пути проходят и нормализуются', () {
      expect(HtmlBundleService.safeRelativePath('index.html'), 'index.html');
      expect(HtmlBundleService.safeRelativePath('assets/app.js'), 'assets/app.js');
      expect(HtmlBundleService.safeRelativePath('./styles.css'), 'styles.css');
      expect(HtmlBundleService.safeRelativePath('a//b/c.png'), 'a/b/c.png');
      // Разделители Windows приводятся к posix.
      expect(HtmlBundleService.safeRelativePath(r'assets\img\logo.png'), 'assets/img/logo.png');
    });

    test('выход за пределы каталога отклоняется', () {
      expect(HtmlBundleService.safeRelativePath('../device.json'), isNull);
      expect(HtmlBundleService.safeRelativePath('../../device.json'), isNull);
      expect(HtmlBundleService.safeRelativePath('assets/../../device.json'), isNull);
      expect(HtmlBundleService.safeRelativePath(r'..\..\device.json'), isNull);
    });

    test('абсолютные пути отклоняются', () {
      expect(HtmlBundleService.safeRelativePath('/etc/passwd'), isNull);
      expect(HtmlBundleService.safeRelativePath(r'C:\Windows\system32\x.dll'), isNull);
      expect(HtmlBundleService.safeRelativePath('C:/Windows/x.dll'), isNull);
    });

    test('пустые и вырожденные имена отклоняются', () {
      expect(HtmlBundleService.safeRelativePath(''), isNull);
      expect(HtmlBundleService.safeRelativePath('   '), isNull);
      expect(HtmlBundleService.safeRelativePath('.'), isNull);
      expect(HtmlBundleService.safeRelativePath('./'), isNull);
    });
  });
}
