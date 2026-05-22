import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppPaths {
  static const String _rootFolderName = 'efir';

  static Future<Directory> rootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _rootFolderName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> playlistFile() async {
    final root = await rootDir();
    return File(p.join(root.path, 'playlist.json'));
  }

  static Future<File> configFile() async {
    final root = await rootDir();
    return File(p.join(root.path, 'config.json'));
  }

  static Future<File> deviceFile() async {
    final root = await rootDir();
    return File(p.join(root.path, 'device.json'));
  }

  static Future<File> manifestFile() async {
    final root = await rootDir();
    return File(p.join(root.path, 'manifest.json'));
  }

  static Future<File> logFile() async {
    final root = await rootDir();
    return File(p.join(root.path, 'log.txt'));
  }

  static Future<Directory> mediaDir() async {
    final root = await rootDir();
    final dir = Directory(p.join(root.path, 'media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
