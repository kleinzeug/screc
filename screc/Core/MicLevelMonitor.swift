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
        var id: String // AVCaptureDevice.uniqueID, == the CoreAudio UID
        var name: String
        var isBluetooth: Bool
    }

    static func all() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone],
                                         mediaType: .audio,
                                         position: .unspecified)
            .devices
            .map { Device(id: $0.uniqueID, name: $0.localizedName,
                          isBluetooth: AudioDevices.isBluetooth(uid: $0.uniqueID)) }
    }

    /// The device a given selection resolves to ("" = the system default).
    static func resolved(_ selection: String) -> Device? {
        let devices = all()
        if !selection.isEmpty {
            return devices.first { $0.id == selection }
        }
        guard let uid = AudioDevices.defaultInputUID() else { return nil }
        return devices.first { $0.id == uid }
    }

    static func firstNonBluetooth() -> Device? {
        all().first { !$0.isBluetooth }
    }
}

/// CoreAudio facts AVFoundation does not expose — chiefly whether a device is
/// Bluetooth, which decides whether opening its microphone will drag playback
/// down to hands-free (telephone) quality.
enum AudioDevices {
    static func isBluetooth(uid: String) -> Bool {
        guard let transport = transport(ofUID: uid) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// True when the microphone about to be opened belongs to the same
    /// Bluetooth device currently playing audio — the case where enabling the
    /// mic audibly wrecks what the user is listening to.
    static func micWouldDegradePlayback(selection: String) -> Bool {
        let inputUID = selection.isEmpty ? defaultInputUID() : selection
        guard let inputUID, isBluetooth(uid: inputUID),
              let outputUID = defaultOutputUID()
        else { return false }
        // The same headset reports different UIDs per direction
        // ("<address>:input" vs "<address>:output"), so compare the device
        // behind them, not the strings.
        return hardwareIdentity(inputUID) == hardwareIdentity(outputUID)
    }

    /// Strips CoreAudio's per-direction suffix so the two sides of one device
    /// compare equal.
    private static func hardwareIdentity(_ uid: String) -> String {
        for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
            return String(uid.dropLast(suffix.count))
        }
        return uid
    }

    static func defaultInputUID() -> String? {
        uid(of: defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
    }

    static func defaultOutputUID() -> String? {
        uid(of: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &device)
        return device
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? uid as String : nil
    }

    private static func transport(ofUID uid: String) -> UInt32? {
        guard let device = CoreAudioDeviceLookup.deviceID(forUID: uid) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
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
