// 總覽與歷史紀錄視窗。
// 總覽：字數、省下的時間、每分鐘字數、總口述時間、活躍與連續天數、使用熱度圖（仿 Typeless 首頁）。
// 歷史：全部／口述／翻譯／提問分頁，可搜尋、複製、重試、另存錄音、刪除，並設定保存期限。

import AppKit
import SwiftUI

let retentionOptions: [(Double, String)] = [(0, "不保存"), (1, "1 天"), (7, "7 天"), (30, "30 天"), (90, "90 天"), (-1, "永久")]

final class HistoryModel: ObservableObject {
  @Published var items: [HistoryEntry] = []
  @Published var historyDays = config.double("historyDays")
  @Published var audioDays = config.double("audioDays")
  @Published var retrying: Set<String> = []
  @Published var notice = ""

  init() { reload() }

  func reload() { items = HistoryStore.load().reversed() }

  func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    flash("已複製")
  }

  func flash(_ s: String) {
    notice = s
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.notice == s { self.notice = "" } }
  }

  func delete(_ e: HistoryEntry) { HistoryStore.delete([e.id]); reload() }

  func deleteAll() {
    let a = NSAlert()
    a.messageText = "刪除所有歷史紀錄？"
    a.informativeText = "本機的歷史與錄音會永久刪除，無法復原。統計數字不受影響。"
    a.addButton(withTitle: "刪除"); a.addButton(withTitle: "取消")
    a.buttons.first?.hasDestructiveAction = true
    if a.runModal() == .alertFirstButtonReturn { HistoryStore.deleteAll(); reload() }
  }

  func setRetention(history: Double? = nil, audio: Double? = nil) {
    if let h = history { historyDays = h; config.set("historyDays", h) }
    if let a = audio { audioDays = a; config.set("audioDays", a) }
    DispatchQueue.global().async { HistoryStore.prune(); DispatchQueue.main.async { self.reload() } }
  }

  // 用存下來的錄音重新轉寫＋整理，結果更新到這筆紀錄並複製到剪貼簿
  func retry(_ e: HistoryEntry) {
    guard let url = e.audioURL, let wav = try? Data(contentsOf: url) else { flash("這筆沒有保存錄音"); return }
    retrying.insert(e.id)
    var ctx = Context()
    ctx.bundle = e.app
    Task {
      let o = await compute(wav, ctx: ctx, mode: e.kind)
      await MainActor.run {
        self.retrying.remove(e.id)
        if let err = o.error { self.flash(err); return }
        var n = e
        n.raw = o.raw; n.text = o.text
        n.status = o.note == "answer" ? "answer" : (o.text.isEmpty ? "empty" : "ok")
        HistoryStore.update(n)
        self.reload()
        if !o.text.isEmpty { self.copy(o.text) }
      }
    }
  }

  func saveAudio(_ e: HistoryEntry) {
    guard let url = e.audioURL else { return }
    let p = NSSavePanel()
    p.nameFieldStringValue = "HAUS Type \(e.id).wav"
    p.allowedContentTypes = [.wav]
    NSApp.activate(ignoringOtherApps: true)
    if p.runModal() == .OK, let dest = p.url { try? FileManager.default.copyItem(at: url, to: dest) }
  }
}

struct HistoryView: View {
  @StateObject var m = HistoryModel()
  @State var tab: Int
  @State var query = ""
  init(tab: Int = 0) { _tab = State(initialValue: tab) }
  private let tabs = ["總覽", "全部", "口述", "翻譯", "提問"]

