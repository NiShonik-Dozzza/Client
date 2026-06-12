import 'dart:convert';
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

class MediaCacheDiagnostics {
  const MediaCacheDiagnostics({
    required this.cachedMediaCount,
    required this.cacheSizeBytes,
    required this.downloadFailures,
  });

  final int cachedMediaCount;
  final int cacheSizeBytes;
  final int downloadFailures;
}

class MediaCacheService {
  MediaCacheService({
    http.Client? client,
    Future<void> Function()? onForbidden,
    String? Function()? tokenProvider,
  }) : _client = client ?? http.Client(),
       _onForbidden = onForbidden,
       _tokenProvider = tokenProvider;

  final http.Client _client;
  final Map<int, Future<File?>> _inflight = {};
  final Map<String, Future<Map<int, _ValidatedCacheEntry>>> _validationIndexes =
      {};
  final Future<void> Function()? _onForbidden;
  final String? Function()? _tokenProvider;
  final _rng = Random();
  int _downloadFailures = 0;

  static const List<int> _downloadBackoffSeconds = [2, 5, 10, 20, 30];
  static const int _maxDownloadAttempts = 5;

  Future<MediaCacheDiagnostics> diagnostics(
    Manifest? manifest,
    String mediaRoot,
  ) async {
    if (manifest == null || mediaRoot.trim().isEmpty) {
      return MediaCacheDiagnostics(
        cachedMediaCount: 0,
        cacheSizeBytes: 0,
        downloadFailures: _downloadFailures,
      );
    }

    var count = 0;
    var sizeBytes = 0;
    for (final media in manifest.media) {
      try {
        final target = await _targetFile(media, mediaRoot);
        if (await _isValid(target, media, verifyHashWhenUncached: false)) {
          count++;
          sizeBytes += await target.length();
        }
      } catch (e) {
        await AppLogger.log(
          'Media cache diagnostics skipped id=${media.id}: $e',
        );
      }
    }
    return MediaCacheDiagnostics(
      cachedMediaCount: count,
      cacheSizeBytes: sizeBytes,
      downloadFailures: _downloadFailures,
    );
  }

  Future<File?> ensureMediaFile(ManifestMedia media, String mediaRoot) {
    return _inflight.putIfAbsent(media.id, () async {
      final startedAt = DateTime.now();

      try {
        if (media.downloadUrl.isEmpty) {
          await AppLogger.log('Media download_url missing: id=${media.id}');
          return null;
        }
        final target = await _targetFile(media, mediaRoot);
        if (await _isValid(target, media, verifyHashWhenUncached: false)) {
          await AppLogger.log(
            'media cache hit: id=${media.id} name=${media.safeBaseName} elapsed=${DateTime.now().difference(startedAt).inMilliseconds}ms path=${target.path}',
          );
          return target;
        }

        await AppLogger.log(
          'media cache miss: id=${media.id} name=${media.safeBaseName} elapsed=${DateTime.now().difference(startedAt).inMilliseconds}ms path=${target.path}',
        );

        bool refreshed = false;
        for (var attempt = 0; attempt < _maxDownloadAttempts; attempt++) {
          try {
            final stored = await _downloadAndStore(media, target);
            if (stored != null) {
              await AppLogger.log(
                'media cache stored: id=${media.id} name=${media.safeBaseName} attempt=${attempt + 1} elapsed=${DateTime.now().difference(startedAt).inMilliseconds}ms path=${stored.path}',
              );
              return stored;
            }
            throw Exception('download failed: checksum mismatch');
          } on DownloadForbidden {
            if (!refreshed && _onForbidden != null) {
              await _onForbidden();
              refreshed = true;
            }
          } catch (e) {
            await AppLogger.log(
              'Media download attempt ${attempt + 1} failed: $e',
            );
          }

          if (attempt < _maxDownloadAttempts - 1) {
            await Future.delayed(_backoffDelay(attempt + 1));
          }
        }
        await AppLogger.log(
          'media cache failed: id=${media.id} name=${media.safeBaseName} elapsed=${DateTime.now().difference(startedAt).inMilliseconds}ms',
        );
        _downloadFailures++;
        return null;
      } catch (e) {
        await AppLogger.log(
          'Media cache error id=${media.id} elapsed=${DateTime.now().difference(startedAt).inMilliseconds}ms: $e',
        );
        _downloadFailures++;
        return null;
      } finally {
        _inflight.remove(media.id);
      }
    });
  }

  /// Возвращает уже закэшированный файл медиа без скачивания (для превью).
  /// null — если файла нет на диске или mediaRoot пуст.
  Future<File?> cachedFile(ManifestMedia media, String mediaRoot) async {
    if (mediaRoot.trim().isEmpty) return null;
    final file = File(
      p.join(mediaRoot, 'media_${media.id}_${media.safeBaseName}'),
    );
    return await file.exists() ? file : null;
  }

  Future<File> _targetFile(ManifestMedia media, String mediaRoot) async {
    final dir = Directory(mediaRoot);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final fileName = 'media_${media.id}_${media.safeBaseName}';
    return File(p.join(dir.path, fileName));
  }

