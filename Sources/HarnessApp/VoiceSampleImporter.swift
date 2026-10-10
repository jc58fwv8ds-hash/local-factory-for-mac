@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import HarnessCore

struct VoiceSampleInspection: Equatable, Sendable {
    let displayName: String
    let durationMilliseconds: Int
    let byteCount: Int
    let sampleRate: Double
    let channelCount: Int

    var durationLabel: String {
        String(format: "%.1f秒", Double(durationMilliseconds) / 1_000)
    }
}

struct ImportedVoiceSample: Sendable {
    let inspection: VoiceSampleInspection
    let normalizedWAVData: Data
}

enum VoiceSampleImportError: LocalizedError, Equatable {
    case unsupportedFormat
    case unreadable
    case tooLarge
    case durationOutOfRange
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "MP3ファイルを選んでください。"
        case .unreadable:
            "この音声を読み込めませんでした。別のMP3を試してください。"
        case .tooLarge:
            "音声ファイルは50MB以内にしてください。"
        case .durationOutOfRange:
            "声の見本は3〜30秒にしてください。"
        case .conversionFailed:
            "音声を声モデル用の形式へ整えられませんでした。"
        }
    }
}

protocol VoiceSampleImporting: Sendable {
    func inspectMP3(at url: URL) async throws -> VoiceSampleInspection
    func importMP3(at url: URL) async throws -> ImportedVoiceSample
}

