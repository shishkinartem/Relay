import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/features/recorder/presentation/overlay/overlay_binding.dart';

/// The regression this file exists for: an overlay engine that stops drawing
/// the moment the application stops being the front one. Recording is that
/// moment, every time — so a frozen control strip is not an edge case, it is
/// the normal state of a recording session.
///
/// This installs a real [OverlayBinding] rather than the test binding, because
/// the behaviour under test *is* the binding.
void main() {
  final OverlayBinding binding =
      OverlayBinding.ensureInitialized() as OverlayBinding;

  Future<void> reportLifecycle(AppLifecycleState state) async {
    final ByteData message = const StringCodec().encodeMessage(
      state.toString(),
    )!;
    ServicesBinding.instance.channelBuffers.push(
      'flutter/lifecycle',
      message,
      (ByteData? _) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  test('no frames before a root widget is attached', () {
    expect(binding.isRootWidgetAttached, isFalse);
    expect(binding.framesEnabled, isFalse);
  });

  test(
    'frames survive every lifecycle state that would disable them',
    () async {
      binding.attachRootWidget(const SizedBox.shrink());
      expect(binding.framesEnabled, isTrue);

      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        await reportLifecycle(state);
        expect(
          binding.lifecycleState,
          state,
          reason: 'the state itself stays honest for observers',
        );
        expect(
          binding.framesEnabled,
          isTrue,
          reason:
              'an always-on-top window is on screen exactly when the '
              'application is not ($state)',
        );
      }

      await reportLifecycle(AppLifecycleState.resumed);
      expect(binding.framesEnabled, isTrue);
    },
  );
}
