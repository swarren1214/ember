import Foundation

// Suffice's money as Suffice itself has it, on this iPhone: `suffice.money.json` in the Hearth
// app group, written by Suffice after every change (SufficeMoneyPublisher). Ember answers money
// questions from it first, so it sees exactly what Suffice shows, bank transactions included,
// with nothing to download or decrypt. Its iCloud copy is the fallback (the Watch, a phone
// without Suffice, or when it's newer because someone else's device synced).

nonisolated struct SufficeMoneyPublication: HearthPublication {
    static let kind = "money"
    static let version = 1
    var book: HearthMoney.Book
}

enum SufficeMoney {
    /// Where an answer's numbers came from.
    enum Source: String {
        case suffice = "Suffice on this iPhone"
        case iCloud = "iCloud"
    }

    /// What Suffice last shared on this iPhone, and when.
    static func onThisPhone() -> (book: HearthMoney.Book, updatedAt: Date)? {
        guard let envelope = Hearth.read(SufficeMoneyPublication.self, from: .suffice) else { return nil }
        return (envelope.value.book, envelope.updatedAt)
    }

    /// The better of Suffice's own copy and Ember's iCloud copy: the one with the newer
    /// transactions (Suffice's when they're even).
    static func best(local: HearthMoney.Book?, mirror: HearthMoney.Book?) -> (book: HearthMoney.Book, source: Source)? {
        switch (local, mirror) {
        case (nil, nil): return nil
        case (let local?, nil): return (local, .suffice)
        case (nil, let mirror?): return mirror.entries.isEmpty && mirror.categories.isEmpty ? nil : (mirror, .iCloud)
        case (let local?, let mirror?):
            let localNewest = local.newestEntry ?? .distantPast
            let mirrorNewest = mirror.newestEntry ?? .distantPast
            return mirrorNewest > localNewest ? (mirror, .iCloud) : (local, .suffice)
        }
    }
}
