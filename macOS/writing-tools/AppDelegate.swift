import SwiftUI
import HotKey
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    
    // Static status item to prevent deallocation
    private static var sharedStatusItem: NSStatusItem?
    
    // Property to track service-triggered popups
    private var isServiceTriggered: Bool = false

    // Computed property to manage the menu bar status item
    var statusBarItem: NSStatusItem! {
        get {
            if AppDelegate.sharedStatusItem == nil {
                AppDelegate.sharedStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                configureStatusBarItem()
            }
            return AppDelegate.sharedStatusItem
        }
        set {
            AppDelegate.sharedStatusItem = newValue
        }
    }
    var hotKey: HotKey?
    let appState = AppState.shared
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private(set) var popupWindow: NSWindow?
    private var settingsHostingView: NSHostingView<SettingsView>?
    private var aboutHostingView: NSHostingView<AboutView>?
    private let windowAccessQueue = DispatchQueue(label: "com.example.writingtools.windowQueue")
    
    // Called when app launches - initializes core functionality
    func applicationDidFinishLaunching(_ notification: Notification) {
        
        NSApp.servicesProvider = self

        if CommandLine.arguments.contains("--reset") {
            DispatchQueue.main.async { [weak self] in
                self?.performRecoveryReset()
            }
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.setupMenuBar()
            self?.setupHotKey()
            
            if self?.statusBarItem == nil {
                self?.recreateStatusBarItem()
            }
            
            if !UserDefaults.standard.bool(forKey: "has_completed_onboarding") {
                self?.showOnboarding()
            }
            
            self?.requestAccessibilityPermissions()
        }
    }
    
    // Called when app is about to close - performs cleanup
    func applicationWillTerminate(_ notification: Notification) {
        WindowManager.shared.cleanupWindows()
    }
    
    // Recreates the menu bar item if it was lost
    private func recreateStatusBarItem() {
        AppDelegate.sharedStatusItem = nil
        _ = self.statusBarItem
    }
    
    // Sets up the status bar item's icon
    private func configureStatusBarItem() {
        guard let button = statusBarItem?.button else { return }
        button.image = NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: "Writing Tools")
    }
    
    // Creates the menu that appears when clicking the status bar icon
    private func setupMenuBar() {
        guard let statusBarItem = self.statusBarItem else {
            print("Failed to create status bar item")
            return
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "Reset App", action: #selector(resetApp), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusBarItem.menu = menu
    }
    
    // Resets app to default state when triggered from menu
    @objc private func resetApp() {
        hotKey = nil
        WindowManager.shared.cleanupWindows()
        
        recreateStatusBarItem()
        setupMenuBar()
        
        setupHotKey()
        
        let alert = NSAlert()
        alert.messageText = "App Reset Complete"
        alert.informativeText = "The app has been reset. If you're still experiencing issues, try restarting the app."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    // Full app reset when launched with --reset flag
    private func performRecoveryReset() {
        // Reset all app defaults
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        
        // Reset the app state
        hotKey = nil
        WindowManager.shared.cleanupWindows()
        
        // Recreate status bar and setup
        recreateStatusBarItem()
        setupMenuBar()
        setupHotKey()
        
        // Show confirmation
        let alert = NSAlert()
        alert.messageText = "Recovery Complete"
        alert.informativeText = "The app has been reset to its default state."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    // Checks and requests accessibility permissions needed for app functionality
    private func requestAccessibilityPermissions() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let alert = NSAlert()
            alert.messageText = "Accessibility Access Required"
            alert.informativeText = "Writing Tools needs accessibility access to detect text selection and simulate keyboard shortcuts. Please grant access in System Settings > Privacy & Security > Accessibility."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }
    
    // Initializes keyboard shortcut handling
    private func setupHotKey() {
        updateHotKey()
        
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }
    
    // Handles changes to keyboard shortcut settings
    @objc private func shortcutChanged() {
        DispatchQueue.main.async { [weak self] in
            if UserDefaults.standard.string(forKey: "shortcut") != nil {
                self?.updateHotKey()
            }
        }
    }
    
    // Updates the active keyboard shortcut based on settings
    private func updateHotKey() {
        // Clear any existing hotKey
        hotKey = nil
        
        // Retrieve raw code & modifiers from UserDefaults
        let rawKeyCode = UserDefaults.standard.integer(forKey: "hotKey_keyCode")
        let rawModifiers = UserDefaults.standard.integer(forKey: "hotKey_modifiers")
        
        // If user never recorded anything, set a default.
        if rawKeyCode == 0 && rawModifiers == 0 {
            // Provide default if needed
            let defaultKeyCode = kVK_ANSI_D
            let defaultFlags   = NSEvent.ModifierFlags.control.carbonFlags
            
            UserDefaults.standard.set(Int(defaultKeyCode), forKey: "hotKey_keyCode")
            UserDefaults.standard.set(Int(defaultFlags), forKey: "hotKey_modifiers")
            
            // Re-read from UserDefaults so code proceeds
            return updateHotKey()
        }
        
        // Construct the HotKey from those raw integers
        let carbonKeyCode = UInt32(rawKeyCode)
        let carbonModifiers = UInt32(rawModifiers)
        
        // Create the HotKey instance
        hotKey = HotKey(keyCombo: KeyCombo(
            carbonKeyCode: carbonKeyCode,
            carbonModifiers: carbonModifiers
        ))
        
        hotKey?.keyDownHandler = { [weak self] in
            DispatchQueue.main.async {
                if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                    self?.appState.previousApplication = frontmostApp
                }
                self?.showPopup()
            }
        }
    }
    
    // Shows the first-time setup/onboarding window
    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Writing Tools"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        
        let onboardingView = OnboardingView(appState: appState)
        let hostingView = NSHostingView(rootView: onboardingView)
        window.contentView = hostingView
        window.level = .floating
        
        WindowManager.shared.setOnboardingWindow(window, hostingView: hostingView)
        window.makeKeyAndOrderFront(nil)
    }
    
    // Opens the settings window
    @objc private func showSettings() {
        settingsWindow?.close()
        settingsWindow = nil
        settingsHostingView = nil
        
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow?.title = "Settings"
        settingsWindow?.center()
        settingsWindow?.isReleasedWhenClosed = false
        
        let settingsView = SettingsView(appState: appState, showOnlyApiSetup: false)
        settingsHostingView = NSHostingView(rootView: settingsView)
        settingsWindow?.contentView = settingsHostingView
        settingsWindow?.delegate = self
        
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    // Opens the about window
    @objc private func showAbout() {
        aboutWindow?.close()
        aboutWindow = nil
        aboutHostingView = nil
        
        aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        aboutWindow?.title = "About Writing Tools"
        aboutWindow?.center()
        aboutWindow?.isReleasedWhenClosed = false
        
        let aboutView = AboutView()
        aboutHostingView = NSHostingView(rootView: aboutView)
        aboutWindow?.contentView = aboutHostingView
        aboutWindow?.delegate = self
        
        aboutWindow?.makeKeyAndOrderFront(nil)
    }
    
    // Shows the main popup window when shortcut is triggered
    private func showPopup() {
        appState.activeProvider.cancel()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.closePopupWindow()
            
            let pasteboard = NSPasteboard.general
            let oldContents = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            
            // Simulate copy command
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                let selectedText = pasteboard.string(forType: .string) ?? ""
                
                pasteboard.clearContents()
                if let oldContents = oldContents {
                    pasteboard.setString(oldContents, forType: .string)
                }
                
                // Create window even if no text is selected
                let window = PopupWindow(appState: self.appState)
                window.delegate = self
                
                self.appState.selectedText = selectedText
                self.popupWindow = window
                
                if selectedText.isEmpty {
                    window.setContentSize(NSSize(width: 400, height: 100))
                }
                
                window.positionNearMouse()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
    
    // Closes and cleans up the popup window
    private func closePopupWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let existingWindow = self.popupWindow as? PopupWindow {
                existingWindow.delegate = nil
                existingWindow.cleanup()
                existingWindow.close()
                
                self.popupWindow = nil
            }
        }
    }
    
    // Handles window cleanup when any window is closed
    func windowWillClose(_ notification: Notification) {
            guard !isServiceTriggered else { return }
            
            guard let window = notification.object as? NSWindow else { return }
            DispatchQueue.main.async { [weak self] in
                if window == self?.settingsWindow {
                    self?.settingsHostingView = nil
                    self?.settingsWindow = nil
                } else if window == self?.aboutWindow {
                    self?.aboutHostingView = nil
                    self?.aboutWindow = nil
                } else if window == self?.popupWindow {
                    self?.popupWindow?.delegate = nil
                    self?.popupWindow = nil
                }
            }
        }
    
    // Service handler for processing selected text
    @objc func handleSelectedText(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
            let types: [NSPasteboard.PasteboardType] = [
                .string,
                .rtf,
                NSPasteboard.PasteboardType("public.plain-text")
            ]
            
            guard let selectedText = types.lazy.compactMap({ pboard.string(forType: $0) }).first,
                  !selectedText.isEmpty else {
                error.pointee = "No text was selected" as NSString
                return
            }
            
            // Store the selected text
            appState.selectedText = selectedText
            
            // Set service trigger flag
            isServiceTriggered = true
            
            // Show the popup
            DispatchQueue.main.async { [weak self] in
                if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                    self?.appState.previousApplication = frontmostApp
                }
                
                guard let self = self else { return }
                
                if !selectedText.isEmpty {
                    let window = PopupWindow(appState: self.appState)
                    window.delegate = self
                    
                    self.closePopupWindow()
                    self.popupWindow = window
                    
                    // Configure window for service mode
                    window.level = .floating
                    window.collectionBehavior = [.moveToActiveSpace]
                    
                    window.positionNearMouse()
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
                
                // Reset the flag after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.isServiceTriggered = false
                }
            }
        }
}

// Converts SwiftUI modifier flags to Carbon modifier flags for HotKey library
extension NSEvent.ModifierFlags {
    var carbonFlags: UInt32 {
        var carbon: UInt32 = 0
        if contains(.command) { carbon |= UInt32(cmdKey) }
        if contains(.option) { carbon |= UInt32(optionKey) }
        if contains(.control) { carbon |= UInt32(controlKey) }
        if contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