actor SystemVoiceSampleImporter: VoiceSampleImporting {
    static let maximumByteCount = 50 * 1_024 * 1_024
    static let outputSampleRate = 24_000.0

    func inspectMP3(at url: URL) async throws -> VoiceSampleInspection {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try await inspectAccessibleMP3(at: url)
    }

    func importMP3(at url: URL) async throws -> ImportedVoiceSample {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let inspection = try await inspectAccessibleMP3(at: url)
        let data = try await normalizedWAVData(from: url)
        return ImportedVoiceSample(inspection: inspection, normalizedWAVData: data)
    }

    private func inspectAccessibleMP3(at url: URL) async throws -> VoiceSampleInspection {
        guard url.pathExtension.caseInsensitiveCompare("mp3") == .orderedSame else {
            throw VoiceSampleImportError.unsupportedFormat
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let byteCount = values.fileSize, byteCount > 0 else {
            throw VoiceSampleImportError.unreadable
        }
        guard byteCount <= Self.maximumByteCount else {
            throw VoiceSampleImportError.tooLarge
        }
        let asset = AVURLAsset(url: url)
        let durationTime: CMTime
        let tracks: [AVAssetTrack]
        do {
            durationTime = try await asset.load(.duration)
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw VoiceSampleImportError.unreadable
        }
        guard let track = tracks.first else {
            throw VoiceSampleImportError.unreadable
        }
        let seconds = CMTimeGetSeconds(durationTime)
        guard seconds.isFinite, seconds > 0 else {
            throw VoiceSampleImportError.unreadable
        }
        let duration = Int((seconds * 1_000).rounded())
        guard duration >= VoiceCapsulePolicy.minimumReferenceDurationMilliseconds,
              duration <= VoiceCapsulePolicy.maximumReferenceDurationMilliseconds else {
            throw VoiceSampleImportError.durationOutOfRange
        }
        let format = try await audioFormat(for: track)
        return VoiceSampleInspection(
            displayName: url.lastPathComponent,
            durationMilliseconds: duration,
            byteCount: byteCount,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
    }

    func normalizedWAVData(from url: URL) async throws -> Data {
        var audioFile: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &audioFile)
        guard openStatus == noErr,
              let audioFile else {
            throw VoiceSampleImportError.conversionFailed
        }
        defer { ExtAudioFileDispose(audioFile) }
        var sourceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(
            audioFile,
            kExtAudioFileProperty_FileDataFormat,
            &formatSize,
            &sourceFormat
        ) == noErr,
              sourceFormat.mSampleRate > 0,
              sourceFormat.mChannelsPerFrame > 0,
              sourceFormat.mChannelsPerFrame <= 2 else {
            throw VoiceSampleImportError.conversionFailed
        }
        let channelCount = Int(sourceFormat.mChannelsPerFrame)
        let bytesPerFrame = UInt32(MemoryLayout<Int16>.size * channelCount)
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sourceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: sourceFormat.mChannelsPerFrame,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let clientStatus = ExtAudioFileSetProperty(
            audioFile,
            kExtAudioFileProperty_ClientDataFormat,
            formatSize,
            &clientFormat
        )
        guard clientStatus == noErr else {
            throw VoiceSampleImportError.conversionFailed
        }

        var pcmData = Data()
        let chunkFrameCount: UInt32 = 4_096
        var samples = [Int16](
            repeating: 0,
            count: Int(chunkFrameCount) * channelCount
        )
        let maximumSeconds = Double(
            VoiceCapsulePolicy.maximumReferenceDurationMilliseconds
        ) / 1_000
        let maximumFrames = Int(sourceFormat.mSampleRate * maximumSeconds)
        let maximumBytes = maximumFrames * Int(bytesPerFrame)
        while true {
            var frames = chunkFrameCount
            let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: sourceFormat.mChannelsPerFrame,
                        mDataByteSize: UInt32(bytes.count),
                        mData: bytes.baseAddress
                    )
                )
                return ExtAudioFileRead(audioFile, &frames, &bufferList)
            }
            guard status == noErr else {
                throw VoiceSampleImportError.conversionFailed
            }
            guard frames > 0 else { break }
            let byteCount = Int(frames * bytesPerFrame)
            samples.withUnsafeBytes { bytes in
                pcmData.append(contentsOf: bytes.bindMemory(to: UInt8.self).prefix(byteCount))
            }
            guard pcmData.count <= maximumBytes else {
                throw VoiceSampleImportError.durationOutOfRange
            }
        }
        guard !pcmData.isEmpty else { throw VoiceSampleImportError.conversionFailed }
        return try convertTo24kMonoWAV(
            pcmData,
            sampleRate: sourceFormat.mSampleRate,
            channelCount: channelCount
        )
    }

    private func convertTo24kMonoWAV(
        _ pcmData: Data,
        sampleRate: Double,
        channelCount: Int
    ) throws -> Data {
        let bytesPerFrame = MemoryLayout<Int16>.size * channelCount
        guard bytesPerFrame > 0, pcmData.count.isMultiple(of: bytesPerFrame),
              let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: true
              ), let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.outputSampleRate,
                channels: 1,
                interleaved: false
              ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw VoiceSampleImportError.conversionFailed
        }
        let inputFrames = pcmData.count / bytesPerFrame
        guard inputFrames <= Int(UInt32.max),
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(inputFrames)
              ) else {
            throw VoiceSampleImportError.conversionFailed
        }
        inputBuffer.frameLength = AVAudioFrameCount(inputFrames)
        let buffers = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
        guard let destination = buffers.first?.mData else {
            throw VoiceSampleImportError.conversionFailed
        }
        pcmData.copyBytes(to: UnsafeMutableRawBufferPointer(
            start: destination,
            count: pcmData.count
        ))
        let outputFrames = ceil(
            Double(inputFrames) * Self.outputSampleRate / sampleRate
        ) + 64
        guard outputFrames <= Double(UInt32.max),
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(outputFrames)
              ) else {
            throw VoiceSampleImportError.conversionFailed
        }
        let inputBox = VoiceConverterInputBox(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, state in
            if inputBox.wasSupplied {
                state.pointee = .endOfStream
                return nil
            }
            inputBox.wasSupplied = true
            state.pointee = .haveData
            return inputBox.buffer
        }
        guard status != .error, conversionError == nil,
              outputBuffer.frameLength > 0,
              let samples = outputBuffer.floatChannelData?[0] else {
            throw VoiceSampleImportError.conversionFailed
        }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Float>.size
        return try makeFloatWAV(pcmData: Data(bytes: samples, count: byteCount))
    }

    private func audioFormat(for track: AVAssetTrack) async throws -> (
        sampleRate: Double,
        channelCount: Int
    ) {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              format.pointee.mSampleRate > 0,
              format.pointee.mChannelsPerFrame > 0 else {
            throw VoiceSampleImportError.unreadable
        }
        return (format.pointee.mSampleRate, Int(format.pointee.mChannelsPerFrame))
    }

    private func makeFloatWAV(pcmData: Data) throws -> Data {
        guard pcmData.count <= Int(UInt32.max) - 36 else {
            throw VoiceSampleImportError.conversionFailed
        }
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36 + pcmData.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(3), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(Self.outputSampleRate), to: &data)
        appendLittleEndian(UInt32(Self.outputSampleRate * 4), to: &data)
        appendLittleEndian(UInt16(4), to: &data)
        appendLittleEndian(UInt16(32), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcmData.count), to: &data)
        data.append(pcmData)
        return data
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private final class VoiceConverterInputBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
