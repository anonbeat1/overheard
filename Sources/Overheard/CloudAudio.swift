import AVFoundation
import Foundation

/// The local WAV format, kept so a download is decoded back to the same kind of file the app wrote.
struct CloudAudioFormat: Codable, Equatable, Sendable {
    let sampleRate: Double
    let channels: Int
    let bits: Int
    let float: Bool
}

/// How audio is stored in the cloud. The Mac always keeps WAV, so playback, transcription and
/// export read the same files as before; only the uploaded copy is compressed.
enum CloudAudioEncoding: String, Codable, Sendable {
    /// Apple Lossless: about 4× smaller, decodes to exactly the original samples.
    case alac
    /// Speech-quality AAC: about 14× smaller, not identical to the original.
    case aac
}

enum CloudAudio {
    static func format(of wav: URL) throws -> CloudAudioFormat {
        let file = try AVAudioFile(forReading: wav)
        let settings = file.fileFormat.settings
        return CloudAudioFormat(sampleRate: file.fileFormat.sampleRate, channels: Int(file.fileFormat.channelCount),
                                bits: settings[AVLinearPCMBitDepthKey] as? Int ?? 16,
                                float: settings[AVLinearPCMIsFloatKey] as? Bool ?? false)
    }

    /// Enough for clear speech at each sample rate; AAC-LC rejects higher rates at low sample rates.
    static func bitRate(_ format: CloudAudioFormat) -> Int {
        let perChannel = format.sampleRate >= 32000 ? 64_000 : 32_000
        return format.channels > 1 ? perChannel * 3 / 2 : perChannel
    }

    /// Encodes `wav` to an .m4a at `destination`. Streams in bounded buffers.
    @discardableResult
    static func encode(_ wav: URL, to destination: URL, as encoding: CloudAudioEncoding) throws -> CloudAudioFormat {
        let format = try format(of: wav)
        switch encoding {
        case .alac:
            // Lossless only for integer PCM: a float WAV is uploaded as it is instead.
            // ≤ 24 bits: the sample-by-sample proof compares in float32, exact only up to 24-bit integers.
            guard !format.float, [16, 20, 24].contains(format.bits), (1...8).contains(format.channels) else {
                throw CloudError.message(String(localized: "Formato audio non comprimibile"))
            }
            try copy(from: wav, to: destination, settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channels,
                AVEncoderBitDepthHintKey: format.bits,
            ])
        case .aac:
            guard (8000...48000).contains(format.sampleRate), (1...2).contains(format.channels) else {
                throw CloudError.message(String(localized: "Formato audio non comprimibile"))
            }
            try copy(from: wav, to: destination, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channels,
                AVEncoderBitRateKey: bitRate(format),
            ])
        }
        return format
    }

    /// True when both files hold exactly the same samples (headers may differ).
    static func samplesEqual(_ a: URL, _ b: URL) throws -> Bool {
        let x = try AVAudioFile(forReading: a), y = try AVAudioFile(forReading: b)
        let channels = Int(x.processingFormat.channelCount)
        guard x.length == y.length, x.processingFormat == y.processingFormat,
              x.processingFormat.commonFormat == .pcmFormatFloat32, !x.processingFormat.isInterleaved,
              let bx = AVAudioPCMBuffer(pcmFormat: x.processingFormat, frameCapacity: 32768),
              let by = AVAudioPCMBuffer(pcmFormat: y.processingFormat, frameCapacity: 32768) else { return false }
        while x.framePosition < x.length {
            try x.read(into: bx); try y.read(into: by)
            guard bx.frameLength == by.frameLength, bx.frameLength > 0 else { return false }
            for channel in 0..<channels where memcmp(bx.floatChannelData![channel], by.floatChannelData![channel],
                                                     Int(bx.frameLength) * MemoryLayout<Float>.size) != 0 { return false }
        }
        return true
    }

    /// Decodes a downloaded .m4a back to a WAV in the original format.
    static func decode(_ m4a: URL, to destination: URL, format: CloudAudioFormat) throws {
        try copy(from: m4a, to: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channels,
            AVLinearPCMBitDepthKey: format.bits,
            AVLinearPCMIsFloatKey: format.float,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
    }

    /// The output file type comes from the destination's extension (.m4a or .wav).
    /// The output is closed when this function returns, before anyone hashes or moves it.
    private static func copy(from source: URL, to destination: URL, settings: [String: Any]) throws {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32768) else {
            throw CloudError.message(String(localized: "Formato audio non comprimibile"))
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}

/// Encoded copies are cached by the SHA-256 of the WAV they come from, so a retried or resumed
/// upload sends the very same bytes instead of a fresh encode. Entries go once uploaded, or after a week.
struct CloudAudioCache: Sendable {
    let directory: URL
    static var standard: CloudAudioCache {
        CloudAudioCache(directory: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/Overheard/cloud-audio"))
    }
    func url(for source: CloudFileVersion, name: String, encoding: CloudAudioEncoding) -> URL {
        directory.appendingPathComponent("\(source.sha256)-\((name as NSString).deletingPathExtension)-\(encoding.rawValue).m4a")
    }
    /// Returns the cached encoding of `wav`, creating it when missing. A lossless encoding is decoded
    /// once and compared sample by sample with the WAV before it is ever used: only a copy proven to
    /// rebuild the original can later replace it.
    func encoded(_ wav: URL, source: CloudFileVersion, name: String, as encoding: CloudAudioEncoding) throws -> (URL, CloudAudioFormat) {
        let target = url(for: source, name: name, encoding: encoding)
        let format = try CloudAudio.format(of: wav)
        if CloudFiles.exists(target) { return (target, format) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Encode beside the cache entry, then move: an interrupted encode never looks finished.
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).m4a")
        let check = directory.appendingPathComponent(".\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: partial); try? FileManager.default.removeItem(at: check) }
        try CloudAudio.encode(wav, to: partial, as: encoding)
        if encoding == .alac {
            try CloudAudio.decode(partial, to: check, format: format)
            guard try CloudAudio.samplesEqual(wav, check) else {
                throw CloudError.message(String(localized: "La compressione senza perdita non ricostruisce l'originale"))
            }
        }
        try FileManager.default.moveItem(at: partial, to: target)
        return (target, format)
    }
    func remove(_ source: CloudFileVersion, name: String, encoding: CloudAudioEncoding) {
        try? FileManager.default.removeItem(at: url(for: source, name: name, encoding: encoding))
    }
    func purge(olderThan age: TimeInterval = 7 * 86400) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            < Date().addingTimeInterval(-age) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
