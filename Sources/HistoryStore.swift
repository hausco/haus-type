// 歷史紀錄與統計的儲存：history.jsonl（每段一行）、audio/（每段的錄音，給重試與另存用）、stats.json（每日統計）。
// 歷史與錄音依保存期限自動清除；統計另外累計，清歷史不影響統計。

import Foundation

let audioDir = homeDir.appendingPathComponent("audio")
let statsURL = homeDir.appendingPathComponent("stats.json")

struct HistoryEntry: Identifiable {
  var id: String
  var date: Date
  var app: String
  var kind: Mode          // 口述／翻譯／提問
  var status: String      // ok、answer、cancelled、error、empty
  var raw: String
  var text: String
  var seconds: Double
  var waitMs: Int?
  var audio: String?      // audio/ 底下的檔名
  var extra: [String: Any] // 其他欄位原樣保留

  var audioURL: URL? { audio.map { audioDir.appendingPathComponent($0) } }

  init?(_ o: [String: Any]) {
    let iso = ISO8601DateFormatter()
    guard let ts = o["ts"] as? String, let d = iso.date(from: ts) else { return nil }
    id = o["id"] as? String ?? ts
    date = d
    app = o["app"] as? String ?? ""
    kind = Mode(rawValue: o["kind"] as? String ?? "dictate") ?? .dictate
    let note = o["mode"] as? String ?? ""
    status = o["status"] as? String ?? (note == "answer" ? "answer" : "ok")
    raw = o["raw"] as? String ?? ""
    text = o["text"] as? String ?? ""
    seconds = (o["seconds"] as? NSNumber)?.doubleValue ?? 0
    waitMs = o["wait_ms"] as? Int
    audio = o["audio"] as? String
    extra = o
  }

  var dict: [String: Any] {
    var o = extra
    o["id"] = id; o["ts"] = ISO8601DateFormatter().string(from: date); o["app"] = app; o["kind"] = kind.rawValue
    o["status"] = status; o["raw"] = raw; o["text"] = text; o["seconds"] = seconds
    if let a = audio { o["audio"] = a } else { o.removeValue(forKey: "audio") }
    return o
  }
}

enum HistoryStore {
  private static let lock = NSLock()

  static func newID() -> String {
    let f = DateFormatter(); f.dateFormat = "yyMMdd-HHmmss"
    return "\(f.string(from: Date()))-\(UUID().uuidString.prefix(6))"
  }

  // 把錄音存檔，回傳檔名；保存期限是「不保存」就不存
  static func saveAudio(_ wav: Data, id: String) -> String? {
    guard config.double("historyDays") != 0, config.double("audioDays") != 0 else { return nil }
    try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    let name = "\(id).wav"
    return (try? wav.write(to: audioDir.appendingPathComponent(name))) != nil ? name : nil
  }

