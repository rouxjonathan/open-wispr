import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Subscribes to OS notifications that can affect audio capture and just logs
/// them. No behavior change — instrumentation only, so we can correlate a
/// failed dictation in the journal with a system event around the same time.
final class SystemObservers {
    private weak var audioEngine: AVAudioEngine?
    private var defaultDeviceListenerInstalled = false
    private var deviceAliveListenerInstalled = false
    private var watchedDeviceID: AudioDeviceID = 0

    func start(currentEngine: AVAudioEngine?) {
        audioEngine = currentEngine

        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(audioConfigurationChanged(_:)),
                       name: .AVAudioEngineConfigurationChange,
                       object: nil)

        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self,
                         selector: #selector(willSleep(_:)),
                         name: NSWorkspace.willSleepNotification,
                         object: nil)
        wsnc.addObserver(self,
                         selector: #selector(didWake(_:)),
                         name: NSWorkspace.didWakeNotification,
                         object: nil)
        wsnc.addObserver(self,
                         selector: #selector(screensSlept(_:)),
                         name: NSWorkspace.screensDidSleepNotification,
                         object: nil)
        wsnc.addObserver(self,
                         selector: #selector(screensWoke(_:)),
                         name: NSWorkspace.screensDidWakeNotification,
                         object: nil)

        nc.addObserver(self,
                       selector: #selector(appBecameActive(_:)),
                       name: NSApplication.didBecomeActiveNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(appResignedActive(_:)),
                       name: NSApplication.didResignActiveNotification,
                       object: nil)

        installCoreAudioListeners()

        Logger.shared.log("observers", "installed")
    }

    func updateEngine(_ engine: AVAudioEngine?) {
        audioEngine = engine
    }

    // MARK: - AVAudioEngine

    @objc private func audioConfigurationChanged(_ note: Notification) {
        let running = audioEngine?.isRunning ?? false
        let sr = audioEngine?.inputNode.outputFormat(forBus: 0).sampleRate ?? -1
        let ch = audioEngine?.inputNode.outputFormat(forBus: 0).channelCount ?? 0
        Logger.shared.log("system", "AVAudioEngineConfigurationChange " + logfmt([
            ("engine_running", running),
            ("sample_rate", sr),
            ("channels", ch),
        ]))
    }

    // MARK: - Sleep / wake

    @objc private func willSleep(_ note: Notification) {
        Logger.shared.log("system", "willSleep")
    }

    @objc private func didWake(_ note: Notification) {
        let running = audioEngine?.isRunning ?? false
        Logger.shared.log("system", "didWake " + logfmt([("engine_running", running)]))
    }

    @objc private func screensSlept(_ note: Notification) {
        Logger.shared.log("system", "screensDidSleep")
    }

    @objc private func screensWoke(_ note: Notification) {
        Logger.shared.log("system", "screensDidWake")
    }

    @objc private func appBecameActive(_ note: Notification) {
        Logger.shared.log("system", "appDidBecomeActive")
    }

    @objc private func appResignedActive(_ note: Notification) {
        Logger.shared.log("system", "appDidResignActive")
    }

    // MARK: - CoreAudio property listeners

    private func installCoreAudioListeners() {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.global(qos: .utility)
        ) { _, _ in
            let newID = AudioDeviceManager.getDefaultInputDeviceID()
            Logger.shared.log("system", "defaultInputDeviceChanged " + logfmt([("new_id", newID)]))
        }
        if defaultStatus == noErr {
            defaultDeviceListenerInstalled = true
        } else {
            Logger.shared.log("system", "defaultInputDeviceListener_failed status=\(defaultStatus)")
        }

        let deviceID = AudioDeviceManager.getDefaultInputDeviceID()
        watchedDeviceID = deviceID
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let aliveStatus = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &aliveAddress,
            DispatchQueue.global(qos: .utility)
        ) { [weak self] _, _ in
            guard let self = self else { return }
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(self.watchedDeviceID, &addr, 0, nil, &size, &alive)
            Logger.shared.log("system", "deviceIsAliveChanged " + logfmt([
                ("device_id", self.watchedDeviceID),
                ("alive", alive),
            ]))
        }
        if aliveStatus == noErr {
            deviceAliveListenerInstalled = true
        } else {
            Logger.shared.log("system", "deviceIsAliveListener_failed status=\(aliveStatus)")
        }
    }
}
