import Carbon.HIToolbox

/// 앱이 활성화돼 있지 않아도 동작하는 전역 단축키 (⌃⌥ + 키). 손쉬운 사용 권한이 필요 없다.
final class HotKeys {
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []

    init(_ bindings: [(keyCode: Int, action: @MainActor () -> Void)]) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData!).takeUnretainedValue()
            // Carbon 이벤트는 메인 스레드에서 온다.
            MainActor.assumeIsolated { hotKeys.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        for (index, binding) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x524D_4C4E), id: UInt32(index))  // 'RMLN'
            RegisterEventHotKey(
                UInt32(binding.keyCode), UInt32(controlKey | optionKey), id,
                GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
            actions[UInt32(index)] = binding.action
        }
    }
}
