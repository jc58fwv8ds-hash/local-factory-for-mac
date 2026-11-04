import Foundation
import HarnessCore

/// What the user can change about the checks (2026-11-02, the user: nothing should be blocked by a false detection).
/// The two fixed lines of `ContentGuard` stay; the user registers phrases that are not to be counted, and chooses whether
/// a model's refusal is answered again by the catalog's refusal model.
struct ContentGuardSettings {
    static let exceptionsKey = "harness.contentGuard.exceptions"
    static let retryKey = "harness.contentGuard.retryRefusals"
    static let sexualKey = "harness.contentGuard.addedSexualWords"
    static let minorKey = "harness.contentGuard.addedMinorWords"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var exceptions: [String] { defaults.stringArray(forKey: Self.exceptionsKey) ?? [] }

    /// Adds a phrase; returns why it cannot be added, or nil.
    func add(_ phrase: String) -> String? {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = ContentGuard.exceptionProblem(text) { return problem }
        guard !exceptions.contains(text) else { return nil }
        defaults.set(exceptions + [text], forKey: Self.exceptionsKey)
        return nil
    }

    func remove(_ phrase: String) { defaults.set(exceptions.filter { $0 != phrase }, forKey: Self.exceptionsKey) }

    enum WordList { case sexual, minor }

    static let removedSexualKey = "harness.contentGuard.removedSexualWords"
    static let removedMinorKey = "harness.contentGuard.removedMinorWords"

    /// Words the user added to a list.
    func added(_ list: WordList) -> [String] { defaults.stringArray(forKey: key(list)) ?? [] }

    /// Default words the user took out (2026-11-04: every word but the core is the user's to decide).
    func removedDefaults(_ list: WordList) -> [String] { defaults.stringArray(forKey: removedKey(list)) ?? [] }

    /// The words that count beside the core ones: the defaults still in, then the added ones.
    func words(_ list: WordList) -> [String] {
        let defaultsIn = Self.defaultWords(list).filter { !removedDefaults(list).contains($0) }
        return defaultsIn + added(list)
    }

    static func coreWords(_ list: WordList) -> [String] { list == .sexual ? ContentGuard.coreSexualWords : ContentGuard.coreMinorWords }
    static func defaultWords(_ list: WordList) -> [String] { list == .sexual ? ContentGuard.defaultSexualWords : ContentGuard.defaultMinorWords }

    func add(_ word: String, to list: WordList) {
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.coreWords(list).contains(text) else { return }
        if Self.defaultWords(list).contains(text) {   // putting back a default word
            defaults.set(removedDefaults(list).filter { $0 != text }, forKey: removedKey(list)); return
        }
        guard !added(list).contains(text) else { return }
        defaults.set(added(list) + [text], forKey: key(list))
    }

    /// Takes a word out: an added word is forgotten, a default word is marked removed; a core word stays.
    func remove(_ word: String, from list: WordList) {
        if Self.defaultWords(list).contains(word) {
            guard !removedDefaults(list).contains(word) else { return }
            defaults.set(removedDefaults(list) + [word], forKey: removedKey(list))
        } else {
            defaults.set(added(list).filter { $0 != word }, forKey: key(list))
        }
    }

    /// Back to the words the app ships with.
    func restoreDefaults(_ list: WordList) {
        defaults.removeObject(forKey: removedKey(list))
        defaults.removeObject(forKey: key(list))
    }

    private func key(_ list: WordList) -> String { list == .sexual ? Self.sexualKey : Self.minorKey }
    private func removedKey(_ list: WordList) -> String { list == .sexual ? Self.removedSexualKey : Self.removedMinorKey }

    /// The check with everything the user set.
    func check(_ text: String, attachesPhoto: Bool) -> ContentGuard.Decision {
        ContentGuard.check(text, attachesPhoto: attachesPhoto, exceptions: exceptions,
                           sexualWords: words(.sexual), minorWords: words(.minor))
    }

    /// On unless the user turns it off.
    var retryRefusals: Bool {
        get { defaults.object(forKey: Self.retryKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.retryKey) }
    }

    /// The model that answers again after a refusal: the catalog's refusal option, when retrying is on.
    func refusalFallback(catalog: PurposeModelCatalog) -> ModelSelection? {
        guard retryRefusals else { return nil }
        return catalog.option(id: catalog.codeRefusalFallback, for: .writing)?.selection
    }
}
