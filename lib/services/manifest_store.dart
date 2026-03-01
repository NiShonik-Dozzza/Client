import 'dart:convert';

import '../models/manifest.dart';
import '../services/app_logger.dart';
import '../services/app_paths.dart';

class ManifestStore {
  Future<Manifest?> read() async {
    try {
      final file = await AppPaths.manifestFile();
      if (!await file.exists()) return null;
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final manifest = Manifest.fromJson(map);
      if (manifest.revision.isEmpty) return null;
      return manifest;
    } catch (e) {
      await AppLogger.log('ManifestStore read error: $e');
      return null;
    }
  }

  Future<void> save(Manifest manifest) async {
    final file = await AppPaths.manifestFile();
    await file.writeAsString(jsonEncode(manifest.toJson()), flush: true);
  }
}
