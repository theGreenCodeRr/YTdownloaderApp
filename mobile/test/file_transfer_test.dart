import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yt_downloader_mobile/data/models/models.dart';
import 'package:yt_downloader_mobile/data/services/file_transfer_service.dart';

void main() {
  test('FileTransferService sends Range header for .part file and appends 206 bytes', () async {
    final tempDir = await Directory.systemTemp.createTemp('ytd_transfer_test_');
    addTearDown(() => tempDir.delete(recursive: true));

    const taskId = 'task-123';
    final fullBytes = List<int>.generate(30, (i) => i);
    final partFile = FileTransferService.partFileForTask(tempDir, taskId);
    await partFile.writeAsBytes(fullBytes.sublist(0, 10));

    String? receivedRangeHeader;
    String? receivedClientId;

    final mockClient = MockClient.streaming((request, bodyStream) async {
      receivedRangeHeader = request.headers['Range'];
      receivedClientId = request.headers['X-Client-ID'];
      final tail = fullBytes.sublist(10);
      return http.StreamedResponse(
        Stream<List<int>>.value(tail),
        206,
        contentLength: tail.length,
        headers: {
          'content-range': 'bytes 10-29/30',
          'content-disposition': "attachment; filename*=UTF-8''%E3%83%86%E3%82%B9%E3%83%88.mp4",
        },
      );
    });

    final service = FileTransferService(
      client: mockClient,
      directoryProvider: () async => tempDir,
    );

    final result = await service.downloadWithResume(
      taskId: taskId,
      uri: Uri.parse('https://yt.quantumsofts.com/api/download/$taskId'),
      title: 'テスト',
      clientId: 'mobile-client-1',
    );

    expect(receivedRangeHeader, 'bytes=10-');
    expect(receivedClientId, 'mobile-client-1');
    expect(result.state, TransferState.completed);
    expect(result.filename, 'テスト.mp4');
    expect(result.receivedBytes, 30);
    expect(result.totalBytes, 30);

    final savedFile = File(result.localPath);
    expect(await savedFile.exists(), isTrue);
    expect(await savedFile.readAsBytes(), fullBytes);
    expect(await partFile.exists(), isFalse);
  });
}