  Future<bool> _isValid(
    File file,
    ManifestMedia media, {
    bool verifyHashWhenUncached = true,
  }) async {
    if (!await file.exists()) return false;

    final stat = await file.stat();
    if (media.size > 0 && stat.size != media.size) return false;

    final index = await _validationIndex(file.parent.path);
    final cached = index[media.id];
    if (cached != null && cached.matches(file, media, stat)) {
      return true;
    }

    if (media.sha256.isEmpty) {
      await _rememberValid(file, media, stat);
      return true;
    }
    if (!verifyHashWhenUncached) return true;

    final digest = await sha256.bind(file.openRead()).first;
    final valid = digest.toString().toLowerCase() == media.sha256.toLowerCase();
    if (valid) {
      await _rememberValid(file, media, stat);
    }
    return valid;
  }

  Future<void> _download(String url, File target) async {
    final uri = Uri.parse(url);
    final request = http.Request('GET', uri);
    final token = _tokenProvider?.call();
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    final response = await _client.send(request);
    if (response.statusCode == 401 ||
        response.statusCode == 403 ||
        response.statusCode == 404) {
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
      await AppLogger.log(
        'Media checksum mismatch: id=${media.id} name=${media.safeBaseName}',
      );
      return null;
    }

    if (await target.exists()) {
      await target.delete();
    }

    await temp.rename(target.path);
    await _rememberValid(target, media, await target.stat());
    return target;
  }

  Future<Map<int, _ValidatedCacheEntry>> _validationIndex(String mediaRoot) {
    final root = Directory(mediaRoot).absolute.path;
    return _validationIndexes.putIfAbsent(root, () async {
      final file = File(p.join(root, '.media_cache_index.json'));
      if (!await file.exists()) return <int, _ValidatedCacheEntry>{};
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is! Map) return <int, _ValidatedCacheEntry>{};
        final entries = <int, _ValidatedCacheEntry>{};
        for (final entry in raw.entries) {
          final id = int.tryParse(entry.key.toString());
          if (id == null || entry.value is! Map) continue;
          final parsed = _ValidatedCacheEntry.fromJson(
            (entry.value as Map).cast<String, dynamic>(),
          );
          if (parsed != null) entries[id] = parsed;
        }
        return entries;
      } catch (e) {
        await AppLogger.log('Media cache index ignored: $e');
        return <int, _ValidatedCacheEntry>{};
      }
    });
  }

  Future<void> _rememberValid(
    File file,
    ManifestMedia media,
    FileStat stat,
  ) async {
    final root = file.parent.absolute.path;
    final index = await _validationIndex(root);
    index[media.id] = _ValidatedCacheEntry(
      path: file.absolute.path,
      sha256: media.sha256.toLowerCase(),
      size: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
    final payload = <String, dynamic>{
      for (final entry in index.entries) '${entry.key}': entry.value.toJson(),
    };
    try {
      await File(
        p.join(root, '.media_cache_index.json'),
      ).writeAsString(jsonEncode(payload));
    } catch (e) {
      await AppLogger.log('Media cache index write warning: $e');
    }
  }

  /// Удаляет кэшированные файлы, которых нет в текущем манифесте.
  /// Вызывать после успешного получения нового манифеста.
  Future<void> pruneUnused(Set<int> neededIds, String mediaRoot) async {
    final dir = Directory(mediaRoot);
    if (!await dir.exists()) return;

    final removed = <int>[];
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith('media_')) continue;

      final parts = name.split('_');
      if (parts.length < 3) continue;
      final id = int.tryParse(parts[1]);
      if (id == null) continue;

      if (!neededIds.contains(id)) {
        try {
          await entry.delete();
          removed.add(id);
        } catch (e) {
          await AppLogger.log('Cache prune error id=$id: $e');
        }
      }
    }

    if (removed.isNotEmpty) {
      await AppLogger.log('Cache pruned: removed ids=$removed');
      final index = await _validationIndex(mediaRoot);
      for (final id in removed) {
        index.remove(id);
      }
      final payload = <String, dynamic>{
        for (final entry in index.entries) '${entry.key}': entry.value.toJson(),
      };
      try {
        await File(
          p.join(Directory(mediaRoot).absolute.path, '.media_cache_index.json'),
        ).writeAsString(jsonEncode(payload));
      } catch (e) {
        await AppLogger.log('Cache index update after prune error: $e');
      }
    }
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

class _ValidatedCacheEntry {
  const _ValidatedCacheEntry({
    required this.path,
    required this.sha256,
    required this.size,
    required this.modifiedMs,
  });

  final String path;
  final String sha256;
  final int size;
  final int modifiedMs;

  static _ValidatedCacheEntry? fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final sha256 = json['sha256'];
    final size = json['size'];
    final modifiedMs = json['modified_ms'];
    if (path is! String ||
        sha256 is! String ||
        size is! int ||
        modifiedMs is! int) {
      return null;
    }
    return _ValidatedCacheEntry(
      path: path,
      sha256: sha256,
      size: size,
      modifiedMs: modifiedMs,
    );
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'sha256': sha256,
    'size': size,
    'modified_ms': modifiedMs,
  };

  bool matches(File file, ManifestMedia media, FileStat stat) {
    return path == file.absolute.path &&
        sha256 == media.sha256.toLowerCase() &&
        size == stat.size &&
        modifiedMs == stat.modified.millisecondsSinceEpoch;
  }
}
