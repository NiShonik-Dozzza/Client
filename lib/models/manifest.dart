import 'package:path/path.dart' as p;

enum ManifestContentType { media, playlist, html }

enum ManifestLoopMode { none, fill }

class Manifest {
  final String deviceId;
  final String revision;
  final String contentRevision;
  final String controlRevision;
  final String timezone;
  final int prefetchSeconds;
  final ManifestPlaybackSettings playback;
  final ManifestDisplaySettings display;
  final List<ManifestItem> items;
  final List<ManifestMedia> media;
  final List<ManifestPlaylist> playlists;
  final List<ManifestHtmlPage> htmlPages;

  Manifest({
    required this.deviceId,
    required this.revision,
    required this.contentRevision,
    required this.controlRevision,
    required this.timezone,
    required this.prefetchSeconds,
    required this.playback,
    required this.display,
    required this.items,
    required this.media,
    required this.playlists,
    this.htmlPages = const [],
  });

  factory Manifest.fromJson(Map<String, dynamic> json) {
    final itemsRaw = (json['items'] as List? ?? []).cast<dynamic>();
    final mediaRaw = (json['media'] as List? ?? []).cast<dynamic>();
    final playlistsRaw = (json['playlists'] as List? ?? []).cast<dynamic>();
    final htmlRaw = (json['html_pages'] as List? ?? []).cast<dynamic>();

    final items =
        itemsRaw
            .map(
              (e) => ManifestItem.fromJson((e as Map).cast<String, dynamic>()),
            )
            .toList()
          ..sort((a, b) => a.startTime.compareTo(b.startTime));

    final media = mediaRaw
        .map((e) => ManifestMedia.fromJson((e as Map).cast<String, dynamic>()))
        .toList();

    final playlists = playlistsRaw
        .map(
          (e) => ManifestPlaylist.fromJson((e as Map).cast<String, dynamic>()),
        )
        .toList();

    return Manifest(
      deviceId: (json['device_id'] as String?)?.trim() ?? '',
      revision: (json['revision'] as String?)?.trim() ?? '',
      contentRevision: (json['content_revision'] as String?)?.trim() ?? '',
      controlRevision: (json['control_revision'] as String?)?.trim() ?? '',
      timezone: (json['timezone'] as String?)?.trim() ?? '',
      prefetchSeconds: _asInt(json['prefetch_seconds'], 300),
      playback: ManifestPlaybackSettings.fromJson(
        ((json['playback'] as Map?) ?? const <String, dynamic>{})
            .cast<String, dynamic>(),
      ),
      display: ManifestDisplaySettings.fromJson(
        ((json['display'] as Map?) ?? const <String, dynamic>{})
            .cast<String, dynamic>(),
      ),
      items: items,
      media: media,
      playlists: playlists,
      htmlPages: htmlRaw
          .map((e) => ManifestHtmlPage.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'revision': revision,
    'content_revision': contentRevision,
    'control_revision': controlRevision,
    'timezone': timezone,
    'prefetch_seconds': prefetchSeconds,
    'playback': playback.toJson(),
    'display': display.toJson(),
    'items': items.map((e) => e.toJson()).toList(),
    'media': media.map((e) => e.toJson()).toList(),
    'playlists': playlists.map((e) => e.toJson()).toList(),
    'html_pages': htmlPages.map((e) => e.toJson()).toList(),
  };

  ManifestMedia? mediaById(int id) {
    for (final m in media) {
      if (m.id == id) return m;
    }
    return null;
  }

  ManifestHtmlPage? htmlPageById(int id) {
    for (final page in htmlPages) {
      if (page.id == id) return page;
    }
    return null;
  }

  ManifestPlaylist? playlistById(int id) {
    for (final p in playlists) {
      if (p.id == id) return p;
    }
    return null;
  }
}

class ManifestPlaybackSettings {
  const ManifestPlaybackSettings({
    required this.masterVolume,
    required this.audioMuted,
  });

  final int masterVolume;
  final bool audioMuted;

  factory ManifestPlaybackSettings.fromJson(Map<String, dynamic> json) {
    return ManifestPlaybackSettings(
      masterVolume: _asInt(json['master_volume']),
      audioMuted: json['audio_muted'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'master_volume': masterVolume,
    'audio_muted': audioMuted,
  };
}

class ManifestDisplaySettings {
  const ManifestDisplaySettings({
    required this.targetDisplayId,
    required this.rotation,
  });

  final String targetDisplayId;
  final int? rotation;

  factory ManifestDisplaySettings.fromJson(Map<String, dynamic> json) {
    final rawRotation = _asNullableInt(json['rotation']);
    return ManifestDisplaySettings(
      targetDisplayId: (json['target_display_id'] as String?)?.trim() ?? '',
      rotation: rawRotation == null ? null : rawRotation % 360,
    );
  }

  Map<String, dynamic> toJson() => {
    'target_display_id': targetDisplayId,
    'rotation': rotation,
  };
}

class ManifestItem {
  final int? eventId;
  final DateTime startTime;
  final DateTime endTime;
  final ManifestContentType contentType;
  final int contentId;
  final ManifestLoopMode loopMode;
  final int priority;

  ManifestItem({
    required this.eventId,
    required this.startTime,
    required this.endTime,
    required this.contentType,
    required this.contentId,
    required this.loopMode,
    required this.priority,
  });

  factory ManifestItem.fromJson(Map<String, dynamic> json) {
    final contentTypeRaw = (json['content_type'] as String?)
        ?.trim()
        .toLowerCase();
    final loopModeRaw = (json['loop_mode'] as String?)?.trim().toLowerCase();

    return ManifestItem(
      eventId: _asNullableInt(json['event_id']),
      startTime: _parseTime(json['start_time'] as String?),
      endTime: _parseTime(json['end_time'] as String?),
      contentType: contentTypeRaw == 'playlist'
          ? ManifestContentType.playlist
          : contentTypeRaw == 'html'
              ? ManifestContentType.html
              : ManifestContentType.media,
      contentId: _asInt(json['content_id']),
      loopMode: loopModeRaw == 'fill'
          ? ManifestLoopMode.fill
          : ManifestLoopMode.none,
      priority: _asInt(json['priority']),
    );
  }

  Map<String, dynamic> toJson() => {
    'event_id': eventId,
    'start_time': startTime.toIso8601String(),
    'end_time': endTime.toIso8601String(),
    'content_type': contentType == ManifestContentType.playlist
        ? 'playlist'
        : contentType == ManifestContentType.html
            ? 'html'
            : 'media',
    'content_id': contentId,
    'loop_mode': loopMode == ManifestLoopMode.fill ? 'fill' : 'none',
    'priority': priority,
  };

  bool isActiveAt(DateTime now) =>
      !now.isBefore(startTime) && now.isBefore(endTime);
}

class ManifestMedia {
  final int id;
  final String originalName;
  final String sha256;
  final int size;
  final String contentType;
  final String objectKey;
  final String downloadUrl;

  ManifestMedia({
    required this.id,
    required this.originalName,
    required this.sha256,
    required this.size,
    required this.contentType,
    required this.objectKey,
    required this.downloadUrl,
  });

  factory ManifestMedia.fromJson(Map<String, dynamic> json) {
    return ManifestMedia(
      id: _asInt(json['id']),
      originalName: (json['original_name'] as String?)?.trim() ?? '',
      sha256: (json['sha256'] as String?)?.trim() ?? '',
      size: _asInt(json['size']),
      contentType: (json['content_type'] as String?)?.trim() ?? '',
      objectKey: (json['object_key'] as String?)?.trim() ?? '',
      downloadUrl: (json['download_url'] as String?)?.trim() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'original_name': originalName,
    'sha256': sha256,
    'size': size,
    'content_type': contentType,
    'object_key': objectKey,
    'download_url': downloadUrl,
  };

  bool get isImage => contentType.toLowerCase().startsWith('image/');
  bool get isVideo => contentType.toLowerCase().startsWith('video/');

  String get safeBaseName {
    final fromOriginal = p.basename(originalName.trim());
    if (fromOriginal.isNotEmpty &&
        fromOriginal != '.' &&
        fromOriginal != '..') {
      return fromOriginal;
    }
    final fromKey = p.basename(objectKey.trim());
    if (fromKey.isNotEmpty && fromKey != '.' && fromKey != '..') {
      return fromKey;
    }
    final ext = _extensionFromContentType(contentType);
    return ext.isEmpty ? 'media_$id' : 'media_$id.$ext';
  }
}

class ManifestPlaylist {
  final int id;
  final String name;
  final String description;
  final List<ManifestPlaylistItem> items;

  ManifestPlaylist({
    required this.id,
    required this.name,
    required this.description,
    required this.items,
  });

  factory ManifestPlaylist.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List? ?? []).cast<dynamic>();
    final items =
        rawItems
            .map(
              (e) => ManifestPlaylistItem.fromJson(
                (e as Map).cast<String, dynamic>(),
              ),
            )
            .toList()
          ..sort((a, b) => a.position.compareTo(b.position));

    return ManifestPlaylist(
      id: _asInt(json['id']),
      name: (json['name'] as String?)?.trim() ?? '',
      description: (json['description'] as String?)?.trim() ?? '',
      items: items,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'items': items.map((e) => e.toJson()).toList(),
  };
}

class ManifestPlaylistItem {
  final int id;
  final int mediaId;
  final int durationSec;
  final int position;

  ManifestPlaylistItem({
    required this.id,
    required this.mediaId,
    required this.durationSec,
    required this.position,
  });

  factory ManifestPlaylistItem.fromJson(Map<String, dynamic> json) {
    return ManifestPlaylistItem(
      id: _asInt(json['id']),
      mediaId: _asInt(json['media_id']),
      durationSec: _asInt(json['duration_sec'], 10),
      position: _asInt(json['position']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'media_id': mediaId,
    'duration_sec': durationSec,
    'position': position,
  };
}


/// Опубликованная HTML-страница в манифесте.
///
/// Адресов источников данных здесь нет — только их ключи: адреса знает панель,
/// и разъезжаться по экранам вместе с бандлом они не должны.
class ManifestHtmlPage {
  const ManifestHtmlPage({
    required this.id,
    required this.name,
    required this.versionNo,
    required this.bundleMediaId,
    required this.entryPath,
    required this.allowNetwork,
    required this.sourceKeys,
    required this.minDurationSec,
    required this.maxDurationSec,
    required this.readyTimeoutSec,
    required this.onDone,
    required this.syncPagination,
    required this.refreshSec,
  });

  final int id;
  final String name;
  final int versionNo;
  final int bundleMediaId;
  final String entryPath;
  final bool allowNetwork;
  final List<String> sourceKeys;
  final int minDurationSec;

  /// Потолок показа. Страница сама сообщает о завершении через `efir.done()`,
  /// и без потолка одна сломанная строчка JS держала бы экран навсегда.
  final int maxDurationSec;
  final int readyTimeoutSec;

  /// next | restart | hold — что делать, если страница закончила раньше слота.
  final String onDone;
  final bool syncPagination;
  final int? refreshSec;

  factory ManifestHtmlPage.fromJson(Map<String, dynamic> json) {
    return ManifestHtmlPage(
      id: _asInt(json['id']),
      name: (json['name'] as String?)?.trim() ?? '',
      versionNo: _asInt(json['version_no']),
      bundleMediaId: _asInt(json['bundle_media_id']),
      entryPath: (json['entry_path'] as String?)?.trim().isNotEmpty == true
          ? (json['entry_path'] as String).trim()
          : 'index.html',
      allowNetwork: json['allow_network'] == true,
      sourceKeys: ((json['source_keys'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      minDurationSec: _asInt(json['min_duration_sec']),
      maxDurationSec: _asInt(json['max_duration_sec'], 300),
      readyTimeoutSec: _asInt(json['ready_timeout_sec'], 15),
      onDone: (json['on_done'] as String?)?.trim() ?? 'next',
      syncPagination: json['sync_pagination'] == true,
      refreshSec: _asNullableInt(json['refresh_sec']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version_no': versionNo,
    'bundle_media_id': bundleMediaId,
    'entry_path': entryPath,
    'allow_network': allowNetwork,
    'source_keys': sourceKeys,
    'min_duration_sec': minDurationSec,
    'max_duration_sec': maxDurationSec,
    'ready_timeout_sec': readyTimeoutSec,
    'on_done': onDone,
    'sync_pagination': syncPagination,
    'refresh_sec': refreshSec,
  };
}

int _asInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

int? _asNullableInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

DateTime _parseTime(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
  final parsed = DateTime.parse(raw);
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

String _extensionFromContentType(String contentType) {
  final lower = contentType.toLowerCase();
  if (!lower.contains('/')) return '';
  final ext = lower.split('/').last.trim();
  if (ext.isEmpty) return '';
  if (ext == 'jpeg') return 'jpg';
  return ext;
}
