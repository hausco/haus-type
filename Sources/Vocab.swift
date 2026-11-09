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
      lines = ["# YuVoice 專有名詞表：一行一個，# 開頭是註解。",
               "# 括號裡寫常被聽錯的樣子，例如「GitHub（get hub、吉哈布）」。改完下一段話就會用新的。"]
    }
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
    lines += terms.filter { keep.contains($0) }
    let block = syncBlock()
    if !block.isEmpty { lines += [""] + block }
    try? (lines.joined(separator: "\n") + "\n").write(to: vocabURL, atomically: true, encoding: .utf8)
  }
}
