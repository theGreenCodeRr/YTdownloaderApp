import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

typedef DownloadDirectoryProvider = Future<Directory> Function();

class TransferPausedException implements Exception {
  const TransferPausedException();
}

/// Streams finished files from `/api/download/{taskId}` to device storage with
/// HTTP `Range` (`206 Partial Content`) resume support and cooperative pausing.
class FileTransferService {
  FileTransferService({
    http.Client? client,
    DownloadDirectoryProvider? directoryProvider,
  })  : _client = client ?? http.Client(),
        _directoryProvider = directoryProvider ?? _defaultDownloadDirectory;

  final http.Client _client;
  final DownloadDirectoryProvider _directoryProvider;
  final Set<String> _pausedTaskIds = <String>{};

  static Future<Directory> _defaultDownloadDirectory() async {
    final base = Platform.isAndroid
        ? (await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory())
        : await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'downloads'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> getDownloadsDirectory() async {
    final dir = await _directoryProvider();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static File partFileForTask(Directory dir, String taskId) {
    final safeId = taskId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return File(p.join(dir.path, '$safeId.part'));
  }

  static String sanitizeLocalFilename(String raw) {
    var name = p.basename(raw.trim());
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    if (name.isEmpty || name == '.' || name == '..') {
      return 'download.mp4';
    }
    return name;
  }

  static String? parseFilenameFromContentDisposition(String? headerValue) {
    if (headerValue == null || headerValue.isEmpty) return null;
    // RFC 5987: filename*=UTF-8''encoded_name
    final starMatch = RegExp(
      r"filename\*\s*=\s*([^']*)'[^']*'([^;\s]+)",
      caseSensitive: false,
    ).firstMatch(headerValue);
    if (starMatch != null) {
      try {
        return Uri.decodeComponent(starMatch.group(2)!);
      } catch (_) {}
    }
    // Fallback: filename="name" or filename=name
    final plainMatch = RegExp(
      r'filename\s*=\s*"([^"]+)"|filename\s*=\s*([^;\s]+)',
      caseSensitive: false,
    ).firstMatch(headerValue);
    if (plainMatch != null) {
      return plainMatch.group(1) ?? plainMatch.group(2);
    }
    return null;
  }

  static int? parseTotalFromContentRange(String? headerValue) {
    if (headerValue == null) return null;
    final slashIdx = headerValue.lastIndexOf('/');
    if (slashIdx == -1) return null;
    return int.tryParse(headerValue.substring(slashIdx + 1).trim());
  }

  void pauseTransfer(String taskId) {
    _pausedTaskIds.add(taskId);
  }

  Future<File> _uniqueDestinationFile(Directory dir, String preferredName) async {
    final clean = sanitizeLocalFilename(preferredName);
    final base = p.basenameWithoutExtension(clean);
    final ext = p.extension(clean);
    var candidate = File(p.join(dir.path, clean));
    var counter = 1;
    while (await candidate.exists()) {
      candidate = File(p.join(dir.path, '$base ($counter)$ext'));
      counter++;
    }
    return candidate;
  }

  /// Downloads [uri] to disk, resuming from any existing `.part` file via `Range`.
  /// Emits throttled progress updates via [onProgress].
  Future<LocalTransferItem> downloadWithResume({
    required String taskId,
    required Uri uri,
    required String title,
    required String clientId,
    String? fallbackFilename,
    void Function(LocalTransferItem progress)? onProgress,
  }) async {
    _pausedTaskIds.remove(taskId);
    final dir = await getDownloadsDirectory();
    final partFile = partFileForTask(dir, taskId);
    var existingBytes = await partFile.exists() ? await partFile.length() : 0;

    final request = http.Request('GET', uri);
    request.headers['X-Client-ID'] = clientId;
    if (existingBytes > 0) {
      request.headers['Range'] = 'bytes=$existingBytes-';
    }

    final streamed = await _client.send(request);
    final statusCode = streamed.statusCode;

    if (statusCode == 410) {
      throw const HttpException('File has expired on the server. Please process it again.');
    }
    if (statusCode != 200 && statusCode != 206) {
      throw HttpException('Download failed with HTTP $statusCode.');
    }

    final isPartial = statusCode == 206;
    if (!isPartial && existingBytes > 0) {
      // Server ignored Range and restarted from byte 0.
      existingBytes = 0;
    }

    final headerFilename = parseFilenameFromContentDisposition(
      streamed.headers['content-disposition'],
    );
    final finalName = sanitizeLocalFilename(
      headerFilename ?? fallbackFilename ?? '$title.mp4',
    );

    final contentLength = streamed.contentLength ?? 0;
    final totalFromRange = parseTotalFromContentRange(streamed.headers['content-range']);
    final totalBytes = totalFromRange ?? (existingBytes + contentLength);

    var received = existingBytes;
    onProgress?.call(LocalTransferItem(
      taskId: taskId,
      title: title,
      filename: finalName,
      localPath: partFile.path,
      receivedBytes: received,
      totalBytes: totalBytes,
      state: TransferState.downloading,
    ));

    final sink = partFile.openWrite(
      mode: isPartial ? FileMode.append : FileMode.write,
    );

    var lastReport = DateTime.now();
    try {
      await for (final chunk in streamed.stream) {
        if (_pausedTaskIds.remove(taskId)) {
          await sink.flush();
          await sink.close();
          throw const TransferPausedException();
        }
        sink.add(chunk);
        received += chunk.length;

        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds >= 150) {
          lastReport = now;
          onProgress?.call(LocalTransferItem(
            taskId: taskId,
            title: title,
            filename: finalName,
            localPath: partFile.path,
            receivedBytes: received,
            totalBytes: totalBytes,
            state: TransferState.downloading,
          ));
        }
      }
      await sink.flush();
      await sink.close();
    } on TransferPausedException {
      return LocalTransferItem(
        taskId: taskId,
        title: title,
        filename: finalName,
        localPath: partFile.path,
        receivedBytes: received,
        totalBytes: totalBytes,
        state: TransferState.paused,
      );
    } catch (e) {
      await sink.close();
      rethrow;
    }

    final destFile = await _uniqueDestinationFile(dir, finalName);
    await partFile.rename(destFile.path);

    final doneItem = LocalTransferItem(
      taskId: taskId,
      title: title,
      filename: p.basename(destFile.path),
      localPath: destFile.path,
      receivedBytes: received,
      totalBytes: totalBytes > 0 ? totalBytes : received,
      state: TransferState.completed,
      completedAt: DateTime.now(),
    );
    onProgress?.call(doneItem);
    return doneItem;
  }

  Future<int> computeStorageUsedBytes() async {
    final dir = await getDownloadsDirectory();
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<void> deleteAllLocalFiles() async {
    final dir = await getDownloadsDirectory();
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        await entity.delete();
      }
    }
  }
}
