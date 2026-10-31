//
//  JustSpeakApp.swift
//  JustSpeak
//
//  Created by Zhuocheng Yu on 11/10/25.
//

import SwiftUI
import AppKit
import Combine
import UserNotifications

@main
struct JustSpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            ShortcutSettingsView(
                store: appDelegate.shortcutStore,
                captureController: appDelegate.shortcutCaptureController
            )
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let shortcutStore = RecordingShortcutStore()
    lazy var shortcutCaptureController = ShortcutCaptureController(
        store: shortcutStore
    )

    private var statusItem: NSStatusItem?
    private let audioRecorder = AudioRecorder()
    private lazy var hotkeyManager = HotkeyManager(shortcut: shortcutStore.shortcut)
    private let transcriptionService = TranscriptionService.shared
    private let clipboardManager = ClipboardManager.shared
    private let transcriptHistory = TranscriptHistoryStore()
    private let recordingOverlay = RecordingOverlayController()
    private let recordingCuePlayer = RecordingCuePlayer()
    private let systemAudioSilencer = SystemAudioSilencer()
#if !LOCAL_BUILD
    private let updateController = UpdateController()
#endif
    private lazy var shortcutSettingsWindowController = ShortcutSettingsWindowController(
        store: shortcutStore,
        captureController: shortcutCaptureController
    )
    private var isRecordingHotkeyHeld = false
    private var recordingAttemptID: UUID?
    private var recordingStartTime: Date?
    private var modelSetupProgressMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private let transcriptHistoryMenu = NSMenu()
    private let audioInputMenu = NSMenu()
    private var shortcutMenuItem: NSMenuItem?
    private var subscriptions = Set<AnyCancellable>()
    private static let selectedDeviceKey = "selectedAudioInputDevice"
    private static let didMigratePreferencesKey = "didMigrateLegacyPreferences"
    private static let legacyBundleIdentifier = "com.zyu.VoiceToText"

    func applicationDidFinishLaunching(_ notification: Notification) {
        systemAudioSilencer.recover()
        requestNotificationPermission()
        migrateLegacyPreferencesIfNeeded()
        migrateSelectedAudioInputPreferenceIfNeeded()
        observeShortcutSettings()
        setupStatusItem()
        setupMenus()
#if !LOCAL_BUILD
        updateController.start()
#endif
        setupHotkeyManager()
        setupTranscriptionService()
        restoreSelectedDevice()
        previewRecordingOverlayIfRequested()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateAccessibilityMenuItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemAudioSilencer.restore()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Just Speak")
            button.image?.isTemplate = true
        }
    }

    private func migrateLegacyPreferencesIfNeeded() {
        let defaults = UserDefaults.standard

        guard !defaults.bool(forKey: Self.didMigratePreferencesKey) else { return }

        if let legacyDefaults = UserDefaults(suiteName: Self.legacyBundleIdentifier),
           defaults.object(forKey: Self.selectedDeviceKey) == nil,
           let legacyDeviceID = legacyDefaults.object(forKey: Self.selectedDeviceKey) {
            defaults.set(legacyDeviceID, forKey: Self.selectedDeviceKey)
            print("Migrated selected audio input from VoiceToText preferences")
        }

        defaults.set(true, forKey: Self.didMigratePreferencesKey)
    }

    private func migrateSelectedAudioInputPreferenceIfNeeded() {
        let defaults = UserDefaults.standard

        guard let storedPreference = defaults.object(forKey: Self.selectedDeviceKey),
              !(storedPreference is String),
              let storedDeviceID = storedPreference as? NSNumber else { return }

        guard let uniqueID = CoreAudioDevice.uniqueID(
            for: storedDeviceID.uint32Value
        ) else {
            defaults.removeObject(forKey: Self.selectedDeviceKey)
            print("Could not migrate selected audio input; using system default")
            return
        }

        defaults.set(uniqueID, forKey: Self.selectedDeviceKey)
        print("Migrated selected audio input to a persistent identifier")
    }

    private func setupMenus() {
        let menu = NSMenu()

        shortcutMenuItem = NSMenuItem(
            title: shortcutMenuTitle,
            action: nil,
            keyEquivalent: ""
        )
        shortcutMenuItem?.isEnabled = false
        menu.addItem(shortcutMenuItem!)

        let changeShortcutItem = NSMenuItem(
            title: "Change Shortcut…",
            action: #selector(openShortcutSettings),
            keyEquivalent: ""
        )
        changeShortcutItem.target = self
        menu.addItem(changeShortcutItem)

        menu.addItem(NSMenuItem.separator())

        accessibilityMenuItem = createAccessibilityMenuItem()
        menu.addItem(accessibilityMenuItem!)

        let transcriptHistoryItem = NSMenuItem(
            title: "Recent Transcripts",
            action: nil,
            keyEquivalent: ""
        )
        transcriptHistoryItem.submenu = transcriptHistoryMenu
        menu.addItem(transcriptHistoryItem)
        refreshTranscriptHistoryMenu()

        let audioInputItem = NSMenuItem(title: "Audio Input", action: nil, keyEquivalent: "")
        audioInputMenu.delegate = self
        refreshAudioInputMenu()
        audioInputItem.submenu = audioInputMenu
        menu.addItem(audioInputItem)

#if !LOCAL_BUILD
        menu.addItem(NSMenuItem.separator())
        menu.addItem(updateController.menuItem)
#endif
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === audioInputMenu else { return }
        refreshAudioInputMenu()
    }

    private func refreshTranscriptHistoryMenu() {
        transcriptHistoryMenu.removeAllItems()

        guard !transcriptHistory.entries.isEmpty else {
            let emptyItem = NSMenuItem(
                title: "No Recent Transcripts",
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            transcriptHistoryMenu.addItem(emptyItem)
            return
        }

        for entry in transcriptHistory.entries {
            let item = NSMenuItem(
                title: transcriptMenuTitle(for: entry.text),
                action: #selector(pasteTranscript(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.text
            item.toolTip = entry.text
            transcriptHistoryMenu.addItem(item)
        }

        transcriptHistoryMenu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(
            title: "Clear History",
            action: #selector(clearTranscriptHistory),
            keyEquivalent: ""
        )
        clearItem.target = self
        transcriptHistoryMenu.addItem(clearItem)
    }

    private func transcriptMenuTitle(for text: String) -> String {
        let singleLineText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let maximumLength = 60

        guard singleLineText.count > maximumLength else {
            return singleLineText
        }

        return "\(singleLineText.prefix(maximumLength))…"
    }

    @objc private func pasteTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        clipboardManager.copyAndPaste(text)
    }

    @objc private func clearTranscriptHistory() {
        transcriptHistory.clear()
        refreshTranscriptHistoryMenu()
    }

    private var shortcutMenuTitle: String {
        "Shortcut: \(shortcutStore.shortcut.displayName)"
    }

    private func observeShortcutSettings() {
        shortcutStore.$shortcut
            .dropFirst()
            .sink { [weak self] shortcut in
                self?.hotkeyManager.updateShortcut(shortcut)
                self?.shortcutMenuItem?.title = "Shortcut: \(shortcut.displayName)"
            }
            .store(in: &subscriptions)

        shortcutCaptureController.$isCapturing
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isCapturing in
                self?.hotkeyManager.setSuspended(isCapturing)
            }
            .store(in: &subscriptions)
    }

    @objc private func openShortcutSettings() {
        shortcutSettingsWindowController.present()
    }

    private func refreshAudioInputMenu() {
        audioInputMenu.removeAllItems()

        let devices = AudioRecorder.getAvailableInputDevices()
        let savedDeviceID = UserDefaults.standard.string(forKey: Self.selectedDeviceKey)
        let savedDeviceIsAvailable = devices.contains {
            $0.uniqueID == savedDeviceID
        }

        let defaultItem = NSMenuItem(
            title: "System Default",
            action: #selector(selectAudioDevice(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.state = savedDeviceID == nil || !savedDeviceIsAvailable ? .on : .off
        audioInputMenu.addItem(defaultItem)

        if !devices.isEmpty {
            audioInputMenu.addItem(NSMenuItem.separator())
        }

        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectAudioDevice(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uniqueID
            item.state = device.uniqueID == savedDeviceID ? .on : .off
            audioInputMenu.addItem(item)
        }
    }

    @objc private func selectAudioDevice(_ sender: NSMenuItem) {
        for item in audioInputMenu.items {
            item.state = .off
        }

        sender.state = .on

        if let deviceID = sender.representedObject as? String {
            UserDefaults.standard.set(deviceID, forKey: Self.selectedDeviceKey)
            audioRecorder.setInputDevice(id: deviceID)
            print("Audio input set to: \(sender.title)")
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedDeviceKey)
            audioRecorder.setInputDevice(id: nil)
            print("Audio input set to system default")
        }
    }

    private func restoreSelectedDevice() {
        if let savedDeviceID = UserDefaults.standard.string(forKey: Self.selectedDeviceKey) {
            audioRecorder.setInputDevice(id: savedDeviceID)
            print("Restored audio input device: \(savedDeviceID)")
        }
    }

    private func updateModelSetupProgress(_ progress: ModelSetupProgress) {
        guard let menu = statusItem?.menu else { return }

        let progressText: String
        switch progress {
        case .downloading(let fractionCompleted):
            progressText = String(
                format: "Downloading model: %.1f%%",
                fractionCompleted * 100
            )
        case .preparing:
            progressText = "Preparing model..."
        }

        print(progressText)

        if let menuItem = modelSetupProgressMenuItem {
            menuItem.title = progressText
        } else {
            let menuItem = NSMenuItem(title: progressText, action: nil, keyEquivalent: "")
            menuItem.isEnabled = false
            menu.insertItem(menuItem, at: 0)
            modelSetupProgressMenuItem = menuItem
        }
    }

    private func removeModelSetupProgress() {
        guard let menuItem = modelSetupProgressMenuItem else { return }
        statusItem?.menu?.removeItem(menuItem)
        modelSetupProgressMenuItem = nil
    }

    private func createAccessibilityMenuItem() -> NSMenuItem {
        let hasPermission = hotkeyManager.hasAccessibilityPermission()
        let title = hasPermission ? "Accessibility Permission ✓" : "Enable Accessibility Permission..."
        let menuItem = NSMenuItem(
            title: title,
            action: hasPermission ? nil : #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        menuItem.target = self
        menuItem.isEnabled = !hasPermission
        return menuItem
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func updateAccessibilityMenuItem() {
        guard let menuItem = accessibilityMenuItem else { return }

        let hasPermission = hotkeyManager.hasAccessibilityPermission()
        menuItem.title = hasPermission ? "Accessibility Permission ✓" : "Enable Accessibility Permission..."
        menuItem.action = hasPermission ? nil : #selector(openAccessibilitySettings)
        menuItem.isEnabled = !hasPermission
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error: \(error)")
            }
        }
    }

    private func setupTranscriptionService() {
        if transcriptionService.isModelDownloaded {
            initializeTranscriptionService()
        } else {
            updateStatusIcon(downloading: true)
            showNotification(
                title: "Downloading Model",
                body: "First time setup: downloading the optimized Parakeet model"
            )

            transcriptionService.downloadModelIfNeeded { [weak self] progress in
                self?.updateModelSetupProgress(progress)
            } completion: { [weak self] result in
                self?.updateStatusIcon(downloading: false)
                self?.removeModelSetupProgress()

                switch result {
                case .success:
                    print("Model downloaded and initialized successfully")
                    self?.showNotification(
                        title: "Setup Complete",
                        body: "Parakeet model ready for transcription"
                    )
                case .failure(let error):
                    print("Model download failed: \(error)")
                    self?.showNotification(
                        title: "Download Failed",
                        body: "Failed to download Parakeet model: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func initializeTranscriptionService() {
        updateStatusIcon(downloading: true)
        Task { [weak self] in
            guard let self else { return }

            do {
                try await transcriptionService.initialize()
                print("Transcription service initialized")
                updateStatusIcon(downloading: false)
            } catch {
                print("Failed to initialize transcription service: \(error)")
                updateStatusIcon(error: true)
                showNotification(
                    title: "Transcription Unavailable",
                    body: "Failed to initialize Parakeet model"
                )
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func setupHotkeyManager() {
        print("🎤 Setting up hotkey manager...")

        hotkeyManager.onKeyDown = { [weak self] in
            self?.handleHotkeyDown()
        }

        hotkeyManager.onKeyUp = { [weak self] in
            self?.handleHotkeyUp()
        }

        hotkeyManager.onCancelRequested = { [weak self] in
            self?.handleCancellation()
        }

        hotkeyManager.onPermissionGranted = { [weak self] in
            self?.updateAccessibilityMenuItem()
            self?.announceHotkeyReady()
        }

        if hotkeyManager.start() {
            announceHotkeyReady()
        } else {
            print("❌ Failed to start hotkey listener - waiting for permission")
            showNotification(
                title: "Permission Required",
                body: "Grant Accessibility permission in System Settings, then wait a moment - no restart needed!"
            )
        }
    }

    private func announceHotkeyReady() {
        let shortcutName = shortcutStore.shortcut.displayName
        print("✅ Hotkey listener ready - Hold \(shortcutName) to record")
        showNotification(
            title: "Voice Dictation Ready",
            body: "Hold \(shortcutName) to record, press Escape to cancel"
        )
    }

    private func handleHotkeyDown() {
        let targetApplication = NSWorkspace.shared.frontmostApplication
        let attemptID = UUID()
        recordingAttemptID = attemptID
        isRecordingHotkeyHeld = true
        updateStatusIcon(recording: true)

        startRecording(
            targetApplication: targetApplication,
            attemptID: attemptID
        )
    }

    private func startRecording(
        targetApplication: NSRunningApplication?,
        attemptID: UUID
    ) {
        let didRequestStart = audioRecorder.startRecording(
            attemptID: attemptID,
            unexpectedFinish: { [weak self] error in
                self?.handleUnexpectedRecordingFinish(
                    error,
                    attemptID: attemptID
                )
            },
            completion: { [weak self] result in
                self?.handleRecordingStart(
                    result,
                    targetApplication: targetApplication,
                    attemptID: attemptID
                )
            }
        )

        if didRequestStart {
            recordingCuePlayer.playStartCue { [weak self] in
                guard let self,
                      self.isRecordingHotkeyHeld,
                      self.recordingAttemptID == attemptID else { return }
                self.systemAudioSilencer.silence()
            }
        } else {
            retryRecordingStart(
                targetApplication: targetApplication,
                attemptID: attemptID
            )
        }
    }

    private func retryRecordingStart(
        targetApplication: NSRunningApplication?,
        attemptID: UUID
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  self.isRecordingHotkeyHeld,
                  self.recordingAttemptID == attemptID else { return }
            self.startRecording(
                targetApplication: targetApplication,
                attemptID: attemptID
            )
        }
    }

    private func handleRecordingStart(
        _ result: Result<AudioRecorder.RecordingStartInfo, Error>,
        targetApplication: NSRunningApplication?,
        attemptID: UUID
    ) {
        guard recordingAttemptID == attemptID, isRecordingHotkeyHeld else {
            if case .success = result {
                audioRecorder.cancelRecording(attemptID: attemptID)
            }
            return
        }

        switch result {
        case .failure(let error):
            systemAudioSilencer.restore()
            recordingAttemptID = nil
            showNotification(
                title: "Recording Failed",
                body: error.localizedDescription
            )
            updateStatusIcon(error: true)
            recordingOverlay.hide()
            recordingStartTime = nil
            return
        case .success(let startInfo):
            recordingStartTime = Date()

            if startInfo.usedSystemDefaultFallback {
                showNotification(
                    title: "Audio Input Unavailable",
                    body: "Using \(startInfo.inputDeviceName) for this recording."
                )
            }
        }

        recordingOverlay.show(targetApplication: targetApplication) { [weak self] deltaTime in
            self?.audioRecorder.sampleLevel(deltaTime: deltaTime) ?? 0
        }
        print("Recording started via hotkey")
    }

    private func handleUnexpectedRecordingFinish(
        _ error: Error,
        attemptID: UUID
    ) {
        guard recordingAttemptID == attemptID else { return }

        systemAudioSilencer.restore()
        isRecordingHotkeyHeld = false
        recordingAttemptID = nil
        recordingStartTime = nil
        recordingCuePlayer.stop()
        recordingOverlay.hide()
        updateStatusIcon(error: true)
        showNotification(
            title: "Recording Failed",
            body: error.localizedDescription
        )
    }

    private func handleHotkeyUp() {
        let attemptID = recordingAttemptID
        isRecordingHotkeyHeld = false
        recordingAttemptID = nil
        recordingCuePlayer.stop()

        guard let startTime = recordingStartTime,
              let attemptID else {
            systemAudioSilencer.restore()
            recordingOverlay.hide()
            updateStatusIcon(recording: false)
            return
        }

        recordingStartTime = nil
        recordingOverlay.hide()
        updateStatusIcon(recording: false)

        let duration = Date().timeIntervalSince(startTime)
        print("Recording duration: \(String(format: "%.1f", duration)) seconds")

        let didRequestStop = audioRecorder.stopRecording(
            attemptID: attemptID,
            didStopCapture: { [weak self] in
                self?.systemAudioSilencer.restore()
            },
            completion: { [weak self] result in
                self?.handleRecordingCompletion(result, duration: duration)
            }
        )

        guard didRequestStop else {
            systemAudioSilencer.restore()
            showNotification(title: "Recording Failed", body: "Could not save recording")
            updateStatusIcon(error: true)
            return
        }
    }

    private func handleRecordingCompletion(
        _ result: Result<URL, Error>,
        duration: TimeInterval
    ) {
        guard case .success(let recordingURL) = result else {
            if case .failure(let error) = result {
                showNotification(
                    title: "Recording Failed",
                    body: error.localizedDescription
                )
                updateStatusIcon(error: true)
            }
            return
        }

        guard duration >= 0.5 else {
            print("Recording too short (\(String(format: "%.1f", duration))s), ignoring")
            AudioRecorder.removeRecordingFile(at: recordingURL)
            return
        }

        processRecording(url: recordingURL)
    }

    private func handleCancellation() {
        systemAudioSilencer.restore()
        let attemptID = recordingAttemptID
        isRecordingHotkeyHeld = false
        recordingAttemptID = nil
        recordingStartTime = nil
        recordingCuePlayer.stop()
        recordingOverlay.hide()
        updateStatusIcon()
        if let attemptID {
            audioRecorder.cancelRecording(attemptID: attemptID)
        }
        print("Recording cancelled by user")
    }

    private func previewRecordingOverlayIfRequested() {
        guard CommandLine.arguments.contains("--preview-recording-overlay") else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.recordingOverlay.showPreview(
                targetApplication: NSWorkspace.shared.frontmostApplication
            )
        }
    }

    private func processRecording(url: URL) {
        guard transcriptionService.isReady else {
            AudioRecorder.removeRecordingFile(at: url)
            showNotification(
                title: "Transcription Unavailable",
                body: "Parakeet model not ready. Please wait for download to complete."
            )
            updateStatusIcon(error: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.updateStatusIcon()
            }
            return
        }

        updateStatusIcon(processing: true)
        print("Processing recording: \(url.path)")

        Task {
            do {
                let text = try await transcriptionService.transcribe(audioFile: url)

                await MainActor.run {
                    updateStatusIcon()
                    handleTranscriptionResult(text)
                    AudioRecorder.removeRecordingFile(at: url)
                }
            } catch {
                await MainActor.run {
                    updateStatusIcon(error: true)
                    showNotification(
                        title: "Transcription Failed",
                        body: error.localizedDescription
                    )
                    print("Transcription error: \(error)")

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.updateStatusIcon()
                    }

                    AudioRecorder.removeRecordingFile(at: url)
                }
            }
        }
    }

    private func handleTranscriptionResult(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            print("No speech detected")
            return
        }

        print("Transcription: \(trimmed)")
        transcriptHistory.add(trimmed)
        refreshTranscriptHistoryMenu()
        clipboardManager.copyAndPaste(trimmed)
    }

    private func updateStatusIcon(recording: Bool = false, processing: Bool = false, downloading: Bool = false, error: Bool = false) {
        guard let button = statusItem?.button else { return }

        if error {
            button.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Error")
            button.image?.isTemplate = true
        } else if downloading {
            button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloading")
            button.image?.isTemplate = true
        } else if processing {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Processing")
            button.image?.isTemplate = true
        } else if recording {
            button.image = NSImage(systemSymbolName: "mic.fill.badge.plus", accessibilityDescription: "Recording")
            button.image?.isTemplate = true
        } else {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Just Speak")
            button.image?.isTemplate = true
        }
    }
}
