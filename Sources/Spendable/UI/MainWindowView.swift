import GRDB
import SwiftUI

/// Milestone 1 main window: the list of accounts, an empty state, and the manual-account form.
/// Observes exactly one narrow query (active accounts) for as long as the window is open.
struct MainWindowView: View {
    let model: AppModel

    @State private var accounts: [Account] = []
    @State private var observationError: String?
    @State private var editing: Account?
    @State private var addingAccount = false

    var body: some View {
        Group {
            if let error = model.startupError {
                ContentUnavailableView("Storage isn't available", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.database == nil {
                ProgressView("Opening your accounts…")
            } else if accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingAccount = true
                } label: {
                    Label("Add an account by hand", systemImage: "plus")
                }
                .disabled(model.database == nil)
            }
        }
        .sheet(isPresented: $addingAccount) {
            if let database = model.database {
                ManualAccountForm(database: database, existing: nil)
            }
        }
        .sheet(item: $editing) { account in
            if let database = model.database {
                ManualAccountForm(database: database, existing: account)
            }
        }
        .task(id: model.database == nil) {
            await observeAccounts()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No accounts yet", systemImage: "building.columns")
        } description: {
            Text("Add an account by hand to start. Connecting your bank through SimpleFIN comes in a later step.")
        } actions: {
            Button("Add an account by hand") { addingAccount = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var accountList: some View {
        List(accounts) { account in
            AccountRow(account: account)
                .contentShape(Rectangle())
                .contextMenu {
                    if account.source == .manual {
                        Button("Edit…") { editing = account }
                    }
                }
                .onTapGesture(count: 2) {
                    if account.source == .manual { editing = account }
                }
        }
        .listStyle(.inset)
    }

    private func observeAccounts() async {
        guard let database = model.database else { return }
        let observation = ValueObservation.tracking { db in
            try Account.activeOrdered().fetchAll(db)
        }
        do {
            for try await rows in observation.values(in: database.reader) {
                accounts = rows
            }
        } catch {
            observationError = "The account list stopped updating. Close and reopen this window."
        }
    }
}

/// One account as a sentence, never a bare figure on a tile.
struct AccountRow: View {
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.displayName)
                    .font(.headline)
                Text(account.effectiveType?.label ?? "Type not set")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(balanceSentence)
                    .font(.body)
                    .monospacedDigit()
            }
            Text(freshnessSentence)
                .font(.caption)
                .foregroundStyle(isStale ? .orange : .secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var balanceSentence: String {
        if account.effectiveType == .credit {
            return "You owe \(Cents.format(Int64(clamping: account.balanceCents.magnitude)))"
        }
        return Cents.format(account.balanceCents)
    }

    private var isStale: Bool {
        let threshold = account.source == .manual ? 3 : 2
        return AsOf.isStale(epochSeconds: account.balanceDate, thresholdDays: threshold)
    }

    private var freshnessSentence: String {
        let day = AsOf.dayPhrase(epochSeconds: account.balanceDate)
        if isStale {
            return account.source == .manual
                ? "Not updated since \(day). Edit it to bring it up to date."
                : "Not updated since \(day)."
        }
        return account.source == .manual ? "Entered by hand, as of \(day)." : "As of \(day)."
    }
}
