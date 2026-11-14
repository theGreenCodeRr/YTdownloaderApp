import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yt_downloader_mobile/data/services/api_service.dart';
import 'package:yt_downloader_mobile/data/services/file_transfer_service.dart';
import 'package:yt_downloader_mobile/data/services/preferences_service.dart';
import 'package:yt_downloader_mobile/main.dart';
import 'package:yt_downloader_mobile/ui/view_models/downloader_view_model.dart';

(DownloaderViewModel, Directory) _buildTestViewModel() {
  final mockClient = MockClient((request) async {
    if (request.url.path == '/api/health') {
      return http.Response(
        jsonEncode({'status': 'ok', 'max_download_gb': 400, 'premium_enabled': true}),
        200,
      );
    }
    if (request.url.path == '/api/recent') {
      return http.Response(jsonEncode({'recent': <dynamic>[]}), 200);
    }
    if (request.url.path == '/api/info') {
      return http.Response(
        jsonEncode({
          'is_playlist': true,
          'title': 'Large Course Playlist',
          'entries': List.generate(
            8,
            (i) => {
              'index': i + 1,
              'url': 'https://youtu.be/v$i',
              'title': 'Lesson ${i + 1}',
              'duration': 90,
            },
          ),
          'formats': [
            {'id': 'best', 'ext': 'mp4', 'res': 'Best', 'note': 'Best', 'size_str': 'Auto', 'kind': 'video'},
            {'id': 'audio-mp3', 'ext': 'mp3', 'res': 'Audio', 'note': 'MP3', 'size_str': 'Auto', 'kind': 'audio'},
          ],
        }),
        200,
      );
    }
    return http.Response('{}', 200);
  });

  final tempDir = Directory.systemTemp.createTempSync('ytd_widget_test_');
  final vm = DownloaderViewModel(
    apiService: ApiService(client: mockClient),
    transferService: FileTransferService(
      client: mockClient,
      directoryProvider: () async => tempDir,
    ),
    preferencesService: PreferencesService(),
    enableShareChannel: false,
  );
  return (vm, tempDir);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Phone layout renders NavigationBar and playlist fraction/range splitting', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (vm, tempDir) = _buildTestViewModel();
    addTearDown(() {
      vm.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    await tester.runAsync(() => vm.initialize());
    await tester.pumpWidget(YTDownloaderApp(viewModel: vm));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Max 400 GB'), findsAtLeastNWidgets(1));

    await tester.enterText(
      find.byKey(const Key('url_input_field')),
      'https://youtube.com/playlist?list=PLTEST',
    );
    await tester.tap(find.byKey(const Key('fetch_info_button')));
    await tester.pumpAndSettle();

    expect(find.text('Large Course Playlist'), findsOneWidget);
    expect(find.text('8 of 8 selected'), findsOneWidget);

    final firstHalfChip = find.text('1st Half (1–4)');
    await Scrollable.ensureVisible(
      tester.element(firstHalfChip),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    expect(firstHalfChip, findsOneWidget);
    expect(find.text('Q4 (7–8)'), findsOneWidget);

    await tester.tap(firstHalfChip);
    await tester.pumpAndSettle();
    expect(find.text('4 of 8 selected'), findsOneWidget);
    expect(find.text('Download 4 (#1–4)'), findsOneWidget);

    final fromField = find.byKey(const Key('range_from_field'));
    final applyBtn = find.byKey(const Key('range_apply_button'));
    await Scrollable.ensureVisible(
      tester.element(applyBtn),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.enterText(fromField, '6');
    await tester.enterText(find.byKey(const Key('range_to_field')), '8');
    await Scrollable.ensureVisible(
      tester.element(applyBtn),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(applyBtn);
    await tester.pumpAndSettle();
    expect(find.text('3 of 8 selected'), findsOneWidget);
    expect(find.text('Download 3 (#6–8)'), findsOneWidget);
  });

  testWidgets('Tablet layout renders NavigationRail and simultaneous two-pane split workspace', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final (vm, tempDir) = _buildTestViewModel();
    addTearDown(() {
      vm.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    await tester.runAsync(() => vm.initialize());
    await tester.pumpWidget(YTDownloaderApp(viewModel: vm));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(const Key('tablet_split_workspace')), findsOneWidget);
    expect(find.byKey(const Key('url_input_field')), findsOneWidget);
    expect(find.text('Transfers & History'), findsOneWidget);
  });
}
