// device-volume.swift — get/set/list the volume of a macOS output device by name.
//
// Part of the Media Alarm tool. Multi-speaker mode uses this to ramp each member
// of a Multi-Output Device independently, since macOS aggregate / Multi-Output
// devices expose no master volume. Compiled at install time with `swiftc`.
//
// Usage:
//   device-volume list
//   device-volume get "<device name>"
//   device-volume set "<device name>" <0-100>
//
// Exit codes: 0 success; 1 error (device not found / no settable volume / bad
// args — message on stderr); 2 usage error.

import Foundation
import CoreAudio
import AudioToolbox

// 'vmvc' — VirtualMainVolume (a.k.a. the older VirtualMasterVolume). Defined by
// its four-char code so it does not depend on the SDK's Main/Master spelling.
let kVirtualMainVolume = AudioObjectPropertySelector(0x766D7663)

let prog = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "device-volume"

func errExit(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(prog): error: \(msg)\n".utf8))
    exit(code)
}

func usage() -> Never {
    FileHandle.standardError.write(Data(
        "usage: \(prog) list | get \"<device>\" | set \"<device>\" <0-100>\n".utf8))
    exit(2)
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func deviceName(_ id: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var name: Unmanaged<CFString>?
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
    guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
    return cf as String
}

func hasOutputChannels(_ id: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
    else { return false }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    var channels: UInt32 = 0
    for buffer in list { channels += buffer.mNumberChannels }
    return channels > 0
}

func outputDevices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr
    else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids.filter(hasOutputChannels)
}

func findDevice(named name: String) -> AudioObjectID? {
    return outputDevices().first { deviceName($0) == name }
}

func volumeAddress() -> AudioObjectPropertyAddress {
    return AudioObjectPropertyAddress(
        mSelector: kVirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
}

func getVolume(_ id: AudioObjectID) -> Float32? {
    var address = volumeAddress()
    var volume: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume) == noErr
    else { return nil }
    return volume
}

func setVolume(_ id: AudioObjectID, _ volume: Float32) -> Bool {
    var address = volumeAddress()
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue
    else { return false }
    var value = volume
    let size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectSetPropertyData(id, &address, 0, nil, size, &value) == noErr
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

switch args[1] {
case "list":
    for id in outputDevices() {
        if let name = deviceName(id) { print(name) }
    }

case "get":
    guard args.count == 3 else { usage() }
    let name = args[2]
    guard let id = findDevice(named: name) else { errExit("output device not found: \(name)") }
    guard let volume = getVolume(id) else { errExit("device has no readable volume: \(name)") }
    print(Int((volume * 100).rounded()))

case "set":
    guard args.count == 4 else { usage() }
    let name = args[2]
    guard let pct = Int(args[3]), pct >= 0, pct <= 100 else {
        errExit("volume must be an integer 0-100")
    }
    guard let id = findDevice(named: name) else { errExit("output device not found: \(name)") }
    guard setVolume(id, Float32(pct) / 100.0) else {
        errExit("could not set volume on '\(name)' (device may not support volume control)")
    }

default:
    usage()
}
