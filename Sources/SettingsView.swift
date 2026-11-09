// YuVoice 設定視窗（SwiftUI）：一般、金鑰與模型、專有名詞、實驗功能、關於。
// 改動立刻寫進 config.json，並發出 configChanged 通知讓主程式重新套用（例如快捷鍵）。

import AVFoundation
import ServiceManagement
import SwiftUI

extension Notification.Name {
  static let yuConfigChanged = Notification.Name("YuVoiceConfigChanged")
}

let transcribeModels: [(String, String)] = [
  ("openai/gpt-transcribe", "GPT Transcribe（建議，準又快）"),
  ("openai/gpt-4o-mini-transcribe", "GPT-4o mini Transcribe"),
  ("mistralai/voxtral-mini-transcribe", "Voxtral mini（Mistral）"),
]
let cleanupModels: [(String, String)] = [
  ("anthropic/claude-haiku-5.5", "Claude Haiku 5.5（建議，約 1 秒）"),
  ("anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5（較聰明、較慢）"),
]

// 把 keyCode 轉回名稱，給自訂快捷鍵顯示用
let keyNames: [Int64: String] = Dictionary(uniqueKeysWithValues: keyCodes.map { ($0.value, $0.key) })

func comboLabel(_ spec: String) -> String {
  spec.split(separator: "+").map { part -> String in
    switch part {
    case "ctrl": return "⌃"
    case "cmd": return "⌘"
    case "shift": return "⇧"
    case "opt": return "⌥"
    case "space": return "Space"
    default: return part.uppercased()
    }
  }.joined()
}

final class SettingsModel: ObservableObject {
  @Published var useFn: Bool
  @Published var useMouse: Bool
  @Published var combo: String
  @Published var recording = false
  @Published var sounds: Bool
  @Published var speculative: Bool
  @Published var cleanup: Bool
  @Published var transcribeModel: String
  @Published var cleanupModel: String
  @Published var typelessSync: Bool
  @Published var login: Bool
  @Published var keyInput = ""
  @Published var keyStatus = ""
  @Published var keyTesting = false
  @Published var hasKey: Bool
  @Published var terms: [String]
  @Published var newTerm = ""
  @Published var syncReport = ""
  private var monitor: Any?

  init() {
    let hk = config.strings("hotkeys")
    useFn = hk.contains("fn")
    useMouse = hk.contains("mouse2")
    combo = hk.first { $0 != "fn" && $0 != "mouse2" } ?? ""
    sounds = config.bool("sounds")
    speculative = config.bool("speculative")
    cleanup = config.bool("cleanup")
    transcribeModel = config.string("transcribeModel")
    cleanupModel = config.string("cleanupModel")
    typelessSync = config.bool("typelessSync")
    login = SMAppService.mainApp.status == .enabled
    hasKey = apiKey() != nil
    terms = VocabStore.userTerms()
  }

  func changed() { NotificationCenter.default.post(name: .yuConfigChanged, object: nil) }

  func saveHotkeys() {
    var hk: [String] = []
    if useFn { hk.append("fn") }
    if useMouse { hk.append("mouse2") }
    if !combo.isEmpty { hk.append(combo) }
    config.set("hotkeys", hk)
    changed()
  }

  // 錄製自訂快捷鍵：下一個帶修飾鍵的按鍵就是新組合
  func startRecording() {
    recording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      guard let self else { return e }
      if e.keyCode == 53 { self.stopRecording(); return nil } // Esc 取消
      var parts: [String] = []
      if e.modifierFlags.contains(.control) { parts.append("ctrl") }
      if e.modifierFlags.contains(.option) { parts.append("opt") }
      if e.modifierFlags.contains(.shift) { parts.append("shift") }
      if e.modifierFlags.contains(.command) { parts.append("cmd") }
      guard let name = keyNames[Int64(e.keyCode)] else { return nil }
      // 單鍵只接受 F13 以上，避免一般字母被吃掉
      if parts.isEmpty && !name.hasPrefix("f") { return nil }
      self.combo = (parts + [name]).joined(separator: "+")
      self.stopRecording()
      self.saveHotkeys()
      return nil
    }
  }

  func stopRecording() {
    recording = false
    if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
  }

  func testAndSaveKey() {
    let k = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !k.isEmpty else { keyStatus = "請先貼上金鑰"; return }
    keyTesting = true
    keyStatus = "測試中…"
    Task {
      let err = await testAPIKey(k)
      await MainActor.run {
        self.keyTesting = false
        if let err { self.keyStatus = "沒有存：\(err)"; return }
        if saveAPIKey(k) {
          self.keyStatus = "已存進鑰匙圈，可以用了"
          self.keyInput = ""
          self.hasKey = true
          self.changed()
        } else {
          self.keyStatus = "存進鑰匙圈失敗"
        }
      }
    }
  }

  func clearKey() {
    deleteAPIKey()
    hasKey = false
    keyStatus = "已清除"
    changed()
  }

  func addTerm() {
    let t = newTerm.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty, !terms.contains(t) else { return }
    terms.append(t)
    newTerm = ""
    VocabStore.save(terms)
  }

  func removeTerms(_ idx: IndexSet) {
    terms.remove(atOffsets: idx)
    VocabStore.save(terms)
  }

  func runTypelessSync() {
    let r = syncWithTypeless(writeCSV: true)
    if let e = r.error { syncReport = e; return }
    var s = "Typeless 有 \(r.typelessTotal) 個詞，\(r.pulled) 個已同步進 YuVoice。"
    s += r.pushed > 0 ? " YuVoice 有 \(r.pushed) 個詞 Typeless 沒有，已寫成 CSV，到 Typeless「字典」頁按「匯入 CSV」選這個檔。" : " 兩邊已經一致。"
    syncReport = s
    if r.pushed > 0 { NSWorkspace.shared.activateFileViewerSelecting([typelessCSV]) }
  }
}

