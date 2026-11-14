import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/models.dart';
import '../../data/services/preferences_service.dart';
import '../view_models/downloader_view_model.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.viewModel,
  });

  final DownloaderViewModel viewModel;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final TextEditingController _serverController;

  DownloaderViewModel get vm => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: vm.baseUrl);
  }

  @override
  void dispose() {
    _serverController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final health = vm.health;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Backend Server',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: const Key('server_url_field'),
                      controller: _serverController,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Server Base URL',
                        hintText: AppConfig.defaultBaseUrl,
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ActionChip(
                          avatar: const Icon(Icons.public_rounded, size: 16),
                          label: const Text('Production (HTTPS)'),
                          onPressed: () {
                            _serverController.text = AppConfig.defaultBaseUrl;
                            vm.updateBaseUrl(AppConfig.defaultBaseUrl);
                          },
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.lan_outlined, size: 16),
                          label: const Text('Local LAN (192.168.1.5:8000)'),
                          onPressed: () {
                            _serverController.text = AppConfig.localLanBaseUrl;
                            vm.updateBaseUrl(AppConfig.localLanBaseUrl);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: vm.isCheckingHealth
                            ? null
                            : () => vm.updateBaseUrl(_serverController.text),
                        icon: const Icon(Icons.sync_rounded),
                        label: Text(
                          vm.isCheckingHealth ? 'Checking server…' : 'Save & Test Connection',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (vm.healthError != null)
                      Text(
                        'Connection error: ${vm.healthError}',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                      )
                    else if (health != null)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _HealthPill(
                            icon: Icons.check_circle_outline_rounded,
                            label: 'Online (${health.ytDlpVersion ?? 'yt-dlp'})',
                            positive: true,
                          ),
                          _HealthPill(
                            icon: Icons.storage_rounded,
                            label: 'Max ${health.maxDownloadGb} GB',
                            positive: true,
                          ),
                          _HealthPill(
                            icon: Icons.lock_outline_rounded,
                            label: health.premiumEnabled ? 'Playlist ZIP On' : 'Single Only',
                            positive: health.premiumEnabled,
                          ),
                          _HealthPill(
                            icon: Icons.cookie_outlined,
                            label: health.cookiesLoaded ? 'Cookies Loaded' : 'No Cookies',
                            positive: health.cookiesLoaded,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'App Preferences',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto-download finished files'),
                      subtitle: const Text(
                        'Starts saving files to this device immediately after server processing completes.',
                      ),
                      value: vm.autoDownloadToDevice,
                      onChanged: vm.setAutoDownloadToDevice,
                    ),
                    const Divider(),
                    const SizedBox(height: 6),
                    Text(
                      'Appearance',
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.system,
                            label: Text('System'),
                            icon: Icon(Icons.brightness_auto_outlined),
                          ),
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.light,
                            label: Text('Light'),
                            icon: Icon(Icons.light_mode_outlined),
                          ),
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.dark,
                            label: Text('Dark'),
                            icon: Icon(Icons.dark_mode_outlined),
                          ),
                        ],
                        selected: {vm.themeMode},
                        onSelectionChanged: (sel) => vm.setThemeMode(sel.first),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Device Storage & Client ID',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Local downloaded media'),
                      subtitle: Text('${formatByteCount(vm.localStorageBytes)} used on device'),
                      trailing: OutlinedButton(
                        onPressed: vm.localStorageBytes == 0
                            ? null
                            : () => _confirmDeleteLocal(context),
                        child: const Text('Delete Files'),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Client ID (24h server history isolation)'),
                      subtitle: Text(
                        vm.clientId,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      trailing: IconButton(
                        tooltip: 'Copy Client ID',
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: vm.clientId));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Client ID copied')),
                          );
                        },
                      ),
                    ),
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Privacy Policy'),
                      subtitle: Text('${vm.baseUrl}/privacy'),
                      trailing: const Icon(Icons.open_in_new_rounded),
                      onTap: () => _openPrivacyPolicy(context),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPrivacyPolicy(BuildContext context) async {
    final uri = Uri.tryParse('${vm.baseUrl}/privacy');
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${uri.toString()}')),
      );
    }
  }

  Future<void> _confirmDeleteLocal(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all local downloads?'),
        content: const Text(
          'This removes downloaded videos and partial .part files stored inside the app folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await vm.deleteAllLocalFiles();
    }
  }
}

class _HealthPill extends StatelessWidget {
  const _HealthPill({
    required this.icon,
    required this.label,
    required this.positive,
  });

  final IconData icon;
  final String label;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: positive ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: positive ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: positive ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
