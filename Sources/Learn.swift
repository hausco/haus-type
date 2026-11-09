// 自動學詞：貼上後 30 秒內，每 3 秒讀一次那個輸入框；使用者把我們打出的某個詞改掉，
// 就請 AI 判斷改成的是不是值得記住的專有名詞，是的話加進詞彙表的「自動新增」，並把原本聽錯的樣子寫在括號裡。

import AppKit
import ApplicationServices
import Foundation

enum Learner {
  private static var timer: Timer?

  private static func focusedValue(_ pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var f: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success, let el = f else { return nil }
    let field = el as! AXUIElement
    if (axString(field, kAXSubroleAttribute) ?? "") == "AXSecureTextField" { return nil }
    return axString(field, kAXValueAttribute)
  }

  // 貼上後呼叫：pasted 是我們打進去的字
  static func watch(pid: pid_t, pasted: String) {
    guard config.bool("autoLearn"), pasted.count >= 2, !config.strings("noContextApps").contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "") else { return }
    timer?.invalidate()
    var baseline: String?
    var ticks = 0
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      baseline = focusedValue(pid)
      guard let b = baseline, b.contains(pasted) else { return }  // 讀不到或不是我們貼的那個框：不學
      timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in
        ticks += 1
        guard ticks <= 10, let now = focusedValue(pid) else { t.invalidate(); return }
        guard now != b, let (old, new) = changedWord(before: b, after: now, pasted: pasted) else { return }
        t.invalidate()
        Task { await judge(old: old, new: new, sentence: pasted) }
      }
    }
  }

  // 比對前後兩版：去掉共同的頭尾，剩下的就是使用者改的部分；要落在我們貼的字裡、而且是短詞
  static func changedWord(before: String, after: String, pasted: String) -> (String, String)? {
    let a = Array(before), b = Array(after)
    var p = 0
    while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
    var s = 0
    while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
    var oldPart = String(a[p..<(a.count - s)]), newPart = String(b[p..<(b.count - s)])
    // 英文要延伸到整個單字
    var lo = p, hiA = a.count - s, hiB = b.count - s
    while lo > 0, a[lo - 1].isLetter, a[lo - 1].isASCII { lo -= 1 }
    while hiA < a.count, a[hiA].isLetter, a[hiA].isASCII { hiA += 1; hiB += 1 }
    if lo != p || hiA != a.count - s { oldPart = String(a[lo..<hiA]); newPart = String(b[lo..<min(hiB, b.count)]) }
    let o = oldPart.trimmingCharacters(in: .whitespacesAndNewlines), n = newPart.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !o.isEmpty, !n.isEmpty, o != n, o.count <= 20, n.count <= 20, pasted.contains(o),
          n.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
    return (o, n)
  }

  static func judge(old: String, new: String, sentence: String) async {
    guard let key = apiKey() else { return }
    let prompt = """
    使用者用語音輸入，系統打出「\(old)」，使用者馬上手動改成「\(new)」。整句：「\(sentence)」。
    判斷「\(new)」是不是值得記進個人詞彙表的詞：人名、地名、品牌、產品、組織、縮寫、專業術語，或使用者固定的特殊寫法。
    只是修正錯別字、改語氣、增刪贅字、改標點的不算。
    term 是完整的正確詞（例如整個人名，不是只有改掉的那個字）；heard 是這個詞在原句裡被聽錯的完整樣子。
    只輸出 JSON：{"add": true 或 false, "term": "正確寫法", "heard": "原句裡聽錯的樣子", "category": "人名、地點、組織與產品、縮寫、專業術語、一般 其中一個"}
    """
    let body: [String: Any] = [
      "model": config.string("cleanupModel"), "max_tokens": 200,
      "messages": [["role": "user", "content": prompt]],
      "reasoning": config.any("reasoning") ?? defaultConfig["reasoning"]!,
    ]
    guard let obj = try? await postJSON(config.string("chatURL"), body, key: key, timeout: 10),
          let content = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
          let s = content.firstIndex(of: "{"), let e = content.lastIndex(of: "}"),
          let r = (try? JSONSerialization.jsonObject(with: Data(String(content[s...e]).utf8))) as? [String: Any],
          r["add"] as? Bool == true, let term = r["term"] as? String, !term.isEmpty else {
      log("自動學詞：「\(old)」→「\(new)」不收")
      return
    }
    let cat = vocabCategories.contains(r["category"] as? String ?? "") ? r["category"] as! String : "一般"
    let heard = (r["heard"] as? String).flatMap { $0.isEmpty || $0 == term ? nil : $0 } ?? old
    switch VocabStore.add("\(term)（\(heard)）", category: cat, auto: true) {
    case "added": log("自動學詞：加入「\(term)（\(heard)）」，分類 \(cat)")
    case "updated": log("自動學詞：「\(term)」已在詞彙表，補上誤聽「\(heard)」")
    default: log("自動學詞：「\(term)」已在詞彙表")
    }
  }

  // 個人化程度：最近 100 段裡，整理結果用到詞彙表、而原稿沒有的段數
  static func personalization() -> (hits: Int, total: Int) {
    let terms = vocabulary().map(baseTerm).filter { $0.count >= 2 }
    let recent = HistoryStore.load().filter { $0.status == "ok" }.suffix(100)
    let hits = recent.filter { e in terms.contains { e.text.contains($0) && !e.raw.contains($0) } }.count
    return (hits, recent.count)
  }
}
