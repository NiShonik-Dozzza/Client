class PlaylistItem {
  final String filename;
  final DateTime startDate;
  final bool loop;
  String get fullPath => 'assets/media/$filename';

  /// Сколько секунд показывать изображение (и вообще элемент, если нужно).
  /// Для изображений критично.
  final int durationSeconds;

  PlaylistItem({
    required this.filename,
    required this.startDate,
    this.loop = true,
    this.durationSeconds = 10,
  });

  factory PlaylistItem.fromJson(Map<String, dynamic> json) {
    return PlaylistItem(
      filename: json['filename'] as String,
      startDate: DateTime.parse(json['start_date'] as String),
      loop: (json['loop'] as bool?) ?? true,
      durationSeconds: (json['duration_seconds'] as int?) ?? 10,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'filename': filename,
      'start_date': startDate.toIso8601String(),
      'loop': loop,
      'duration_seconds': durationSeconds,
    };
  }

  bool get isImage {
    final f = filename.toLowerCase();
    return f.endsWith('.jpg') ||
        f.endsWith('.jpeg') ||
        f.endsWith('.png') ||
        f.endsWith('.gif') ||
        f.endsWith('.webp');
  }

  bool get isVideo {
    final f = filename.toLowerCase();
    return f.endsWith('.mp4') ||
        f.endsWith('.mov') ||
        f.endsWith('.avi') ||
        f.endsWith('.mkv') ||
        f.endsWith('.webm');
  }
}
