import CoreGraphics
import Carbon.HIToolbox
import Combine

enum ShortcutEvent {
    case activationStarted   // Modifier+Tab pressed - start timer, don't show UI yet
    case showSwitcher        // Timer expired without release - show UI now
    case cycleNext
    case cyclePrevious
    case cycleWindowNext
    case cycleWindowPrevious
    case activateSearch
    case confirm
    case dismiss
    case navigateUp      // Arrow up in search mode
    case navigateDown    // Arrow down in search mode
    case navigateRowUp   // Arrow up in normal mode - move to row above
    case navigateRowDown // Arrow down in normal mode - move to row below
    case quickSwitch     // Quick CMD+TAB to previous app (no UI)
}

final class KeyboardEventTap {
    let onShortcutTriggered = PassthroughSubject<ShortcutEvent, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let modifierTracker = ModifierKeyTracker()
    private var previousFlags: CGEventFlags = []
    private var switcherVisible = false
    private var searchModeActive = false  // When true, don't auto-confirm on modifier release

    // Quick-switch detection
    private var activationTime: CFAbsoluteTime = 0
    private var hadInteractionSinceActivation = false
    private let quickSwitchThreshold: CFAbsoluteTime = 0.12  // 120ms - faster detection
    private var showSwitcherTimer: DispatchWorkItem?
    private var pendingActivation = false  // True between activation and timer/release

    // Configuration
    private var activationModifier: ModifierKey = .option  // OPTION+TAB for development
    private let activationKeyCode: UInt16 = UInt16(kVK_Tab)

    init() {
        setupEventTap()
    }

    deinit {
        disable()
    }

