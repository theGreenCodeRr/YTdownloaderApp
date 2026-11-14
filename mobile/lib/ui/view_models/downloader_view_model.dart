import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models/models.dart';
import '../../data/services/api_service.dart';
import '../../data/services/file_transfer_service.dart';
import '../../data/services/preferences_service.dart';

/// Main application ViewModel coordinating extraction, server queue polling,
/// playlist fraction selection, resumable device transfers, and settings.
class DownloaderViewModel extends ChangeNotifier {
  DownloaderViewModel({
    required ApiService apiService,
    required FileTransferService transferService,
    required PreferencesService preferencesService,
    this.enableShareChannel = true,
  })  : _api = apiService,
        _transfers = transferService,
        _prefs = preferencesService;

  final ApiService _api;
  final FileTransferService _transfers;
  final PreferencesService _prefs;
  final bool enableShareChannel;

  static const MethodChannel _shareChannel = MethodChannel(
    'com.quantumsofts.ytdownloader/share_intent',
  );

  bool _disposed = false;
  Timer? _pollTimer;

  // Settings & server capabilities
  String _clientId = 'mobile';
  String _baseUrl = AppConfig.defaultBaseUrl;
  String _premiumPassword = '';
  bool _autoDownloadToDevice = true;
  ThemeMode _themeMode = ThemeMode.system;
  HealthInfo? _health;
  bool _isCheckingHealth = false;
  String? _healthError;
  int _localStorageBytes = 0;

  // Extraction state
  String _urlInput = '';
  bool _isLoadingInfo = false;
  String? _infoError;
  MediaInfo? _mediaInfo;
  String? _actionMessage;

  // Single-video selection
  bool _showAudioFormats = false;
  String _selectedSingleFormatId = 'best';

  // Playlist selection
  final Set<int> _selectedIndices = <int>{};
  String _playlistSearchQuery = '';
  String _selectedPlaylistFormatId = 'best';

  // Tasks & local transfers
  final Map<String, TaskStatusInfo> _serverTasks = <String, TaskStatusInfo>{};
  final Map<String, LocalTransferItem> _localTransfers = <String, LocalTransferItem>{};
  bool _isSubmittingDownload = false;
  String? _submitError;

  // Getters
  String get clientId => _clientId;
  String get baseUrl => _baseUrl;
  String get premiumPassword => _premiumPassword;
  bool get autoDownloadToDevice => _autoDownloadToDevice;
  ThemeMode get themeMode => _themeMode;
  HealthInfo? get health => _health;
  bool get isCheckingHealth => _isCheckingHealth;
  String? get healthError => _healthError;
  int get maxDownloadGb => _health?.maxDownloadGb ?? 400;
  bool get premiumEnabled => _health?.premiumEnabled ?? true;
  int get localStorageBytes => _localStorageBytes;

  String get urlInput => _urlInput;
  bool get isLoadingInfo => _isLoadingInfo;
  String? get infoError => _infoError;
  MediaInfo? get mediaInfo => _mediaInfo;
  String? get actionMessage => _actionMessage;

  bool get showAudioFormats => _showAudioFormats;
  String get selectedSingleFormatId => _selectedSingleFormatId;

  Set<int> get selectedIndices => Set.unmodifiable(_selectedIndices);
  int get selectedCount => _selectedIndices.length;
  String get playlistSearchQuery => _playlistSearchQuery;
  String get selectedPlaylistFormatId => _selectedPlaylistFormatId;

  bool get isSubmittingDownload => _isSubmittingDownload;
  String? get submitError => _submitError;

