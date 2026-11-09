// 詞彙表讀寫：vocabulary.txt 分成「使用者區」與「Typeless 同步區」（見 TypelessSync.swift）。
// 設定視窗只編輯使用者區，存檔時同步區原樣保留。

import Foundation

enum VocabStore {
  // 使用者自己的詞（不含註解、不含同步區）
  static func userTerms() -> [String] {
    let text = (try? String(contentsOf: vocabURL, encoding: .utf8)) ?? ""
    var out: [String] = []
    var inSync = false
    for line in text.components(separatedBy: "\n") {
      if line == syncBegin { inSync = true; continue }
      if line == syncEnd { inSync = false; continue }
      let t = line.trimmingCharacters(in: .whitespaces)
      if !inSync, !t.isEmpty, !t.hasPrefix("#") { out.append(t) }
    }
    return out
  }

  // 同步區原文（含開始、結束標記），沒有就是空陣列
  static func syncBlock() -> [String] {
    let text = (try? String(contentsOf: vocabURL, encoding: .utf8)) ?? ""
    var out: [String] = []
    var inSync = false
    for line in text.components(separatedBy: "\n") {
      if line == syncBegin { inSync = true }
      if inSync { out.append(line) }
      if line == syncEnd { inSync = false }
    }
    return out
  }

  static func syncedCount() -> Int {
    syncBlock().filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
  }

  // 寫回使用者區，保留同步區。原本的註解與分組照舊留在原位：
  // 被刪掉的詞拿掉、還在的詞留在原行、新詞加在使用者區最後
  static func save(_ terms: [String]) {
    let text = (try? String(contentsOf: vocabURL, encoding: .utf8)) ?? ""
    var keep = Set(terms)
    var lines: [String] = []
    var inSync = false
    for line in text.components(separatedBy: "\n") {
      if line == syncBegin { inSync = true; continue }
      if line == syncEnd { inSync = false; continue }
      if inSync { continue }
      let t = line.trimmingCharacters(in: .whitespaces)
      if t.isEmpty || t.hasPrefix("#") { lines.append(line); continue }
      if keep.contains(t) { lines.append(line); keep.remove(t) }
    }
    if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      lines = ["# HAUS Type 專有名詞表：一行一個，# 開頭是註解。",
               "# 括號裡寫常被聽錯的樣子，例如「GitHub（get hub、吉哈布）」。改完下一段話就會用新的。"]
    }
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
    lines += terms.filter { keep.contains($0) }
    let block = syncBlock()
    if !block.isEmpty { lines += [""] + block }
    try? (lines.joined(separator: "\n") + "\n").write(to: vocabURL, atomically: true, encoding: .utf8)
  }
}

// MARK: - 分類與來源（vocab-meta.json）

let vocabMetaURL = homeDir.appendingPathComponent("vocab-meta.json")
let vocabCategories = ["人名", "地點", "組織與產品", "縮寫", "專業術語", "一般"]

struct VocabMeta: Codable {
  var category: String
  var auto: Bool
  var added: Date
}

struct VocabItem: Identifiable, Hashable {
  var id: String { line }
  let line: String        // 檔案裡的整行（可能含括號誤聽註記）
  let category: String
  let source: String      // manual、auto、typeless
}

extension VocabStore {
  static func key(_ term: String) -> String { baseTerm(term).lowercased() }

  static func loadMeta() -> [String: VocabMeta] {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    return (try? d.decode([String: VocabMeta].self, from: Data(contentsOf: vocabMetaURL))) ?? [:]
  }

  static func saveMeta(_ m: [String: VocabMeta]) {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? e.encode(m) { try? data.write(to: vocabMetaURL) }
  }

  // 全部詞條：使用者區（手動或自動學到）＋ Typeless 同步區
  static func items() -> [VocabItem] {
    let meta = loadMeta()
    var out = userTerms().map { line -> VocabItem in
      let m = meta[key(line)]
      return VocabItem(line: line, category: m?.category ?? "一般", source: m?.auto == true ? "auto" : "manual")
    }
    let synced = syncBlock().filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    out += synced.map { VocabItem(line: $0, category: meta[key($0)]?.category ?? "一般", source: "typeless") }
    return out
  }

