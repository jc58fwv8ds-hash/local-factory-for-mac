import AVFoundation
import Foundation

enum VoiceMicrophoneAuthorization: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unavailable

    var conversationHelp: String {
        switch self {
        case .authorized:
            "ボイスモードを開始。話した音声はMac内で文字になり、録音は保存されません"
        case .notDetermined:
            "ボイスモードを開始。初回だけmacOSがマイク使用を確認します。録音は保存されません"
        case .denied:
            "マイクがオフです。システム設定の「プライバシーとセキュリティ」で許可できます"
        case .restricted:
            "このMacではマイクの使用が制限されています"
        case .unavailable:
            "このMacでは端末内音声を利用できません"
        }
    }

    var pushToTalkHelp: String {
        switch self {
        case .authorized:
            "押している間だけ話す。離すと編集できる下書きになります"
        case .notDetermined:
            "押して話す。初回だけmacOSがマイク使用を確認します。録音は保存されません"
        case .denied:
            "マイクがオフです。システム設定の「プライバシーとセキュリティ」で許可できます"
        case .restricted:
            "このMacではマイクの使用が制限されています"
        case .unavailable:
            "このMacでは端末内音声を利用できません"
        }
    }

    var failure: VoiceTranscriptionError? {
        switch self {
        case .authorized:
            nil
        case .notDetermined, .denied:
            .microphoneDenied
        case .restricted:
            .microphoneRestricted
        case .unavailable:
            .microphoneAuthorizationUnavailable
        }
    }
}

@MainActor
protocol VoiceMicrophoneAuthorizing: AnyObject {
    var authorization: VoiceMicrophoneAuthorization { get }

    func requestAccess() async -> Bool
}

@MainActor
final class SystemVoiceMicrophoneAuthorizer: VoiceMicrophoneAuthorizing {
    var authorization: VoiceMicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            .authorized
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .unavailable
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
