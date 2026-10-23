import Foundation

// What a backup holds for a stored message whose body begins with `{"qa_loc":` (docs/LOCATION_SHARING.md 1.3, "Backups and exports"), when
// a backup is written and when one is read back. The judgement is the typed reading of the row (`LocationRowForm.parse`), never a
// substring test:
//
//  - a valid pin keeps its body (the coordinates are the message, like a photo, and follow the rule of text messages);
//  - a live row keeps the LOCAL FORM of the start (`sid`, `st`, `du`; no `k`, no position), so a restored live row shows "Condivisione
//    terminata": no live-share record stands behind it. This is also what happens to the row of a share that ended before its `msg_sent`
//    echo, whose row still holds the full start body, key included, because the outbox re-seals the text of the row;
//  - everything else becomes the fixed placeholder: what was in it is never written to a backup and never trusted when one is read.
//
// A body that is not a location is returned unchanged.

public enum LocationBackupBody {

    public static func normalised(_ body: String) -> String {
        guard LocationCodec.hasLocationPrefix(body) else { return body }
        switch LocationRowForm.parse(body) {
        case .pin?:
            return body
        case .live(let row)?:
            return LocationRowForm.localForm(sid: row.sid, startedAt: row.startedAt, duration: row.duration)
        case nil:
            return LocationBodyPlaceholder.text(.unavailable)
        }
    }
}
