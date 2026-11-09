// HAUS Type 的提示音與浮動指示框（仿 Typeless：✕ 取消｜聲波｜✓ 完成；取消後顯示「轉錄已取消｜復原」）。

import Cocoa

// MARK: - 提示音（自己合成，不用系統的 Tink／Pop：聽起來像錯誤音）

enum Tone {
  // 產生一段柔和提示音（正弦波＋淡入淡出），回傳 44.1 kHz WAV
  static func make(_ freqs: [Double], noteMs: Double = 70, volume: Double = 0.18) -> Data {
    let rate = 44100.0
    var pcm = Data()
    for f in freqs {
      let n = Int(rate * noteMs / 1000)
      for i in 0..<n {
        let t = Double(i) / rate
        let env = min(1, Double(i) / (rate * 0.008)) * min(1, Double(n - i) / (rate * 0.03))
        var v = Int16(sin(2 * .pi * f * t) * env * volume * 32767).littleEndian
        pcm.append(Data(bytes: &v, count: 2))
      }
    }
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
    d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
    return d
  }
  // 開始：上升兩音；結束：下降兩音；取消：單一低音
  static let start = NSSound(data: make([660, 990]))
  static let stop = NSSound(data: make([880, 590]))
  static let cancel = NSSound(data: make([520], noteMs: 90))
}

// MARK: - 指示框的畫面

final class HUDView: NSView {
  enum Mode { case recording, processing, message, cancelled }
  var mode: Mode = .recording { didSet { needsDisplay = true } }
  var message = "" { didSet { needsDisplay = true } }
  var levels = [Float](repeating: 0, count: 18)
  // 翻譯／提問模式時在 ✕ 右邊顯示模式文字（口述模式為空）
  var modeLabel = "" { didSet { needsDisplay = true } }
  var onCancel: (() -> Void)?
  var onDone: (() -> Void)?
  var onUndo: (() -> Void)?
  private var phase = 0.0

  override var isFlipped: Bool { true }
  // 不用先點一下讓視窗取得焦點，第一下就能按
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  func push(_ level: Float) {
    levels.removeFirst()
    levels.append(level)
    needsDisplay = true
  }

  func tick() {
    phase += 0.25
    if mode == .processing { needsDisplay = true }
  }

  override func draw(_ dirty: NSRect) {
    // 單一膠囊底，裡面的元素都不加圓角底（遵守「圓角框不包圓角框」）
    let b = bounds
    NSColor(white: 0.06, alpha: 0.94).setFill()
    NSBezierPath(roundedRect: b, xRadius: b.height / 2, yRadius: b.height / 2).fill()
    switch mode {
    case .recording:
      drawSymbol("xmark", at: NSPoint(x: 20, y: b.midY), size: 12)
      drawSymbol("checkmark", at: NSPoint(x: b.width - 20, y: b.midY), size: 13)
      var barsX: CGFloat = 40
      if !modeLabel.isEmpty {
        let w = labelWidth(modeLabel)
        drawText(modeLabel, in: NSRect(x: 40, y: 0, width: w, height: b.height),
                 color: NSColor(calibratedRed: 0.30, green: 0.73, blue: 0.71, alpha: 1), align: .left)
        barsX = 40 + w + 8
      }
      drawBars(in: NSRect(x: barsX, y: 0, width: b.width - barsX - 40, height: b.height))
    case .processing:
      drawDots(in: b)
    case .message:
      drawText(message, in: NSRect(x: 16, y: 0, width: b.width - 32, height: b.height), color: .white)
    case .cancelled:
      drawText(message, in: NSRect(x: 18, y: 0, width: b.width - 80, height: b.height), color: .white, align: .left)
      drawText("復原", in: NSRect(x: b.width - 62, y: 0, width: 46, height: b.height),
               color: NSColor(calibratedRed: 0.45, green: 0.62, blue: 1, alpha: 1))
    }
  }

