import Foundation

extension RemoteHost {
    public func matches(search query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return name.range(of: query, options: options) != nil
            || address.range(of: query, options: options) != nil
    }
}

extension Sequence<RemoteHost> {
    public func matching(search query: String) -> [RemoteHost] {
        filter { $0.matches(search: query) }
    }
}
