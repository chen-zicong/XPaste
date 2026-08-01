import Carbon
import Foundation

@MainActor
final class GlobalHotKeyManager {
    enum Action: UInt32 {
        case history = 1
        case favorites = 2
    }

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var registeredShortcuts: [Action: GlobalShortcut] = [:]
    private let registrationOverride: ((GlobalShortcut, Action) -> EventHotKeyRef?)?
    private let unregistration: (EventHotKeyRef) -> Void
    var onAction: ((Action) -> Void)?

    init(
        installSystemHandler: Bool = true,
        registration: ((GlobalShortcut, Action) -> EventHotKeyRef?)? = nil,
        unregistration: @escaping (EventHotKeyRef) -> Void = { UnregisterEventHotKey($0) }
    ) {
        self.registrationOverride = registration
        self.unregistration = unregistration
        if installSystemHandler { installHandler() }
    }

    deinit {
        hotKeyRefs.values.forEach(unregistration)
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Atomically replaces both registrations. If either new shortcut cannot be
    /// registered, the previous pair is restored before the method returns.
    func register(history: GlobalShortcut, favorites: GlobalShortcut) -> Set<Action> {
        guard handlerRef != nil || registrationOverride != nil else { return [.history, .favorites] }
        var invalid = Set<Action>()
        if !history.isReasonable { invalid.insert(.history) }
        if !favorites.isReasonable { invalid.insert(.favorites) }
        guard invalid.isEmpty else { return invalid }
        guard history != favorites else { return [.history, .favorites] }

        let requested: [Action: GlobalShortcut] = [
            .history: history,
            .favorites: favorites
        ]
        guard requested != registeredShortcuts else { return [] }

        let previous = registeredShortcuts
        unregisterCurrentRegistrations()

        let attempt = registerAll(requested)
        guard attempt.conflicts.isEmpty else {
            attempt.references.values.forEach(unregistration)
            hotKeyRefs.removeAll()
            registeredShortcuts.removeAll()

            // A failed replacement must not silently disable the last working keys.
            let restoration = registerAll(previous)
            hotKeyRefs = restoration.references
            registeredShortcuts = previous.filter { restoration.references[$0.key] != nil }
            return attempt.conflicts
        }

        hotKeyRefs = attempt.references
        registeredShortcuts = requested
        return []
    }

    func registeredShortcut(for action: Action) -> GlobalShortcut? {
        registeredShortcuts[action]
    }

    private func registerAll(
        _ shortcuts: [Action: GlobalShortcut]
    ) -> (references: [Action: EventHotKeyRef], conflicts: Set<Action>) {
        var references: [Action: EventHotKeyRef] = [:]
        var conflicts = Set<Action>()
        for action in [Action.history, .favorites] {
            guard let shortcut = shortcuts[action] else { continue }
            if let reference = makeRegistration(shortcut, action: action) {
                references[action] = reference
            } else {
                conflicts.insert(action)
            }
        }
        return (references, conflicts)
    }

    private func unregisterCurrentRegistrations() {
        hotKeyRefs.values.forEach(unregistration)
        hotKeyRefs.removeAll()
        registeredShortcuts.removeAll()
    }

    private func makeRegistration(_ shortcut: GlobalShortcut, action: Action) -> EventHotKeyRef? {
        if let registrationOverride { return registrationOverride(shortcut, action) }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x5850_5354, id: action.rawValue)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        guard status == noErr else { return nil }
        return ref
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            guard hotKeyID.signature == 0x5850_5354,
                  let action = Action(rawValue: hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onAction?(action) }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr { handlerRef = nil }
    }
}
