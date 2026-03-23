import SwiftUI

struct FormatActions {
    var toggleBold: () -> Void
    var toggleItalic: () -> Void
    var makeFontBigger: () -> Void
    var makeFontSmaller: () -> Void
    var canIncreaseFontSize: Bool
    var canDecreaseFontSize: Bool
}

struct FormatActionsKey: FocusedValueKey {
    typealias Value = FormatActions
}

extension FocusedValues {
    var formatActions: FormatActions? {
        get { self[FormatActionsKey.self] }
        set { self[FormatActionsKey.self] = newValue }
    }
}
