// 跟 Typeless 雙向同步詞庫（不使用 Typeless 的登入憑證）。
// Typeless → YuVoice：讀 Typeless（Electron）本機的 HTTP 快取裡 /user/dictionary/list 的回應（brotli 壓縮的 JSON），
//   寫進 vocabulary.txt 的「Typeless 同步區」。快取只在使用者打開 Typeless 字典頁時更新。
// YuVoice → Typeless：把 YuVoice 有、Typeless 沒有的詞寫成一欄 CSV（一行一個詞），
//   使用者在 Typeless 字典頁按「匯入 CSV」。寫入 Typeless 必須經過它的伺服器，所以這一步留給使用者按。

import Compression
import Foundation

let typelessCacheDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Typeless/Partitions/no-proxy-session/Cache/Cache_Data")
let typelessCSV = homeDir.appendingPathComponent("typeless-import.csv")
let syncBegin = "# ==== Typeless 同步區開始（自動產生，這一區不要手改；要刪詞請到 Typeless 字典刪） ===="
let syncEnd = "# ==== Typeless 同步區結束 ===="

struct TypelessDict {
  var terms: [String]
  var total: Int
  var updated: Date
}

// Chromium simple cache 一筆：24 位元組檔頭（第 12 位元組起是 key 長度）＋ key ＋ body ＋ EOF 記號
private let eofMagic: [UInt8] = [0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4]

private func brotliDecode(_ data: Data) -> Data? {
  let cap = 4 * 1024 * 1024
  var out = Data(count: cap)
  let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
    data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
      compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_BROTLI)
    }
  }
  return n > 0 ? out.prefix(n) : nil
}

// 讀一筆快取：回傳 (網址, body)；不是字典清單就回 nil
private func readCacheEntry(_ url: URL) -> (String, Data)? {
  // 先只讀檔頭看網址，不是字典清單就跳過（快取資料夾可能有上千個檔）
  guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
  let head = (try? h.read(upToCount: 512)) ?? Data()
  try? h.close()
  guard head.range(of: Data("api.typeless.com/user/dictionary/list".utf8)) != nil else { return nil }
  guard let b = try? Data(contentsOf: url), b.count > 32 else { return nil }
  let bytes = [UInt8](b)
  let keyLen = Int(UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24)
  guard 24 + keyLen < bytes.count, let key = String(bytes: bytes[24..<(24 + keyLen)], encoding: .utf8),
        key.contains("api.typeless.com/user/dictionary/list") else { return nil }
  let start = 24 + keyLen
  var end = -1
  var i = start
  while i + 8 <= bytes.count {
    if Array(bytes[i..<(i + 8)]) == eofMagic { end = i; break }
    i += 1
  }
  guard end > start else { return nil }
  let raw = Data(bytes[start..<end])
  // 正常是 brotli；萬一沒壓縮就直接用
  return (key, brotliDecode(raw) ?? raw)
}

