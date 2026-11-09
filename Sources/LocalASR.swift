// 本機辨識：用常駐的 Python 子行程跑 Breeze-ASR-25（MLX fp16），模型只載入一次。
// 錄音寫成暫存 WAV 交給子行程，轉完立刻刪掉；整個過程不送出網路。
// 找不到 Python 環境或模型、子行程起不來或逾時，呼叫端會自動退回雲端轉寫。

import Foundation

let localDir = homeDir.appendingPathComponent("local")

func expandPath(_ p: String) -> String { (p as NSString).expandingTildeInPath }

final class LocalASR {
  static let shared = LocalASR()

  enum State: Equatable { case off, starting, ready, failed(String) }

  private var process: Process?
  private var stdin: FileHandle?
  private var buffer = Data()
  private var pending: [String: CheckedContinuation<String, Error>] = [:]
  private let q = DispatchQueue(label: "haustype.localasr")
  private(set) var state: State = .off { didSet { NotificationCenter.default.post(name: .localASRState, object: nil) } }

  var pythonPath: String { expandPath(config.string("localPython")) }
  var modelPath: String { expandPath(config.string("localModel")) }

  // 環境檢查：回傳 nil 代表可以用，否則是看得懂的原因
  func missingReason() -> String? {
    let fm = FileManager.default
    if !fm.isExecutableFile(atPath: pythonPath) { return "找不到本機辨識的 Python 環境（\(config.string("localPython"))）" }
    if !fm.fileExists(atPath: (modelPath as NSString).appendingPathComponent("weights.safetensors")) { return "找不到本機模型（\(config.string("localModel"))）" }
    if serverScript() == nil { return "找不到本機辨識程式" }
    return nil
  }

  private func serverScript() -> String? {
    if let p = Bundle.main.path(forResource: "breeze_server", ofType: "py") { return p }
    let dev = localDir.appendingPathComponent("breeze_server.py").path
    return FileManager.default.fileExists(atPath: dev) ? dev : nil
  }

  // 啟動子行程並載入模型（已啟動就不重來）
  func start() {
    q.async {
      if self.process?.isRunning == true { return }
      if let why = self.missingReason() { self.state = .failed(why); return }
      self.state = .starting
      let p = Process()
      p.executableURL = URL(fileURLWithPath: self.pythonPath)
      p.arguments = ["-u", self.serverScript()!, "--model", self.modelPath]
      let inPipe = Pipe(), outPipe = Pipe()
      p.standardInput = inPipe
      p.standardOutput = outPipe
      p.standardError = FileHandle.nullDevice
      outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
        let d = h.availableData
        guard !d.isEmpty else { return }
        self?.q.async { self?.consume(d) }
      }
      p.terminationHandler = { [weak self] _ in
        self?.q.async {
          self?.process = nil
          if case .ready = self?.state { self?.state = .off }
          for (_, c) in self?.pending ?? [:] { c.resume(throwing: APIError(message: "本機辨識程式結束了")) }
          self?.pending = [:]
        }
      }
      do { try p.run() } catch { self.state = .failed("本機辨識程式起不來：\(error.localizedDescription)"); return }
      self.process = p
      self.stdin = inPipe.fileHandleForWriting
    }
  }

  func stop() { q.async { self.process?.terminate(); self.process = nil; self.state = .off } }

  // 子行程每印一行就處理一次
  private func consume(_ d: Data) {
    buffer.append(d)
    while let nl = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<nl]
      buffer.removeSubrange(buffer.startIndex...nl)
      guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
      if let ready = o["ready"] as? Bool {
        state = ready ? .ready : .failed(o["error"] as? String ?? "本機模型載入失敗")
        log(ready ? "本機辨識就緒（載入 \(o["load_s"] ?? "?") 秒）" : "本機辨識失敗：\(o["error"] ?? "")")
        continue
      }
      guard let id = o["id"] as? String, let c = pending.removeValue(forKey: id) else { continue }
      if let t = o["text"] as? String { c.resume(returning: t) } else { c.resume(throwing: APIError(message: o["error"] as? String ?? "本機辨識失敗")) }
    }
  }

  // 詞彙表提示：Whisper 提示詞上限約 223 token，取前 80 字
  private func prompt() -> String {
    var out = ""
    for t in vocabulary().map(baseTerm) {
      if out.count + t.count + 1 > 80 { break }
      out += (out.isEmpty ? "" : "、") + t
    }
    return out
  }

  func transcribe(_ wav: Data, timeout: Double = 15) async throws -> String {
    start()
    // 等模型載入完成（第一次最多 20 秒）
    let deadline = Date().addingTimeInterval(20)
    while true {
      let s = q.sync { state }
      if s == .ready { break }
      if case .failed(let why) = s { throw APIError(message: why) }
      if Date() > deadline { throw APIError(message: "本機模型載入逾時") }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let tmp = localDir.appendingPathComponent("tmp")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let id = UUID().uuidString
    let file = tmp.appendingPathComponent("\(id).wav")
    try wav.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let req: [String: Any] = ["id": id, "wav": file.path, "prompt": prompt()]
    let line = try JSONSerialization.data(withJSONObject: req) + Data([0x0A])
    // 兩個子工作賽跑：本機結果（String）與逾時（nil）；逾時會把等待中的請求以錯誤結束
    return try await withThrowingTaskGroup(of: String?.self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
          self.q.async {
            self.pending[id] = c
            do { try self.stdin?.write(contentsOf: line) } catch {
              self.pending.removeValue(forKey: id)
              c.resume(throwing: APIError(message: "送不進本機辨識程式"))
            }
          }
        }
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        self.q.sync { if let c = self.pending.removeValue(forKey: id) { c.resume(throwing: APIError(message: "本機辨識逾時")) } }
        return nil
      }
      for try await r in group {
        if let text = r { group.cancelAll(); return text }
      }
      throw APIError(message: "本機辨識逾時")
    }
  }
}

extension Notification.Name {
  static let localASRState = Notification.Name("HausTypeLocalASRState")
}