  List<TaskStatusInfo> get tasksSorted {
    final list = _serverTasks.values.toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  int get activeWorkCount {
    var count = 0;
    for (final task in _serverTasks.values) {
      if (task.isActive) count++;
    }
    for (final local in _localTransfers.values) {
      if (local.state == TransferState.downloading) count++;
    }
    return count;
  }

  LocalTransferItem? transferForTask(String taskId) => _localTransfers[taskId];

  List<PlaylistRangePreset> get playlistFractions {
    final info = _mediaInfo;
    if (info == null || !info.isPlaylist) return const [];
    return computePlaylistFractions(info.entries.length);
  }

  (int start, int end)? get contiguousSelectionRange {
    final info = _mediaInfo;
    if (info == null || !info.isPlaylist) return null;
    if (_selectedIndices.length == info.entries.length) return null;
    return detectContiguousRange(info.entries, _selectedIndices);
  }

  List<int> get filteredPlaylistIndices {
    final info = _mediaInfo;
    if (info == null || !info.isPlaylist) return const [];
    final q = _playlistSearchQuery.trim().toLowerCase();
    final indices = <int>[];
    for (var i = 0; i < info.entries.length; i++) {
      final entry = info.entries[i];
      if (q.isEmpty ||
          entry.title.toLowerCase().contains(q) ||
          '${entry.index}'.contains(q)) {
        indices.add(i);
      }
    }
    return indices;
  }

  List<VideoFormat> get visibleSingleFormats {
    final info = _mediaInfo;
    if (info == null || info.isPlaylist) return const [];
    return info.formats
        .where((f) => _showAudioFormats ? f.isAudio : !f.isAudio)
        .toList(growable: false);
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    _clientId = await _prefs.getOrCreateClientId();
    _baseUrl = await _prefs.getBaseUrl();
    _premiumPassword = await _prefs.getPremiumPassword();
    _autoDownloadToDevice = await _prefs.getAutoDownload();
    _themeMode = await _prefs.getThemeMode();
    _api.configure(baseUrl: _baseUrl, clientId: _clientId);

    final savedTransfers = await _prefs.getLocalTransfers();
    for (final t in savedTransfers) {
      // Any transfer interrupted mid-stream on last kill becomes paused so user can resume.
      final adjusted = t.state == TransferState.downloading
          ? t.copyWith(state: TransferState.paused)
          : t;
      _localTransfers[adjusted.taskId] = adjusted;
    }
    await _refreshStorageUsage();
    _safeNotify();

    if (enableShareChannel) {
      _setupShareIntentListener();
    }

    await Future.wait([
      refreshHealth(silent: true),
      refreshRecentTasks(),
    ]);
  }

  void _setupShareIntentListener() {
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedText' && call.arguments is String) {
        handleSharedText(call.arguments as String);
      }
    });

    () async {
      try {
        final initial = await _shareChannel.invokeMethod<String>('getInitialSharedText');
        if (initial != null && initial.isNotEmpty) {
          handleSharedText(initial);
        }
      } catch (_) {
        // Ignore on platforms/tests where the Android MethodChannel is absent.
      }
    }();
  }

  void handleSharedText(String rawText) {
    final match = RegExp(r'https?://\S+').firstMatch(rawText);
    final extracted = (match?.group(0) ?? rawText).trim();
    if (extracted.isEmpty) return;
    _urlInput = extracted;
    _safeNotify();
    if (extracted.startsWith('http://') || extracted.startsWith('https://')) {
      unawaited(fetchInfo(extracted));
    }
  }

  void setUrlInput(String value) {
    _urlInput = value;
    if (_infoError != null) _infoError = null;
    _safeNotify();
  }

  void clearUrlInput() {
    _urlInput = '';
    _infoError = null;
    _mediaInfo = null;
    _selectedIndices.clear();
    _playlistSearchQuery = '';
    _safeNotify();
  }

  void consumeActionMessage() {
    _actionMessage = null;
    _safeNotify();
  }

  Future<void> refreshHealth({bool silent = false}) async {
    if (!silent) {
      _isCheckingHealth = true;
      _healthError = null;
      _safeNotify();
    }
    try {
      _health = await _api.fetchHealth();
      _healthError = null;
    } catch (e) {
      _healthError = e.toString();
    } finally {
      _isCheckingHealth = false;
      _safeNotify();
    }
  }

  Future<void> refreshRecentTasks() async {
    try {
      final recent = await _api.fetchRecentTasks();
      var hasActive = false;
      for (final item in recent) {
        final existing = _serverTasks[item.taskId];
        // Keep richer live status if currently polling, otherwise apply recent.
        if (existing != null && existing.isActive && item.isActive) {
          hasActive = true;
          continue;
        }
        _serverTasks[item.taskId] = item;
        if (item.isActive) hasActive = true;
      }
      if (hasActive) {
        _ensurePolling();
      }
      _safeNotify();
    } catch (_) {
      // Non-fatal on offline startup
    }
  }

  Future<void> fetchInfo([String? explicitUrl]) async {
    final target = (explicitUrl ?? _urlInput).trim();
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      _infoError = 'Please enter a valid URL starting with http:// or https://';
      _safeNotify();
      return;
    }

    _urlInput = target;
    _isLoadingInfo = true;
    _infoError = null;
    _submitError = null;
    _safeNotify();

    try {
      final info = await _api.fetchMediaInfo(target);
      _mediaInfo = info;
      _showAudioFormats = false;
      if (info.isPlaylist) {
        _selectedIndices
          ..clear()
          ..addAll(List<int>.generate(info.entries.length, (i) => i));
        _playlistSearchQuery = '';
        _selectedPlaylistFormatId =
            info.formats.isNotEmpty ? info.formats.first.id : 'best';
      } else {
        _selectedSingleFormatId =
            info.formats.isNotEmpty ? info.formats.first.id : 'best';
      }
    } catch (e) {
      _infoError = e.toString();
    } finally {
      _isLoadingInfo = false;
      _safeNotify();
    }
  }

  void setSingleMediaTab(bool audioOnly) {
    if (_showAudioFormats == audioOnly) return;
    _showAudioFormats = audioOnly;
    final list = visibleSingleFormats;
    if (list.isNotEmpty && !list.any((f) => f.id == _selectedSingleFormatId)) {
      _selectedSingleFormatId = list.first.id;
    }
    _safeNotify();
  }

  void selectSingleFormat(String formatId) {
    _selectedSingleFormatId = formatId;
    _safeNotify();
  }

  void setPlaylistSearchQuery(String query) {
    _playlistSearchQuery = query;
    _safeNotify();
  }

  void selectPlaylistFormat(String formatId) {
    _selectedPlaylistFormatId = formatId;
    _safeNotify();
  }

  void togglePlaylistIndex(int listIndex) {
    if (_selectedIndices.contains(listIndex)) {
      _selectedIndices.remove(listIndex);
    } else {
      _selectedIndices.add(listIndex);
    }
    _safeNotify();
  }

  void selectAllPlaylistEntries() {
    final info = _mediaInfo;
    if (info == null || !info.isPlaylist) return;
    _selectedIndices
      ..clear()
      ..addAll(List<int>.generate(info.entries.length, (i) => i));
    _safeNotify();
  }

  void deselectAllPlaylistEntries() {
    _selectedIndices.clear();
    _safeNotify();
  }

  void selectPlaylistRange(int startOneBased, int endOneBased) {
    final info = _mediaInfo;
    if (info == null || !info.isPlaylist || info.entries.isEmpty) return;
    final total = info.entries.length;
    var s = startOneBased.clamp(1, total);
    var e = endOneBased.clamp(1, total);
    if (e < s) {
      final tmp = s;
      s = e;
      e = tmp;
    }
    _selectedIndices.clear();
    for (var i = 0; i < info.entries.length; i++) {
      final pos = info.entries[i].index;
      if (pos >= s && pos <= e) {
        _selectedIndices.add(i);
      }
    }
    _safeNotify();
  }

  Future<MediaInfo> inspectPlaylistEntry(PlaylistEntry entry) async {
    return _api.fetchMediaInfo(entry.url);
  }

  Future<bool> startSingleDownload({
    String? overrideUrl,
    String? overrideFormatId,
    String? overrideTitle,
    String? overrideThumbnail,
  }) async {
    final info = _mediaInfo;
    final url = overrideUrl ?? info?.sourceUrl ?? _urlInput.trim();
    final formatId = overrideFormatId ?? _selectedSingleFormatId;
    final title = overrideTitle ?? info?.title ?? 'video';
    final thumbnail = overrideThumbnail ?? info?.thumbnail ?? '';

    if (url.isEmpty || formatId.isEmpty) return false;

    _isSubmittingDownload = true;
    _submitError = null;
    _safeNotify();

    try {
      final taskId = await _api.startSingleProcess(
        url: url,
        formatId: formatId,
        title: title,
        thumbnail: thumbnail,
      );
      _serverTasks[taskId] = TaskStatusInfo(
        taskId: taskId,
        status: 'processing',
        title: title,
        kind: 'video',
        progress: 'Queued on server…',
        percent: 0.0,
        format: formatId,
        thumbnail: thumbnail,
        timestamp: DateTime.now().millisecondsSinceEpoch / 1000.0,
      );
      _actionMessage = 'Download queued on server';
      _ensurePolling();
      return true;
    } catch (e) {
      _submitError = e.toString();
      return false;
    } finally {
      _isSubmittingDownload = false;
      _safeNotify();
    }
  }

  Future<bool> startPlaylistDownload(String password) async {
    final info = _mediaInfo;
    if (info == null || !info.isPlaylist || _selectedIndices.isEmpty) {
      return false;
    }
    final cleanPassword = password.trim();
    if (cleanPassword.isEmpty) {
      _submitError = 'Please enter the premium password for playlist ZIP downloads.';
      _safeNotify();
      return false;
    }

    await _prefs.setPremiumPassword(cleanPassword);
    _premiumPassword = cleanPassword;

    final allSelected = _selectedIndices.length == info.entries.length;
    final range = !allSelected ? detectContiguousRange(info.entries, _selectedIndices) : null;
    final sorted = _selectedIndices.toList()..sort();
    final items = allSelected
        ? null
        : sorted
            .map((i) => PlaylistProcessItem(
                  url: info.entries[i].url,
                  title: info.entries[i].title,
                  index: info.entries[i].index,
                ))
            .toList(growable: false);

    final baseTitle = info.title.isNotEmpty ? info.title : 'playlist';
    final displayTitle =
        range != null ? '$baseTitle [#${range.$1}-${range.$2}]' : baseTitle;

    _isSubmittingDownload = true;
    _submitError = null;
    _safeNotify();

    try {
      final taskId = await _api.startPlaylistProcess(
        url: info.sourceUrl,
        formatId: _selectedPlaylistFormatId,
        title: displayTitle,
        password: cleanPassword,
        items: items,
      );
      final label = allSelected
          ? displayTitle
          : '$displayTitle (${sorted.length} selected)';
      _serverTasks[taskId] = TaskStatusInfo(
        taskId: taskId,
        status: 'processing',
        title: label,
        kind: 'playlist',
        progress: 'Starting playlist job…',
        percent: 0.0,
        format: _selectedPlaylistFormatId,
        timestamp: DateTime.now().millisecondsSinceEpoch / 1000.0,
      );
      _actionMessage = 'Playlist download started on server';
      _ensurePolling();
      return true;
    } catch (e) {
      _submitError = e.toString();
      return false;
    } finally {
      _isSubmittingDownload = false;
      _safeNotify();
    }
  }

  void _ensurePolling() {
    if (_pollTimer != null && _pollTimer!.isActive) return;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      unawaited(_pollActiveTasks());
    });
  }

  Future<void> _pollActiveTasks() async {
    if (_disposed) {
      _pollTimer?.cancel();
      return;
    }
    final activeIds = _serverTasks.entries
        .where((e) => e.value.isActive)
        .map((e) => e.key)
        .toList();

    if (activeIds.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    for (final id in activeIds) {
      if (_disposed) return;
      final prev = _serverTasks[id];
      if (prev == null) continue;
      try {
        final updated = await _api.fetchTaskStatus(id, existing: prev);
        _serverTasks[id] = updated;
        if (updated.isCompleted && _autoDownloadToDevice) {
          final existingLocal = _localTransfers[id];
          if (existingLocal == null) {
            unawaited(downloadTaskToDevice(id));
          }
        }
      } on ApiException catch (e) {
        if (e.statusCode == 404) {
          _serverTasks[id] = prev.copyWith(
            status: 'failed',
            error: 'Task expired on server',
          );
        }
      } catch (_) {
        // Keep polling across transient network drops.
      }
    }
    _safeNotify();
  }

  Future<void> cancelServerTask(String taskId) async {
    try {
      await _api.cancelTask(taskId);
      final prev = _serverTasks[taskId];
      if (prev != null) {
        _serverTasks[taskId] = prev.copyWith(
          progress: 'Cancelling…',
        );
      }
      _safeNotify();
    } catch (e) {
      _actionMessage = 'Cancel failed: $e';
      _safeNotify();
    }
  }

  Future<void> downloadTaskToDevice(String taskId) async {
    final task = _serverTasks[taskId];
    if (task == null) return;

    final existing = _localTransfers[taskId];
    if (existing != null && existing.state == TransferState.downloading) {
      return;
    }

    final defaultExt = task.kind == 'playlist'
        ? '.zip'
        : ((task.format != null && task.format!.startsWith('audio-'))
            ? '.${task.format!.split('-').last}'
            : '.mp4');
    final fallbackName = '${task.title}$defaultExt';

    _localTransfers[taskId] = (existing ??
            LocalTransferItem(
              taskId: taskId,
              title: task.title,
              filename: fallbackName,
              localPath: '',
            ))
        .copyWith(state: TransferState.downloading, error: null);
    _safeNotify();

    try {
      final result = await _transfers.downloadWithResume(
        taskId: taskId,
        uri: _api.downloadUri(taskId),
        title: task.title,
        clientId: _clientId,
        fallbackFilename: fallbackName,
        onProgress: (progressItem) {
          _localTransfers[taskId] = progressItem;
          _safeNotify();
        },
      );
      _localTransfers[taskId] = result;
      await _persistTransfers();
      await _refreshStorageUsage();
    } catch (e) {
      final prev = _localTransfers[taskId];
      if (prev != null) {
        _localTransfers[taskId] = prev.copyWith(
          state: TransferState.failed,
          error: e.toString(),
        );
        await _persistTransfers();
      }
    }
    _safeNotify();
  }

  void pauseDeviceTransfer(String taskId) {
    _transfers.pauseTransfer(taskId);
    final prev = _localTransfers[taskId];
    if (prev != null) {
      _localTransfers[taskId] = prev.copyWith(state: TransferState.paused);
      unawaited(_persistTransfers());
      _safeNotify();
    }
  }

  Future<void> clearAllHistory() async {
    try {
      await _api.clearRecentHistory();
      _serverTasks.removeWhere((_, task) => !task.isActive);
      _localTransfers.removeWhere(
        (_, local) => local.state != TransferState.downloading && local.state != TransferState.paused,
      );
      await _persistTransfers();
      _actionMessage = 'History cleared';
      _safeNotify();
    } catch (e) {
      _actionMessage = 'Could not clear history: $e';
      _safeNotify();
    }
  }

  Future<void> updateBaseUrl(String newUrl) async {
    final normalized = PreferencesService.normalizeBaseUrl(newUrl);
    _baseUrl = normalized;
    _api.configure(baseUrl: normalized, clientId: _clientId);
    await _prefs.setBaseUrl(normalized);
    await refreshHealth();
    await refreshRecentTasks();
  }

  Future<void> setAutoDownloadToDevice(bool enabled) async {
    _autoDownloadToDevice = enabled;
    await _prefs.setAutoDownload(enabled);
    _safeNotify();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _prefs.setThemeMode(mode);
    _safeNotify();
  }

  Future<void> savePremiumPassword(String value) async {
    _premiumPassword = value;
    await _prefs.setPremiumPassword(value);
    _safeNotify();
  }

  Future<void> deleteAllLocalFiles() async {
    await _transfers.deleteAllLocalFiles();
    _localTransfers.clear();
    await _persistTransfers();
    await _refreshStorageUsage();
    _actionMessage = 'Local downloads deleted';
    _safeNotify();
  }

  Future<void> _persistTransfers() async {
    await _prefs.saveLocalTransfers(_localTransfers.values.toList());
  }

  Future<void> _refreshStorageUsage() async {
    try {
      _localStorageBytes = await _transfers.computeStorageUsedBytes();
    } catch (_) {
      _localStorageBytes = 0;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }
}
