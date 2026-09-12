import Foundation
import AppKit
import Carbon.HIToolbox

/// The three system-wide shortcuts: ⇧⌘R starts or stops a recording, ⇧⌘P pauses and resumes it, ⌥⌘K brings
/// the capture bar back. They go through Carbon's hot-key API rather than a global `NSEvent` monitor because
/// hot keys work without Accessibility access and are consumed before the frontmost app sees the key.
@MainActor
final class HotKeyCenter {
    enum Action: UInt32, CaseIterable {
        case toggleRecording = 1
        case togglePause = 2
        case showCaptureBar = 3

        var keyCode: UInt32 {
            switch self {
            case .toggleRecording: return UInt32(kVK_ANSI_R)
            case .togglePause: return UInt32(kVK_ANSI_P)
            case .showCaptureBar: return UInt32(kVK_ANSI_K)
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .toggleRecording, .togglePause: return UInt32(cmdKey | shiftKey)
            case .showCaptureBar: return UInt32(cmdKey | optionKey)
            }
        }

        /// How the shortcut reads in menus and settings.
        var display: String {
            switch self {
            case .toggleRecording: return "⇧⌘R"
            case .togglePause: return "⇧⌘P"
            case .showCaptureBar: return "⌥⌘K"
            }
        }
    }

    /// 'KTTO'
    private static let signature: OSType = 0x4B54_544F

    /// The one live instance, reached from the C callback, which cannot capture anything.
    private static weak var current: HotKeyCenter?

    var onAction: ((Action) -> Void)?
    private var handlerRef: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    init() {}

    /// Registers the handler and the three hot keys. Safe to call once; a failure to register one key (another
    /// app already holds it) leaves the others working.
    func install() {
        guard handlerRef == nil else { return }
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                ByteCount(MemoryLayout<EventHotKeyID>.size),
                nil,
                &hotKeyID
            )
            guard status == 0 else { return status }
            let identifier = hotKeyID.id
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated {
                HotKeyCenter.current?.dispatch(identifier)
            }
            return 0
        }, ItemCount(1), &spec, nil, &installed)
        guard status == 0, let installed else { return }
        handlerRef = installed
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            if RegisterEventHotKey(action.keyCode, action.modifiers, id, GetApplicationEventTarget(), 0, &ref) == 0, let ref {
                hotKeys.append(ref)
            }
        }
    }

    func uninstall() {
        for ref in hotKeys {
            _ = UnregisterEventHotKey(ref)
        }
        hotKeys.removeAll()
        if let handlerRef {
            _ = RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if Self.current === self { Self.current = nil }
    }

    private func dispatch(_ identifier: UInt32) {
        guard let action = Action(rawValue: identifier) else { return }
        onAction?(action)
    }
}
