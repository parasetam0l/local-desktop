import UIKit

/// Maps keys of a keyboard attached to the iPhone or iPad (USB HID usages) to the Mac's
/// virtual key codes, so they can be sent as real key presses and the Mac's own keyboard
/// layout decides what they type.
enum HardwareKeyMap {
    static func macKeyCode(for usage: UIKeyboardHIDUsage) -> UInt16? {
        table[usage.rawValue]
    }

    /// The modifier a key stands for, if it is one.
    static func modifier(for usage: UIKeyboardHIDUsage) -> RDModifiers? {
        switch usage {
        case .keyboardLeftShift, .keyboardRightShift: return .shift
        case .keyboardLeftControl, .keyboardRightControl: return .control
        case .keyboardLeftAlt, .keyboardRightAlt: return .option
        case .keyboardLeftGUI, .keyboardRightGUI: return .command
        default: return nil
        }
    }

    private static let table: [Int: UInt16] = {
        var map: [Int: UInt16] = [:]
        // a…z are HID 4…29.
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (index, code) in letters.enumerated() { map[4 + index] = code }
        // 1…9, 0 are HID 30…39.
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (index, code) in digits.enumerated() { map[30 + index] = code }
        // return, escape, backspace, tab, space, - = [ ] \ (non-US #) ; ' ` , . /
        let punctuation: [UInt16] = [36, 53, 51, 48, 49, 27, 24, 33, 30, 42, 42, 41, 39, 50, 43, 47, 44]
        for (index, code) in punctuation.enumerated() { map[40 + index] = code }
        // F1…F12 are HID 58…69.
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() { map[58 + index] = code }
        map[74] = 115   // home
        map[75] = 116   // page up
        map[76] = 117   // forward delete
        map[77] = 119   // end
        map[78] = 121   // page down
        map[79] = 124   // right
        map[80] = 123   // left
        map[81] = 125   // down
        map[82] = 126   // up
        map[100] = 10   // the extra key on ISO keyboards
        return map
    }()
}
