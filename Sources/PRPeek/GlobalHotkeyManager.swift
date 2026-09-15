import AppKit
import Carbon

/// Manages system-wide global hotkeys using native Carbon APIs (zero accessibility
/// permission prompt required).
///
/// Default Shortcuts:
/// - ⌥⇧P: Summon / dismiss PR Search window
/// - ⌥⇧D: Toggle Desktop Panel
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private static let enabledKey = "globalHotkeysEnabled"
    private static let signature = OSType(0x5052504B) // 'PRPK'
    private static let searchHotKeyID = UInt32(1)
    private static let panelHotKeyID = UInt32(2)

    private var eventHandlerRef: EventHandlerRef?
    private var searchHotKeyRef: EventHotKeyRef?
    private var panelHotKeyRef: EventHotKeyRef?

    var onSearch: (() -> Void)?
    var onTogglePanel: (() -> Void)?

    init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        AppLog.appModel.info("Global hotkeys enabled=\(on, privacy: .public)")
        if on {
            registerAll()
        } else {
            unregisterAll()
        }
    }

    func start() {
        guard isEnabled else { return }
        registerAll()
    }

    func stop() {
        unregisterAll()
    }

    private func registerAll() {
        installHandlerIfNeeded()

        if searchHotKeyRef == nil {
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.searchHotKeyID)
            RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(optionKey | shiftKey), hotKeyID,
                                GetApplicationEventTarget(), 0, &searchHotKeyRef)
        }

        if panelHotKeyRef == nil {
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.panelHotKeyID)
            RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(optionKey | shiftKey), hotKeyID,
                                GetApplicationEventTarget(), 0, &panelHotKeyRef)
        }
    }

    private func unregisterAll() {
        if let ref = searchHotKeyRef {
            UnregisterEventHotKey(ref)
            searchHotKeyRef = nil
        }
        if let ref = panelHotKeyRef {
            UnregisterEventHotKey(ref)
            panelHotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == GlobalHotkeyManager.signature else {
                return noErr
            }

            DispatchQueue.main.async {
                if hotKeyID.id == GlobalHotkeyManager.searchHotKeyID {
                    GlobalHotkeyManager.shared.onSearch?()
                } else if hotKeyID.id == GlobalHotkeyManager.panelHotKeyID {
                    GlobalHotkeyManager.shared.onTogglePanel?()
                }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)
    }
}