  static func load() -> [HistoryEntry] {
    guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
      guard let d = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
      return HistoryEntry(o)
    }
  }

  private static func write(_ entries: [HistoryEntry]) {
    let lines = entries.compactMap { e -> String? in
      guard let d = try? JSONSerialization.data(withJSONObject: e.dict) else { return nil }
      return String(data: d, encoding: .utf8)
    }
    try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: historyURL, atomically: true, encoding: .utf8)
  }

  // 新增一段：寫歷史（保存期限不是「不保存」時）並累計統計
  static func append(_ entry: [String: Any]) {
    lock.lock(); defer { lock.unlock() }
    if let e = HistoryEntry(entry) { Stats.add(e) }
    guard config.double("historyDays") != 0 else { return }
    guard let d = try? JSONSerialization.data(withJSONObject: entry), var line = String(data: d, encoding: .utf8) else { return }
    line += "\n"
    if let h = try? FileHandle(forWritingTo: historyURL) {
      h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
      try? line.write(to: historyURL, atomically: true, encoding: .utf8)
    }
  }

  static func update(_ e: HistoryEntry) {
    lock.lock(); defer { lock.unlock() }
    var all = load()
    if let i = all.firstIndex(where: { $0.id == e.id }) { all[i] = e; write(all) }
  }

  static func delete(_ ids: Set<String>) {
    lock.lock(); defer { lock.unlock() }
    var all = load()
    for e in all where ids.contains(e.id) { if let u = e.audioURL { try? FileManager.default.removeItem(at: u) } }
    all.removeAll { ids.contains($0.id) }
    write(all)
  }

  static func deleteAll() {
    lock.lock(); defer { lock.unlock() }
    try? FileManager.default.removeItem(at: historyURL)
    try? FileManager.default.removeItem(at: audioDir)
  }

  // 依保存期限清掉過期的歷史與錄音（historyDays／audioDays：-1 永久、0 不保存、其他是天數）
  static func prune() {
    lock.lock(); defer { lock.unlock() }
    let hDays = config.double("historyDays"), aDays = config.double("audioDays")
    var all = load()
    let now = Date()
    if hDays == 0 {
      all = []
    } else if hDays > 0 {
      all.removeAll { now.timeIntervalSince($0.date) > hDays * 86400 }
    }
    var keepAudio = Set<String>()
    for i in all.indices {
      if let a = all[i].audio {
        if aDays == 0 || (aDays > 0 && now.timeIntervalSince(all[i].date) > aDays * 86400) { all[i].audio = nil } else { keepAudio.insert(a) }
      }
    }
    write(all)
    // 刪掉沒有被任何紀錄引用的錄音檔
    if let files = try? FileManager.default.contentsOfDirectory(atPath: audioDir.path) {
      for f in files where !keepAudio.contains(f) { try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(f)) }
    }
  }
}

// MARK: - 統計

struct DayStat: Codable {
  var chars = 0       // 打出去的字數（口述與翻譯）
  var seconds = 0.0   // 講話秒數
  var count = 0       // 段數
}

enum Stats {
  private static var cache: [String: DayStat]?
  static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

  static func load() -> [String: DayStat] {
    if let c = cache { return c }
    var days = (try? JSONDecoder().decode([String: DayStat].self, from: Data(contentsOf: statsURL))) ?? [:]
    // 第一次：用現有歷史補算
    if days.isEmpty {
      for e in HistoryStore.load() { add(e, into: &days) }
      save(days)
    }
    cache = days
    return days
  }

  private static func save(_ d: [String: DayStat]) {
    if let data = try? JSONEncoder().encode(d) { try? data.write(to: statsURL) }
  }

  private static func add(_ e: HistoryEntry, into days: inout [String: DayStat]) {
    guard e.status == "ok" || e.status == "answer" else { return }
    let k = dayFormat.string(from: e.date)
    var s = days[k] ?? DayStat()
    s.count += 1
    s.seconds += e.seconds
    if e.kind != .ask || e.status == "ok" { s.chars += e.text.count }
    days[k] = s
  }

  static func add(_ e: HistoryEntry) {
    var d = load()
    add(e, into: &d)
    cache = d
    save(d)
  }

  struct Summary {
    var chars = 0, count = 0, seconds = 0.0
    var activeDays = 0, streak = 0, longest = 0
    var perMinute: Int { seconds > 0 ? Int(Double(chars) / (seconds / 60)) : 0 }
    // 省下的時間：以打字每分鐘 40 字估算，扣掉實際講話時間
    var savedHours: Double { max(0, Double(chars) / 40 / 60 - seconds / 3600) }
  }

  static func summary() -> Summary {
    let days = load()
    var s = Summary()
    for (_, d) in days { s.chars += d.chars; s.count += d.count; s.seconds += d.seconds }
    let active = Set(days.filter { $0.value.count > 0 }.keys)
    s.activeDays = active.count
    // 連續天數：從今天（或昨天）往回數
    let cal = Calendar.current
    var day = Date()
    if !active.contains(dayFormat.string(from: day)) { day = cal.date(byAdding: .day, value: -1, to: day)! }
    while active.contains(dayFormat.string(from: day)) { s.streak += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
    // 最長連續
    let sorted = active.compactMap { dayFormat.date(from: $0) }.sorted()
    var run = 0, prev: Date?
    for d in sorted {
      if let p = prev, cal.dateComponents([.day], from: p, to: d).day == 1 { run += 1 } else { run = 1 }
      s.longest = max(s.longest, run); prev = d
    }
    return s
  }
}
