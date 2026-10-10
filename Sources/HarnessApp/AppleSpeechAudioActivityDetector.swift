@preconcurrency import AVFAudio
import Foundation
import HarnessCore

@available(macOS 26.0, *)
final class AppleSpeechAudioActivityDetector: @unchecked Sendable {
    private var noiseFloor: Float = 0.003
    private var voicedDuration = 0.0
    private var quietDuration = 0.0
    private var isSpeaking = false

    func receive(_ buffer: AVAudioPCMBuffer) -> VoiceConversationActivity? {
        guard let level = rootMeanSquare(of: buffer),
              buffer.format.sampleRate > 0 else { return nil }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate

        if isSpeaking {
            let quietThreshold = max(0.008, noiseFloor * 1.8)
            if level < quietThreshold {
                quietDuration += duration
                if quietDuration >= 0.65 {
                    isSpeaking = false
                    voicedDuration = 0
                    quietDuration = 0
                    return .speechEnded
                }
            } else {
                quietDuration = 0
            }
            return nil
        }

        let voiceThreshold = max(0.012, noiseFloor * 2.8)
        if level >= voiceThreshold {
            voicedDuration += duration
            if voicedDuration >= 0.12 {
                isSpeaking = true
                voicedDuration = 0
                quietDuration = 0
                return .speechStarted
            }
        } else {
            voicedDuration = 0
            noiseFloor = min(0.02, (noiseFloor * 0.96) + (level * 0.04))
        }
        return nil
    }

    private func rootMeanSquare(of buffer: AVAudioPCMBuffer) -> Float? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }
        let stride = Int(buffer.stride)
        var squareSum: Double = 0

        if let channels = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let sample = Double(samples[frame * stride])
                    squareSum += sample * sample
                }
            }
        } else if let channels = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let sample = Double(samples[frame * stride]) / Double(Int16.max)
                    squareSum += sample * sample
                }
            }
        } else if let channels = buffer.int32ChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let sample = Double(samples[frame * stride]) / Double(Int32.max)
                    squareSum += sample * sample
                }
            }
        } else {
            return nil
        }
        return Float(sqrt(squareSum / Double(frameCount * channelCount)))
    }
}
