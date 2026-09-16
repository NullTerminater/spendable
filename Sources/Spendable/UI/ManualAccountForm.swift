import GRDB
import SwiftUI

/// Add or edit an account by hand: a name, what kind of account it is, and its balance.
/// Credit cards are entered as the amount owed and stored as a negative balance, matching the
/// most common bank convention, so one display rule covers both manual and synced cards.
struct ManualAccountForm: View {
    let database: AppDatabase
    let existing: Account?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var type: AccountType
    @State private var balanceText: String
    @State private var problem: String?
    @State private var saving = false

    init(database: AppDatabase, existing: Account?) {
        self.database = database
        self.existing = existing
        _name = State(initialValue: existing?.displayName ?? "")
        _type = State(initialValue: existing?.effectiveType ?? .checking)
        if let existing {
            let shown = existing.effectiveType == .credit ? Int64(existing.balanceCents.magnitude) : existing.balanceCents
            _balanceText = State(initialValue: Self.plainNumber(shown))
        } else {
            _balanceText = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add an account by hand" : "Edit \(existing?.displayName ?? "account")")
                .font(.title2)

            Form {
                TextField("Name", text: $name, prompt: Text("Chase Checking"))

                Picker("Kind of account", selection: $type) {
                    ForEach(AccountType.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Text(type.gloss)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(balanceLabel, text: $balanceText, prompt: Text("0.00"))
                    .monospacedDigit()
                Text("Dollars and cents, like 1240.50. No commas or symbols.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var balanceLabel: String {
        type == .credit ? "How much you owe on it" : "Balance right now"
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let entered: Int64
        do {
            entered = try Cents.parse(balanceText)
        } catch {
            problem = "That amount doesn't look right. Use plain digits with an optional decimal point, like 1240.50."
            return
        }
        if type == .credit, entered < 0 {
            problem = "Enter the amount you owe as a positive number."
            return
        }
        let stored = type == .credit ? -entered : entered
        saving = true
        defer { saving = false }
        do {
            let now = Int64(Date.now.timeIntervalSince1970)
            if let account = existing, let id = account.id {
                let selectedType = type
                // A first bank sync can flag a duplicate while this sheet is open. Saving an old
                // whole-row snapshot would silently clear that safeguard and count both balances.
                try await database.writer.write { db in
                    try db.execute(sql: """
                        UPDATE account SET display_name = ?, user_type = ?, balance_cents = ?,
                            balance_date = ?, manual_updated_at = ? WHERE id = ? AND source = 'manual'
                        """, arguments: [trimmedName, selectedType.rawValue, stored, now, now, id])
                }
            } else {
                let account = Account.manual(displayName: trimmedName, type: type, balanceCents: stored)
                try await database.writer.write { db in
                    var row = account
                    try row.insert(db)
                }
            }
            dismiss()
        } catch {
            problem = "Spendable couldn't save that. Try again."
        }
    }

    /// "1240.50" from cents, for pre-filling the field. Never locale-formatted: the field is parsed by `Cents.parse`.
    private static func plainNumber(_ cents: Int64) -> String {
        let sign = cents < 0 ? "-" : ""
        let magnitude = cents.magnitude
        let dollars = magnitude / 100
        let rest = magnitude % 100
        return "\(sign)\(dollars).\(rest < 10 ? "0" : "")\(rest)"
    }
}
