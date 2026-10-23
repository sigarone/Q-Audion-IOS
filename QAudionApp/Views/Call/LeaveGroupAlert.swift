import SwiftUI

/// The question asked before a 1:1 call is placed or answered while a group call is live
/// (spec 27): "Vuoi uscire dal gruppo?". Primitives and closures only; the state it reads and
/// the answers it gives live in `AppState` (`leaveGroupPrompt`, `confirmLeaveGroupPrompt`,
/// `cancelLeaveGroupPrompt`).
struct LeaveGroupAlertModifier: ViewModifier {
    let isPresented: Bool
    let isAnswer: Bool
    let onConfirm: () -> Void
    let onStay: () -> Void

    private var title: String {
        String(localized: "group_call.leave_prompt_title", defaultValue: "Vuoi uscire dal gruppo?",
               comment: "Group call alert — title of the question asked before a 1:1 call is placed or answered while a group call is live")
    }

    private var message: String {
        if isAnswer {
            return String(localized: "group_call.leave_prompt_message_answer",
                          defaultValue: "Per rispondere devi prima uscire dalla chiamata di gruppo.",
                          comment: "Group call alert — message when the user is about to answer a 1:1 call while in a group call")
        }
        return String(localized: "group_call.leave_prompt_message_dial",
                      defaultValue: "Per fare questa chiamata devi prima uscire dalla chiamata di gruppo.",
                      comment: "Group call alert — message when the user is about to place a 1:1 call while in a group call")
    }

    private var confirmTitle: String {
        String(localized: "group_call.leave_prompt_confirm", defaultValue: "Esci dal gruppo",
               comment: "Group call alert — button: leave the group call and carry on with the 1:1 call")
    }

    private var stayTitle: String {
        String(localized: "group_call.leave_prompt_stay", defaultValue: "Resta nel gruppo",
               comment: "Group call alert — button: stay in the group call (an incoming 1:1 call is declined as busy)")
    }

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: .constant(isPresented),
            actions: {
                Button(confirmTitle, role: .destructive, action: onConfirm)
                Button(stayTitle, role: .cancel, action: onStay)
            },
            message: {
                Text(message)
            })
    }
}

extension View {
    /// See `LeaveGroupAlertModifier`.
    func leaveGroupAlert(isPresented: Bool, isAnswer: Bool,
                         onConfirm: @escaping () -> Void, onStay: @escaping () -> Void) -> some View {
        modifier(LeaveGroupAlertModifier(isPresented: isPresented, isAnswer: isAnswer,
                                         onConfirm: onConfirm, onStay: onStay))
    }
}