  var filtered: [HistoryEntry] {
    let kind: Mode? = tab == 2 ? .dictate : tab == 3 ? .translate : tab == 4 ? .ask : nil
    return m.items.filter { e in
      (kind == nil || e.kind == kind) &&
        (query.isEmpty || e.text.localizedCaseInsensitiveContains(query) || e.raw.localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // 分頁列：純文字＋底線
      HStack(spacing: 22) {
        ForEach(tabs.indices, id: \.self) { i in
          Button { tab = i; m.reload() } label: {
            VStack(spacing: 5) {
              Text(tabs[i]).fontWeight(tab == i ? .semibold : .regular).foregroundStyle(tab == i ? Color.primary : Color.secondary)
              Rectangle().fill(tab == i ? Color.accentColor : Color.clear).frame(height: 2)
            }.fixedSize()
          }.buttonStyle(.plain)
        }
      }
      .padding(.top, 12)
      Divider()
      if tab == 0 { OverviewView() } else { historyList }
    }
    .frame(width: 680, height: 600)
  }

  var historyList: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("搜尋", text: $query).textFieldStyle(.roundedBorder)
        Picker("保存", selection: Binding(get: { m.historyDays }, set: { m.setRetention(history: $0) })) {
          ForEach(retentionOptions, id: \.0) { Text($0.1).tag($0.0) }
        }.frame(width: 130)
        Picker("錄音", selection: Binding(get: { m.audioDays }, set: { m.setRetention(audio: $0) })) {
          ForEach(retentionOptions, id: \.0) { Text($0.1).tag($0.0) }
        }.frame(width: 130)
        Button("全部刪除") { m.deleteAll() }
      }
      .padding(10)
      if !m.notice.isEmpty { Text(m.notice).font(.caption).foregroundStyle(.secondary).padding(.bottom, 4) }
      if filtered.isEmpty {
        Spacer()
        Text(m.historyDays == 0 ? "目前設定為不保存歷史" : "還沒有紀錄").foregroundStyle(.secondary)
        Spacer()
      } else {
        List(filtered) { e in row(e) }
      }
    }
  }

  func statusText(_ e: HistoryEntry) -> String? {
    switch e.status {
    case "cancelled": return "已取消"
    case "error": return "失敗：\(e.extra["error"] as? String ?? "")"
    case "empty": return "沒有聽到內容"
    default: return nil
    }
  }

  func row(_ e: HistoryEntry) -> some View {
    let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
    let app = e.app.split(separator: ".").last.map(String.init) ?? ""
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text("\(f.string(from: e.date))  \(e.kind.label)  \(app)").font(.caption).foregroundStyle(.secondary)
        if let w = e.waitMs, e.status == "ok" { Text("等待 \(w) ms").font(.caption).foregroundStyle(.tertiary) }
        Spacer()
        if m.retrying.contains(e.id) { Text("重試中…").font(.caption).foregroundStyle(.secondary) }
        if !e.text.isEmpty { Button("複製") { m.copy(e.text) }.buttonStyle(.borderless) }
        Menu("更多") {
          if !e.raw.isEmpty && e.raw != e.text { Button("複製原稿") { m.copy(e.raw) } }
          if e.audio != nil {
            Button("重試") { m.retry(e) }
            Button("另存錄音…") { m.saveAudio(e) }
          }
          Divider()
          Button("刪除") { m.delete(e) }
        }
        .menuStyle(.borderlessButton).fixedSize()
      }
      if let st = statusText(e) { Text(st).font(.callout).foregroundStyle(.orange) }
      if !e.text.isEmpty {
        Text(e.status == "answer" ? "問：\(e.raw)" : e.text).textSelection(.enabled)
        if e.status == "answer" { Text(e.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6) }
      }
      if !e.raw.isEmpty && e.raw != e.text && e.status == "ok" {
        Text(e.raw).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - 總覽

struct OverviewView: View {
  let s = Stats.summary()
  let days = Stats.load()

  func fmtHours(_ h: Double) -> String { h >= 1 ? String(format: "%.1f 小時", h) : "\(Int(h * 60)) 分鐘" }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("講出來，不要打字").font(.largeTitle).bold()
        // 數字：純文字排版，不用卡片框
        Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 18) {
          GridRow {
            stat("\(s.chars.formatted()) 字", "口述字數")
            stat(fmtHours(s.savedHours), "省下的時間（以打字每分鐘 40 字估算）")
          }
          GridRow {
            stat("\(s.perMinute) 字", "平均每分鐘")
            stat(fmtHours(s.seconds / 3600), "總口述時間")
          }
          GridRow {
            stat("\(s.activeDays) 天", "活躍天數")
            stat("\(s.streak) 天／\(s.longest) 天", "目前連續／最長連續")
          }
        }
        Text("使用熱度（最近 26 週）").font(.headline)
        Heatmap(days: days)
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  func stat(_ v: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(v).font(.title).bold().monospacedDigit()
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}

// 熱度圖：每格一天，直欄是一週；方格不加圓角
struct Heatmap: View {
  let days: [String: DayStat]
  let weeks = 26
  let cell: CGFloat = 14
  let gap: CGFloat = 3

  var body: some View {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let weekday = cal.component(.weekday, from: today) - 1  // 0＝週日
    let start = cal.date(byAdding: .day, value: -(weeks - 1) * 7 - weekday, to: today)!
    let maxCount = max(1, days.values.map(\.count).max() ?? 1)
    return HStack(alignment: .top, spacing: gap) {
      ForEach(0..<weeks, id: \.self) { w in
        VStack(spacing: gap) {
          ForEach(0..<7, id: \.self) { d in
            let date = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
            let n = days[Stats.dayFormat.string(from: date)]?.count ?? 0
            Rectangle()
              .fill(date > today ? Color.clear : n == 0 ? Color.secondary.opacity(0.15)
                    : Color(red: 0, green: 0.306, blue: 0.635).opacity(0.3 + 0.7 * Double(n) / Double(maxCount)))
              .frame(width: cell, height: cell)
              .help("\(Stats.dayFormat.string(from: date))：\(n) 段")
          }
        }
      }
    }
  }
}
