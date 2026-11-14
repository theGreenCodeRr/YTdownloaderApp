import 'package:material_ui/material_ui.dart';

import '../view_models/downloader_view_model.dart';
import '../widgets/extractor_pane.dart';
import '../widgets/transfers_pane.dart';
import 'settings_view.dart';

const double tabletBreakpointWidth = 700.0;

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.viewModel,
  });

  final DownloaderViewModel viewModel;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _phoneTabIndex = 0;
  int _tabletSectionIndex = 0;

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_handleViewModelUpdate);
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel != widget.viewModel) {
      oldWidget.viewModel.removeListener(_handleViewModelUpdate);
      widget.viewModel.addListener(_handleViewModelUpdate);
    }
  }

  void _handleViewModelUpdate() {
    final msg = widget.viewModel.actionMessage;
    if (msg != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
        widget.viewModel.consumeActionMessage();
      });
    }
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_handleViewModelUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth >= tabletBreakpointWidth;
            return isTablet
                ? _buildTabletShell(context)
                : _buildPhoneShell(context);
          },
        );
      },
    );
  }

  Widget _buildPhoneShell(BuildContext context) {
    final activeCount = widget.viewModel.activeWorkCount;
    final pages = [
      ExtractorPane(viewModel: widget.viewModel),
      TransfersPane(viewModel: widget.viewModel),
      SettingsView(viewModel: widget.viewModel),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('YT Downloader'),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              label: Text('Max ${widget.viewModel.maxDownloadGb} GB'),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _phoneTabIndex,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _phoneTabIndex,
        onDestinationSelected: (idx) => setState(() => _phoneTabIndex = idx),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.link_rounded),
            label: 'Download',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: activeCount > 0,
              label: Text('$activeCount'),
              child: const Icon(Icons.download_done_rounded),
            ),
            label: 'Activity',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildTabletShell(BuildContext context) {
    final activeCount = widget.viewModel.activeWorkCount;
    return Scaffold(
      appBar: AppBar(
        title: const Text('YT Downloader'),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Chip(
              avatar: const Icon(Icons.storage_rounded, size: 16),
              label: Text('Server Cap: ${widget.viewModel.maxDownloadGb} GB'),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _tabletSectionIndex,
            onDestinationSelected: (idx) => setState(() => _tabletSectionIndex = idx),
            labelType: NavigationRailLabelType.all,
            destinations: [
              NavigationRailDestination(
                icon: Badge(
                  isLabelVisible: activeCount > 0,
                  label: Text('$activeCount'),
                  child: const Icon(Icons.dashboard_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: activeCount > 0,
                  label: Text('$activeCount'),
                  child: const Icon(Icons.dashboard_rounded),
                ),
                label: const Text('Workspace'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings_rounded),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _tabletSectionIndex == 0
                ? Row(
                    key: const Key('tablet_split_workspace'),
                    children: [
                      Expanded(
                        flex: 6,
                        child: ExtractorPane(viewModel: widget.viewModel),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        flex: 5,
                        child: TransfersPane(viewModel: widget.viewModel),
                      ),
                    ],
                  )
                : SettingsView(viewModel: widget.viewModel),
          ),
        ],
      ),
    );
  }
}
