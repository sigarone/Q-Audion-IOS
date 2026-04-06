import Foundation

public final class VoiceprintStore {
    private var templates: [String: [Float]] = [:]

    public init() {}

    public func save(contactId: String, template: [Float]) { templates[contactId] = template }
    public func load(contactId: String) -> [Float]? { templates[contactId] }
    public func delete(contactId: String) { templates.removeValue(forKey: contactId) }
    public func listContacts() -> [String] { Array(templates.keys) }
    public func hasTemplate(contactId: String) -> Bool { templates[contactId] != nil }
}