  // 回傳 added（新詞）、updated（已有的詞補上誤聽註記）或 nil（已經有了，沒有變動）
  @discardableResult
  static func add(_ line: String, category: String, auto: Bool) -> String? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }
    var terms = userTerms()
    if let i = terms.firstIndex(where: { key($0) == key(t) }) {
      // 已有這個詞：把新的誤聽樣子併進括號
      let heard = hints(t).filter { !hints(terms[i]).contains($0) }
      guard !heard.isEmpty else { return nil }
      terms[i] = "\(baseTerm(terms[i]))（\((hints(terms[i]) + heard).joined(separator: "、"))）"
      save(terms)
      return "updated"
    }
    // Typeless 同步區已有：不重複加
    if syncBlock().contains(where: { key($0) == key(t) }) { return nil }
    terms.append(t)
    save(terms)
    var m = loadMeta()
    m[key(t)] = VocabMeta(category: category, auto: auto, added: Date())
    saveMeta(m)
    return "added"
  }

  // 括號裡的誤聽樣子：「GitHub（get hub、吉哈布）」→ ["get hub", "吉哈布"]
  static func hints(_ line: String) -> [String] {
    guard let l = line.firstIndex(where: { $0 == "（" || $0 == "(" }), let r = line.lastIndex(where: { $0 == "）" || $0 == ")" }), l < r else { return [] }
    return line[line.index(after: l)..<r].split(whereSeparator: { $0 == "、" || $0 == "," || $0 == "，" })
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  // 編輯：改字或改分類；自動學到的詞被手動編輯後算手動
  static func edit(_ old: String, to new: String, category: String) {
    var terms = userTerms()
    guard let i = terms.firstIndex(of: old) else {
      // Typeless 同步的詞只能改分類
      var m = loadMeta(); var v = m[key(old)] ?? VocabMeta(category: category, auto: false, added: Date())
      v.category = category; m[key(old)] = v; saveMeta(m); return
    }
    terms[i] = new.trimmingCharacters(in: .whitespaces)
    save(terms)
    var m = loadMeta()
    let added = m[key(old)]?.added ?? Date()
    m.removeValue(forKey: key(old))
    m[key(new)] = VocabMeta(category: category, auto: false, added: added)
    saveMeta(m)
  }

  static func delete(_ lines: Set<String>) {
    save(userTerms().filter { !lines.contains($0) })
    var m = loadMeta()
    for l in lines { m.removeValue(forKey: key(l)) }
    saveMeta(m)
  }
}


// 用 AI 幫還沒分類的詞分類（一次送全部，回傳分好的數量）
func autoCategorizeVocab() async -> Int {
  guard let key = apiKey() else { return 0 }
  let meta = VocabStore.loadMeta()
  let todo = VocabStore.items().map { baseTerm($0.line) }.filter { meta[$0.lowercased()] == nil }
  guard !todo.isEmpty else { return 0 }
  let prompt = """
  把下面每個詞分到這六類之一：人名、地點、組織與產品、縮寫、專業術語、一般。
  只輸出 JSON 物件，key 是詞、value 是分類，不要其他文字。
  \(todo.prefix(400).joined(separator: "\n"))
  """
  let body: [String: Any] = ["model": config.string("cleanupModel"), "max_tokens": 8000,
                             "messages": [["role": "user", "content": prompt]],
                             "reasoning": config.any("reasoning") ?? defaultConfig["reasoning"]!]
  guard let obj = try? await postJSON(config.string("chatURL"), body, key: key, timeout: 60),
        let content = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
        let a = content.firstIndex(of: "{"), let b = content.lastIndex(of: "}"),
        let map = (try? JSONSerialization.jsonObject(with: Data(String(content[a...b]).utf8))) as? [String: String] else { return 0 }
  var m = VocabStore.loadMeta()
  var n = 0
  for (term, cat) in map where vocabCategories.contains(cat) && m[term.lowercased()] == nil {
    m[term.lowercased()] = VocabMeta(category: cat, auto: false, added: Date()); n += 1
  }
  VocabStore.saveMeta(m)
  return n
}
