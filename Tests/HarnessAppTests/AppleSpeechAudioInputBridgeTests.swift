@preconcurrency import AVFAudio
import Foundation
import Speech
import Testing
@testable import HarnessApp

@MainActor
@Suite(.serialized)
struct AppleSpeechAudioInputBridgeTests {
    @Test func localAudioActivityDetectsSpeechAndFollowingSilence() throws {
        guard #available(macOS 26.0, *) else { return }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let detector = AppleSpeechAudioActivityDetector()
        let voiced = try audioBuffer(format: format, value: 0.08)
        let quiet = try audioBuffer(format: format, value: 0)

        #expect(detector.receive(voiced) == nil)
        #expect(detector.receive(voiced) == .speechStarted)
        for _ in 0..<7 {
            #expect(detector.receive(quiet) == nil)
        }
        #expect(detector.receive(quiet) == .speechEnded)
    }

    @Test(.disabled("CoreAudio tap callbacks require a live audio service; this host's swift-testing-helper loses its XPC connection. Run in the macOS app test host."))
    func audioTapRunsOnItsRealtimeQueueWithoutMainActorIsolation() async throws {
        guard #available(macOS 26.0, *) else { return }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let converter = try #require(AppleSpeechAudioConverter(
            from: format,
            to: format
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 256
        ))
        buffer.frameLength = 256
        let streamPair = AsyncStream<AnalyzerInput>.makeStream()
        let bridge = AppleSpeechAudioInputBridge(
            converter: converter,
            continuation: streamPair.continuation,
            onFailure: { _ in }
        )
        let invocation = AudioTapInvocation(
            block: bridge.makeTapBlock(),
            buffer: buffer
        )

        await withCheckedContinuation { continuation in
            DispatchQueue(label: "harness.tests.audio-tap").async {
                invocation.call()
                continuation.resume()
            }
        }
        streamPair.continuation.finish()
        var iterator = streamPair.stream.makeAsyncIterator()

        #expect(await iterator.next() != nil)
    }

    private func audioBuffer(
        format: AVAudioFormat,
        value: Float
    ) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_096
        ))
        buffer.frameLength = 4_096
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = value
        }
        return buffer
    }
}

@available(macOS 26.0, *)
private final class AudioTapInvocation: @unchecked Sendable {
    private let block: AVAudioNodeTapBlock
    private let buffer: AVAudioPCMBuffer

    init(block: @escaping AVAudioNodeTapBlock, buffer: AVAudioPCMBuffer) {
        self.block = block
        self.buffer = buffer
    }

    func call() {
        // The zeroed convenience initializer asks the CoreAudio XPC service for a
        // live clock and can terminate swift-testing-helper on headless CI. A real
        // monotonic host timestamp keeps this callback deterministic and avoids
        // touching the audio service.
        block(buffer, AVAudioTime(hostTime: mach_absolute_time()))
    }
}
