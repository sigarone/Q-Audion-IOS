import SwiftUI
import UIKit
import QAudionEngine

// SwiftUI glue for `KeyboardScrollPolicy` (QAudionEngine/UI): keeps the end of the conversation in view while the user
// writes, in the 1:1 chat and in the group chat. All the decisions live in the policy (pure, unit tested); this file only
// reads the keyboard notifications and the composer height, asks the policy, and calls `ScrollViewProxy.scrollTo`.
//
// No AppState in any signature (CLAUDE.md section 16): the file takes a proxy, an id and numbers.

private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Reports the height of this view (the composer area) into `height`.
    func reportsComposerHeight(_ height: Binding<CGFloat>) -> some View {
        self
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: ComposerHeightKey.self, value: geometry.size.height)
                }
            )
            .onPreferenceChange(ComposerHeightKey.self) { newValue in
                if abs(height.wrappedValue - newValue) >= 0.5 {
                    height.wrappedValue = newValue
                }
            }
    }

    /// Put on the `ScrollView` inside its `ScrollViewReader`. `lastId` is the id of the last row (nil when empty),
    /// `composerHeight` the value filled by `reportsComposerHeight`.
    func keyboardFollowsBottom<ID: Hashable>(
        proxy: ScrollViewProxy,
        lastId: ID?,
        composerHeight: CGFloat
    ) -> some View {
        modifier(KeyboardFollowsBottom(proxy: proxy, lastId: lastId, composerHeight: composerHeight))
    }
}

struct KeyboardFollowsBottom<ID: Hashable>: ViewModifier {
    let proxy: ScrollViewProxy
    let lastId: ID?
    let composerHeight: CGFloat

    @State private var keyboardHeight: CGFloat = 0
    @State private var previousComposerHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                handleKeyboard(note, trigger: .keyboardWillShow)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                handleKeyboard(note, trigger: .keyboardFrameChanged)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
            .onChange(of: composerHeight) { newHeight in
                handleComposer(newHeight)
            }
    }

    private func handleKeyboard(_ note: Notification, trigger: KeyboardScrollTrigger) {
        let info = note.userInfo
        var after: Double = 0
        if let frame = info?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let visible = frame.intersection(UIScreen.main.bounds)
            if !visible.isNull && visible.height.isFinite {
                after = Double(visible.height)
            }
        }
        let duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        let curve = info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
        let input = KeyboardScrollInput(
            trigger: trigger,
            keyboardHeightBefore: Double(keyboardHeight),
            keyboardHeightAfter: after,
            hasLastMessage: lastId != nil,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            notificationDurationSeconds: duration,
            notificationCurveRawValue: curve
        )
        keyboardHeight = CGFloat(after)
        perform(KeyboardScrollPolicy.action(for: input))
    }

    private func handleComposer(_ newHeight: CGFloat) {
        let input = KeyboardScrollInput(
            trigger: .composerHeightChanged,
            keyboardHeightAfter: Double(keyboardHeight),
            composerHeightBefore: Double(previousComposerHeight),
            composerHeightAfter: Double(newHeight),
            hasLastMessage: lastId != nil,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
        previousComposerHeight = newHeight
        perform(KeyboardScrollPolicy.action(for: input))
    }

    private func perform(_ action: KeyboardScrollAction) {
        guard case let .scrollToBottom(animationSeconds, curve, settleAfterSeconds) = action else { return }
        guard let id = lastId else { return }
        if animationSeconds > 0 {
            withAnimation(animation(curve, animationSeconds)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
        if let settle = settleAfterSeconds {
            let target = proxy
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                target.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func animation(_ curve: KeyboardScrollCurve, _ seconds: Double) -> Animation {
        switch curve {
        case .easeIn: return .easeIn(duration: seconds)
        case .easeOut: return .easeOut(duration: seconds)
        case .linear: return .linear(duration: seconds)
        case .easeInOut: return .easeInOut(duration: seconds)
        }
    }
}
