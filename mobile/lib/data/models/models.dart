import 'dart:convert';
import 'dart:math' as math;

enum TransferState {
  idle,
  downloading,
  paused,
  completed,
  failed,
}

String formatDuration(num? seconds) {
  if (seconds == null || seconds <= 0) return '';
  final total = seconds.floor();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (h > 0) return '$h:${two(m)}:${two(s)}';
  return '$m:${two(s)}';
}

String formatByteCount(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var idx = 0;
  while (value >= 1024 && idx < units.length - 1) {
    value /= 1024;
    idx++;
  }
  return idx == 0
      ? '${value.toInt()} ${units[idx]}'
      : '${value.toStringAsFixed(1)} ${units[idx]}';
}

/// Server health and capability metadata from `GET /api/health`.
class HealthInfo {
  final String status;
  final String? ytDlpVersion;
  final bool jsRuntime;
  final bool cookiesLoaded;
  final bool premiumEnabled;
  final int maxDownloadGb;
  final int activeDownloads;

  const HealthInfo({
    required this.status,
    this.ytDlpVersion,
    required this.jsRuntime,
    required this.cookiesLoaded,
    required this.premiumEnabled,
    this.maxDownloadGb = 400,
    this.activeDownloads = 0,
  });

  factory HealthInfo.fromJson(Map<String, dynamic> json) {
    return HealthInfo(
      status: (json['status'] as String?) ?? 'unknown',
      ytDlpVersion: json['yt_dlp_version'] as String?,
      jsRuntime: (json['js_runtime'] as bool?) ?? false,
      cookiesLoaded: (json['cookies_loaded'] as bool?) ?? false,
      premiumEnabled: (json['premium_enabled'] as bool?) ?? true,
      maxDownloadGb: (json['max_download_gb'] as num?)?.toInt() ?? 400,
      activeDownloads: (json['active_downloads'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Downloadable format option returned by `POST /api/info`.
class VideoFormat {
  final String id;
  final String ext;
  final String resolution;
  final String note;
  final String sizeStr;
  final String kind; // 'video' | 'audio'

  const VideoFormat({
    required this.id,
    required this.ext,
    required this.resolution,
    required this.note,
    required this.sizeStr,
    required this.kind,
  });

  bool get isAudio => kind == 'audio';
  String get badgeLabel => '$resolution · ${ext.toUpperCase()}';

  factory VideoFormat.fromJson(Map<String, dynamic> json) {
    return VideoFormat(
      id: (json['id'] as String?) ?? 'best',
      ext: (json['ext'] as String?) ?? 'mp4',
      resolution: (json['res'] as String?) ?? 'Best',
      note: (json['note'] as String?) ?? '',
      sizeStr: (json['size_str'] as String?) ?? 'Auto',
      kind: (json['kind'] as String?) ?? 'video',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'ext': ext,
        'res': resolution,
        'note': note,
        'size_str': sizeStr,
        'kind': kind,
      };
}

/// A single entry in a playlist returned by `POST /api/info`.
class PlaylistEntry {
  final int index; // 1-based original playlist position
  final String url;
  final String title;
  final num? duration;
  final String thumbnail;

  const PlaylistEntry({
    required this.index,
    required this.url,
    required this.title,
    this.duration,
    this.thumbnail = '',
  });

  String get formattedDuration => formatDuration(duration);

  factory PlaylistEntry.fromJson(Map<String, dynamic> json, [int fallbackIndex = 1]) {
    return PlaylistEntry(
      index: (json['index'] as num?)?.toInt() ?? fallbackIndex,
      url: (json['url'] as String?) ?? '',
      title: (json['title'] as String?) ?? 'Video $fallbackIndex',
      duration: json['duration'] as num?,
      thumbnail: (json['thumbnail'] as String?) ?? '',
    );
  }
}

/// Extracted metadata for either a single media item or a playlist.
class MediaInfo {
  final bool isPlaylist;
  final String title;
  final String thumbnail;
  final num? duration;
  final String? uploader;
  final int? viewCount;
  final String? extractor;
  final List<VideoFormat> formats;
  final List<PlaylistEntry> entries;
  final String sourceUrl;

  const MediaInfo({
    required this.isPlaylist,
    required this.title,
    this.thumbnail = '',
    this.duration,
    this.uploader,
    this.viewCount,
    this.extractor,
    required this.formats,
    this.entries = const [],
    required this.sourceUrl,
  });

  String get formattedDuration => formatDuration(duration);

  factory MediaInfo.fromJson(Map<String, dynamic> json, {String sourceUrl = ''}) {
    final rawFormats = (json['formats'] as List<dynamic>?) ?? const [];
    final parsedFormats = rawFormats
        .whereType<Map<String, dynamic>>()
        .map(VideoFormat.fromJson)
        .toList(growable: false);

    final rawEntries = (json['entries'] as List<dynamic>?) ?? const [];
    final parsedEntries = <PlaylistEntry>[];
    for (var i = 0; i < rawEntries.length; i++) {
      final item = rawEntries[i];
      if (item is Map<String, dynamic>) {
        parsedEntries.add(PlaylistEntry.fromJson(item, i + 1));
      }
    }

    return MediaInfo(
      isPlaylist: (json['is_playlist'] as bool?) ?? false,
      title: (json['title'] as String?) ?? 'Untitled',
      thumbnail: (json['thumbnail'] as String?) ?? '',
      duration: json['duration'] as num?,
      uploader: json['uploader'] as String?,
      viewCount: (json['view_count'] as num?)?.toInt(),
      extractor: json['extractor'] as String?,
      formats: parsedFormats,
      entries: parsedEntries,
      sourceUrl: sourceUrl,
    );
  }
}

/// Top-level JSON parser safe for Flutter `compute()` isolate execution.
MediaInfo parseMediaInfoPayload(Map<String, String> payload) {
  final body = payload['body'] ?? '{}';
  final sourceUrl = payload['sourceUrl'] ?? '';
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Unexpected response format from /api/info.');
  }
  return MediaInfo.fromJson(decoded, sourceUrl: sourceUrl);
}

/// Request item sent to `POST /api/process_playlist`.
class PlaylistProcessItem {
  final String url;
  final String title;
  final int index;

  const PlaylistProcessItem({
    required this.url,
    required this.title,
    required this.index,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'index': index,
      };
}

/// Server-side download/packing task status returned by `/api/status/{taskId}` or `/api/recent`.
class TaskStatusInfo {
  final String taskId;
  final String status; // processing | completed | failed | cancelled | expired
  final String title;
  final String kind; // video | playlist
  final String progress;
  final double percent;
  final String? error;
  final String? note;
  final String? format;
  final String? thumbnail;
  final double timestamp;

  const TaskStatusInfo({
    required this.taskId,
    required this.status,
    required this.title,
    this.kind = 'video',
    this.progress = '',
    this.percent = 0.0,
    this.error,
    this.note,
    this.format,
    this.thumbnail,
    this.timestamp = 0.0,
  });

  bool get isActive => status == 'processing' || status == 'queued';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isCancelled => status == 'cancelled';
  bool get isExpired => status == 'expired';

  TaskStatusInfo copyWith({
    String? status,
    String? title,
    String? progress,
    double? percent,
    String? error,
    String? note,
  }) {
    return TaskStatusInfo(
      taskId: taskId,
      status: status ?? this.status,
      title: title ?? this.title,
      kind: kind,
      progress: progress ?? this.progress,
      percent: percent ?? this.percent,
      error: error ?? this.error,
      note: note ?? this.note,
      format: format,
      thumbnail: thumbnail,
      timestamp: timestamp,
    );
  }

  factory TaskStatusInfo.fromRecentJson(Map<String, dynamic> json) {
    final rawStatus = (json['status'] as String?) ?? 'processing';
    return TaskStatusInfo(
      taskId: (json['task_id'] as String?) ?? '',
      status: rawStatus,
      title: (json['title'] as String?) ?? 'Download',
      kind: (json['kind'] as String?) ?? 'video',
      progress: rawStatus == 'completed'
          ? 'Ready on server'
          : (rawStatus == 'processing' ? 'Processing…' : rawStatus),
      percent: rawStatus == 'completed' ? 100.0 : 0.0,
      error: json['error'] as String?,
      note: json['note'] as String?,
      format: json['format'] as String?,
      thumbnail: json['thumbnail'] as String?,
      timestamp: (json['timestamp'] as num?)?.toDouble() ?? 0.0,
    );
  }

  factory TaskStatusInfo.fromStatusJson(
    Map<String, dynamic> json, {
    TaskStatusInfo? existing,
  }) {
    final rawStatus = (json['status'] as String?) ?? existing?.status ?? 'processing';
    final percentVal = (json['percent'] as num?)?.toDouble();
    return TaskStatusInfo(
      taskId: (json['task_id'] as String?) ?? existing?.taskId ?? '',
      status: rawStatus,
      title: existing?.title ?? 'Download',
      kind: existing?.kind ?? 'video',
      progress: (json['progress'] as String?) ?? existing?.progress ?? '',
      percent: percentVal ?? (rawStatus == 'completed' ? 100.0 : (existing?.percent ?? 0.0)),
      error: json['error'] as String?,
      note: existing?.note,
      format: existing?.format,
      thumbnail: existing?.thumbnail,
      timestamp: existing?.timestamp ?? DateTime.now().millisecondsSinceEpoch / 1000.0,
    );
  }
}

/// Client-side transfer & local file record (persisted across app restarts).
class LocalTransferItem {
  final String taskId;
  final String title;
  final String filename;
  final String localPath;
  final int receivedBytes;
  final int totalBytes;
  final TransferState state;
  final String? error;
  final DateTime? completedAt;

  const LocalTransferItem({
    required this.taskId,
    required this.title,
    required this.filename,
    required this.localPath,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.state = TransferState.idle,
    this.error,
    this.completedAt,
  });

  double? get progressRatio {
    if (totalBytes <= 0) return state == TransferState.completed ? 1.0 : null;
    return math.min(1.0, math.max(0.0, receivedBytes / totalBytes));
  }

  LocalTransferItem copyWith({
    String? title,
    String? filename,
    String? localPath,
    int? receivedBytes,
    int? totalBytes,
    TransferState? state,
    String? error,
    DateTime? completedAt,
  }) {
    return LocalTransferItem(
      taskId: taskId,
      title: title ?? this.title,
      filename: filename ?? this.filename,
      localPath: localPath ?? this.localPath,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      state: state ?? this.state,
      error: error,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  factory LocalTransferItem.fromJson(Map<String, dynamic> json) {
    final stateName = (json['state'] as String?) ?? 'idle';
    final state = TransferState.values.firstWhere(
      (s) => s.name == stateName,
      orElse: () => TransferState.idle,
    );
    final completedIso = json['completedAt'] as String?;
    return LocalTransferItem(
      taskId: (json['taskId'] as String?) ?? '',
      title: (json['title'] as String?) ?? 'Download',
      filename: (json['filename'] as String?) ?? '',
      localPath: (json['localPath'] as String?) ?? '',
      receivedBytes: (json['receivedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      state: state,
      error: json['error'] as String?,
      completedAt: completedIso != null ? DateTime.tryParse(completedIso) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'title': title,
        'filename': filename,
        'localPath': localPath,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'state': state.name,
        'error': error,
        'completedAt': completedAt?.toIso8601String(),
      };
}

/// Quick-split preset chip definition for large playlists (All, 1st Half, 2nd Half, Q1–Q4).
class PlaylistRangePreset {
  final String label;
  final int start; // 1-based inclusive
  final int end; // 1-based inclusive

  const PlaylistRangePreset({
    required this.label,
    required this.start,
    required this.end,
  });
}

/// Generates All, 1st/2nd Half, and Q1–Q4 presets matching the web UI rules.
List<PlaylistRangePreset> computePlaylistFractions(int total) {
  if (total < 2) return const [];
  final presets = <PlaylistRangePreset>[
    PlaylistRangePreset(label: 'All (1–$total)', start: 1, end: total),
  ];
  final mid = (total / 2).ceil();
  presets.add(PlaylistRangePreset(label: '1st Half (1–$mid)', start: 1, end: mid));
  presets.add(PlaylistRangePreset(label: '2nd Half (${mid + 1}–$total)', start: mid + 1, end: total));

  if (total >= 4) {
    for (var k = 0; k < 4; k++) {
      final qStart = (k * total) ~/ 4 + 1;
      final qEnd = ((k + 1) * total) ~/ 4;
      if (qEnd >= qStart) {
        presets.add(PlaylistRangePreset(label: 'Q${k + 1} ($qStart–$qEnd)', start: qStart, end: qEnd));
      }
    }
  }
  return presets;
}

/// Returns `(startIndex, endIndex)` (1-based) when [selectedListIndices] forms a
/// contiguous non-empty block inside [entries], or `null` otherwise.
(int start, int end)? detectContiguousRange(
  List<PlaylistEntry> entries,
  Set<int> selectedListIndices,
) {
  if (entries.isEmpty || selectedListIndices.isEmpty) return null;
  final sorted = selectedListIndices.toList()..sort();
  if (sorted.first < 0 || sorted.last >= entries.length) return null;
  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i] != sorted[i - 1] + 1) return null;
  }
  return (entries[sorted.first].index, entries[sorted.last].index);
}