struct SettingsView: View {
  @StateObject var m = SettingsModel()
  @State var tab = 0
  private let tabs = ["一般", "金鑰與模型", "專有名詞", "實驗功能", "關於"]

  var body: some View {
    VStack(spacing: 0) {
      // 分頁列：純文字＋底線（不用系統膠囊分頁，避免圓角框包圓角框）
      HStack(spacing: 22) {
        ForEach(tabs.indices, id: \.self) { i in
          Button { tab = i } label: {
            VStack(spacing: 5) {
              Text(tabs[i]).fontWeight(tab == i ? .semibold : .regular)
                .foregroundStyle(tab == i ? Color.primary : Color.secondary)
              Rectangle().fill(tab == i ? Color.accentColor : Color.clear).frame(height: 2)
            }
            .fixedSize()
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.top, 12)
      Divider()
      Group {
        switch tab {
        case 0: general
        case 1: keyAndModel
        case 2: vocab
        case 3: labs
        default: about
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(width: 580, height: 480)
    .onDisappear { m.stopRecording() }
  }

  var general: some View {
    Form {
      Section("快捷鍵（按一下開始、再按一下結束；按住超過 1 秒放開也會結束）") {
        Toggle("Fn（🌐）鍵", isOn: $m.useFn).onChange(of: m.useFn) { m.saveHotkeys() }
        Toggle("滑鼠中鍵", isOn: $m.useMouse).onChange(of: m.useMouse) { m.saveHotkeys() }
        HStack {
          Text("自訂組合鍵")
          Spacer()
          Text(m.recording ? "請按下組合鍵…（Esc 取消）" : (m.combo.isEmpty ? "未設定" : comboLabel(m.combo)))
            .foregroundStyle(.secondary)
          Button(m.recording ? "取消" : "錄製") { m.recording ? m.stopRecording() : m.startRecording() }
          if !m.combo.isEmpty && !m.recording { Button("清除") { m.combo = ""; m.saveHotkeys() } }
        }
        Text("用 Fn 鍵前，請到「系統設定 → 鍵盤 → 按下 🌐 鍵時」選「不做任何事」。錄音中按 Esc 可取消。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("其他") {
        Toggle("提示音", isOn: $m.sounds).onChange(of: m.sounds) { config.set("sounds", m.sounds) }
        Toggle("預先轉寫（講完停頓時先送出，按結束後更快貼上）", isOn: $m.speculative)
          .onChange(of: m.speculative) { config.set("speculative", m.speculative) }
        Toggle("登入時開啟", isOn: $m.login).onChange(of: m.login) {
          do { if m.login { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
          catch { log("登入項目設定失敗：\(error)") }
          m.login = SMAppService.mainApp.status == .enabled
        }
      }
    }
    .formStyle(.columns)
    .padding(20)
  }

  var keyAndModel: some View {
    Form {
      Section("OpenRouter 金鑰") {
        HStack {
          Text(m.hasKey ? "已設定（存在 macOS 鑰匙圈）" : "尚未設定")
            .foregroundStyle(m.hasKey ? Color.secondary : Color.red)
          Spacer()
          if m.hasKey { Button("清除") { m.clearKey() } }
        }
        SecureField("新金鑰", text: $m.keyInput, prompt: Text("貼上 sk-or- 開頭的金鑰"))
        HStack {
          Button(m.keyTesting ? "測試中…" : "測試並儲存") { m.testAndSaveKey() }.disabled(m.keyTesting)
          Link("到 openrouter.ai 申請金鑰", destination: URL(string: "https://openrouter.ai/settings/keys")!)
          Spacer()
        }
        if !m.keyStatus.isEmpty { Text(m.keyStatus).font(.caption).foregroundStyle(.secondary) }
      }
      Section("模型") {
        Picker("語音轉文字", selection: $m.transcribeModel) {
          ForEach(transcribeModels, id: \.0) { Text($0.1).tag($0.0) }
        }.onChange(of: m.transcribeModel) { config.set("transcribeModel", m.transcribeModel) }
        Toggle("AI 整理（去贅字、改口、條列、依 app 調語氣）", isOn: $m.cleanup)
          .onChange(of: m.cleanup) { config.set("cleanup", m.cleanup) }
        Picker("整理模型", selection: $m.cleanupModel) {
          ForEach(cleanupModels, id: \.0) { Text($0.1).tag($0.0) }
        }.disabled(!m.cleanup).onChange(of: m.cleanupModel) { config.set("cleanupModel", m.cleanupModel) }
        Text("費用由你的 OpenRouter 帳戶支付。一天講 1 小時，轉寫加整理一個月約 3 到 8 美元。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.columns)
    .padding(20)
  }

  var vocab: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("轉寫常聽錯的人名、品牌、術語加在這裡，整理時會改成正確寫法。括號裡可以寫常被聽成的樣子，例如「GitHub（get hub）」。")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        TextField("新增專有名詞", text: $m.newTerm).onSubmit { m.addTerm() }
        Button("新增") { m.addTerm() }
      }
      List {
        ForEach(m.terms, id: \.self) { Text($0) }.onDelete { m.removeTerms($0) }
      }
      HStack {
        Text("共 \(m.terms.count) 個（選取後按 Delete 刪除）").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("用文字編輯器開啟") { NotificationCenter.default.post(name: .yuOpenVocabFile, object: nil) }
      }
    }
    .padding()
  }

  var labs: some View {
    Form {
      Section("與 Typeless 同步詞庫") {
        Toggle("自動把 Typeless 字典同步進來", isOn: $m.typelessSync)
          .onChange(of: m.typelessSync) { config.set("typelessSync", m.typelessSync); m.changed() }
        Text("讀取 Typeless 在本機的字典快取，不需要 Typeless 帳號密碼。Typeless 改版時可能失效。快取只在打開 Typeless「字典」頁時更新。")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("立即雙向同步") { m.runTypelessSync() }.disabled(!m.typelessSync)
          Text("目前同步區 \(VocabStore.syncedCount()) 個詞").font(.caption).foregroundStyle(.secondary)
        }
        if !m.syncReport.isEmpty { Text(m.syncReport).font(.caption) }
      }
    }
    .formStyle(.columns)
    .padding(20)
  }

  var about: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
        VStack(alignment: .leading) {
          Text("YuVoice").font(.title2).bold()
          Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開發版")")
            .foregroundStyle(.secondary)
        }
      }
      Text("隱私").font(.headline)
      Text("錄音與游標附近的文字會送到 OpenRouter，再轉給你選的模型供應商（OpenAI、Anthropic 等）處理。歷史紀錄、詞彙表與設定只存在這台 Mac 的 ~/.yuvoice 資料夾。密碼欄位不會讀取。")
        .font(.callout).fixedSize(horizontal: false, vertical: true)
      Text("授權").font(.headline)
      Text("MIT 授權。整理規則改寫自 jarvis-voice（MIT）。").font(.callout)
      HStack {
        Button("開啟資料夾") { NSWorkspace.shared.open(homeDir) }
        Link("專案網站", destination: URL(string: "https://github.com/hausco/yuvoice")!)
      }
      Spacer()
    }
    .padding(20)
  }
}

extension Notification.Name {
  static let yuOpenVocabFile = Notification.Name("YuVoiceOpenVocabFile")
}

// 視窗管理：同一時間只開一個設定視窗
enum Windows {
  static var settings: NSWindow?
  static var history: NSWindow?
  static var onboarding: NSWindow?

  static func show<V: View>(_ slot: inout NSWindow?, title: String, view: V) {
    if let w = slot { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
    let w = NSWindow(contentViewController: NSHostingController(rootView: view))
    w.title = title
    w.styleMask = [.titled, .closable, .miniaturizable]
    w.isReleasedWhenClosed = false
    w.center()
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    slot = w
  }
}
