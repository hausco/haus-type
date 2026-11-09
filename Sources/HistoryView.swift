// 歷史紀錄視窗：最近 300 段的整理結果與原稿，可以複製。資料來源是 ~/.yuvoice/history.jsonl。

import SwiftUI

struct HistoryItem: Identifiable {
  let id = UUID()
  let time: String
  let app: String
  let text: String
  let raw: String
  let waitMs: Int?
}

func loadHistory(limit: Int = 300) -> [HistoryItem] {
  guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
  let iso = ISO8601DateFormatter()
  let out = DateFormatter(); out.dateFormat = "M/d HH:mm"
  return text.split(separator: "\n").suffix(limit).reversed().compactMap { line in
    guard let d = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
    let ts = (o["ts"] as? String).flatMap { iso.date(from: $0) }.map { out.string(from: $0) } ?? ""
    let app = (o["app"] as? String ?? "").split(separator: ".").last.map(String.init) ?? ""
    return HistoryItem(time: ts, app: app, text: o["text"] as? String ?? "", raw: o["raw"] as? String ?? "", waitMs: o["wait_ms"] as? Int)
  }.filter { !$0.text.isEmpty || !$0.raw.isEmpty }
}

struct HistoryView: View {
  @State var items = loadHistory()
  @State var query = ""

  var filtered: [HistoryItem] {
    query.isEmpty ? items : items.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.raw.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("搜尋", text: $query).textFieldStyle(.roundedBorder)
        Button("重新整理") { items = loadHistory() }
      }
      .padding(10)
      List(filtered) { it in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("\(it.time)  \(it.app)").font(.caption).foregroundStyle(.secondary)
            if let w = it.waitMs { Text("等待 \(w) ms").font(.caption).foregroundStyle(.tertiary) }
            Spacer()
            Button("複製") { copy(it.text) }.buttonStyle(.borderless)
            if it.raw != it.text { Button("複製原稿") { copy(it.raw) }.buttonStyle(.borderless) }
          }
          Text(it.text).textSelection(.enabled)
          if it.raw != it.text { Text(it.raw).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(.vertical, 4)
      }
    }
    .frame(width: 620, height: 520)
  }

  func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
  }
}
