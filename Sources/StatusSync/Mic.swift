import CoreAudio
import Foundation

/// Asks CoreAudio which processes are currently capturing audio input (macOS 14+).
enum Mic {
    static func activeInputBundleIDs() -> Set<String> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &ids) == noErr else { return [] }

        var result = Set<String>()
        for id in ids {
            var runningAddr = address(kAudioProcessPropertyIsRunningInput)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &runningAddr, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }

            var bundleAddr = address(kAudioProcessPropertyBundleID)
            var bundleID: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &bundleAddr, 0, nil, &bundleSize, &bundleID) == noErr,
               let value = bundleID?.takeRetainedValue() {
                result.insert(value as String)
            }
        }
        return result
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
