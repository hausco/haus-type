// HAUS Type 設定視窗（SwiftUI）：一般、金鑰與模型、專有名詞、實驗功能、關於。
// 改動立刻寫進 config.json，並發出 configChanged 通知讓主程式重新套用（例如快捷鍵）。

import AVFoundation
import ServiceManagement
import SwiftUI

extension Notification.Name {
  static let yuConfigChanged = Notification.Name("HausTypeConfigChanged")
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

let askModels: [(String, String)] = [
  ("anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5（建議，寫作與問答較好）"),
  ("anthropic/claude-haiku-5.5", "Claude Haiku 5.5（較快、較便宜）"),
  ("anthropic/claude-opus-5.5", "Claude Opus 5.5（最聰明、較慢較貴）"),
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
  // 三種模式各自的快捷鍵：Fn 系列（口述 fn、翻譯 fn+shift、提問 fn+space）、滑鼠中鍵、自訂組合
  @Published var fnOn: [Mode: Bool] = [:]
  @Published var mouseOn: [Mode: Bool] = [:]
  @Published var combos: [Mode: String] = [:]
  @Published var recordingFor: Mode?
  @Published var micUID: String
  @Published var mics: [AudioDevice] = inputDevices()
  @Published var mute: Bool
  @Published var showInDock: Bool
  @Published var smartFormatting: Bool
  @Published var autoPunctuation: Bool
  @Published var englishVariant: String
  @Published var noContextApps: [String]
  @Published var translateTargets: [String]
  @Published var translateTarget: String
  @Published var askModel: String
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
  @Published var items: [VocabItem] = VocabStore.items()
  @Published var newTerm = ""
  @Published var newCategory = "一般"
  @Published var vocabFilter = 0          // 0 全部、1 手動、2 自動新增、3 Typeless
  @Published var selection = Set<String>()
  @Published var editing: VocabItem?
  @Published var editText = ""
  @Published var editCategory = "一般"
  @Published var autoLearn = config.bool("autoLearn")
  @Published var styleSample = config.string("styleSample")
  @Published var categorizing = ""
  @Published var syncReport = ""
  private var monitor: Any?

  init() {
    micUID = config.string("micUID")
    mute = config.bool("muteWhileDictating")
    showInDock = config.bool("showInDock")
    smartFormatting = config.bool("smartFormatting")
    autoPunctuation = config.bool("autoPunctuation")
    englishVariant = config.string("englishVariant")
    noContextApps = config.strings("noContextApps")
    translateTargets = config.strings("translateTargets")
    translateTarget = currentTranslateTarget()
    askModel = config.string("askModel")
    sounds = config.bool("sounds")
    speculative = config.bool("speculative")
    cleanup = config.bool("cleanup")
    transcribeModel = config.string("transcribeModel")
    cleanupModel = config.string("cleanupModel")
    typelessSync = config.bool("typelessSync")
    login = SMAppService.mainApp.status == .enabled
    hasKey = apiKey() != nil
    var f: [Mode: Bool] = [:], ms: [Mode: Bool] = [:], cs: [Mode: String] = [:]
    for m in [Mode.dictate, .translate, .ask] {
      let hk = config.strings(SettingsModel.key(m)).map { $0.lowercased() }
      f[m] = hk.contains(SettingsModel.fnSpec(m))
      ms[m] = hk.contains("mouse2")
      cs[m] = hk.first { !$0.hasPrefix("fn") && $0 != "mouse2" } ?? ""
    }
    fnOn = f; mouseOn = ms; combos = cs
  }

  func changed() { NotificationCenter.default.post(name: .yuConfigChanged, object: nil) }

  static func key(_ m: Mode) -> String { m == .dictate ? "hotkeys" : m == .translate ? "translateHotkeys" : "askHotkeys" }
  static func fnSpec(_ m: Mode) -> String { m == .dictate ? "fn" : m == .translate ? "fn+shift" : "fn+space" }

  func saveHotkeys(_ m: Mode) {
    // 滑鼠中鍵只能給一種模式
    if mouseOn[m] == true { for o in [Mode.dictate, .translate, .ask] where o != m && mouseOn[o] == true { mouseOn[o] = false; write(o) } }
    write(m)
    changed()
  }

  private func write(_ m: Mode) {
    var hk: [String] = []
    if fnOn[m] == true { hk.append(SettingsModel.fnSpec(m)) }
    if mouseOn[m] == true { hk.append("mouse2") }
    if let c = combos[m], !c.isEmpty { hk.append(c) }
    config.set(SettingsModel.key(m), hk)
  }

  // 隱私清單：加入或移除 app（bundle id）
  func addNoContext(_ bundle: String) {
    guard !bundle.isEmpty, !noContextApps.contains(bundle) else { return }
    noContextApps.append(bundle)
    config.set("noContextApps", noContextApps)
  }

  func removeNoContext(_ bundle: String) {
    noContextApps.removeAll { $0 == bundle }
    config.set("noContextApps", noContextApps)
  }

  func toggleTarget(_ lang: String, _ on: Bool) {
    if on { if !translateTargets.contains(lang) && translateTargets.count < 3 { translateTargets.append(lang) } }
    else { translateTargets.removeAll { $0 == lang } }
    if !translateTargets.contains(translateTarget) { translateTarget = translateTargets.first ?? "英文" }
    config.set("translateTargets", translateTargets)
    config.set("translateTarget", translateTarget)
    changed()
  }

  // 錄製自訂快捷鍵：下一個帶修飾鍵的按鍵就是新組合
  func startRecording(_ mode: Mode) {
    recordingFor = mode
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
      if let m = self.recordingFor { self.combos[m] = (parts + [name]).joined(separator: "+"); self.saveHotkeys(m) }
      self.stopRecording()
      return nil
    }
  }

