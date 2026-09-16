import Foundation
import GRDB

enum AccountSource: String, Codable, Sendable, DatabaseValueConvertible {
    case simplefin
    case manual
}

enum AccountType: String, Codable, Sendable, CaseIterable, Identifiable, DatabaseValueConvertible {
    case checking
    case savings
    case cash
    case credit

    var id: String { rawValue }

    /// Plain-English label for the UI.
    var label: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .cash: "Cash"
        case .credit: "Credit card"
        }
    }

    /// One sentence explaining what the type means for the number, shown next to the picker.
    var gloss: String {
        switch self {
        case .checking: "Money you can spend from. Counts toward safe to spend."
        case .savings: "Set aside. Shown, but not counted unless you say so."
        case .cash: "Cash on hand. Counts toward safe to spend."
        case .credit: "A card you owe money on. Never counted as money you have."
        }
    }
}

/// One row of the `account` table. Both SimpleFIN and manual accounts live here.
struct Account: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "account"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    var source: AccountSource
    var connId: String?
    var externalId: String?
    var remoteName: String?
    var connName: String?
    var orgId: String?
    var orgName: String?
    var displayName: String
    var guessedType: AccountType?
    var userType: AccountType?
    var currency: String
    var balanceCents: Int64
    var availableCents: Int64?
    /// Unix epoch seconds. For SimpleFIN accounts this is the bank's `balance-date`, never the sync time.
    var balanceDate: Int64
    var lastSeenInSyncAt: Int64?
    var txSyncedThrough: Int64?
    var backfilledThrough: Int64?
    var historyCoverageStart: Int64?
    var manualUpdatedAt: Int64?
    var archivedAt: Int64?
    var replacedBy: Int64?
    var amountsReversed: Bool
    var includeInSafeToSpend: Bool?
    var ccDueDay: Int?
    var ccMinimumCents: Int64?
    var ccStatementCents: Int64?
    var ccStatementEnteredAt: Int64?
    var ccHasCreditBalance: Bool
    /// How many holdings the bank reports. Anything above zero means the balance is a market value
    /// rather than money, which is the only signal SimpleFIN gives that an account is investments.
    var holdingsCount: Int
    /// When this account stopped updating: it vanished from an otherwise good sync, or the server
    /// said something was wrong with it. Set the moment it happens, not after its balance ages.
    var notUpdatingSince: Int64?
    var createdAt: Int64
    /// Facts recorded once when a synced row first arrives. Renames never silently re-type it.
    var guessedFromName: String? = nil
    var guessClass: String? = nil
    var holdingsObservedAt: Int64? = nil
    var resumedUpdatingAt: Int64? = nil
    var mergeCandidateFor: Int64? = nil
    var mergeAnsweredAt: Int64? = nil

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The type the app acts on: the owner's correction always wins over the guess.
    var effectiveType: AccountType? { userType ?? guessedType }

    /// A hand-entered account. Its type is the owner's own statement, so it goes in `userType`.
    static func manual(displayName: String, type: AccountType, balanceCents: Int64, now: Date = .now) -> Account {
        let seconds = Int64(now.timeIntervalSince1970)
        return Account(
            id: nil,
            source: .manual,
            connId: nil,
            externalId: nil,
            remoteName: nil,
            connName: nil,
            orgId: nil,
            orgName: nil,
            displayName: displayName,
            guessedType: nil,
            userType: type,
            currency: "USD",
            balanceCents: balanceCents,
            availableCents: nil,
            balanceDate: seconds,
            lastSeenInSyncAt: nil,
            txSyncedThrough: nil,
            backfilledThrough: nil,
            historyCoverageStart: nil,
            manualUpdatedAt: seconds,
            archivedAt: nil,
            replacedBy: nil,
            amountsReversed: false,
            includeInSafeToSpend: nil,
            ccDueDay: nil,
            ccMinimumCents: nil,
            ccStatementCents: nil,
            ccStatementEnteredAt: nil,
            ccHasCreditBalance: false,
            holdingsCount: 0,
            notUpdatingSince: nil,
            createdAt: seconds)
    }
}

extension Account {
    /// Accounts the owner sees, newest first, archived ones excluded.
    static func activeOrdered() -> QueryInterfaceRequest<Account> {
        Account.filter(Column("archived_at") == nil).order(Column("created_at").desc, Column("id").desc)
    }
}
