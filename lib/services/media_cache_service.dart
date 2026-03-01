import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/manifest.dart';
import '../services/app_logger.dart';

class DownloadForbidden implements Exception {
  @override
  String toString() => 'DownloadForbidden(403)';
}

class MediaCacheService {
  MediaCacheService({http.Client? client, Future<void> Function()? onForbidden})
      : _client = client ?? http.Client(),
        _onForbidden = onForbidden;

  final http.Client _client;
  final Map<int, Future<File?>> _inflight = {};
  final Future<void> Function()? _onForbidden;
  final _rng = Random();

  static const List<int> _downloadBackoffSeconds = [2, 5, 10, 20, 30];
  static const int _maxDownloadAttempts = 5;

  Future<File?> ensureMediaFile(ManifestMedia media, String mediaRoot) {
    return _inflight.putIfAbsent(media.id, () async {
      try {
        if (media.downloadUrl.isEmpty) {
          await AppLogger.log('Media download_url missing: id=${media.id}');
          return null;
        }
        final target = await _targetFile(media, mediaRoot);
        if (await _isValid(target, media)) return target;

        bool refreshed = false;
        for (var attempt = 0; attempt < _maxDownloadAttempts; attempt++) {
          try {
            final stored = await _downloadAndStore(media, target);
            if (stored != null) return stored;
            throw Exception('download failed: checksum mismatch');
          } on DownloadForbidden {
            if (!refreshed && _onForbidden != null) {
              await _onForbidden!();
              refreshed = true;
            }
          } catch (e) {
            await AppLogger.log('Media download attempt ${attempt + 1} failed: $e');
          }

          if (attempt < _maxDownloadAttempts - 1) {
            await Future.delayed(_backoffDelay(attempt + 1));
          }
        }
        return null;
      } catch (e) {
        await AppLogger.log('Media cache error id=${media.id}: $e');
        return null;
      } finally {
        _inflight.remove(media.id);
      }
    });
  }

  Future<File> _targetFile(ManifestMedia media, String mediaRoot) async {
    final dir = Directory(mediaRoot);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final fileName = 'media_${media.id}_${media.safeBaseName}';
    return File(p.join(dir.path, fileName));
  }

  Future<bool> _isValid(File file, ManifestMedia media) async {
    if (!await file.exists()) return false;

    if (media.size > 0) {
      final stat = await file.stat();
      if (stat.size != media.size) return false;
    }

    if (media.sha256.isEmpty) return true;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == media.sha256.toLowerCase();
  }

  Future<void> _download(String url, File target) async {
    final uri = Uri.parse(url);
    final response = await _client.send(http.Request('GET', uri));
    if (response.statusCode == 403) {
      throw DownloadForbidden();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('download failed: ${response.statusCode}');
    }
    final sink = target.openWrite();
    await response.stream.pipe(sink);
    await sink.flush();
    await sink.close();
  }

  Future<File?> _downloadAndStore(ManifestMedia media, File target) async {
    final temp = File('${target.path}.download');
    if (await temp.exists()) {
      await temp.delete();
    }

    await _download(media.downloadUrl, temp);

    if (!await _isValid(temp, media)) {
      await temp.delete();
      await AppLogger.log('Media checksum mismatch: id=${media.id} name=${media.safeBaseName}');
      return null;
    }

    if (await target.exists()) {
      await target.delete();
    }

    await temp.rename(target.path);
    return target;
  }

  Duration _backoffDelay(int attempt) {
    final index = (attempt - 1).clamp(0, _downloadBackoffSeconds.length - 1);
    final base = Duration(seconds: _downloadBackoffSeconds[index]);
    return _withJitter(base);
  }

  Duration _withJitter(Duration base) {
    final jitter = 0.8 + (_rng.nextDouble() * 0.4);
    final ms = (base.inMilliseconds * jitter).round();
    return Duration(milliseconds: ms < 500 ? 500 : ms);
  }
}
