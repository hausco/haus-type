// 音訊裝置：列出麥克風、指定錄音用的麥克風、錄音時把喇叭靜音（結束後還原）。

import AVFoundation
import CoreAudio
import Foundation

struct AudioDevice: Hashable, Identifiable {
  let id: AudioDeviceID
  let uid: String
  let name: String
}

private func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func deviceString(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
  var a = address(sel)
  var v: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr, let v else { return nil }
  return v.takeRetainedValue() as String
}

// 所有有輸入聲道的裝置（內建麥克風、耳機、USB 麥克風、iPhone 連續互通麥克風）
func inputDevices() -> [AudioDevice] {
  var a = address(kAudioHardwarePropertyDevices)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
  var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
  guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
  return ids.compactMap { id in
    var sa = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
    var s: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &s) == noErr, s > 0,
          let uid = deviceString(id, kAudioDevicePropertyDeviceUID), let name = deviceString(id, kAudioObjectPropertyName) else { return nil }
    return AudioDevice(id: id, uid: uid, name: name)
  }
}

// 設定檔指定的麥克風（micUID）；空字串或裝置拔掉了就用系統預設
func selectedInputDevice() -> AudioDevice? {
  let uid = config.string("micUID")
  guard !uid.isEmpty else { return nil }
  return inputDevices().first { $0.uid == uid }
}

// 讓 AVAudioEngine 改用指定的麥克風；要在讀 inputNode 格式之前呼叫
func applyInputDevice(_ engine: AVAudioEngine, _ dev: AudioDevice?) {
  guard var id = dev?.id, let unit = engine.inputNode.audioUnit else { return }
  let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
  if err != noErr { log("指定麥克風失敗：\(err)，改用系統預設") }
}

// MARK: - 錄音時靜音

enum OutputMute {
  private static var device: AudioDeviceID = 0
  private static var active = false

  private static func defaultOutput() -> AudioDeviceID? {
    var a = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr else { return nil }
    return id
  }

  private static func get(_ id: AudioDeviceID) -> UInt32? {
    var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
    var v = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v
  }

  private static func set(_ id: AudioDeviceID, _ on: Bool) {
    var a = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
    var v: UInt32 = on ? 1 : 0
    AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
  }

  // 開始錄音：喇叭原本沒靜音才靜音，並記在設定檔，萬一程式中途結束，下次開啟會還原
  static func begin() {
    guard config.bool("muteWhileDictating"), !active, let id = defaultOutput(), get(id) == 0 else { return }
    set(id, true)
    device = id
    active = true
    config.set("mutedByUs", true)
  }

  // 結束錄音：只還原我們自己靜音的
  static func end() {
    guard active else { return }
    set(device, false)
    active = false
    config.set("mutedByUs", nil)
  }

  // 啟動時：上次靜音後沒還原（程式當掉或被強制結束）就還原
  static func recoverIfNeeded() {
    guard config.bool("mutedByUs"), let id = defaultOutput() else { return }
    set(id, false)
    config.set("mutedByUs", nil)
    log("還原上次錄音時的靜音")
  }
}

// MARK: - 麥克風測試（設定視窗用）

final class MicTester: ObservableObject {
  @Published var level: Float = 0
  @Published var running = false
  private var engine: AVAudioEngine?

  func start() {
    stop()
    let e = AVAudioEngine()
    applyInputDevice(e, selectedInputDevice())
    let fmt = e.inputNode.outputFormat(forBus: 0)
    guard fmt.sampleRate > 0 else { return }
    e.inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
      guard let ch = buf.floatChannelData else { return }
      var peak: Float = 0
      for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[0][i])) }
      DispatchQueue.main.async { self?.level = max(peak, (self?.level ?? 0) * 0.85) }
    }
    do { try e.start() } catch { log("麥克風測試失敗：\(error.localizedDescription)"); return }
    engine = e
    running = true
    // 8 秒後自動停，不要一直占用麥克風
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.stop() }
  }

  func stop() {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    running = false
    level = 0
  }
}