// 找最新的「完整清單」快取（網址沒有 category／auto 篩選）；沒有就合併最新的 auto=true＋auto=false
func readTypelessDictionary() -> TypelessDict? {
  guard let files = try? FileManager.default.contentsOfDirectory(at: typelessCacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
  var best: [String: (Date, [String], Int)] = [:]
  for f in files where f.lastPathComponent.hasSuffix("_0") {
    guard let (key, body) = readCacheEntry(f),
          let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          let data = obj["data"] as? [String: Any], let words = data["words"] as? [[String: Any]] else { continue }
    let kind = key.contains("category=") ? "category" : key.contains("auto=true") ? "auto" : key.contains("auto=false") ? "manual" : "all"
    if kind == "category" { continue }
    let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    let terms = words.compactMap { $0["term"] as? String }
    let total = data["total_count"] as? Int ?? terms.count
    if best[kind].map({ date > $0.0 }) ?? true { best[kind] = (date, terms, total) }
  }
  if let all = best["all"], all.0 >= max(best["auto"]?.0 ?? .distantPast, best["manual"]?.0 ?? .distantPast) {
    return TypelessDict(terms: all.1, total: all.2, updated: all.0)
  }
  guard best["auto"] != nil || best["manual"] != nil else { return best["all"].map { TypelessDict(terms: $0.1, total: $0.2, updated: $0.0) } }
  let a = best["auto"], m = best["manual"]
  return TypelessDict(terms: (m?.1 ?? []) + (a?.1 ?? []), total: (m?.2 ?? 0) + (a?.2 ?? 0),
                      updated: max(a?.0 ?? .distantPast, m?.0 ?? .distantPast))
}

// 詞彙表一行去掉括號註記（「GitHub（get hub）」→「GitHub」），比對時不分大小寫、忽略空白
func baseTerm(_ line: String) -> String {
  var s = line
  if let r = s.range(of: "（") ?? s.range(of: "(") { s = String(s[..<r.lowerBound]) }
  return s.trimmingCharacters(in: .whitespaces)
}

private func norm(_ s: String) -> String { baseTerm(s).lowercased().replacingOccurrences(of: " ", with: "") }

struct SyncReport {
  var pulled = 0       // 寫進同步區的詞數
  var pushed = 0       // CSV 裡要匯入 Typeless 的詞數
  var typelessTotal = 0
  var updated: Date?
  var paged = false    // Typeless 詞數超過一頁，快取只有前 150 個
  var changed = false  // 詞彙表這次有沒有變
  var error: String?
}

// 同步：更新 vocabulary.txt 的同步區，並產生要匯入 Typeless 的 CSV
func syncWithTypeless(writeCSV: Bool) -> SyncReport {
  var rep = SyncReport()
  guard let dict = readTypelessDictionary() else {
    rep.error = "找不到 Typeless 字典快取：請先打開 Typeless 的「字典」頁一次"
    return rep
  }
  rep.typelessTotal = dict.total
  rep.updated = dict.updated
  rep.paged = dict.total > dict.terms.count
  let text = (try? String(contentsOf: vocabURL, encoding: .utf8)) ?? ""
  // 拆出使用者自己寫的部分（同步區以外）
  var userLines: [String] = []
  var inSync = false
  for line in text.components(separatedBy: "\n") {
    if line == syncBegin { inSync = true; continue }
    if line == syncEnd { inSync = false; continue }
    if !inSync { userLines.append(line) }
  }
  while userLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { userLines.removeLast() }
  let userTerms = userLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
  let userKeys = Set(userTerms.map(norm))
  // Typeless → YuVoice：使用者區已經有的不重複寫
  var seen = Set<String>()
  let pulled = dict.terms.filter { t in
    let k = norm(t)
    guard !k.isEmpty, !userKeys.contains(k), !seen.contains(k) else { return false }
    seen.insert(k); return true
  }
  rep.pulled = pulled.count
  let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
  let block = [syncBegin, "# Typeless 快取時間 \(f.string(from: dict.updated))，共 \(dict.total) 個詞"] + pulled + [syncEnd]
  let newText = (userLines + [""] + block).joined(separator: "\n") + "\n"
  if newText != text { try? newText.write(to: vocabURL, atomically: true, encoding: .utf8); rep.changed = true }
  // YuVoice → Typeless：使用者區有、Typeless 沒有的詞
  if writeCSV {
    let typelessKeys = Set(dict.terms.map(norm))
    var pushSeen = Set<String>()
    let push = userTerms.map(baseTerm).filter { t in
      let k = norm(t)
      guard !k.isEmpty, !typelessKeys.contains(k), !pushSeen.contains(k) else { return false }
      pushSeen.insert(k); return true
    }
    rep.pushed = push.count
    // CSV 欄位裡有逗號或引號就用雙引號包起來
    let csv = push.map { $0.contains(",") || $0.contains("\"") ? "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" : $0 }
      .joined(separator: "\n") + "\n"
    try? csv.write(to: typelessCSV, atomically: true, encoding: .utf8)
  }
  return rep
}
