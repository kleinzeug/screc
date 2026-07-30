import AVFoundation
import CoreAudio
import os

/// Live input-level meter for the Settings microphone section. Runs an
/// AVAudioEngine tap while the section is visible and enabled — completely
/// separate from the recording pipeline (which captures the mic through
/// ScreenCaptureKit). Requires the microphone permission; `start` is a no-op
/// without it.
@MainActor
final class MicLevelMonitor: ObservableObject {
    /// Smoothed 0…1 display level (fast attack, slow decay).
    @Published private(set) var level: Double = 0
    /// False when the engine could not start (no device, permission missing).
    @Published private(set) var running = false

    private var engine: AVAudioEngine?
    private var displayTimer: Timer?
    /// Written by the realtime audio thread, read on the main actor at
    /// display rate. A lock (not a Task hop per buffer) keeps allocation and
    /// actor machinery off the audio thread.
    private let latestRMS = OSAllocatedUnfairLock(initialState: 0.0)

    func start(deviceUID: String) {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty,
           var deviceID = CoreAudioDeviceLookup.deviceID(forUID: deviceUID),
           let audioUnit = input.audioUnit {
            // AVAudioEngine follows the system default; a specific device is
            // set on the underlying input AudioUnit.
            let status = AudioUnitSetProperty(audioUnit,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0,
                                              &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                Log.app.error("mic meter: could not select device \(deviceUID) (\(status))")
            }
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        // MUST be explicitly @Sendable: this class is @MainActor, so an
        // inferred closure would inherit that isolation, and Swift emits an
        // executor assertion at its prologue — which traps the instant the
        // audio render thread delivers the first buffer. Capture only the
        // lock, never self.
        let sink = latestRMS
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            let rms = Self.rms(buffer)
            sink.withLock { $0 = rms }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)

        do {
            try engine.start()
            self.engine = engine
            running = true
            startDisplayTimer()
        } catch {
            Log.app.error("mic meter failed to start: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
        }
    }

    /// Samples the shared level at display rate — fast attack, slow decay.
    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0,
                                            repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rms = self.latestRMS.withLock { $0 }
                // Perceptual-ish scaling; decay keeps the bar readable.
                let target = min(1, pow(rms * 4, 0.6))
                self.level = max(target, self.level * 0.82)
            }
        }
    }

    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        latestRMS.withLock { $0 = 0 }
        running = false
        level = 0
    }

    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = data[0]
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        return Double(sqrt(sum / Float(buffer.frameLength)))
    }
}

/// All microphones visible to the system, for the Settings device picker.
enum MicDevices {
    struct Device: Identifiable, Equatable {
        var id: String // AVCaptureDevice.uniqueID
        var name: String
    }

    static func all() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone],
                                         mediaType: .audio,
                                         position: .unspecified)
            .devices
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }
}

enum CoreAudioDeviceLookup {
    /// AVCaptureDevice.uniqueID ↔ CoreAudio UID share the same string for
    /// audio devices; translate it to the AudioDeviceID the AudioUnit needs.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var uidRef = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uidRef) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address,
                                       UInt32(MemoryLayout<CFString>.size),
                                       uidPointer,
                                       &size,
                                       &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
