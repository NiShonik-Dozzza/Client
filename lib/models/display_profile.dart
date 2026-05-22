class DeviceDisplayProfile {
  const DeviceDisplayProfile({
    required this.id,
    required this.label,
    required this.width,
    required this.height,
    this.isPrimary = false,
    this.isCurrent = false,
  });

  final String id;
  final String label;
  final int width;
  final int height;
  final bool isPrimary;
  final bool isCurrent;

  String get resolutionLabel => '${width}x$height';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': label,
    'width': width,
    'height': height,
    'is_primary': isPrimary,
    'is_current': isCurrent,
  };

  factory DeviceDisplayProfile.fromJson(Map<String, dynamic> json) {
    return DeviceDisplayProfile(
      id: (json['id'] as String?)?.trim() ?? '',
      label: (json['name'] as String?)?.trim() ?? '',
      width: _asInt(json['width']),
      height: _asInt(json['height']),
      isPrimary: json['is_primary'] == true,
      isCurrent: json['is_current'] == true,
    );
  }

  DeviceDisplayProfile copyWith({
    String? id,
    String? label,
    int? width,
    int? height,
    bool? isPrimary,
    bool? isCurrent,
  }) {
    return DeviceDisplayProfile(
      id: id ?? this.id,
      label: label ?? this.label,
      width: width ?? this.width,
      height: height ?? this.height,
      isPrimary: isPrimary ?? this.isPrimary,
      isCurrent: isCurrent ?? this.isCurrent,
    );
  }
}

int _asInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}
