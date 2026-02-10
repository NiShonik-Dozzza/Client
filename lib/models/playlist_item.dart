// lib/models/playlist_item.dart
import 'package:path/path.dart' as p;

class PlaylistItem {
  /// В JSON это может быть:
  /// - "test.mp4" (имя)
  /// - "C:\\...\\test.mp4" (абсолютный путь)
  final String filename;

  /// Начало активности (локальное время)
  final DateTime startDate;

  /// Конец активности (локальное время). Может быть null в JSON,
  /// тогда контроллер рассчитает автоматически.
  final DateTime? stopDate;

  /// Оставляем для будущего:
  /// - НЕ используется для “следующий по списку”
  /// - может использоваться для “перезапуск видео в своём окне”
  final bool loop;

  /// Для картинок: если loop=false, можно показать один раз N секунд
  final int durationSeconds;

  PlaylistItem({
    required this.filename,
    required this.startDate,
    required this.stopDate,
    required this.loop,
    required this.durationSeconds,
  });

  factory PlaylistItem.fromJson(Map<String, dynamic> json) {
    final stopRaw = json['stop_date'];

    return PlaylistItem(
      filename: (json['filename'] as String).trim(),
      startDate: DateTime.parse(json['start_date'] as String),
      stopDate: (stopRaw == null || (stopRaw is String && stopRaw.trim().isEmpty))
          ? null
          : DateTime.parse(stopRaw as String),
      loop: (json['loop'] as bool?) ?? true,
      durationSeconds: (json['duration_seconds'] as int?) ?? 10,
    );
  }

  PlaylistItem copyWith({
    String? filename,
    DateTime? startDate,
    DateTime? stopDate,
    bool? loop,
    int? durationSeconds,
  }) {
    return PlaylistItem(
      filename: filename ?? this.filename,
      startDate: startDate ?? this.startDate,
      stopDate: stopDate ?? this.stopDate,
      loop: loop ?? this.loop,
      durationSeconds: durationSeconds ?? this.durationSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
    'filename': filename,
    'start_date': startDate.toIso8601String(),
    'stop_date': stopDate?.toIso8601String(),
    'loop': loop,
    'duration_seconds': durationSeconds,
  };

  String get baseName => p.basename(filename);

  bool get isImage {
    final f = baseName.toLowerCase();
    return f.endsWith('.jpg') ||
        f.endsWith('.jpeg') ||
        f.endsWith('.png') ||
        f.endsWith('.gif') ||
        f.endsWith('.webp');
  }

  bool get isVideo {
    final f = baseName.toLowerCase();
    return f.endsWith('.mp4') ||
        f.endsWith('.mov') ||
        f.endsWith('.avi') ||
        f.endsWith('.mkv') ||
        f.endsWith('.webm');
  }

  /// Активен в момент now: start <= now < stop (если stop задан)
  bool isActiveAt(DateTime now) {
    if (now.isBefore(startDate)) return false;
    if (stopDate == null) return true;
    return now.isBefore(stopDate!);
  }
}