    func disable() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        print("[KeyboardEventTap] Disabled")
    }

    func setSwitcherVisible(_ visible: Bool) {
        switcherVisible = visible
        if !visible {
            searchModeActive = false  // Reset search mode when switcher hides
            hadInteractionSinceActivation = false
            pendingActivation = false
            showSwitcherTimer?.cancel()
            showSwitcherTimer = nil
        }
    }

    func setSearchModeActive(_ active: Bool) {
        searchModeActive = active
        print("[KeyboardEventTap] Search mode: \(active)")
    }

    func setActivationModifier(_ modifier: ModifierKey) {
        activationModifier = modifier
    }

    private func setupEventTap() {
        // Events to monitor: key down, key up, flags changed (modifiers)
        let eventMask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        // Store self reference for callback
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let eventTap = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                return eventTap.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            print("[KeyboardEventTap] Failed to create event tap. Check Input Monitoring permission.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[KeyboardEventTap] Successfully created and enabled")
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled events
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[KeyboardEventTap] Re-enabled after being disabled")
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Handle modifier changes
        if type == .flagsChanged {
            let oldFlags = previousFlags
            previousFlags = flags
            modifierTracker.update(flags: flags)

            // Check if activation modifier was released
            if modifierTracker.wasModifierReleased(oldFlags: oldFlags, newFlags: flags, modifier: activationModifier) {
                let elapsed = CFAbsoluteTimeGetCurrent() - activationTime

                // Cancel the show timer if pending
                showSwitcherTimer?.cancel()
                showSwitcherTimer = nil

                // Quick switch: released before timer fired (UI never shown)
                if pendingActivation && !hadInteractionSinceActivation {
                    pendingActivation = false
                    print("[KeyboardEventTap] Quick switch detected (\(Int(elapsed * 1000))ms)")
                    onShortcutTriggered.send(.quickSwitch)
                    return Unmanaged.passUnretained(event)
                }

                // Normal release while switcher visible (not in search mode)
                if switcherVisible && !searchModeActive {
                    pendingActivation = false
                    print("[KeyboardEventTap] Modifier released, confirming selection")
                    onShortcutTriggered.send(.confirm)
                    return Unmanaged.passUnretained(event)
                }

                pendingActivation = false
            }

            return Unmanaged.passUnretained(event)
        }

        // Only handle key down events for shortcuts
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Handle shortcuts while switcher is visible OR pending (check this FIRST)
        if switcherVisible || pendingActivation {
            // TAB = cycle through apps (while holding modifier)
            // If pending, this cancels quick-switch and shows the panel
            if keyCode == activationKeyCode && modifierTracker.contains([activationModifier]) {
                hadInteractionSinceActivation = true

                // If still pending, cancel timer and show panel now
                if pendingActivation {
                    showSwitcherTimer?.cancel()
                    showSwitcherTimer = nil
                    pendingActivation = false
                    switcherVisible = true
                    print("[KeyboardEventTap] Second TAB pressed, showing switcher immediately")
                    onShortcutTriggered.send(.showSwitcher)
                    // Don't cycle yet - first show, next TAB will cycle
                    return nil
                }

                if modifierTracker.isShiftPressed {
                    print("[KeyboardEventTap] Cycle previous")
                    onShortcutTriggered.send(.cyclePrevious)
                } else {
                    print("[KeyboardEventTap] Cycle next")
                    onShortcutTriggered.send(.cycleNext)
                }
                return nil  // Consume the event
            }

            // Backtick (`) = cycle windows within app (with or without modifier held)
            if keyCode == UInt16(kVK_ANSI_Grave) {
                hadInteractionSinceActivation = true
                if modifierTracker.isShiftPressed {
                    print("[KeyboardEventTap] Cycle window previous")
                    onShortcutTriggered.send(.cycleWindowPrevious)
                } else {
                    print("[KeyboardEventTap] Cycle window next")
                    onShortcutTriggered.send(.cycleWindowNext)
                }
                return nil
            }

            // Q/E = cycle windows within selected app (handle early to intercept CMD+Q)
            // Only when not in search mode (so user can type these letters)
            if !searchModeActive {
                if keyCode == UInt16(kVK_ANSI_Q) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Q = previous window")
                    onShortcutTriggered.send(.cycleWindowPrevious)
                    return nil
                }

                if keyCode == UInt16(kVK_ANSI_E) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] E = next window")
                    onShortcutTriggered.send(.cycleWindowNext)
                    return nil
                }
            }

            // Enter = activate search OR confirm selection (in search mode)
            if keyCode == UInt16(kVK_Return) {
                hadInteractionSinceActivation = true
                if searchModeActive {
                    print("[KeyboardEventTap] Confirm search selection")
                    onShortcutTriggered.send(.confirm)
                } else {
                    print("[KeyboardEventTap] Activate search")
                    onShortcutTriggered.send(.activateSearch)
                }
                return nil
            }

            // Escape = dismiss
            if keyCode == UInt16(kVK_Escape) {
                print("[KeyboardEventTap] Dismiss")
                onShortcutTriggered.send(.dismiss)
                return nil
            }

            // Arrow keys for navigation (WSAD only in normal mode so user can type in search)
            if searchModeActive {
                // In search mode: only arrow keys navigate results (WSAD passed through for typing)
                if keyCode == UInt16(kVK_UpArrow) || keyCode == UInt16(kVK_LeftArrow) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Navigate up (search)")
                    onShortcutTriggered.send(.navigateUp)
                    return nil
                }

                if keyCode == UInt16(kVK_DownArrow) || keyCode == UInt16(kVK_RightArrow) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Navigate down (search)")
                    onShortcutTriggered.send(.navigateDown)
                    return nil
                }

                // TAB in search mode = navigate down (like down arrow)
                if keyCode == activationKeyCode {
                    hadInteractionSinceActivation = true
                    if modifierTracker.isShiftPressed {
                        print("[KeyboardEventTap] Tab+Shift in search = navigate up")
                        onShortcutTriggered.send(.navigateUp)
                    } else {
                        print("[KeyboardEventTap] Tab in search = navigate down")
                        onShortcutTriggered.send(.navigateDown)
                    }
                    return nil
                }
            } else {
                // In normal mode: arrow keys and WSAD navigate the app grid
                // Left/Right (A/D) = cycle through apps (linear)
                if keyCode == UInt16(kVK_LeftArrow) || keyCode == UInt16(kVK_ANSI_A) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Left/A = previous app")
                    onShortcutTriggered.send(.cyclePrevious)
                    return nil
                }

                if keyCode == UInt16(kVK_RightArrow) || keyCode == UInt16(kVK_ANSI_D) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Right/D = next app")
                    onShortcutTriggered.send(.cycleNext)
                    return nil
                }

                // Up/Down (W/S) = move to row above/below in the grid
                if keyCode == UInt16(kVK_UpArrow) || keyCode == UInt16(kVK_ANSI_W) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Up/W = row above")
                    onShortcutTriggered.send(.navigateRowUp)
                    return nil
                }

                if keyCode == UInt16(kVK_DownArrow) || keyCode == UInt16(kVK_ANSI_S) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Down/S = row below")
                    onShortcutTriggered.send(.navigateRowDown)
                    return nil
                }
            }

            // Pass through other keys
            return Unmanaged.passUnretained(event)
        }

        // Check for activation shortcut (OPTION+TAB by default) - only when switcher not visible
        if keyCode == activationKeyCode && modifierTracker.contains([activationModifier]) && !pendingActivation {
            print("[KeyboardEventTap] Activation started (switcherVisible=\(switcherVisible))")
            activationTime = CFAbsoluteTimeGetCurrent()
            hadInteractionSinceActivation = false
            pendingActivation = true

            // Notify that activation started (for pre-caching)
            onShortcutTriggered.send(.activationStarted)

            // Start timer to show switcher if not released quickly
            showSwitcherTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self, self.pendingActivation else { return }
                self.pendingActivation = false
                self.switcherVisible = true
                print("[KeyboardEventTap] Timer fired, showing switcher")
                self.onShortcutTriggered.send(.showSwitcher)
            }
            showSwitcherTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + quickSwitchThreshold, execute: timer)

            return nil  // Consume the event
        }

        return Unmanaged.passUnretained(event)
    }
}
