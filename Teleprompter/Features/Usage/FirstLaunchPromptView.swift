import SwiftUI
import SwiftData
import Combine

/// 首次启动联网提示视图
struct FirstLaunchPromptView: View {
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            
            Text("需要联网才能使用语音功能")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("请确保手机已连接WiFi或移动网络，以便使用语音识别功能。")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("我知道了") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .background(Color.teleprompterBackground)
        .cornerRadius(20)
    }
}

// MARK: - 预览

#Preview {
    FirstLaunchPromptView(onDismiss: {})
}