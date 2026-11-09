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
  @Published var engine = config.string("transcribeEngine")
  @Published var localStatus = ""
  private var stateObs: Any?
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
    stateObs = NotificationCenter.default.addObserver(forName: .localASRState, object: nil, queue: .main) { [weak self] _ in self?.refreshLocalStatus() }
    refreshLocalStatus()
  }

  func refreshLocalStatus() {
    switch LocalASR.shared.state {
    case .ready: localStatus = "本機模型已就緒"
    case .starting: localStatus = "本機模型載入中…"
    case .failed(let why): localStatus = "\(why)，聽寫會自動改用雲端"
    case .off: localStatus = LocalASR.shared.missingReason().map { "\($0)，聽寫會自動改用雲端" } ?? "本機模型未啟動"
    }
  }

  func setEngine(_ e: String) {
    engine = e
    config.set("transcribeEngine", e)
    changed()
    refreshLocalStatus()
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

// 段落標題：粗體、上方留白，跟設定項目分開
struct SectionHeader: View {
  let text: String
  init(_ t: String) { text = t }
  var body: some View { Text(text).font(.headline).padding(.top, 14).padding(.bottom, 2) }
}

// 設定視窗：macOS 27「系統設定」式側邊欄。
// 內容不用分組卡片（遵守「圓角框不包圓角框」），說明文字收進滑過才出現的提示。
enum SettingsPage: String, CaseIterable, Identifiable {
  case general = "一般", shortcuts = "快捷鍵", models = "辨識與模型", vocab = "字典", labs = "實驗功能", about = "關於"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .general: return "gearshape"
    case .shortcuts: return "keyboard"
    case .models: return "waveform"
    case .vocab: return "character.book.closed"
    case .labs: return "flask"
    case .about: return "info.circle"
    }
  }
}

struct SettingsView: View {
  @StateObject var m = SettingsModel()
  @StateObject var tester = MicTester()
  @State var addApp = ""
  @State var page: SettingsPage?
  init(tab: Int = 0) { _page = State(initialValue: SettingsPage.allCases[min(max(tab, 0), SettingsPage.allCases.count - 1)]) }

