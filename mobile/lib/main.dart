import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'data/services/api_service.dart';
import 'data/services/file_transfer_service.dart';
import 'data/services/preferences_service.dart';
import 'ui/core/app_theme.dart';
import 'ui/view_models/downloader_view_model.dart';
import 'ui/views/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const YTDownloaderApp());
}

class YTDownloaderApp extends StatefulWidget {
  const YTDownloaderApp({
    super.key,
    this.viewModel,
  });

  final DownloaderViewModel? viewModel;

  @override
  State<YTDownloaderApp> createState() => _YTDownloaderAppState();
}

class _YTDownloaderAppState extends State<YTDownloaderApp> {
  late final DownloaderViewModel _viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    if (widget.viewModel != null) {
      _viewModel = widget.viewModel!;
      _ownsViewModel = false;
    } else {
      _ownsViewModel = true;
      _viewModel = DownloaderViewModel(
        apiService: ApiService(),
        transferService: FileTransferService(),
        preferencesService: PreferencesService(),
      );
      unawaited(_viewModel.initialize());
    }
  }

  @override
  void dispose() {
    if (_ownsViewModel) {
      _viewModel.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        return MaterialApp(
          title: 'Simple Downloader',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: _viewModel.themeMode,
          home: HomeShell(viewModel: _viewModel),
        );
      },
    );
  }
}
