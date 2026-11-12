import Foundation

/// When the stall monitor writes its start mark. The monitor pings the main queue; a ping that is
/// still unanswered after `thresholdMs` means the main thread is not responding, and the line that
/// says so is written from the monitor's own queue at that moment, once per ping, instead of after
/// the main thread answers.
public enum MainThreadStallMarkPolicy {

    public static func shouldMarkStart(pingAgeMs: Int, alreadyMarked: Bool, thresholdMs: Int) -> Bool {
        !alreadyMarked && pingAgeMs >= thresholdMs
    }
}
