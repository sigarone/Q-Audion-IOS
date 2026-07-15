import Foundation

/// Modelli condivisi per il trio Group Chat (W40). 1:1 port di
/// `qaudion-android-new/feature/feature-chat/.../group/*UiState`.
///
/// Engine wiring pending: nessun `GroupChatRepository` iOS-side oggi —
/// queste struct sono il contratto-API che l'engine implementerà
/// quando lands la pipeline group messaging cross-platform.

// MARK: - Create Group

public struct ContactPickerRowUi: Identifiable, Equatable {
    public let id: String          // = userId (univoco per peer)
    public let userId: String
    public let displayName: String
    public let avatarUrl: URL?

    public init(userId: String, displayName: String, avatarUrl: URL? = nil) {
        self.id = userId
        self.userId = userId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
    }
}

public struct CreateGroupUiState: Equatable {
    public var name: String
    public var query: String
    public var contacts: [ContactPickerRowUi]      // raw lista da contacts store
    public var selectedMemberIds: Set<String>      // userId selezionati
    public var error: String?
    public var creating: Bool

    public init(name: String = "",
                query: String = "",
                contacts: [ContactPickerRowUi] = [],
                selectedMemberIds: Set<String> = [],
                error: String? = nil,
                creating: Bool = false) {
        self.name = name
        self.query = query
        self.contacts = contacts
        self.selectedMemberIds = selectedMemberIds
        self.error = error
        self.creating = creating
    }

    /// Lista filtrata per `query` (case-insensitive su displayName).
    public var filteredContacts: [ContactPickerRowUi] {
        guard !query.isEmpty else { return contacts }
        let q = query.lowercased()
        return contacts.filter { $0.displayName.lowercased().contains(q) }
    }
}

// MARK: - Group Chat

public struct GroupMessageRowUi: Identifiable, Equatable {
    public let id: String
    public let text: String
    public let senderLabel: String   // displayName breve, "Tu" se mine
    public let timestamp: String      // pre-formattato HH:mm
    public let mine: Bool
    // Fase 1B — attachment rendering. `attachmentKind` nil ⇒ plain text
    // row (unchanged behaviour). "image" ⇒ ImageBubbleContent, "file" ⇒
    // FileBubbleContent; `text` then carries the optional caption.
    public let attachmentKind: String?
    public let mediaMime: String?
    public let mediaLocalPath: String?
    public let fileName: String?
    public let byteLength: Int64?

    public init(id: String, text: String, senderLabel: String,
                timestamp: String, mine: Bool,
                attachmentKind: String? = nil, mediaMime: String? = nil,
                mediaLocalPath: String? = nil, fileName: String? = nil,
                byteLength: Int64? = nil) {
        self.id = id; self.text = text; self.senderLabel = senderLabel
        self.timestamp = timestamp; self.mine = mine
        self.attachmentKind = attachmentKind
        self.mediaMime = mediaMime
        self.mediaLocalPath = mediaLocalPath
        self.fileName = fileName
        self.byteLength = byteLength
    }
}

public struct GroupChatUiState: Equatable {
    public var name: String
    public var memberCount: Int
    public var composerText: String
    public var messages: [GroupMessageRowUi]
    public var error: String?

    public init(name: String = "", memberCount: Int = 0,
                composerText: String = "",
                messages: [GroupMessageRowUi] = [],
                error: String? = nil) {
        self.name = name; self.memberCount = memberCount
        self.composerText = composerText; self.messages = messages
        self.error = error
    }
}

// MARK: - Group Info

public struct GroupMemberRowUi: Identifiable, Equatable {
    public let id: String           // = userId
    public let userId: String
    public let displayName: String
    public let avatarUrl: URL?
    public let isAdmin: Bool
    public let isSelf: Bool

    public init(userId: String, displayName: String, avatarUrl: URL? = nil,
                isAdmin: Bool = false, isSelf: Bool = false) {
        self.id = userId
        self.userId = userId; self.displayName = displayName
        self.avatarUrl = avatarUrl; self.isAdmin = isAdmin; self.isSelf = isSelf
    }
}

public struct GroupInfoUiState: Equatable {
    /// W52: groupId — usato dal QR-invite sheet per encodare il payload
    /// `qaudion-group-invite`. Default UUID() per backward-compat con
    /// call sites pre-W52 che non lo passano.
    public var groupId: UUID
    public var name: String
    public var epoch: Int
    public var members: [GroupMemberRowUi]
    public var error: String?
    /// Fase 1C — the group avatar, derived from the local `avatarRef`
    /// (`serverUrl + "/api/v1/files/" + avatarRef`). nil ⇒ no avatar set
    /// (falls back to the person.3.fill placeholder, same as before 1C).
    public var avatarUrl: URL?

    public init(groupId: UUID = UUID(),
                name: String = "", epoch: Int = 0,
                members: [GroupMemberRowUi] = [], error: String? = nil,
                avatarUrl: URL? = nil) {
        self.groupId = groupId
        self.name = name; self.epoch = epoch
        self.members = members; self.error = error
        self.avatarUrl = avatarUrl
    }
}
