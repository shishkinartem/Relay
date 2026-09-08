/// Copy about input devices that two layers have to agree on word for word.
///
/// The launch screen's disclosure and the control strip's device sheet both
/// tell the user that a remembered device is gone. They are built by different
/// objects — a widget and the view model — and the two used to hold separate
/// copies of the same sentence, which is a rename away from disagreeing on the
/// one screen where both can be open at once.
///
/// No Flutter import: this is a string, and `/domain/` may not reach for a
/// widget (`test/architecture_test.dart`).
library;

/// Said when the device the user picked last time is no longer attached.
///
/// Names the device rather than the kind, because "your microphone is gone" is
/// not actionable when three are plugged in and one was unplugged.
String unresolvedDeviceNotice(String label) =>
    '“$label” is gone. Using the default device.';
