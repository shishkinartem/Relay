import AVFoundation
import CoreAudio
import Foundation
import RecorderCore

/// Watches for the machine moving its *default* device (§33.7).
///
/// `AVCaptureDevice.wasConnected` and `wasDisconnected` report a device
/// arriving or leaving, and nothing else. A user who changes the input in
/// System Settings > Sound unplugs nothing: without this the launch screen goes
/// on marking the old microphone "default", the meter goes on listening to it,
/// and both are wrong in the one place the user is looking (§33.2).
///
/// Threading. The Core Audio listener blocks are dispatched on `queue`, and the
/// camera observation arrives on whichever thread moved the property, so every
/// notice is hopped to the main queue before it reaches `onChange` — the
/// plugin's event sink and `InputMeter` are both driven from there. The two
/// stored registrations are touched only by `init` and `deinit`, which are the
/// owner's own calls and cannot overlap; the blocks hold `self` weakly, so one
/// firing while the observer is being torn down is a no-op rather than a call
/// into freed memory.
final class DefaultDeviceObserver: NSObject {
  typealias Handler = (DeviceChangeNotice) -> Void

  private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

  /// The class-level property AVFoundation publishes the preferred camera on.
  /// Spelled once, because the string has to match on the way out as well.
  private static let cameraKeyPath = "systemPreferredCamera"

  private let onChange: Handler
  private let queue = DispatchQueue(label: "relay.default.device")

  /// One registration: the address it was made for, and the block that was
  /// added. Removing it needs both, and needs that very block rather than an
  /// equal one.
  private typealias AudioListener = (
    address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock
  )

  private var audioListeners: [AudioListener] = []
  private var observingCamera = false

  init(onChange: @escaping Handler) {
    self.onChange = onChange
    super.init()
    // The default *input* is the one that matters: it is what the meter follows
    // and what the microphone list marks as the default row.
    observeAudioDefault(
      selector: kAudioHardwarePropertyDefaultInputDevice, kind: .microphone)
    // The default *output* is one more address for the same block, so it is
    // observed too. It names `systemAudio`, which Dart has no list to re-read
    // for — ScreenCaptureKit delivers the mix and there is no endpoint to
    // choose (§33.8) — so nothing on screen changes today. It is here so the
    // two halves of the event mean the same thing: the machine's audio routing
    // moved, and whatever comes to depend on that hears about it.
    observeAudioDefault(
      selector: kAudioHardwarePropertyDefaultOutputDevice, kind: .systemAudio)
    observeCameraDefault()
  }

  deinit {
    for listener in audioListeners {
      var address = listener.address
      AudioObjectRemovePropertyListenerBlock(
        DefaultDeviceObserver.systemObject, &address, queue, listener.block)
    }
    if observingCamera {
      (AVCaptureDevice.self as AnyObject).removeObserver(
        self, forKeyPath: DefaultDeviceObserver.cameraKeyPath)
    }
  }

  /// One Core Audio property on the system object, which is where the machine's
  /// defaults live. A registration that is refused is left out of the list
  /// rather than removed later, so teardown only undoes what was done.
  private func observeAudioDefault(
    selector: AudioObjectPropertySelector, kind: MediaDeviceKind
  ) {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.notify(DeviceChangeNotice(kind: kind))
    }
    let status = AudioObjectAddPropertyListenerBlock(
      DefaultDeviceObserver.systemObject, &address, queue, block)
    guard status == noErr else { return }
    audioListeners.append((address: address, block: block))
  }

  /// The video half of the same question.
  ///
  /// Observed on the class rather than on an instance because that is where
  /// AVFoundation publishes it. macOS 14 introduced `systemPreferredCamera` and
  /// this build's floor is 13.5 (`Package.swift`): on 13 the system has no
  /// notion of a preferred camera to observe, so connect and disconnect remain
  /// the whole of what the camera list can be told there.
  private func observeCameraDefault() {
    guard #available(macOS 14.0, *) else { return }
    (AVCaptureDevice.self as AnyObject).addObserver(
      self, forKeyPath: DefaultDeviceObserver.cameraKeyPath, options: [],
      context: nil)
    observingCamera = true
  }

  override func observeValue(
    forKeyPath keyPath: String?, of object: Any?,
    change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
  ) {
    guard keyPath == DefaultDeviceObserver.cameraKeyPath else {
      super.observeValue(
        forKeyPath: keyPath, of: object, change: change, context: context)
      return
    }
    notify(DeviceChangeNotice(kind: .camera))
  }

  private func notify(_ notice: DeviceChangeNotice) {
    DispatchQueue.main.async { [weak self] in self?.onChange(notice) }
  }
}
