import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../app/app_scope.dart';
import '../../../design_system/design_system.dart';
import '../application/recorder_view_model.dart';
import '../domain/session_state.dart';

/// The custom in-application source list: displays first, then windows
/// (design `1a`, §4.1).
///
/// Thumbnails come from one snapshot refreshed on focus, never a live stream.
class SourcePickerScreen extends StatefulWidget {
  const SourcePickerScreen({super.key});

  @override
  State<SourcePickerScreen> createState() => _SourcePickerScreenState();
}

class _SourcePickerScreenState extends State<SourcePickerScreen> {
  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final List<CaptureSource> displays = vm.sources
        .where((CaptureSource s) => s.type == CaptureSourceType.display)
        .toList();
    final List<CaptureSource> windows = vm.sources
        .where((CaptureSource s) => s.type == CaptureSourceType.window)
        .toList();
    final SessionState state = vm.state;
    final bool loading = state is SessionSelectingSource && state.loading;

    return Focus(
      autofocus: true,
      onFocusChange: (bool hasFocus) {
        if (hasFocus) {
          unawaitedRefresh(vm);
        }
      },
      child: AppPanel(
        title: 'Recorder',
        titleBarTrailing: AppMonoText(
          '${vm.settings.quality.label} · ${vm.settings.frameRate}',
        ),
        // Pinned: with fifteen windows the list is far taller than the panel,
        // and the committing action must not be something to scroll for.
        footer: AppButton(
          label: vm.selectedSource == null
              ? 'Select a source'
              : 'Continue with ${vm.selectedSource!.title}',
          variant: AppButtonVariant.primary,
          expand: true,
          height: 38,
          onPressed: vm.selectedSource == null
              ? null
              : () {
                  vm.closeSourcePicker();
                  Navigator.of(context).pop();
                },
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AppRow(
              leading: const AppKicker('Select a source'),
              trailing: AppMonoText(
                loading
                    ? 'refreshing…'
                    : '${_plural(displays.length, 'screen')} · ${_plural(windows.length, 'window')}',
              ),
            ),
            const SizedBox(height: 10),
            for (final CaptureSource display in displays) ...<Widget>[
              SourceCard(
                title:
                    display.type == CaptureSourceType.display &&
                        display.isCurrentDisplay
                    ? 'Entire screen'
                    : display.title,
                subtitle: '${display.title} · ${display.subtitle}',
                thumbnail: display.thumbnail,
                thumbnailHeight: 96,
                badge: display.isCurrentDisplay ? 'Default' : null,
                selected: vm.selectedSource?.id == display.id,
                onSelected: () => vm.selectSource(display),
              ),
              const SizedBox(height: 18),
            ],
            if (windows.isNotEmpty) ...<Widget>[
              const AppKicker('Windows'),
              const SizedBox(height: 9),
              _WindowGrid(
                windows: windows,
                selectedId: vm.selectedSource?.id,
                onSelected: vm.selectSource,
              ),
            ] else if (!loading)
              const AppMonoText('No capturable application windows found.'),
          ],
        ),
      ),
    );
  }

  static String _plural(int count, String noun) =>
      '$count $noun${count == 1 ? '' : 's'}';

  void unawaitedRefresh(RecorderViewModel vm) {
    vm.refreshSources();
  }
}

class _WindowGrid extends StatelessWidget {
  const _WindowGrid({
    required this.windows,
    required this.selectedId,
    required this.onSelected,
  });

  final List<CaptureSource> windows;
  final String? selectedId;
  final ValueChanged<CaptureSource> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      const double gap = 14;
      // The grid answers to the width it is given, not to a platform, a device
      // or the window around it (§28, §33.6). Fifteen windows in two columns at
      // 420 is a long scroll of small thumbnails on a display with room for
      // four.
      //
      // Its own constraints rather than the window's, so the component is the
      // same object wherever it is placed. §33.6 states the breakpoints as this
      // width for that reason, and names the window widths they work out to.
      final int columns = AppSpacing.gridColumns(constraints.maxWidth);
      final double columnWidth =
          (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: <Widget>[
          for (final CaptureSource window in windows)
            SizedBox(
              width: columnWidth,
              child: SourceCard(
                title: window.title,
                subtitle: window.subtitle,
                thumbnail: window.thumbnail,
                selected: selectedId == window.id,
                onSelected: () => onSelected(window),
              ),
            ),
        ],
      );
    },
  );
}
