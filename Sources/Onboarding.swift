// 首次啟動引導：麥克風 → 輔助使用 → Fn 鍵設定 → OpenRouter 金鑰 → 完成。
// 每秒檢查一次權限狀態，使用者在系統設定打開後畫面自動打勾。

import ApplicationServices
import AVFoundation
import SwiftUI

final class OnboardingModel: ObservableObject {
  @Published var mic = AVCaptureDevice.authorizationStatus(for: .audio)
  @Published var trusted = AXIsProcessTrusted()
  @Published var hasKey = apiKey() != nil
  @Published var keyInput = ""
  @Published var keyStatus = ""
  @Published var testing = false
  private var timer: Timer?

  init() {
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
  }
  deinit { timer?.invalidate() }

  func refresh() {
    mic = AVCaptureDevice.authorizationStatus(for: .audio)
    trusted = AXIsProcessTrusted()
    hasKey = apiKey() != nil
  }

  var micOK: Bool { mic == .authorized }
  var allOK: Bool { micOK && trusted && hasKey }

  func requestMic() {
    if mic == .notDetermined {
      AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
    } else {
      // 之前拒絕過：只能到系統設定打開
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
  }

  func openAccessibility() {
    // 讓 HAUS Type 出現在清單裡（系統會跳一次詢問），再打開設定頁
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }

  func openKeyboard() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
  }

  func saveKey() {
    let k = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !k.isEmpty else { keyStatus = "請先貼上金鑰"; return }
    testing = true
    keyStatus = "測試中…"
    Task {
      let err = await testAPIKey(k)
      await MainActor.run {
        self.testing = false
        if let err { self.keyStatus = err; return }
        self.keyStatus = saveAPIKey(k) ? "已存好" : "存進鑰匙圈失敗"
        self.keyInput = ""
        self.refresh()
      }
    }
  }
}

struct OnboardingView: View {
  @StateObject var m = OnboardingModel()
  var onFinish: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
        VStack(alignment: .leading, spacing: 4) {
          Text("歡迎使用 HAUS Type").font(.title2).bold()
          Text("按一下快捷鍵講話，再按一下，整理好的文字就會打進游標所在的地方。").foregroundStyle(.secondary)
        }
      }
      Divider()
      step(1, "麥克風", done: m.micOK, detail: "聽你講話用。") {
        Button(m.mic == .denied ? "到系統設定打開" : "允許麥克風") { m.requestMic() }
      }
      step(2, "輔助使用", done: m.trusted, detail: "偵測快捷鍵、把文字貼進輸入框用。在清單裡打開 HAUS Type。") {
        Button("開啟設定") { m.openAccessibility() }
      }
      step(3, "Fn 鍵", done: nil, detail: "要用 Fn（🌐）鍵，請把「按下 🌐 鍵時」改成「不做任何事」。用滑鼠中鍵或自訂組合鍵可以略過。") {
        Button("開啟鍵盤設定") { m.openKeyboard() }
      }
      VStack(alignment: .leading, spacing: 8) {
        stepTitle(4, "OpenRouter 金鑰", done: m.hasKey)
        Text("轉寫與整理透過 OpenRouter 呼叫 AI 模型，費用由你的帳戶支付。").font(.callout).foregroundStyle(.secondary)
        if !m.hasKey {
          HStack {
            SecureField("貼上 sk-or- 開頭的金鑰", text: $m.keyInput)
            Button(m.testing ? "測試中…" : "測試並儲存") { m.saveKey() }.disabled(m.testing)
          }
          HStack {
            Link("到 openrouter.ai 申請金鑰", destination: URL(string: "https://openrouter.ai/settings/keys")!)
            if !m.keyStatus.isEmpty { Text(m.keyStatus).font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
      Spacer()
      HStack {
        Text(m.allOK ? "都設定好了。按一下 Fn 講一句話試試看。" : "完成上面的步驟後就能開始用。")
          .foregroundStyle(.secondary)
        Spacer()
        Button("完成") { onFinish() }.keyboardShortcut(.defaultAction).disabled(!m.allOK)
      }
    }
    .padding(24)
    .frame(width: 560, height: 520)
  }

  func stepTitle(_ n: Int, _ title: String, done: Bool?) -> some View {
    HStack(spacing: 8) {
      Image(systemName: done == true ? "checkmark.circle.fill" : done == false ? "\(n).circle" : "info.circle")
        .foregroundStyle(done == true ? Color.green : Color.secondary)
        .font(.title3)
      Text(title).font(.headline)
    }
  }

  func step<B: View>(_ n: Int, _ title: String, done: Bool?, detail: String, @ViewBuilder button: () -> B) -> some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        stepTitle(n, title, done: done)
        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      if done != true { button() }
    }
  }
}