  func labelWidth(_ s: String) -> CGFloat {
    ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width)
  }

  private func drawSymbol(_ name: String, at p: NSPoint, size: CGFloat) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [.white]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    let s = img.size
    img.draw(in: NSRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }

  // 聲波：平頭直線，跟著音量變高（開根號讓小聲也看得到動）
  private func drawBars(in r: NSRect) {
    let step = r.width / CGFloat(levels.count)
    NSColor.white.setStroke()
    for (i, lv) in levels.enumerated() {
      let h = max(2, min(r.height * 0.6, CGFloat(sqrt(lv)) * r.height * 1.4))
      let x = r.minX + step * (CGFloat(i) + 0.5)
      let p = NSBezierPath()
      p.lineWidth = 2
      p.lineCapStyle = .butt
      p.move(to: NSPoint(x: x, y: r.midY - h / 2))
      p.line(to: NSPoint(x: x, y: r.midY + h / 2))
      p.stroke()
    }
  }

  // 辨識中：三個點依序變亮
  private func drawDots(in r: NSRect) {
    for i in 0..<3 {
      let a = 0.3 + 0.7 * max(0, sin(phase - Double(i) * 0.8))
      NSColor(white: 1, alpha: a).setFill()
      let x = r.midX + CGFloat(i - 1) * 14
      NSBezierPath(ovalIn: NSRect(x: x - 3, y: r.midY - 3, width: 6, height: 6)).fill()
    }
  }

  private func drawText(_ s: String, in r: NSRect, color: NSColor, align: NSTextAlignment = .center) {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color, .paragraphStyle: para]
    let h = (s as NSString).size(withAttributes: attrs).height
    (s as NSString).draw(in: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h), withAttributes: attrs)
  }

  override func mouseDown(with e: NSEvent) {
    let x = convert(e.locationInWindow, from: nil).x
    switch mode {
    case .recording:
      if x < 40 { onCancel?() } else if x > bounds.width - 40 { onDone?() }
    case .cancelled:
      if x > bounds.width - 70 { onUndo?() }
    default:
      break
    }
  }
}

// MARK: - 指示框視窗

final class HUD {
  private let panel: NSPanel
  private let view = HUDView()
  private var timer: Timer?
  private var hideWork: DispatchWorkItem?

  init() {
    // nonactivatingPanel：點了也不會把焦點從使用者正在打字的 app 搶走
    panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 34),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    panel.contentView = view
  }

  var onCancel: (() -> Void)? { get { view.onCancel } set { view.onCancel = newValue } }
  var onDone: (() -> Void)? { get { view.onDone } set { view.onDone = newValue } }
  var onUndo: (() -> Void)? { get { view.onUndo } set { view.onUndo = newValue } }

  // 放在滑鼠所在螢幕的下方中間
  private func show(width: CGFloat) {
    hideWork?.cancel()
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    guard let vf = screen?.visibleFrame else { return }
    panel.setFrame(NSRect(x: vf.midX - width / 2, y: vf.minY + 48, width: width, height: 34), display: true)
    panel.orderFrontRegardless()
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.view.tick() }
    }
  }

  func recording(label: String = "") {
    view.levels = [Float](repeating: 0, count: view.levels.count)
    view.modeLabel = label
    view.mode = .recording
    show(width: label.isEmpty ? 150 : 150 + view.labelWidth(label) + 8)
  }

  // 錄音中改模式：更新文字並調整寬度
  func setMode(_ label: String) {
    guard view.mode == .recording else { return }
    view.modeLabel = label
    show(width: label.isEmpty ? 150 : 150 + view.labelWidth(label) + 8)
  }

  func level(_ v: Float) { if view.mode == .recording { view.push(v) } }

  func processing() {
    view.mode = .processing
    show(width: 90)
  }

  func flash(_ text: String, seconds: Double = 2.0) {
    view.message = text
    view.mode = .message
    let w = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width + 40
    show(width: min(460, max(90, w)))
    hide(after: seconds)
  }

  func cancelled() {
    view.message = "轉錄已取消"
    view.mode = .cancelled
    show(width: 170)
    hide(after: 4)
  }

  func hide(after s: Double = 0) {
    hideWork?.cancel()
    let w = DispatchWorkItem { [weak self] in
      self?.panel.orderOut(nil)
      self?.timer?.invalidate()
      self?.timer = nil
    }
    hideWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
  }
}