  var body: some View {
    NavigationSplitView {
      // 側邊欄圖示不加彩色方塊底（選取的圓角底色裡再包一個圓角方塊會違反規則）
      List(SettingsPage.allCases, selection: $page) { p in
        Label(p.rawValue, systemImage: p.symbol).tag(p)
      }
      .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 200)
    } detail: {
      ScrollView {
        Group {
          switch page ?? .general {
          case .general: general
          case .shortcuts: shortcuts
          case .models: keyAndModel
          case .vocab: vocab
          case .labs: labs
          case .about: about
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .navigationTitle((page ?? .general).rawValue)
    }
    .frame(width: 760, height: 560)
    .onDisappear { m.stopRecording(); tester.stop() }
  }

  // 一般
  var general: some View {
    Form {
      Section(header: SectionHeader("音訊")) {
        Picker("麥克風", selection: $m.micUID) {
          Text("系統預設").tag("")
          ForEach(m.mics) { Text($0.name).tag($0.uid) }
        }.onChange(of: m.micUID) { config.set("micUID", m.micUID); if tester.running { tester.start() } }
        LabeledContent("輸入音量") {
          HStack {
            // 音量條：平頭長條，不用圓角
            GeometryReader { g in
              ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.2))
                Rectangle().fill(Color.accentColor).frame(width: g.size.width * CGFloat(min(1, sqrt(tester.level) * 1.2)))
              }
            }.frame(height: 6)
            Button(tester.running ? "停止" : "測試") { tester.running ? tester.stop() : tester.start() }
          }
        }
        Toggle("錄音時靜音其他聲音", isOn: $m.mute).onChange(of: m.mute) { config.set("muteWhileDictating", m.mute) }
      }
      Section(header: SectionHeader("輸出")) {
        Toggle("智慧排版", isOn: $m.smartFormatting).help("講「第一、第二」排成條列、自動分段")
          .onChange(of: m.smartFormatting) { config.set("smartFormatting", m.smartFormatting) }
        Toggle("自動標點", isOn: $m.autoPunctuation).onChange(of: m.autoPunctuation) { config.set("autoPunctuation", m.autoPunctuation) }
        Picker("英文拼寫", selection: $m.englishVariant) {
          Text("美式").tag("us")
          Text("英式").tag("uk")
        }.onChange(of: m.englishVariant) { config.set("englishVariant", m.englishVariant) }
        Toggle("預先轉寫", isOn: $m.speculative).help("講完停頓時先送出，按結束後更快貼上")
          .onChange(of: m.speculative) { config.set("speculative", m.speculative) }
      }
      Section {
        ForEach(m.noContextApps, id: \.self) { b in
          LabeledContent(appName(b)) { Button("移除") { m.removeNoContext(b) }.buttonStyle(.borderless) }
        }
        Picker("加入 App", selection: $addApp) {
          Text("選擇…").tag("")
          ForEach(runningAppChoices(), id: \.0) { Text($0.1).tag($0.0) }
        }.onChange(of: addApp) { m.addNoContext(addApp); addApp = "" }
      } header: {
        SectionHeader("不讀取上下文的 App").help("這些 App 在最前面時，只送 App 名稱，不讀游標附近的文字與視窗標題")
      }
      Section(header: SectionHeader("一般")) {
        Toggle("提示音", isOn: $m.sounds).onChange(of: m.sounds) { config.set("sounds", m.sounds) }
        Toggle("顯示在 Dock", isOn: $m.showInDock).onChange(of: m.showInDock) { config.set("showInDock", m.showInDock); m.changed() }
        Toggle("登入時開啟", isOn: $m.login).onChange(of: m.login) {
          do { if m.login { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
          catch { log("登入項目設定失敗：\(error)") }
          m.login = SMAppService.mainApp.status == .enabled
        }
      }
    }
    .formStyle(.columns)
    .toggleStyle(.switch)
    .controlSize(.small)
    .padding(24)
  }

  // 快捷鍵：三種模式各一組
  var shortcuts: some View {
    Form {
      shortcutSection(.dictate, fnLabel: "Fn（🌐）", help: "講的話整理後打進游標處")
      shortcutSection(.translate, fnLabel: "Fn＋Shift", help: "講中文，打出目標語言")
      Section(header: SectionHeader("翻譯目標")) {
        // 多選選單：最多 3 種，選單列可以切換目前用哪一種
        Menu(m.translateTargets.isEmpty ? "選擇語言" : m.translateTargets.joined(separator: "、")) {
          ForEach(translateLanguages, id: \.self) { lang in
            Toggle(lang, isOn: Binding(get: { m.translateTargets.contains(lang) }, set: { m.toggleTarget(lang, $0) }))
              .disabled(!m.translateTargets.contains(lang) && m.translateTargets.count >= 3)
          }
        }
        .fixedSize()
        .help("最多 3 種，從選單列切換目前使用的語言")
      }
      shortcutSection(.ask, fnLabel: "Fn＋Space", help: "選取字後改寫或提問；沒選取時幫你寫或回答")
    }
    .formStyle(.columns)
    .toggleStyle(.switch)
    .controlSize(.small)
    .padding(24)
  }

  func shortcutSection(_ mode: Mode, fnLabel: String, help: String) -> some View {
    Section {
      Toggle(fnLabel, isOn: Binding(get: { m.fnOn[mode] ?? false }, set: { m.fnOn[mode] = $0; m.saveHotkeys(mode) }))
        .help(mode == .dictate ? "系統設定 → 鍵盤 → 按下 🌐 鍵時，選「不做任何事」" : "")
      Toggle("滑鼠中鍵", isOn: Binding(get: { m.mouseOn[mode] ?? false }, set: { m.mouseOn[mode] = $0; m.saveHotkeys(mode) }))
      LabeledContent("組合鍵") {
        let c = m.combos[mode] ?? ""
        HStack {
          Text(m.recordingFor == mode ? "按下組合鍵…" : (c.isEmpty ? "未設定" : comboLabel(c))).foregroundStyle(.secondary)
          Button(m.recordingFor == mode ? "取消" : "錄製") { m.recordingFor == mode ? m.stopRecording() : m.startRecording(mode) }
          if !c.isEmpty && m.recordingFor != mode { Button("清除") { m.combos[mode] = ""; m.saveHotkeys(mode) } }
        }
      }
    } header: {
      SectionHeader(mode.label == "提問" ? "隨便問" : mode.label).help(help)
    }
  }

  // 辨識與模型
  var keyAndModel: some View {
    Form {
      Section(header: SectionHeader("OpenRouter 金鑰")) {
        LabeledContent("狀態") {
          HStack {
            Text(m.hasKey ? "已設定" : "尚未設定").foregroundStyle(m.hasKey ? Color.secondary : Color.red)
            if m.hasKey { Button("清除") { m.clearKey() }.buttonStyle(.borderless) }
          }
        }
        SecureField("新金鑰", text: $m.keyInput, prompt: Text("sk-or-…"))
        LabeledContent("") {
          HStack {
            Button(m.keyTesting ? "測試中…" : "測試並儲存") { m.testAndSaveKey() }.disabled(m.keyTesting)
            Link("申請金鑰", destination: URL(string: "https://openrouter.ai/settings/keys")!)
          }
        }
        if !m.keyStatus.isEmpty { LabeledContent("") { Text(m.keyStatus).font(.caption).foregroundStyle(.secondary) } }
      }
      Section(header: SectionHeader("語音辨識")) {
        Picker("引擎", selection: Binding(get: { m.engine }, set: { m.setEngine($0) })) {
          Text("雲端").tag("cloud")
          Text("本機（錄音不離開這台 Mac）").tag("local")
        }
        .help("本機使用 Breeze-ASR-25；整理、翻譯、隨便問仍會把文字送到 OpenRouter")
        if m.engine == "local" { LabeledContent("") { Text(m.localStatus).font(.caption).foregroundStyle(.secondary) } }
        Picker("雲端模型", selection: $m.transcribeModel) {
          ForEach(transcribeModels, id: \.0) { Text($0.1).tag($0.0) }
        }.onChange(of: m.transcribeModel) { config.set("transcribeModel", m.transcribeModel) }
      }
      Section(header: SectionHeader("AI")) {
        Toggle("整理", isOn: $m.cleanup).help("去贅字、改口、條列、依 App 調語氣")
          .onChange(of: m.cleanup) { config.set("cleanup", m.cleanup) }
        Picker("整理模型", selection: $m.cleanupModel) {
          ForEach(cleanupModels, id: \.0) { Text($0.1).tag($0.0) }
        }.disabled(!m.cleanup).onChange(of: m.cleanupModel) { config.set("cleanupModel", m.cleanupModel) }
        Picker("隨便問模型", selection: $m.askModel) {
          ForEach(askModels, id: \.0) { Text($0.1).tag($0.0) }
        }.onChange(of: m.askModel) { config.set("askModel", m.askModel) }
      }
    }
    .formStyle(.columns)
    .toggleStyle(.switch)
    .controlSize(.small)
    .padding(24)
  }

  // 字典與個人化
  var vocab: some View {
    VStack(alignment: .leading, spacing: 12) {
      let p = Learner.personalization()
      let manual = m.items.filter { $0.source == "manual" }.count, auto = m.items.filter { $0.source == "auto" }.count
      HStack(spacing: 28) {
        figure("\(m.items.count)", "詞彙")
        figure("\(auto)", "自動學到")
        figure("\(p.hits)／\(p.total)", "靠詞彙改對").help("最近幾段裡，整理結果用到詞彙表、而原稿沒有的段數")
        Spacer()
        Toggle("自動學詞", isOn: $m.autoLearn).help("貼上後 30 秒內你改掉的專有名詞，自動加進詞彙表")
          .onChange(of: m.autoLearn) { config.set("autoLearn", m.autoLearn) }
      }
      HStack {
        TextField("新增詞彙", text: $m.newTerm).onSubmit { m.addVocab() }
          .help("括號裡可寫常被聽成的樣子，例如 GitHub（get hub）")
        Picker("", selection: $m.newCategory) { ForEach(vocabCategories, id: \.self) { Text($0) } }.labelsHidden().frame(width: 110)
        Button("新增") { m.addVocab() }.disabled(m.newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      HStack(spacing: 16) {
        ForEach(Array(["全部", "手動 \(manual)", "自動 \(auto)", "Typeless \(m.items.count - manual - auto)"].enumerated()), id: \.offset) { i, t in
          Button(t) { m.vocabFilter = i; m.selection = [] }.buttonStyle(.plain)
            .fontWeight(m.vocabFilter == i ? .semibold : .regular)
            .foregroundStyle(m.vocabFilter == i ? Color.primary : Color.secondary)
        }
        Spacer()
        if !m.categorizing.isEmpty { Text(m.categorizing).font(.caption).foregroundStyle(.secondary) }
        Button("AI 分類") { m.autoCategorize() }.buttonStyle(.borderless).help("幫還沒分類的詞自動分類")
        if !m.selection.isEmpty { Button("刪除 \(m.selection.count) 個") { m.deleteSelected() }.buttonStyle(.borderless) }
      }
      List(m.filteredItems, selection: $m.selection) { it in
        HStack {
          Text(it.line)
          Spacer()
          Text(it.category).font(.caption).foregroundStyle(.secondary)
          Button("編輯") { m.startEdit(it) }.buttonStyle(.borderless)
        }
        .tag(it.line)
        .contextMenu { Button("編輯") { m.startEdit(it) }; Button("刪除") { m.selection = [it.line]; m.deleteSelected() } }
      }
      .frame(minHeight: 230)
      Text("寫作風格樣本").font(.headline).help("貼 2 到 3 段你自己寫的文字，整理與隨便問會參考你的用詞與語氣")
      TextEditor(text: $m.styleSample).frame(height: 64).border(Color.secondary.opacity(0.3))
        .onChange(of: m.styleSample) { config.set("styleSample", m.styleSample) }
      HStack {
        Spacer()
        Button("用文字編輯器開啟") { NotificationCenter.default.post(name: .yuOpenVocabFile, object: nil) }.buttonStyle(.borderless)
      }
    }
    .padding(24)
    .sheet(item: $m.editing) { it in
      Form {
        TextField("詞彙", text: $m.editText).disabled(it.source == "typeless")
          .help(it.source == "typeless" ? "Typeless 同步的詞只能改分類" : "")
        Picker("分類", selection: $m.editCategory) { ForEach(vocabCategories, id: \.self) { Text($0) } }
      }
      .formStyle(.columns)
      .padding(24)
      .frame(width: 380)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { m.editing = nil } }
        ToolbarItem(placement: .confirmationAction) { Button("儲存") { m.saveEdit() } }
      }
    }
  }

  func figure(_ v: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(v).font(.title2).bold().monospacedDigit()
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  // 實驗功能
  var labs: some View {
    Form {
      Section {
        Toggle("同步 Typeless 字典", isOn: $m.typelessSync)
          .help("讀取 Typeless 在本機的字典快取，不需要帳號密碼；Typeless 改版時可能失效")
          .onChange(of: m.typelessSync) { config.set("typelessSync", m.typelessSync); m.changed() }
        LabeledContent("同步區") {
          HStack {
            Text("\(VocabStore.syncedCount()) 個詞").foregroundStyle(.secondary)
            Button("立即雙向同步") { m.runTypelessSync() }.disabled(!m.typelessSync)
          }
        }
        if !m.syncReport.isEmpty { LabeledContent("") { Text(m.syncReport).font(.caption).foregroundStyle(.secondary) } }
      } header: { SectionHeader("Typeless") }
    }
    .formStyle(.columns)
    .toggleStyle(.switch)
    .controlSize(.small)
    .padding(24)
  }

  // 關於
  var about: some View {
    VStack(spacing: 14) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
      Text("HAUS Type").font(.largeTitle).bold()
      Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開發版")")
        .foregroundStyle(.secondary)
      HStack(spacing: 18) {
        Button("開啟資料夾") { NSWorkspace.shared.open(homeDir) }
        Link("隱私說明", destination: URL(string: "https://github.com/hausco/haus-type#隱私")!)
        Link("專案網站", destination: URL(string: "https://github.com/hausco/haus-type")!)
      }
      Text("MIT 授權・整理規則改寫自 jarvis-voice").font(.caption).foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 48)
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
    // macOS 27：內容延伸到標題列下，側邊欄與工具列合成一體
    w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    w.toolbarStyle = .unified
    w.isReleasedWhenClosed = false
    w.center()
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    slot = w
  }
}
