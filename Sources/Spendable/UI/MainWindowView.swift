import GRDB
import SwiftUI

enum MainScreen: String, CaseIterable, Identifiable {
    case overview
    case accounts
    case bills

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "What you can spend"
        case .accounts: "Accounts"
        case .bills: "Bills"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "dollarsign.circle"
        case .accounts: "building.columns"
        case .bills: "calendar"
        }
    }

    /// Debug builds can open straight to a screen, so a run can be checked without clicking.
    static var initialScreen: MainScreen {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_SCREEN"],
           let screen = MainScreen(rawValue: name) {
            return screen
        }
        #endif
        return .overview
    }
}

struct MainWindowView: View {
    let model: AppModel
    @Bindable var state: MainWindowState

    @State private var screen: MainScreen = MainScreen.initialScreen

    var body: some View {
        NavigationSplitView {
            List(MainScreen.allCases, selection: $screen) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                if let error = model.startupError {
                    ContentUnavailableView("Storage isn't available", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if let store = model.store, let database = model.database {
                    switch screen {
                    case .overview: OverviewView(store: store, state: state)
                    case .accounts: AccountsView(store: store, database: database, state: state)
                    case .bills: BillsView(store: store)
                    }
                } else {
                    ProgressView("Opening your accounts…")
                }
            }
            .navigationTitle(screen.title)
        }
    }
}

/// The accounts list, and the way in to adding one by hand.
struct AccountsView: View {
    let store: SpendableStore
    let database: AppDatabase
    @Bindable var state: MainWindowState

    @State private var editing: Account?

    private var visible: [Account] {
        store.accounts.filter { $0.archivedAt == nil }
            .sorted { ($0.createdAt, $0.id ?? 0) > ($1.createdAt, $1.id ?? 0) }
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label("No accounts yet", systemImage: "building.columns")
                } description: {
                    Text("Add an account by hand to start. Connecting your bank through SimpleFIN comes in a later step.")
                } actions: {
                    Button("Add an account by hand") { state.addingAccount = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(visible) { account in
                        AccountRow(account: account, store: store)
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
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $state.addingAccount) {
            ManualAccountForm(database: database, existing: nil)
        }
        .sheet(item: $editing) { account in
            ManualAccountForm(database: database, existing: account)
        }
    }
}

/// One account as a sentence, never a bare figure on a tile.
struct AccountRow: View {
    let account: Account
    let store: SpendableStore

    private var classified: ClassifiedAccount? {
        guard case .figures(let report) = store.result else { return nil }
        return report.accounts.first { $0.id == account.id }
    }

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
            Text(standingSentence)
                .font(.caption)
                .foregroundStyle(isHeldOut ? .orange : .secondary)
            if account.effectiveType == .savings {
                Toggle("Count this towards what I can spend", isOn: Binding(
                    get: { account.includeInSafeToSpend == true },
                    set: { include in Task { await store.setIncludeInSafeToSpend(account, include) } }))
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }
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

    private var isHeldOut: Bool {
        if case .heldOut = classified?.standing { return true }
        return classified?.standing == .counted(.stale)
    }

    private var standingSentence: String {
        let day = AsOf.dayPhrase(epochSeconds: account.balanceDate)
        guard let standing = classified?.standing else {
            return account.source == .manual ? "Entered by hand, as of \(day)." : "As of \(day)."
        }
        switch standing {
        case .counted(.fresh):
            return account.source == .manual ? "Entered by hand, as of \(day)." : "As of \(day)."
        case .counted(.stale):
            return account.source == .manual
                ? "Entered by hand on \(day). Update it when you get a chance."
                : "As of \(day), which is a few days ago."
        case .heldOut(.stoppedUpdating):
            return "Not counted. Nothing new since \(day)."
        case .heldOut(.savingsNotCounted):
            return "Savings, not counted towards what you can spend. As of \(day)."
        case .heldOut(.typeNotSet):
            return "Not counted until you say what kind of account this is."
        case .heldOut(.notUSDollars):
            return "Not in US dollars, so it isn't counted."
        case .heldOut(.holdsInvestments):
            return "Holds investments, not money. Not counted towards what you can spend."
        case .creditCard:
            return "Money you owe, never counted as money you have. As of \(day)."
        case .archived:
            return "Put away."
        }
    }
}
