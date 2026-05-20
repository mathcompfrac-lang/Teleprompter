import AVFoundation
import Speech
import SwiftUI

/// 麦克风 + 语音识别权限管理
enum AudioPermission {
    enum Status {
        case notDetermined
        case granted
        case denied
        case restricted
    }

    static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    static var speechStatus: Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    static func request() async -> Bool {
        // 同时请求麦克风和语音识别权限
        let micGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        return micGranted && speechGranted
    }
}

/// 麦克风 + 语音识别权限请求视图
struct AudioPermissionView: View {
    var onGranted: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("需要麦克风和语音识别权限")
                .font(.title2)
                .bold()

            Text("悬浮提词器需要麦克风权限来拾取您的声音，\n并需要语音识别权限来解析您朗读的内容，\n实现精确逐字高亮追踪。\n我们不会录制或保存任何音频。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)

            Button(action: {
                Task {
                    let granted = await AudioPermission.request()
                    if granted {
                        onGranted()
                    }
                }
            }) {
                Text("允许访问")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)

            if AudioPermission.status == .denied || AudioPermission.speechStatus == .denied {
                Text("权限已被拒绝，请前往 设置 > 悬浮提词器 开启麦克风和语音识别权限")
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding()
    }
}
