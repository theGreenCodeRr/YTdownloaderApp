import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models/models.dart';
import '../core/app_theme.dart';
import '../view_models/downloader_view_model.dart';

class ExtractorPane extends StatefulWidget {
  const ExtractorPane({
    super.key,
    required this.viewModel,
  });

  final DownloaderViewModel viewModel;

  @override
  State<ExtractorPane> createState() => _ExtractorPaneState();
}

class _ExtractorPaneState extends State<ExtractorPane> {
  late final TextEditingController _urlController;
  late final TextEditingController _searchController;
  late final TextEditingController _fromController;
  late final TextEditingController _toController;
  late final TextEditingController _passwordController;
  bool _obscurePassword = true;

  DownloaderViewModel get vm => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: vm.urlInput);
    _searchController = TextEditingController(text: vm.playlistSearchQuery);
    _fromController = TextEditingController();
    _toController = TextEditingController();
    _passwordController = TextEditingController(text: vm.premiumPassword);
    vm.addListener(_syncControllers);
  }

  @override
  void didUpdateWidget(covariant ExtractorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel != widget.viewModel) {
      oldWidget.viewModel.removeListener(_syncControllers);
      vm.addListener(_syncControllers);
      _syncControllers();
    }
  }

  void _syncControllers() {
    if (_urlController.text != vm.urlInput) {
      _urlController.value = TextEditingValue(
        text: vm.urlInput,
        selection: TextSelection.collapsed(offset: vm.urlInput.length),
      );
    }
    if (_passwordController.text.isEmpty && vm.premiumPassword.isNotEmpty) {
      _passwordController.text = vm.premiumPassword;
    }
    final range = vm.contiguousSelectionRange;
    if (range != null) {
      final f = '${range.$1}';
      final t = '${range.$2}';
      if (_fromController.text != f) _fromController.text = f;
      if (_toController.text != t) _toController.text = t;
    }
  }

  @override
  void dispose() {
    vm.removeListener(_syncControllers);
    _urlController.dispose();
    _searchController.dispose();
    _fromController.dispose();
    _toController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    _urlController.text = text;
    vm.setUrlInput(text);
    if (text.startsWith('http://') || text.startsWith('https://')) {
      await vm.fetchInfo(text);
    }
  }

  void _applyCustomRange() {
    final info = vm.mediaInfo;
    if (info == null || !info.isPlaylist) return;
    final total = info.entries.length;
    if (total == 0) return;

    var from = int.tryParse(_fromController.text.trim()) ?? 1;
    var to = int.tryParse(_toController.text.trim()) ?? total;
    from = from.clamp(1, total);
    to = to.clamp(1, total);
    if (to < from) {
      final tmp = from;
      from = to;
      to = tmp;
    }
    _fromController.text = '$from';
    _toController.text = '$to';
    vm.selectPlaylistRange(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final info = vm.mediaInfo;

    if (info != null && info.isPlaylist) {
      return _buildPlaylistLayout(context, info);
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildUrlInputCard(context),
            if (vm.infoError != null || vm.submitError != null) ...[
              const SizedBox(height: 12),
              _ErrorBanner(message: vm.infoError ?? vm.submitError ?? ''),
            ],
            const SizedBox(height: 12),
            if (vm.isLoadingInfo)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 14),
                      Text('Fetching video & format metadata…'),
                    ],
                  ),
                ),
              )
            else if (info != null)
              _buildSingleVideoSection(context, info)
            else
              _buildWelcomeCard(context),
          ],
        ),
      ),
    );
  }

  Widget _buildUrlInputCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Extract Media',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Max ${vm.maxDownloadGb} GB',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('url_input_field'),
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onChanged: vm.setUrlInput,
                    onSubmitted: (_) => vm.fetchInfo(_urlController.text),
                    decoration: InputDecoration(
                      hintText: 'Paste video, audio, or playlist URL…',
                      prefixIcon: const Icon(Icons.link_rounded),
                      suffixIcon: _urlController.text.isNotEmpty
                          ? IconButton(
                              tooltip: 'Clear',
                              onPressed: () {
                                _urlController.clear();
                                vm.clearUrlInput();
                              },
                              icon: const Icon(Icons.close_rounded),
                            )
                          : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('paste_url_button'),
                  onPressed: vm.isLoadingInfo ? null : _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste_go_rounded, size: 18),
                  label: const Text('Paste'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('fetch_info_button'),
                    onPressed: vm.isLoadingInfo
                        ? null
                        : () => vm.fetchInfo(_urlController.text),
                    icon: const Icon(Icons.search_rounded),
                    label: Text(vm.isLoadingInfo ? 'Fetching…' : 'Get Formats'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomeCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const features = [
      (Icons.high_quality_rounded, 'Up to 4K Video & Lossless Audio (MP3, WAV, FLAC)'),
      (Icons.view_column_rounded, 'Quick-Split Big Playlists (Half, Quarters, Custom Range)'),
      (Icons.wifi_tethering_rounded, 'Resumable Transfers for 400 GB Archives over Wi-Fi / 5G'),
      (Icons.share_rounded, 'Share media links directly from your browser or social apps'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ready for Phones & Tablets',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            for (final (icon, text) in features) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        text,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSingleVideoSection(BuildContext context, MediaInfo info) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final formats = vm.visibleSingleFormats;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MediaThumbnailBox(url: info.thumbnail),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (info.uploader != null && info.uploader!.isNotEmpty)
                            _MetaChip(label: info.uploader!),
                          if (info.formattedDuration.isNotEmpty)
                            _MetaChip(label: info.formattedDuration),
                          if (info.extractor != null && info.extractor!.isNotEmpty)
                            _MetaChip(label: info.extractor!),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment<bool>(
                        value: false,
                        icon: Icon(Icons.videocam_outlined),
                        label: Text('Video'),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        icon: Icon(Icons.audiotrack_outlined),
                        label: Text('Audio'),
                      ),
                    ],
                    selected: {vm.showAudioFormats},
                    onSelectionChanged: (sel) => vm.setSingleMediaTab(sel.first),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (formats.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No formats available in this category.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: formats.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 250,
                  mainAxisExtent: 82,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemBuilder: (context, idx) {
                  final f = formats[idx];
                  final selected = f.id == vm.selectedSingleFormatId;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => vm.selectSingleFormat(f.id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: selected
                            ? scheme.primaryContainer.withValues(alpha: 0.6)
                            : scheme.surfaceContainerLow,
                        border: Border.all(
                          color: selected
                              ? scheme.primary
                              : scheme.outlineVariant.withValues(alpha: 0.5),
                          width: selected ? 1.8 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  f.resolution,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                f.ext.toUpperCase(),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  f.note,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                f.sizeStr,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('download_single_button'),
                onPressed: vm.isSubmittingDownload ? null : () => vm.startSingleDownload(),
                icon: const Icon(Icons.download_rounded),
                label: Text(
                  vm.isSubmittingDownload
                      ? 'Queueing…'
                      : (vm.showAudioFormats ? 'Download Audio' : 'Download Video'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistLayout(BuildContext context, MediaInfo info) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final filtered = vm.filteredPlaylistIndices;
    final fractions = vm.playlistFractions;
    final range = vm.contiguousSelectionRange;
    final rangeSuffix = range != null ? ' (#${range.$1}–${range.$2})' : '';

    // Combine server playlist presets with lossless audio options supported by backend.
    final qualityOptions = <VideoFormat>[
      ...info.formats,
      if (!info.formats.any((f) => f.id == 'audio-wav'))
        const VideoFormat(
          id: 'audio-wav',
          ext: 'wav',
          resolution: 'WAV',
          note: 'Lossless WAV',
          sizeStr: 'Auto',
          kind: 'audio',
        ),
      if (!info.formats.any((f) => f.id == 'audio-flac'))
        const VideoFormat(
          id: 'audio-flac',
          ext: 'flac',
          resolution: 'FLAC',
          note: 'Lossless FLAC',
          sizeStr: 'Auto',
          kind: 'audio',
        ),
    ];

    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildUrlInputCard(context),
                          if (vm.infoError != null || vm.submitError != null) ...[
                            const SizedBox(height: 10),
                            _ErrorBanner(message: vm.infoError ?? vm.submitError ?? ''),
                          ],
                          const SizedBox(height: 12),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          info.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.titleMedium?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: scheme.primaryContainer,
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '${vm.selectedCount} of ${info.entries.length} selected',
                                          style: theme.textTheme.labelSmall?.copyWith(
                                            color: scheme.onPrimaryContainer,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'ZIP Quality',
                                    style: theme.textTheme.labelMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: qualityOptions.map((fmt) {
                                      return ChoiceChip(
                                        label: Text(fmt.resolution),
                                        selected: vm.selectedPlaylistFormatId == fmt.id,
                                        onSelected: (_) => vm.selectPlaylistFormat(fmt.id),
                                      );
                                    }).toList(),
                                  ),
                                  if (fractions.isNotEmpty) ...[
                                    const SizedBox(height: 14),
                                    Text(
                                      'Quick Split / Custom Range',
                                      style: theme.textTheme.labelMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      key: const Key('playlist_fraction_chips'),
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: fractions.map((preset) {
                                        final allSel =
                                            vm.selectedCount == info.entries.length;
                                        final active = (preset.start == 1 &&
                                                preset.end == info.entries.length &&
                                                allSel) ||
                                            (range != null &&
                                                range.$1 == preset.start &&
                                                range.$2 == preset.end);
                                        return ChoiceChip(
                                          label: Text(preset.label),
                                          selected: active,
                                          onSelected: (_) {
                                            _fromController.text = '${preset.start}';
                                            _toController.text = '${preset.end}';
                                            vm.selectPlaylistRange(
                                              preset.start,
                                              preset.end,
                                            );
                                          },
                                        );
                                      }).toList(),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        SizedBox(
                                          width: 82,
                                          child: TextField(
                                            key: const Key('range_from_field'),
                                            controller: _fromController,
                                            keyboardType: TextInputType.number,
                                            onSubmitted: (_) => _applyCustomRange(),
                                            decoration: const InputDecoration(
                                              labelText: 'From',
                                              isDense: true,
                                            ),
                                          ),
                                        ),
                                        const Padding(
                                          padding: EdgeInsets.symmetric(horizontal: 6),
                                          child: Text('–'),
                                        ),
                                        SizedBox(
                                          width: 82,
                                          child: TextField(
                                            key: const Key('range_to_field'),
                                            controller: _toController,
                                            keyboardType: TextInputType.number,
                                            onSubmitted: (_) => _applyCustomRange(),
                                            decoration: const InputDecoration(
                                              labelText: 'To',
                                              isDense: true,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        FilledButton.tonal(
                                          key: const Key('range_apply_button'),
                                          onPressed: _applyCustomRange,
                                          child: const Text('Select'),
                                        ),
                                      ],
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _searchController,
                                          onChanged: vm.setPlaylistSearchQuery,
                                          decoration: const InputDecoration(
                                            hintText: 'Filter playlist videos…',
                                            prefixIcon: Icon(Icons.filter_list_rounded),
                                            isDense: true,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      TextButton(
                                        onPressed: vm.selectAllPlaylistEntries,
                                        child: const Text('All'),
                                      ),
                                      TextButton(
                                        onPressed: vm.deselectAllPlaylistEntries,
                                        child: const Text('None'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    sliver: SliverList.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, pos) {
                        final entryIndex = filtered[pos];
                        final entry = info.entries[entryIndex];
                        final checked = vm.selectedIndices.contains(entryIndex);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: CheckboxListTile(
                            value: checked,
                            onChanged: (_) => vm.togglePlaylistIndex(entryIndex),
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(
                              '${entry.index}. ${entry.title}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: entry.formattedDuration.isNotEmpty
                                ? Text(entry.formattedDuration)
                                : null,
                            secondary: TextButton(
                              onPressed: () => _openEntryFormats(context, entry),
                              child: const Text('Formats'),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Material(
          elevation: 6,
          color: scheme.surface,
          child: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: !vm.premiumEnabled
                      ? Row(
                          children: [
                            Icon(Icons.info_outline_rounded, color: scheme.secondary),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Playlist ZIP mode is disabled on the server. Tap "Formats" on any video to download it individually.',
                              ),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    key: const Key('premium_password_field'),
                                    controller: _passwordController,
                                    obscureText: _obscurePassword,
                                    decoration: InputDecoration(
                                      labelText: 'Premium Password',
                                      isDense: true,
                                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                                      suffixIcon: IconButton(
                                        onPressed: () => setState(
                                          () => _obscurePassword = !_obscurePassword,
                                        ),
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility_outlined
                                              : Icons.visibility_off_outlined,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                FilledButton.icon(
                                  key: const Key('download_playlist_button'),
                                  onPressed: (vm.selectedCount == 0 || vm.isSubmittingDownload)
                                      ? null
                                      : () => vm.startPlaylistDownload(
                                            _passwordController.text,
                                          ),
                                  icon: const Icon(Icons.archive_outlined),
                                  label: Text(
                                    vm.selectedCount == 0
                                        ? 'Select videos'
                                        : 'Download ${vm.selectedCount}$rangeSuffix',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openEntryFormats(BuildContext context, PlaylistEntry entry) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _PlaylistEntryFormatsSheet(
        entry: entry,
        viewModel: vm,
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistEntryFormatsSheet extends StatefulWidget {
  const _PlaylistEntryFormatsSheet({
    required this.entry,
    required this.viewModel,
  });

  final PlaylistEntry entry;
  final DownloaderViewModel viewModel;

  @override
  State<_PlaylistEntryFormatsSheet> createState() =>
      _PlaylistEntryFormatsSheetState();
}

class _PlaylistEntryFormatsSheetState extends State<_PlaylistEntryFormatsSheet> {
  late Future<MediaInfo> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.viewModel.inspectPlaylistEntry(widget.entry);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<MediaInfo>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('Error: ${snapshot.error}'));
                  }
                  final data = snapshot.data;
                  if (data == null || data.formats.isEmpty) {
                    return const Center(child: Text('No formats found.'));
                  }
                  return ListView.separated(
                    controller: scrollController,
                    itemCount: data.formats.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, idx) {
                      final fmt = data.formats[idx];
                      return ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        tileColor: theme.colorScheme.surfaceContainerLow,
                        leading: Icon(
                          fmt.isAudio ? Icons.audiotrack_rounded : Icons.movie_outlined,
                        ),
                        title: Text('${fmt.resolution} (${fmt.ext.toUpperCase()})'),
                        subtitle: Text(fmt.note.isNotEmpty ? fmt.note : fmt.sizeStr),
                        trailing: FilledButton.tonal(
                          onPressed: () async {
                            final nav = Navigator.of(context);
                            final ok = await widget.viewModel.startSingleDownload(
                              overrideUrl: widget.entry.url,
                              overrideFormatId: fmt.id,
                              overrideTitle: data.title,
                              overrideThumbnail: data.thumbnail,
                            );
                            if (ok && mounted) nav.pop();
                          },
                          child: const Text('Get'),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
