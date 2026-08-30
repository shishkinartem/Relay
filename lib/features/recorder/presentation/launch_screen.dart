import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../app/app_scope.dart';
import '../../../app/panel_route.dart';
import '../../../core/formatting/size_estimate.dart';
import '../../../design_system/design_system.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_screen.dart';
import '../application/recorder_view_model.dart';
import 'source_picker_screen.dart';
import 'widgets/destination_summary_row.dart';
import 'widgets/input_settings_row.dart';
import 'widgets/labelled_control_row.dart';

/// The screen the application opens on: source, per-session settings and Start
/// in one panel (design `1c`).
class LaunchScreen extends StatelessWidget {
  const LaunchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);
    final RecorderViewModel vm = scope.recorder;
    final SettingsGateway settings = scope.settings;
    final RecorderCapabilities capabilities = vm.capabilities;
    final CaptureSource? source = vm.selectedSource;

    return AppPanel(
      title: 'Recorder',
      titleBarTrailing: AppIconButton(
        icon: AppIcons.settings,
        semanticLabel: 'Settings',
        variant: AppButtonVariant.ghost,
        size: 24,
        onPressed: () =>
            Navigator.of(context)
                .push<void>(panelRoute(const SettingsScreen())),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const AppKicker('Record'),
          const SizedBox(height: 9),
          _SelectedSourceRow(source: source),
          const SizedBox(height: 16),
          _SessionControls(vm: vm, settings: settings),
          const SizedBox(height: 14),
          AppButton(
            label: 'Start recording',
            icon: AppIcons.record,
            variant: AppButtonVariant.primary,
            expand: true,
            height: 38,
            busy: vm.isBusy,
            onPressed: source == null || !capabilities.isSupported
                ? null
                : vm.requestStart,
          ),
          const SizedBox(height: 8),
          Center(
            child: AppMonoText(
              '${const RecordingSizeEstimator().describePerHour(settings.settings.quality, settings.settings.frameRate)} at this profile',
            ),
          ),
          if (!capabilities.isSupported) ...<Widget>[
            const SizedBox(height: 8),
            Center(
              child: AppMonoText(
                capabilities.unsupportedReason ?? 'Recording is unavailable.',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SelectedSourceRow extends StatelessWidget {
  const _SelectedSourceRow({required this.source});

  final CaptureSource? source;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    return BlueprintFrame(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 38,
            height: 26,
            child: BlueprintFrame(
              showCorners: false,
              // Unduotoned, for the same reason as `SourceCard`: this thumbnail
              // is here to confirm *which* screen or window is about to be
              // recorded, and an accent wash makes every one of them look alike.
              child: (source?.thumbnail?.isEmpty ?? true)
                  ? const HatchedSurface(stripe: 5)
                  : ClipRect(
                      child: Image.memory(
                        source!.thumbnail!,
                        fit: BoxFit.cover,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AppKicker(
                  source == null
                      ? 'Source'
                      : 'Source · ${source!.type == CaptureSourceType.display ? 'display' : 'window'}',
                ),
                Text(
                  source == null
                      ? 'No capture source available'
                      : '${source!.title} · ${source!.subtitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodyEmphasis,
                ),
              ],
            ),
          ),
          AppButton(
            label: 'Change',
            variant: AppButtonVariant.ghost,
            fontSize: 12,
            onPressed: () async {
              await vm.openSourcePicker();
              if (context.mounted) {
                await Navigator.of(context)
                    .push<void>(panelRoute(const SourcePickerScreen()));
              }
            },
          ),
        ],
      ),
    );
  }
}

class _SessionControls extends StatelessWidget {
  const _SessionControls({required this.vm, required this.settings});

  final RecorderViewModel vm;
  final SettingsGateway settings;

  @override
  Widget build(BuildContext context) {
    final RecorderCapabilities capabilities = vm.capabilities;
    final List<int> frameRates = capabilities.sortedFrameRates.isEmpty
        ? <int>[30, 60]
        : capabilities.sortedFrameRates;
    final List<RecordingQuality> qualities =
        capabilities.sortedQualities.isEmpty
        ? RecordingQuality.values
        : capabilities.sortedQualities;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppRow(
          leading: const AppKicker('Quality'),
          trailing: AppSegmentedControl<RecordingQuality>(
            semanticLabel: 'Quality',
            value: settings.settings.quality,
            onChanged: settings.setQuality,
            segments: <AppSegment<RecordingQuality>>[
              for (final RecordingQuality q in qualities)
                AppSegment<RecordingQuality>(value: q, label: q.label),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AppRow(
          leading: const AppKicker('Frame rate'),
          trailing: AppSegmentedControl<int>(
            semanticLabel: 'Frame rate',
            value: settings.settings.frameRate,
            onChanged: settings.setFrameRate,
            segments: <AppSegment<int>>[
              for (final int rate in frameRates)
                AppSegment<int>(value: rate, label: '$rate'),
            ],
          ),
        ),
        const AppDivider(margin: EdgeInsets.symmetric(vertical: 10)),
        InputSettingsRow(
          kind: MediaDeviceKind.microphone,
          icon: AppIcons.microphone,
          label: 'Microphone',
          enabled: settings.settings.microphoneEnabled,
          onEnabledChanged: capabilities.supportsMicrophone
              ? settings.setMicrophoneEnabled
              : null,
        ),
        const SizedBox(height: 12),
        InputSettingsRow(
          kind: MediaDeviceKind.systemAudio,
          icon: AppIcons.systemAudio,
          label: 'System audio',
          // Where the platform captures the whole mix rather than one endpoint
          // there is no device to enumerate, and the row still has to say what
          // is being recorded (§33.8).
          fixedDeviceLabel: 'System mix',
          enabled: settings.settings.systemAudioEnabled,
          onEnabledChanged: capabilities.supportsSystemAudio
              ? settings.setSystemAudioEnabled
              : null,
        ),
        const SizedBox(height: 12),
        InputSettingsRow(
          kind: MediaDeviceKind.camera,
          icon: AppIcons.camera,
          label: 'Camera',
          enabled: settings.settings.cameraEnabled,
          onEnabledChanged: capabilities.supportsCamera
              ? settings.setCameraEnabled
              : null,
        ),
        const SizedBox(height: 12),
        _AdvancedSection(vm: vm, settings: settings),
        const AppDivider(margin: EdgeInsets.symmetric(vertical: 10)),
        const DestinationSummaryRow(),
      ],
    );
  }
}

class _AdvancedSection extends StatefulWidget {
  const _AdvancedSection({required this.vm, required this.settings});

  final RecorderViewModel vm;
  final SettingsGateway settings;

  @override
  State<_AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<_AdvancedSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: AppColors.divider)),
    ),
    padding: const EdgeInsets.only(top: 11),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          button: true,
          expanded: _expanded,
          label: 'Advanced',
          child: GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(
                children: <Widget>[
                  const AppKicker('Advanced'),
                  const SizedBox(width: 6),
                  RotatedBox(
                    quarterTurns: _expanded ? 2 : 0,
                    child: AppIcon(
                      AppIcons.chevronDown,
                      size: 13,
                      color: AppColors.ink(45),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded) ...<Widget>[
          const SizedBox(height: 12),
          LabelledControlRow(
            icon: AppIcons.cursor,
            label: 'Show cursor',
            control: AppOnOffControl(
              semanticLabel: 'Show cursor',
              value: widget.settings.settings.showCursor,
              onChanged: widget.vm.capabilities.supportsCursorCapture
                  ? widget.settings.setShowCursor
                  : null,
            ),
          ),
          const SizedBox(height: 9),
          const AppMonoText(
            'showCursor = true · §4.3 requires it in the output',
          ),
        ],
      ],
    ),
  );
}
