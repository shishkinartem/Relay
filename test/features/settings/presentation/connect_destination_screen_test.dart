import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/settings/presentation/connect_destination_screen.dart';
import 'package:relay/features/settings/presentation/settings_screen.dart';
import 'package:upload_core/upload_core.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// Connecting a destination from Settings (§15–§17).
///
/// The screen renders whatever the destination declares, so a new destination
/// arrives with its own instructions instead of a branch here.
void main() {
  /// The editable field a destination declared, found by the name it gave it.
  Finder fieldNamed(String label) => find.descendant(
    of: find.byWidgetPredicate(
      (Widget widget) =>
          widget is AppTextField && widget.semanticLabel == label,
    ),
    matching: find.byType(EditableText),
  );

  testWidgets('the destination supplies the steps and the fields', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    final FakeUploadDestination destination =
        harness.destinations.all.first as FakeUploadDestination..account = null;

    await tester.pumpWidget(
      harness.wrap(ConnectDestinationScreen(destination: destination)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ask the fake service for a token.'), findsOneWidget);
    expect(fieldNamed('Token'), findsOneWidget);
    expect(fieldNamed('Room'), findsOneWidget);
    expect(find.text('Where to send it'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });

  testWidgets('connecting stores the values and reports the account', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    final FakeUploadDestination destination =
        harness.destinations.all.first as FakeUploadDestination..account = null;

    await tester.pumpWidget(
      harness.wrap(ConnectDestinationScreen(destination: destination)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(fieldNamed('Token'), 'secret-token');
    await tester.enterText(fieldNamed('Room'), 'standup');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(destination.connected['token'], 'secret-token');
    expect(destination.connected['room'], 'standup');
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('fake@example.com'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('a secret is cleared after it is stored, never read back', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    final FakeUploadDestination destination =
        harness.destinations.all.first as FakeUploadDestination..account = null;

    await tester.pumpWidget(
      harness.wrap(ConnectDestinationScreen(destination: destination)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(fieldNamed('Token'), 'secret-token');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    final EditableText field = tester.widget<EditableText>(fieldNamed('Token'));
    expect(field.controller.text, isEmpty);
    expect(field.obscureText, isTrue);
  });

  testWidgets('a refused connection shows the reason and stays put', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    final FakeUploadDestination destination =
        harness.destinations.all.first as FakeUploadDestination
          ..account = null
          ..connectFailure = const UploadError(
            UploadErrorKind.authentication,
            'That token was refused by the service.',
          );

    await tester.pumpWidget(
      harness.wrap(ConnectDestinationScreen(destination: destination)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('That token was refused by the service.'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('disconnecting forgets the account', (WidgetTester tester) async {
    await loadDesignFonts();
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    final FakeUploadDestination destination =
        harness.destinations.all.first as FakeUploadDestination;

    await tester.pumpWidget(
      harness.wrap(ConnectDestinationScreen(destination: destination)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsOneWidget);

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(destination.calls, contains('disconnect'));
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('Settings reaches the flow and re-reads the account after it', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    final FakeUploadDestination drive =
        harness.destinations.all.first as FakeUploadDestination..account = null;

    await tester.pumpWidget(harness.wrap(const SettingsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Not connected'), findsOneWidget);

    await tester.tap(find.text('Set up').first);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectDestinationScreen), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();

    // The account line is resolved once per destination, so returning from the
    // flow has to invalidate it or Settings would still say "Not connected".
    expect(drive.account, isNotNull);
    expect(find.text('Not connected'), findsNothing);
  });
}
