// lib/models/playlist_item.dart
import 'package:flutter/foundation.dart';

class PlaylistItem {
  final String filename;
  final DateTime startDate;
  final bool loop;

  PlaylistItem({
    required this.filename,
    required this.startDate,
    this.loop = true,
  });

  factory PlaylistItem.fromJson(Map<String, dynamic> json) {
    return PlaylistItem(
      filename: json['filename'],
      startDate: DateTime.parse(json['start_date']),
      loop: json['loop'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'filename': filename,
      'start_date': startDate.toIso8601String(),
      'loop': loop,
    };
  }

  bool get isImage => filename.endsWith('.jpg') ||
      filename.endsWith('.jpeg') ||
      filename.endsWith('.png') ||
      filename.endsWith('.gif');

  bool get isVideo => filename.endsWith('.mp4') ||
      filename.endsWith('.mov') ||
      filename.endsWith('.avi');

  String get fullPath => 'assets/media/$filename';
}