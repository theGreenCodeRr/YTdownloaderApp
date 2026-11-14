import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yt_downloader_mobile/data/models/models.dart';
import 'package:yt_downloader_mobile/data/services/api_service.dart';

void main() {
  group('Models & Playlist Fraction Logic', () {
    test('HealthInfo parses max_download_gb=400 and flags', () {
      final info = HealthInfo.fromJson({
        'status': 'ok',
        'yt_dlp_version': '2026.11.01',
        'js_runtime': true,
        'cookies_loaded': true,
        'premium_enabled': false,
        'max_download_gb': 400,
        'active_downloads': 2,
      });
      expect(info.status, 'ok');
      expect(info.ytDlpVersion, '2026.11.01');
      expect(info.jsRuntime, isTrue);
      expect(info.cookiesLoaded, isTrue);
      expect(info.premiumEnabled, isFalse);
      expect(info.maxDownloadGb, 400);
      expect(info.activeDownloads, 2);
    });

    test('computePlaylistFractions builds halves and quarters for 100 items', () {
      final presets = computePlaylistFractions(100);
      expect(presets.length, 7);
      expect(presets[0].label, 'All (1–100)');
      expect((presets[0].start, presets[0].end), (1, 100));
      expect(presets[1].label, '1st Half (1–50)');
      expect((presets[1].start, presets[1].end), (1, 50));
      expect(presets[2].label, '2nd Half (51–100)');
      expect((presets[2].start, presets[2].end), (51, 100));
      expect(presets[3].label, 'Q1 (1–25)');
      expect((presets[3].start, presets[3].end), (1, 25));
      expect(presets[4].label, 'Q2 (26–50)');
      expect((presets[4].start, presets[4].end), (26, 50));
      expect(presets[5].label, 'Q3 (51–75)');
      expect((presets[5].start, presets[5].end), (51, 75));
      expect(presets[6].label, 'Q4 (76–100)');
      expect((presets[6].start, presets[6].end), (76, 100));
    });

    test('detectContiguousRange returns bounds for contiguous block and null on gap', () {
      final entries = List.generate(
        5,
        (i) => PlaylistEntry(index: i + 1, url: 'https://x/$i', title: 'V$i'),
      );
      expect(detectContiguousRange(entries, {1, 2, 3}), (2, 4));
      expect(detectContiguousRange(entries, {0, 2}), isNull);
    });

    test('MediaInfo parses single video and playlist JSON payloads', () {
      final single = MediaInfo.fromJson({
        'is_playlist': false,
        'title': 'Sample Video',
        'thumbnail': 'https://img.example/1.jpg',
        'duration': 125,
        'uploader': 'Channel',
        'extractor': 'YouTube',
        'formats': [
          {'id': 'best', 'ext': 'mp4', 'res': 'Best', 'note': 'Auto', 'size_str': 'Auto', 'kind': 'video'},
          {'id': 'audio-mp3', 'ext': 'mp3', 'res': 'Audio', 'note': 'MP3', 'size_str': 'Auto', 'kind': 'audio'},
        ],
      }, sourceUrl: 'https://youtu.be/abc');

      expect(single.isPlaylist, isFalse);
      expect(single.formattedDuration, '2:05');
      expect(single.formats.length, 2);

      final playlist = MediaInfo.fromJson({
        'is_playlist': true,
        'title': 'Big Playlist',
        'entries': [
          {'index': 1, 'url': 'https://youtu.be/1', 'title': 'Track 1', 'duration': 61},
          {'index': 2, 'url': 'https://youtu.be/2', 'title': 'Track 2', 'duration': 3605},
        ],
        'formats': [
          {'id': 'best', 'ext': 'mp4', 'res': 'Best', 'note': '', 'size_str': 'Auto', 'kind': 'video'},
        ],
      }, sourceUrl: 'https://youtube.com/playlist?list=123');

      expect(playlist.isPlaylist, isTrue);
      expect(playlist.entries.length, 2);
      expect(playlist.entries[1].formattedDuration, '1:00:05');
    });
  });

  group('ApiService', () {
    test('sends X-Client-ID header and parses endpoints accurately', () async {
      final capturedRequests = <http.Request>[];
      final mockClient = MockClient((request) async {
        capturedRequests.add(request);
        if (request.url.path == '/api/health') {
          return http.Response(
            jsonEncode({'status': 'ok', 'max_download_gb': 400, 'premium_enabled': true}),
            200,
          );
        }
        if (request.url.path == '/api/info') {
          return http.Response(
            jsonEncode({
              'is_playlist': false,
              'title': 'Demo',
              'formats': [
                {'id': 'best', 'ext': 'mp4', 'res': 'Best', 'note': '', 'size_str': 'Auto', 'kind': 'video'},
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/recent/clear') {
          return http.Response(jsonEncode({'cleared': 3}), 200);
        }
        return http.Response('Not found', 404);
      });

      final api = ApiService(
        client: mockClient,
        baseUrl: 'https://yt.quantumsofts.com/',
        clientId: 'client-uuid-99',
      );

      final health = await api.fetchHealth();
      expect(health.maxDownloadGb, 400);

      final info = await api.fetchMediaInfo('https://example.com/watch?v=1');
      expect(info.title, 'Demo');

      final cleared = await api.clearRecentHistory();
      expect(cleared, 3);

      expect(capturedRequests.length, 3);
      for (final req in capturedRequests) {
        expect(req.headers['X-Client-ID'], 'client-uuid-99');
        expect(req.url.toString().startsWith('https://yt.quantumsofts.com/api/'), isTrue);
      }
    });
  });
}
