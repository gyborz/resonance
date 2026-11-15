import CoreAudio
import Foundation
import OSLog
import RecognitionCore

struct HALCaptureError: Error {
    let operation: String
    let status: OSStatus
}

enum CaptureProperty {
    case defaultOutput
    case outputDataSource
    case serviceRestart
    case tapFormat(AudioObjectID)
    case aggregateSampleRate(AudioObjectID)
    case ioStoppedAbnormally(AudioObjectID)
}

protocol CaptureHAL: Sendable {
    func createTap() throws -> AudioObjectID
    func tapUID(_ tap: AudioObjectID) throws -> String
    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription
    func createAggregate(tapUID: String) throws -> AudioObjectID
    func maximumCallbackFrames(_ device: AudioObjectID) throws -> UInt32

    func observe(
        _ property: CaptureProperty,
        change: @escaping @Sendable () -> Void
    ) throws -> () -> Void

    func registerIO(on device: AudioObjectID, ring: AudioBufferRing) throws -> AudioDeviceIOProcID
    func start(_ device: AudioObjectID, io: AudioDeviceIOProcID) throws
    func stop(_ device: AudioObjectID, io: AudioDeviceIOProcID)
    func unregisterIO(on device: AudioObjectID, io: AudioDeviceIOProcID)
    func destroyAggregate(_ device: AudioObjectID)
    func destroyTap(_ tap: AudioObjectID)
}

struct CoreAudioHAL: CaptureHAL {
    private static let propertyQueue = DispatchQueue(label: "Resonance.CoreAudioProperties")
    private let diagnosticsEnabled: Bool

    init(diagnosticsEnabled: Bool) {
        self.diagnosticsEnabled = diagnosticsEnabled
    }

    func createTap() throws -> AudioObjectID {
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        try check("Resolve the app's process audio object", AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process
        ))

        let excludedProcesses = process == kAudioObjectUnknown ? [] : [process]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        if process == kAudioObjectUnknown {
            guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
                throw RecognitionFailure.captureUnavailable(diagnostic: "The app's audio identity is unavailable")
            }
            description.bundleIDs = [bundleIdentifier]
        }
        description.name = "Resonance System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check("Create the process tap", AudioHardwareCreateProcessTap(description, &tap))
        return tap
    }

    func tapUID(_ tap: AudioObjectID) throws -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: uid))
        var property = address(kAudioTapPropertyUID)
        try check("Read the tap UID", AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &uid))
        guard let uid else {
            throw RecognitionFailure.captureUnavailable(diagnostic: "Core Audio did not return the tap UID")
        }
        // The Tap Object Properties contract transfers ownership of this CFString.
        return uid.takeRetainedValue() as String
    }

    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        var property = address(kAudioTapPropertyFormat)
        try check("Read the tap format", AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &format))
        return format
    }

    func createAggregate(tapUID: String) throws -> AudioObjectID {
        let tap = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true,
        ] as [String: Any]
        let composition = [
            kAudioAggregateDeviceNameKey: "Resonance Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [tap],
            // Let start return even when no tapped process is currently playing.
            kAudioAggregateDeviceTapAutoStartKey: false,
        ] as [String: Any]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check("Create the private aggregate device", AudioHardwareCreateAggregateDevice(
            composition as CFDictionary, &device
        ))
        return device
    }

    func maximumCallbackFrames(_ device: AudioObjectID) throws -> UInt32 {
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: frames))
        // When present, the variable-size property contains the maximum frame count.
        var property = address(kAudioDevicePropertyUsesVariableBufferFrameSizes)
        if !AudioObjectHasProperty(device, &property) {
            property = address(kAudioDevicePropertyBufferFrameSize)
        }
        try check("Read the maximum callback frame count", AudioObjectGetPropertyData(
            device, &property, 0, nil, &size, &frames
        ))
        return frames
    }

    func observe(
        _ property: CaptureProperty,
        change: @escaping @Sendable () -> Void
    ) throws -> () -> Void {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        switch property {
        case .defaultOutput:
            (object, selector, scope) = (system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        case .outputDataSource:
            // Some devices switch between speakers and wired output inside one HAL device.
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout.size(ofValue: device))
            var outputAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
            try check("Read the default output device", AudioObjectGetPropertyData(
                system, &outputAddress, 0, nil, &size, &device
            ))
            var sourceAddress = address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
            guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &sourceAddress) else { return {} }
            (object, selector, scope) = (device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        case .serviceRestart:
            (object, selector, scope) = (system, kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal)
        case .tapFormat(let tap):
            (object, selector, scope) = (tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal)
        case .aggregateSampleRate(let device):
            (object, selector, scope) = (device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal)
        case .ioStoppedAbnormally(let device):
            (object, selector, scope) = (device, kAudioDevicePropertyIOStoppedAbnormally, kAudioObjectPropertyScopeGlobal)
        }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in change() }
        var propertyAddress = address(selector, scope: scope)
        try check("Observe audio hardware changes", AudioObjectAddPropertyListenerBlock(
            object, &propertyAddress, Self.propertyQueue, listener
        ))
        return {
            var propertyAddress = address(selector, scope: scope)
            logCleanup("Remove the hardware listener", AudioObjectRemovePropertyListenerBlock(
                object, &propertyAddress, Self.propertyQueue, listener
            ))
        }
    }

    func registerIO(on device: AudioObjectID, ring: AudioBufferRing) throws -> AudioDeviceIOProcID {
        var io: AudioDeviceIOProcID?
        // The HAL retains the block (and ring) until callback registration is destroyed.
        // A nil queue runs the block directly on the HAL callback thread.
        try check("Register the audio callback", AudioDeviceCreateIOProcIDWithBlock(
            &io, device, nil
        ) { _, input, inputTime, _, _ in
            ring.write(input, at: inputTime)
        })
        guard let io else {
            throw RecognitionFailure.captureUnavailable(diagnostic: "Core Audio did not register the audio callback")
        }
        return io
    }

    func start(_ device: AudioObjectID, io: AudioDeviceIOProcID) throws {
        try check("Start system audio capture", AudioDeviceStart(device, io))
    }

    func stop(_ device: AudioObjectID, io: AudioDeviceIOProcID) {
        logCleanup("Stop system audio capture", AudioDeviceStop(device, io))
    }

    func unregisterIO(on device: AudioObjectID, io: AudioDeviceIOProcID) {
        logCleanup("Destroy the audio callback registration", AudioDeviceDestroyIOProcID(device, io))
    }

    func destroyAggregate(_ device: AudioObjectID) {
        logCleanup("Destroy the private aggregate device", AudioHardwareDestroyAggregateDevice(device))
    }

    func destroyTap(_ tap: AudioObjectID) {
        logCleanup("Destroy the process tap", AudioHardwareDestroyProcessTap(tap))
    }

    private func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func check(_ operation: String, _ status: OSStatus) throws {
        guard status == noErr else { throw HALCaptureError(operation: operation, status: status) }
    }

    private func logCleanup(_ operation: String, _ status: OSStatus) {
        if diagnosticsEnabled && status != noErr {
            let logger = Logger(subsystem: "Resonance.SystemAudioCapture", category: "HAL")
            logger.error("\(operation, privacy: .public) returned \(status, privacy: .public)")
        }
    }
}
