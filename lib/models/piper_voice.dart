/// Metadata for a single Piper voice returned by the backend.
class PiperVoice {
  PiperVoice({
    required this.key,
    required this.name,
    required this.quality,
    required this.language,
    required this.filePaths,
    this.numSpeakers = 1,
    this.onnxBytes = 0,
    this.jsonBytes = 0,
  });

  /// Unique voice identifier, e.g. "pt_BR-cadu-medium".
  final String key;

  /// Speaker name, e.g. "cadu".
  final String name;

  /// "low", "medium", "high".
  final String quality;

  final PiperVoiceLanguage language;

  /// All file paths from the server (keys of the `files` map).
  final List<String> filePaths;

  final int numSpeakers;
  final int onnxBytes;
  final int jsonBytes;

  /// Only .onnx and .onnx.json paths (what we actually need to download).
  List<String> get downloadPaths => filePaths
      .where((p) => p.endsWith('.onnx') || p.endsWith('.onnx.json'))
      .toList();

  /// Total download size in bytes.
  int get totalBytes => onnxBytes + jsonBytes;

  /// Estimated display name: "Speaker — quality".
  String get displayName {
    final rawSpeaker =
        name.isNotEmpty ? name : key.split('-').elementAtOrNull(1);
    var spk =
        (rawSpeaker != null && rawSpeaker.isNotEmpty) ? rawSpeaker : key.trim();
    if (spk.isEmpty) return '$key · $quality'.trim();
    final title =
        spk.length == 1 ? spk.toUpperCase() : '${spk[0].toUpperCase()}${spk.substring(1)}';
    return '$title — $quality';
  }

  factory PiperVoice.fromJson(Map<String, dynamic> json) {
    final lang = json['language'] as Map<String, dynamic>? ?? const {};
    final filesRaw = json['files'] as Map<String, dynamic>? ?? const {};

    return PiperVoice(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      quality: json['quality'] as String? ?? 'medium',
      language: PiperVoiceLanguage.fromJson(lang),
      filePaths: filesRaw.keys.toList(),
      numSpeakers: (json['num_speakers'] as num?)?.toInt() ?? 1,
      onnxBytes: (json['onnx_bytes'] as num?)?.toInt() ?? 0,
      jsonBytes: (json['json_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class PiperVoiceLanguage {
  const PiperVoiceLanguage({
    required this.code,
    required this.family,
    required this.region,
  });

  final String code;
  final String family;
  final String region;

  factory PiperVoiceLanguage.fromJson(Map<String, dynamic> json) {
    return PiperVoiceLanguage(
      code: json['code'] as String? ?? '',
      family: json['family'] as String? ?? '',
      region: json['region'] as String? ?? '',
    );
  }
}