  func stopRecording() {
    recordingFor = nil
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

  func reloadVocab() { items = VocabStore.items(); selection = [] }

  var filteredItems: [VocabItem] {
    switch vocabFilter {
    case 1: return items.filter { $0.source == "manual" }
    case 2: return items.filter { $0.source == "auto" }
    case 3: return items.filter { $0.source == "typeless" }
    default: return items
    }
  }

  func addVocab() {
    VocabStore.add(newTerm, category: newCategory, auto: false)
    newTerm = ""
    reloadVocab()
  }

  func deleteSelected() {
    VocabStore.delete(selection)
    reloadVocab()
  }

  func autoCategorize() {
    categorizing = "分類中…"
    Task {
      let n = await autoCategorizeVocab()
      await MainActor.run { self.categorizing = n > 0 ? "已分類 \(n) 個" : "沒有需要分類的詞"; self.reloadVocab() }
    }
  }

  func startEdit(_ it: VocabItem) { editing = it; editText = it.line; editCategory = it.category }

  func saveEdit() {
    guard let it = editing else { return }
    VocabStore.edit(it.line, to: editText, category: editCategory)
    editing = nil
    reloadVocab()
  }

  func addTerm() { addVocab() }

  func runTypelessSync() {
    let r = syncWithTypeless(writeCSV: true)
    if let e = r.error { syncReport = e; return }
    var s = "Typeless 有 \(r.typelessTotal) 個詞，\(r.pulled) 個已同步進 HAUS Type。"
    s += r.pushed > 0 ? " HAUS Type 有 \(r.pushed) 個詞 Typeless 沒有，已寫成 CSV，到 Typeless「字典」頁按「匯入 CSV」選這個檔。" : " 兩邊已經一致。"
    syncReport = s
    if r.pushed > 0 { NSWorkspace.shared.activateFileViewerSelecting([typelessCSV]) }
  }
}

// bundle id 轉成 app 顯示名稱（找不到就顯示 bundle id）
let knownAppNames = ["com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
                     "com.bitwarden.desktop": "Bitwarden", "com.apple.keychainaccess": "鑰匙圈存取", "com.apple.Passwords": "密碼"]

func appName(_ bundle: String) -> String {
  if let n = knownAppNames[bundle] { return n }
  guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
  return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

// 目前開著的一般 app（加入隱私清單用）
func runningAppChoices() -> [(String, String)] {
  NSWorkspace.shared.runningApplications
    .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
    .map { ($0.bundleIdentifier!, $0.localizedName ?? $0.bundleIdentifier!) }
    .sorted { $0.1 < $1.1 }
}

struct SettingsView: View {
  @StateObject var m = SettingsModel()
  @StateObject var tester = MicTester()
  @State var addApp = ""
  @State var tab: Int
  init(tab: Int = 0) { _tab = State(initialValue: tab) }
  private let tabs = ["一般", "快捷鍵", "金鑰與模型", "字典", "實驗功能", "關於"]

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
      ScrollView {
        switch tab {
        case 0: general
        case 1: shortcuts
        case 2: keyAndModel
        case 3: vocab
        case 4: labs
        default: about
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(width: 600, height: 520)
    .onDisappear { m.stopRecording(); tester.stop() }
  }

  var general: some View {
    Form {
      Section("音訊") {
        Picker("麥克風", selection: $m.micUID) {
          Text("系統預設").tag("")
          ForEach(m.mics) { Text($0.name).tag($0.uid) }
        }.onChange(of: m.micUID) { config.set("micUID", m.micUID); if tester.running { tester.start() } }
        HStack {
          Button(tester.running ? "停止測試" : "測試麥克風") { tester.running ? tester.stop() : tester.start() }
          // 音量條：平頭長條，不用圓角
          GeometryReader { g in
            ZStack(alignment: .leading) {
              Rectangle().fill(Color.secondary.opacity(0.2))
              Rectangle().fill(Color.accentColor).frame(width: g.size.width * CGFloat(min(1, sqrt(tester.level) * 1.2)))
            }
          }.frame(height: 6)
        }
        Toggle("錄音時把其他聲音靜音", isOn: $m.mute).onChange(of: m.mute) { config.set("muteWhileDictating", m.mute) }
      }
      Section("輸出") {
        Toggle("智慧排版（講「第一、第二」排成條列、自動分段）", isOn: $m.smartFormatting)
          .onChange(of: m.smartFormatting) { config.set("smartFormatting", m.smartFormatting) }
        Toggle("自動補標點", isOn: $m.autoPunctuation).onChange(of: m.autoPunctuation) { config.set("autoPunctuation", m.autoPunctuation) }
        Picker("英文拼寫", selection: $m.englishVariant) {
          Text("美式（color）").tag("us")
          Text("英式（colour）").tag("uk")
        }.onChange(of: m.englishVariant) { config.set("englishVariant", m.englishVariant) }
      }
      Section("隱私：這些 app 在最前面時，不讀取游標附近的文字與視窗標題") {
        ForEach(m.noContextApps, id: \.self) { b in
          HStack {
            Text(appName(b))
            Spacer()
            Button("移除") { m.removeNoContext(b) }
          }
        }
        Picker("加入目前開著的 app", selection: $addApp) {
          Text("選擇…").tag("")
          ForEach(runningAppChoices(), id: \.0) { Text($0.1).tag($0.0) }
        }.onChange(of: addApp) { m.addNoContext(addApp); addApp = "" }
      }
      Section("一般") {
        Toggle("顯示在 Dock", isOn: $m.showInDock).onChange(of: m.showInDock) { config.set("showInDock", m.showInDock); m.changed() }
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

  // 快捷鍵頁：三種模式各一組
  var shortcuts: some View {
    Form {
      shortcutSection(.dictate, title: "口述：講的話整理後打進游標處", fnLabel: "Fn（🌐）")
      shortcutSection(.translate, title: "翻譯：講中文，打出目標語言", fnLabel: "Fn＋Shift")
      Section {
        ForEach(translateLanguages, id: \.self) { lang in
          Toggle(lang, isOn: Binding(get: { m.translateTargets.contains(lang) }, set: { m.toggleTarget(lang, $0) }))
            .disabled(!m.translateTargets.contains(lang) && m.translateTargets.count >= 3)
        }
      } header: {
        Text("翻譯目標（最多 3 種，選單列可以切換目前用哪一種）")
      }
      shortcutSection(.ask, title: "隨便問：選取字後改寫或提問，沒選取時幫你寫或回答", fnLabel: "Fn＋Space")
      Text("按一下開始、再按一下結束；按住超過 1 秒放開也會結束；錄音中按 Esc 取消。用 Fn 前，請到「系統設定 → 鍵盤 → 按下 🌐 鍵時」選「不做任何事」。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .formStyle(.columns)
    .padding(20)
  }

  func shortcutSection(_ mode: Mode, title: String, fnLabel: String) -> some View {
    Section(title) {
      Toggle(fnLabel, isOn: Binding(get: { m.fnOn[mode] ?? false }, set: { m.fnOn[mode] = $0; m.saveHotkeys(mode) }))
      Toggle("滑鼠中鍵", isOn: Binding(get: { m.mouseOn[mode] ?? false }, set: { m.mouseOn[mode] = $0; m.saveHotkeys(mode) }))
      HStack {
        Text("自訂組合鍵")
        Spacer()
        let c = m.combos[mode] ?? ""
        Text(m.recordingFor == mode ? "請按下組合鍵…（Esc 取消）" : (c.isEmpty ? "未設定" : comboLabel(c))).foregroundStyle(.secondary)
        Button(m.recordingFor == mode ? "取消" : "錄製") { m.recordingFor == mode ? m.stopRecording() : m.startRecording(mode) }
        if !c.isEmpty && m.recordingFor != mode { Button("清除") { m.combos[mode] = ""; m.saveHotkeys(mode) } }
      }
    }
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
        Picker("隨便問模型", selection: $m.askModel) {
          ForEach(askModels, id: \.0) { Text($0.1).tag($0.0) }
        }.onChange(of: m.askModel) { config.set("askModel", m.askModel) }
        Text("費用由你的 OpenRouter 帳戶支付。一天講 1 小時，轉寫加整理一個月約 3 到 8 美元。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.columns)
    .padding(20)
  }

  var vocab: some View {
    VStack(alignment: .leading, spacing: 10) {
      let p = Learner.personalization()
      let manual = m.items.filter { $0.source == "manual" }.count, auto = m.items.filter { $0.source == "auto" }.count
      Text("個人化：詞彙 \(m.items.count) 個（手動 \(manual)、自動學到 \(auto)、Typeless \(m.items.count - manual - auto)）。最近 \(p.total) 段裡有 \(p.hits) 段靠詞彙表改對專有名詞。")
        .font(.callout)
      Toggle("自動學詞：貼上後 30 秒內你改掉的專有名詞，自動加進「自動新增」", isOn: $m.autoLearn)
        .onChange(of: m.autoLearn) { config.set("autoLearn", m.autoLearn) }
      HStack {
        TextField("新增專有名詞，括號裡可寫常被聽成的樣子，例如 GitHub（get hub）", text: $m.newTerm).onSubmit { m.addVocab() }
        Picker("", selection: $m.newCategory) { ForEach(vocabCategories, id: \.self) { Text($0) } }.frame(width: 120)
        Button("新增") { m.addVocab() }
      }
      HStack(spacing: 16) {
        ForEach(Array(["全部", "手動新增", "自動新增", "Typeless"].enumerated()), id: \.offset) { i, t in
          Button(t) { m.vocabFilter = i; m.selection = [] }.buttonStyle(.plain)
            .fontWeight(m.vocabFilter == i ? .semibold : .regular)
            .foregroundStyle(m.vocabFilter == i ? Color.primary : Color.secondary)
        }
        Spacer()
        if !m.categorizing.isEmpty { Text(m.categorizing).font(.caption).foregroundStyle(.secondary) }
        Button("用 AI 自動分類") { m.autoCategorize() }.buttonStyle(.borderless)
        if !m.selection.isEmpty { Button("刪除選取的 \(m.selection.count) 個") { m.deleteSelected() } }
      }
      List(m.filteredItems, selection: $m.selection) { it in
        HStack {
          Text(it.line)
          Spacer()
          Text(it.category).font(.caption).foregroundStyle(.secondary)
          Text(it.source == "auto" ? "自動" : it.source == "typeless" ? "Typeless" : "手動").font(.caption).foregroundStyle(.tertiary).frame(width: 56, alignment: .trailing)
          Button("編輯") { m.startEdit(it) }.buttonStyle(.borderless)
        }
        .tag(it.line)
      }
      .frame(minHeight: 260)
      Text("寫作風格樣本（貼 2 到 3 段你自己寫的文字，整理與隨便問會參考你的用詞與語氣）").font(.callout)
      TextEditor(text: $m.styleSample).frame(height: 70).border(Color.secondary.opacity(0.3))
        .onChange(of: m.styleSample) { config.set("styleSample", m.styleSample) }
      HStack {
        Spacer()
        Button("用文字編輯器開啟詞彙表") { NotificationCenter.default.post(name: .yuOpenVocabFile, object: nil) }
      }
    }
    .padding()
    .sheet(item: $m.editing) { it in
      VStack(alignment: .leading, spacing: 12) {
        Text("編輯詞彙").font(.headline)
        TextField("詞彙", text: $m.editText).disabled(it.source == "typeless")
        if it.source == "typeless" { Text("Typeless 同步的詞只能改分類；要改字請到 Typeless 字典").font(.caption).foregroundStyle(.secondary) }
        Picker("分類", selection: $m.editCategory) { ForEach(vocabCategories, id: \.self) { Text($0) } }
        HStack {
          Spacer()
          Button("取消") { m.editing = nil }
          Button("儲存") { m.saveEdit() }.keyboardShortcut(.defaultAction)
        }
      }
      .padding(20).frame(width: 380)
    }
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
          Text("HAUS Type").font(.title2).bold()
          Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開發版")")
            .foregroundStyle(.secondary)
        }
      }
      Text("隱私").font(.headline)
      Text("錄音與游標附近的文字會送到 OpenRouter，再轉給你選的模型供應商（OpenAI、Anthropic 等）處理。歷史紀錄、詞彙表與設定只存在這台 Mac 的 ~/.haustype 資料夾。密碼欄位不會讀取。")
        .font(.callout).fixedSize(horizontal: false, vertical: true)
      Text("授權").font(.headline)
      Text("MIT 授權。整理規則改寫自 jarvis-voice（MIT）。").font(.callout)
      HStack {
        Button("開啟資料夾") { NSWorkspace.shared.open(homeDir) }
        Link("專案網站", destination: URL(string: "https://github.com/hausco/haus-type")!)
      }
      Spacer()
    }
    .padding(20)
  }
}

extension Notification.Name {
  static let yuOpenVocabFile = Notification.Name("HausTypeOpenVocabFile")
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
