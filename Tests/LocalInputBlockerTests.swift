import AppKit
import XCTest
import CoreGraphics

final class LocalInputBlockerTests: XCTestCase {
    private let blocker = LocalInputBlocker()

    private func key(tagged: Bool) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        if tagged { event.setIntegerValueField(.eventSourceUserData, value: LocalInputBlocker.injectedEventTag) }
        return event
    }

    private func click(_ type: CGEventType, tagged: Bool) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                          mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: .left))
        if tagged { event.setIntegerValueField(.eventSourceUserData, value: LocalInputBlocker.injectedEventTag) }
        return event
    }

    /// The tap hands back unretained events, so the event is kept alive here and only
    /// the decision leaves.
    private func passes(_ type: CGEventType, _ event: CGEvent) -> Bool {
        withExtendedLifetime(event) { blocker.handle(type, event) != nil }
    }

    func testLocalDesktopsOwnEventsPass() throws {
        XCTAssertTrue(passes(.keyDown, try key(tagged: true)))
        XCTAssertTrue(passes(.leftMouseDown, try click(.leftMouseDown, tagged: true)))
    }

    func testTheMacsOwnInputPassesOnlyWhileTheMainQueueIsStuck() throws {
        let now = ProcessInfo.processInfo.systemUptime
        blocker.noteMainQueueAlive(at: now)
        XCTAssertFalse(passes(.keyDown, try key(tagged: false)))
        blocker.noteMainQueueAlive(at: now - LocalInputBlocker.mainQueueStallLimit - 1)
        XCTAssertTrue(passes(.keyDown, try key(tagged: false)))
        blocker.noteMainQueueAlive(at: now)
        XCTAssertFalse(passes(.keyDown, try key(tagged: false)))
    }

    func testTheMacsOwnInputIsDropped() throws {
        XCTAssertFalse(passes(.keyDown, try key(tagged: false)))
        XCTAssertFalse(passes(.flagsChanged, try key(tagged: false)))
        XCTAssertFalse(passes(.leftMouseDown, try click(.leftMouseDown, tagged: false)))
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0))
        XCTAssertFalse(passes(.scrollWheel, scroll))
    }

    func testReleasesPassSoNothingStaysPressed() throws {
        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
        XCTAssertTrue(passes(.keyUp, keyUp))
        XCTAssertTrue(passes(.rightMouseUp, try click(.rightMouseUp, tagged: false)))
    }

    private func modifier(keyCode: Int64, flags: UInt64) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: keyCode)
        event.flags = CGEventFlags(rawValue: flags)
        return event
    }

    func testOnlyAModifiersReleasePasses() throws {
        XCTAssertTrue(passes(.flagsChanged, try modifier(keyCode: 56, flags: 0x100)))
        XCTAssertFalse(passes(.flagsChanged, try modifier(keyCode: 56, flags: 0x20102)))
        XCTAssertFalse(passes(.flagsChanged, try modifier(keyCode: 57, flags: 0x100)))
    }

    private func mediaKey(state: Int) throws -> CGEvent {
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, subtype: 8, data1: (1 << 16) | (state << 8), data2: -1)
        return try XCTUnwrap(event?.cgEvent)
    }

    func testOnlyAMediaKeysReleasePasses() throws {
        let systemDefined = try XCTUnwrap(CGEventType(rawValue: 14))
        XCTAssertTrue(passes(systemDefined, try mediaKey(state: 0x0B)))
        XCTAssertFalse(passes(systemDefined, try mediaKey(state: 0x0A)))
    }

    func testOtherTaggedValuesDontPass() throws {
        let event = try key(tagged: false)
        event.setIntegerValueField(.eventSourceUserData, value: 42)
        XCTAssertFalse(passes(.keyDown, event))
    }

    func testDisabledTapNoticesPassThrough() throws {
        XCTAssertTrue(passes(.tapDisabledByTimeout, try key(tagged: false)))
        XCTAssertTrue(passes(.tapDisabledByUserInput, try key(tagged: false)))
    }

    func testMaskCoversKeyboardPointerAndGestures() {
        let mask = LocalInputBlocker.eventMask
        func covers(_ raw: UInt32) -> Bool { mask & (CGEventMask(1) << CGEventMask(raw)) != 0 }
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp,
                                  .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel] {
            XCTAssertTrue(covers(type.rawValue), "\(type.rawValue)")
        }
        XCTAssertTrue(covers(14), "media and brightness keys")
        XCTAssertTrue(covers(29), "trackpad gestures")
        XCTAssertFalse(covers(CGEventType.null.rawValue))
    }
}
