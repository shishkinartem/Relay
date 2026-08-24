import AVFoundation
import Foundation
import RecorderCore

/// Mixes microphone and system audio into the single output track (§8).
///
/// The two sources have independent clocks, so they are not concatenated —
/// each incoming buffer is summed into a ring keyed by its position on the one
/// monotonic recording timeline. A source that is switched off simply stops
/// contributing; its stream keeps running, so toggling never restarts capture.
///
/// The ring is bounded (`ringSeconds`); samples that arrive outside its window
/// are counted as discontinuities and dropped rather than growing memory.
final class AudioMixer {
  static let sampleRate: Double = 48_000
  static let channelCount: Int = 2

  private let ringSeconds: Double = 4
  private let queue = DispatchQueue(label: "relay.audio.mixer")

  private var ring: [Float]
  private let ringFrames: Int
  /// Absolute frame index stored at `ring[0]`.
  private var ringOrigin: Int64 = 0
  /// One past the highest absolute frame index written into the ring.
  private var writeHead: Int64 = 0
  /// One past the highest absolute frame index already emitted downstream.
  private var emitHead: Int64 = 0

  private var converters: [String: AVAudioConverter] = [:]
  private let outputFormat: AVAudioFormat
  private var formatDescription: CMAudioFormatDescription?

  private(set) var discontinuities: Int = 0

