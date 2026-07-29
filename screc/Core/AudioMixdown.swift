import AVFoundation

/// Post-stop mix-down for microphone recordings. During capture the engine
/// writes the mic as a SEPARATE audio track (mixing two live streams in real
/// time is where recorders grow subtle drift bugs; a second track is
/// loss-free and cheap). Players disagree about multiple audio tracks —
/// browsers typically play only the first — so before the file is surfaced,
/// this rewrites it: video copied compressed (passthrough, no quality loss),
/// all audio tracks decoded and mixed by AVAssetReaderAudioMixOutput (the
/// OS mixer) into one AAC track. Roughly IO-bound — a few seconds per
/// recorded minute.
enum AudioMixdown {
    /// `gains` maps each audio track (in track order) to its mix volume;
    /// tracks beyond the array get 1.0.
    static func mix(input: URL, output: URL, gains: [Float],
                    audioBitrateKbps: Int, channels: Int) async throws {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ScrecError.writerFailed("mix-down: no video track")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ScrecError.writerFailed("mix-down: no audio tracks")
        }
        let videoFormat = try await videoTrack.load(.formatDescriptions).first

        let reader = try AVAssetReader(asset: asset)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioTracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(index < gains.count ? gains[index] : 1.0, at: .zero)
            return parameters
        }
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks,
                                                      audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        audioOutput.audioMix = audioMix
        reader.add(audioOutput)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: max(audioBitrateKbps, 64) * 1000,
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard reader.startReading() else {
            throw ScrecError.writerFailed(reader.error?.localizedDescription
                                          ?? "mix-down: could not read")
        }
        guard writer.startWriting() else {
            throw ScrecError.writerFailed(writer.error?.localizedDescription
                                          ?? "mix-down: could not write")
        }
        writer.startSession(atSourceTime: .zero)

        // Built OUTSIDE the async lets: their right-hand expressions run in
        // the child task, which must only capture the Sendable pumps.
        let videoPump = Pump(output: videoOutput, input: videoInput, label: "mixdown.video")
        let audioPump = Pump(output: audioOutput, input: audioInput, label: "mixdown.audio")
        async let videoDone: Void = drain(videoPump)
        async let audioDone: Void = drain(audioPump)
        _ = await (videoDone, audioDone)

        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw ScrecError.writerFailed(reader.error?.localizedDescription
                                          ?? "mix-down: decode failed")
        }
        await writer.finishWriting()
        if writer.status == .failed {
            try? FileManager.default.removeItem(at: output)
            throw ScrecError.writerFailed(writer.error?.localizedDescription
                                          ?? "mix-down: encode failed")
        }
    }

    /// @unchecked Sendable by discipline: for the duration of the pump each
    /// reader-output/writer-input pair is touched ONLY from its own serial
    /// queue inside `drain`.
    private struct Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let label: String
    }

    private static func drain(_ pump: Pump) async {
        let queue = DispatchQueue(label: "app.screc.\(pump.label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pump.input.requestMediaDataWhenReady(on: queue) {
                while pump.input.isReadyForMoreMediaData {
                    guard let sample = pump.output.copyNextSampleBuffer() else {
                        pump.input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    pump.input.append(sample)
                }
            }
        }
    }
}