  init() {
    ringFrames = Int(AudioMixer.sampleRate * ringSeconds)
    ring = [Float](repeating: 0, count: ringFrames * AudioMixer.channelCount)
    outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: AudioMixer.sampleRate,
      channels: AVAudioChannelCount(AudioMixer.channelCount),
      interleaved: true)!
  }

  func reset() {
    queue.sync {
      for index in ring.indices { ring[index] = 0 }
      ringOrigin = 0
      writeHead = 0
      emitHead = 0
      discontinuities = 0
    }
  }

  /// Sums one source's buffer into the mix at `timelineSeconds`.
  ///
  /// `sourceKey` keeps one converter per source, because rebuilding an
  /// `AVAudioConverter` per buffer would allocate on the capture thread.
  func mix(
    sampleBuffer: CMSampleBuffer, timelineSeconds: Double, sourceKey: String
  ) {
    guard let samples = convert(sampleBuffer, sourceKey: sourceKey), !samples.isEmpty
    else { return }
    let startFrame = Int64((timelineSeconds * AudioMixer.sampleRate).rounded())
    queue.sync { write(samples: samples, startFrame: startFrame) }
  }

  /// Emits everything older than `latencySeconds`, so late-arriving samples
  /// from the other source still have a chance to be summed in.
  func drain(upToTimelineSeconds: Double, latencySeconds: Double = 0.25)
    -> CMSampleBuffer?
  {
    let target = Int64(
      ((upToTimelineSeconds - latencySeconds) * AudioMixer.sampleRate).rounded())
    return queue.sync { emit(upTo: target) }
  }

  /// Emits every remaining sample. Used once, at stop.
  func flush() -> CMSampleBuffer? {
    return queue.sync { emit(upTo: writeHead) }
  }

  // MARK: - ring

  private func write(samples: [Float], startFrame: Int64) {
    let frames = samples.count / AudioMixer.channelCount
    guard frames > 0 else { return }

    if writeHead == 0 && emitHead == 0 && ringOrigin == 0 {
      ringOrigin = max(0, startFrame)
      writeHead = ringOrigin
      emitHead = ringOrigin
    }

    // Anything already emitted, or further ahead than the ring can hold, is a
    // discontinuity rather than something to buffer indefinitely.
    //
    // The window is measured from the *read* head, which is what the ring
    // actually protects: slots behind `emitHead` have been drained and zeroed,
    // and only `ringFrames` of them exist. Measuring it from `ringOrigin`
    // instead collapses the window to nothing once the origin catches up, and
    // every live buffer — which always runs ahead of the drain — is discarded.
    if startFrame + Int64(frames) <= emitHead
      || startFrame >= emitHead + Int64(ringFrames)
    {
      discontinuities += 1
      return
    }

    let firstFrame = max(startFrame, emitHead)
    let skipped = Int(firstFrame - startFrame)
    let usable = frames - skipped
    guard usable > 0 else { return }

    for frame in 0..<usable {
      let absolute = firstFrame + Int64(frame)
      let slot = Int((absolute - ringOrigin) % Int64(ringFrames))
      let ringBase = slot * AudioMixer.channelCount
      let sourceBase = (skipped + frame) * AudioMixer.channelCount
      for channel in 0..<AudioMixer.channelCount {
        ring[ringBase + channel] += samples[sourceBase + channel]
      }
    }
    writeHead = max(writeHead, firstFrame + Int64(usable))
  }

  private func emit(upTo target: Int64) -> CMSampleBuffer? {
    let end = min(target, writeHead)
    guard end > emitHead else { return nil }
    let frames = Int(end - emitHead)
    var interleaved = [Float](repeating: 0, count: frames * AudioMixer.channelCount)
    for frame in 0..<frames {
      let absolute = emitHead + Int64(frame)
      let slot = Int((absolute - ringOrigin) % Int64(ringFrames))
      let ringBase = slot * AudioMixer.channelCount
      let outBase = frame * AudioMixer.channelCount
      for channel in 0..<AudioMixer.channelCount {
        // Soft clip: summing two full-scale sources can exceed 1.0.
        interleaved[outBase + channel] = max(-1, min(1, ring[ringBase + channel]))
        ring[ringBase + channel] = 0
      }
    }
    let presentation = CMTime(
      value: emitHead, timescale: CMTimeScale(AudioMixer.sampleRate))
    emitHead = end
    // `ringOrigin` is the fixed anchor the `% ringFrames` slot mapping is
    // computed from, not a moving window. Re-basing it here both invalidated
    // the mapping for frames already in the ring and, through the write guard,
    // silenced every source after the first few seconds.
    return makeSampleBuffer(interleaved: interleaved, presentation: presentation)
  }

  // MARK: - conversion

  private func convert(_ sampleBuffer: CMSampleBuffer, sourceKey: String) -> [Float]? {
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
    else { return nil }
    let inputFormat = AVAudioFormat(streamDescription: asbd)
    guard let inputFormat else { return nil }

    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frameCount > 0,
      let input = AVAudioPCMBuffer(
        pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount))
    else { return nil }
    input.frameLength = AVAudioFrameCount(frameCount)

    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(frameCount),
      into: input.mutableAudioBufferList)
    guard status == noErr else { return nil }

    if inputFormat == outputFormat {
      return interleavedFloats(from: input)
    }

    let converter: AVAudioConverter
    if let existing = converters[sourceKey], existing.inputFormat == inputFormat {
      converter = existing
    } else {
      guard let created = AVAudioConverter(from: inputFormat, to: outputFormat)
      else { return nil }
      converters[sourceKey] = created
      converter = created
    }

    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(frameCount) * ratio + 64)
    guard
      let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
    else { return nil }

    var consumed = false
    var conversionError: NSError?
    converter.convert(to: output, error: &conversionError) { _, statusPointer in
      if consumed {
        statusPointer.pointee = .noDataNow
        return nil
      }
      consumed = true
      statusPointer.pointee = .haveData
      return input
    }
    guard conversionError == nil else { return nil }
    return interleavedFloats(from: output)
  }

  private func interleavedFloats(from buffer: AVAudioPCMBuffer) -> [Float]? {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return [] }
    let list = buffer.audioBufferList.pointee
    if buffer.format.isInterleaved {
      guard let data = list.mBuffers.mData else { return nil }
      let channels = Int(buffer.format.channelCount)
      let pointer = data.assumingMemoryBound(to: Float.self)
      var out = [Float](repeating: 0, count: frames * AudioMixer.channelCount)
      for frame in 0..<frames {
        for channel in 0..<AudioMixer.channelCount {
          out[frame * AudioMixer.channelCount + channel] =
            pointer[frame * channels + min(channel, channels - 1)]
        }
      }
      return out
    }
    guard let channelData = buffer.floatChannelData else { return nil }
    let channels = Int(buffer.format.channelCount)
    var out = [Float](repeating: 0, count: frames * AudioMixer.channelCount)
    for frame in 0..<frames {
      for channel in 0..<AudioMixer.channelCount {
        out[frame * AudioMixer.channelCount + channel] =
          channelData[min(channel, channels - 1)][frame]
      }
    }
    return out
  }

  private func makeSampleBuffer(interleaved: [Float], presentation: CMTime)
    -> CMSampleBuffer?
  {
    if formatDescription == nil {
      var asbd = outputFormat.streamDescription.pointee
      var created: CMAudioFormatDescription?
      let status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &created)
      guard status == noErr else { return nil }
      formatDescription = created
    }
    guard let formatDescription else { return nil }

    let frames = interleaved.count / AudioMixer.channelCount
    let byteCount = interleaved.count * MemoryLayout<Float>.size
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: byteCount,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: byteCount,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard status == noErr, let blockBuffer else { return nil }

    status = interleaved.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(
        with: raw.baseAddress!,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: byteCount)
    }
    guard status == noErr else { return nil }

    var sampleBuffer: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: frames,
      presentationTimeStamp: presentation,
      packetDescriptions: nil,
      sampleBufferOut: &sampleBuffer)
    guard status == noErr else { return nil }
    return sampleBuffer
  }
}
