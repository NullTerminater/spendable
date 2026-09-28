import GRDB
import SwiftUI

enum MainScreen: String, CaseIterable, Identifiable {
    case overview
    case accounts
    case bills
    case connect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "What you can spend"
        case .accounts: "Accounts"
        case .bills: "Bills & subscriptions"
        case .connect: "Connect your bank"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "dollarsign.circle"
        case .accounts: "building.columns"
        case .bills: "calendar"
        case .connect: "link"
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
            VStack(alignment: .leading, spacing: 0) {
                ConnectionBannerView(model: model)
                HStack {
                    Spacer()
                    Button {
                        Task { await model.refresh() }
                    } label: { Label(model.isSyncing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.isSyncing)
                }.padding(.horizontal, 16).padding(.top, 8)
                Group {
                if let error = model.startupError {
                    ContentUnavailableView("Storage isn't available", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if let store = model.store, let database = model.database {
                    switch screen {
                    case .overview: OverviewView(store: store, state: state, connect: { screen = .connect })
                    case .accounts: AccountsView(store: store, database: database, state: state, connect: { screen = .connect })
                    case .bills: BillsView(store: store, database: database)
                    case .connect: SetupConnectionView(model: model)
                    }
                } else {
                    ProgressView("Opening your accounts…")
                }
                }
                if let message = model.syncMessage {
                    Text(message).font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let failure = model.store?.failure {
                    Text(failure).foregroundStyle(.red).font(.callout).padding(12)
                }
            }
            .navigationTitle(screen.title)
        }
        .onChange(of: model.setupScreenRequested) { _, requested in
            if requested {
                if screen == .connect { Task { await model.prepareSetup() } }
                else { screen = .connect }
                model.setupScreenRequested = false
            }
        }
        .sheet(isPresented: $state.addingAccount) {
            if let database = model.database { ManualAccountForm(database: database, existing: nil) }
        }
    }
}

/// The accounts list, and the way in to adding one by hand.
struct AccountsView: View {
    let store: SpendableStore
    let database: AppDatabase
    @Bindable var state: MainWindowState
    var connect: () -> Void = {}

    @State private var editing: Account?
    @State private var renaming: Account?
    @State private var archiving: Account?

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
                    Text("Add an account by hand, or connect your bank through SimpleFIN.")
                } actions: {
                    Button("Add an account by hand") { state.addingAccount = true }
                        .buttonStyle(.borderedProminent)
                    Button("Connect your bank") { connect() }
                }
            } else {
                List {
                    Section {
                        if let summary = store.connectionSummary {
                            Text(summary).font(.callout).foregroundStyle(.orange)
                        }
                        ForEach(Array(store.accountSummary.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout)
                        }
                        if let message = store.accountChangeMessage {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Connect your bank through SimpleFIN") { connect() }
                    }
                    ForEach(visible.filter { $0.mergeCandidateFor != nil && $0.mergeAnsweredAt == nil }) { manual in
                        if let synced = store.accounts.first(where: { $0.id == manual.mergeCandidateFor }) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(mergeQuestion(manual: manual, synced: synced))
                                ViewThatFits(in: .horizontal) {
                                    HStack { mergeButtons(manual: manual, synced: synced) }
                                    VStack(alignment: .leading) { mergeButtons(manual: manual, synced: synced) }
                                }
                            }.padding(.vertical, 8)
                        }
                    }
                    ForEach(visible) { account in
                        AccountRow(account: account, store: store)
                            .contentShape(Rectangle())
                            .contextMenu {
                                if account.source == .manual {
                                    Button("Edit…") { editing = account }
                                }
                                Button("Rename…") { renaming = account }
                                Button("Put away…") { archiving = account }
                            }
                            .onTapGesture(count: 2) {
                                if account.source == .manual { editing = account }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editing) { account in
            ManualAccountForm(database: database, existing: account)
        }
        .sheet(item: $renaming) { account in AccountNameForm(account: account, store: store) }
        .confirmationDialog("Put this account away?", isPresented: Binding(
            get: { archiving != nil }, set: { if !$0 { archiving = nil } }), titleVisibility: .visible) {
                if let account = archiving {
                    Button("Put it away", role: .destructive) { Task { await store.archive(account) }; archiving = nil }
                }
                Button("Cancel", role: .cancel) { archiving = nil }
            } message: {
                if let account = archiving { Text(store.archiveConfirmation(account)) }
            }
    }

    private func mergeQuestion(manual: Account, synced: Account) -> String {
        let question = "You added \(manual.displayName) by hand, and your bank has now sent an account with almost the same name. Are these the same account?"
        if synced.archivedAt != nil {
            return question + " You've put the bank's account away. You can keep the hand-entered account separate to count it again."
        }
        if store.classifiedAccounts.first(where: { $0.id == synced.id })?.standing.isCounted == true {
            return question + " Until you tell me, I'm counting only the \(Cents.format(synced.balanceCents, currency: synced.currency)) your bank sent — never both, so this number can't be doubled."
        }
        return question + " I'm holding your hand-entered balance out while you answer, and the bank's account isn't counted yet either — see its note below. Your bills still come off the figure."
    }

    @ViewBuilder
    private func mergeButtons(manual: Account, synced: Account) -> some View {
        Button("Yes, the same account") { Task { await store.answerMerge(manual, sameAccount: true) } }
            .disabled(synced.archivedAt != nil)
        Button(synced.archivedAt == nil ? "No, two different accounts" : "Keep my hand-entered account") {
            Task { await store.answerMerge(manual, sameAccount: false) }
        }
    }
}

/// One account as a sentence, never a bare figure on a tile.
struct AccountRow: View {
    let account: Account
    let store: SpendableStore
    @State private var changingType = false

    private var classified: ClassifiedAccount? {
        store.classifiedAccounts.first { $0.id == account.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.displayName)
                    .font(.headline)
                Text(account.guessClass == "investment" || account.holdingsCount > 0 ? "Investments" : account.guessClass == "loan" ? "Loan" : account.effectiveType?.label ?? "Type not set")
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
            if AccountPresentation.permitsTypeChoice(account), account.source == .simplefin {
                typeControls
            }
            if offersTheSavingsSwitch {
                Toggle("Count this towards what I can spend", isOn: Binding(
                    get: { account.includeInSafeToSpend == true },
                    set: { include in Task { await store.setIncludeInSafeToSpend(account, include) } }))
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }
            if account.source == .simplefin, account.effectiveType != nil, account.effectiveType != .credit,
               AccountPresentation.permitsTypeChoice(account) {
                Toggle("Amounts look reversed", isOn: Binding(
                    get: { account.amountsReversed },
                    set: { reversed in Task { await store.setAmountsReversed(account, reversed) } }))
                    .toggleStyle(.checkbox).font(.caption)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var typeControls: some View {
        if account.effectiveType == nil || changingType {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(AccountType.allCases) { type in
                    HStack(alignment: .top) {
                        Button(type.label) { Task { await store.setType(account, type); changingType = false } }
                            .frame(width: 100, alignment: .leading)
                        Text(type.gloss).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if changingType { Button("Cancel") { changingType = false }.font(.caption) }
            }.padding(.vertical, 8)
        } else if account.userType == nil, let type = account.guessedType {
            VStack(alignment: .leading, spacing: 6) {
                Text("Is this right?").font(.caption.weight(.semibold))
                if let original = account.guessedFromName, let renamed = account.remoteName, original != renamed {
                    Text("Your bank now calls this account \(renamed). I've been treating it as \(type.label.lowercased()) — is that still right?").font(.callout)
                }
                Text(type == .checking
                     ? "Is \(account.displayName) a checking account — money you spend from day to day?"
                     : "Is \(account.displayName) \(type == .credit ? "a credit card" : "a " + type.label.lowercased() + " account")? \(type.gloss)")
                    .font(.callout)
                ViewThatFits(in: .horizontal) {
                    HStack { confirmationButtons(type) }
                    VStack(alignment: .leading) { confirmationButtons(type) }
                }
                if let warning = AccountPresentation.availableWarning(account) {
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 6)
        } else {
            Button("Change kind of account") { changingType = true }.font(.caption).buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func confirmationButtons(_ type: AccountType) -> some View {
        Button("Yes, that's right") { Task { await store.setType(account, type) } }
        Button("No, it's something else") { changingType = true }
    }

    /// The account's own currency, not the app's. A balance the engine refuses to count because it
    /// is not in US dollars must not be shown with a dollar sign: the owner's reasonable next move
    /// on reading "$2,400.00 — not in US dollars, so it isn't counted" is to type $2,400 in by hand.
    private var balanceSentence: String {
        if account.effectiveType == .credit && account.guessClass == nil && account.holdingsCount == 0 {
            return "You owe \(Cents.format(Int64(clamping: account.balanceCents.magnitude), currency: account.currency))"
        }
        return Cents.format(classified?.balanceCents ?? account.balanceCents, currency: account.currency)
    }

    private var isHeldOut: Bool {
        if case .heldOut = classified?.standing { return true }
        return classified?.standing == .counted(.stale)
    }

    /// Whether to offer "count this towards what I can spend".
    ///
    /// Only when turning it on would actually change the number. An account holding shares is held
    /// out whatever its type says, so offering the switch there would be a control that does
    /// nothing — and worse, one that suggests the owner could put a share portfolio into what they
    /// can spend this month. They have said plainly that they do not want that.
    private var offersTheSavingsSwitch: Bool {
        AccountPresentation.offersSavingsSwitch(account)
    }

    private var standingSentence: String {
        if let notice = AccountPresentation.notice(for: account, in: store.syncNotices) {
            return "Not counted. \(AccountPresentation.problemAction(account, notice: notice))"
        }
        guard let classified else { return "As of \(AsOf.dayPhrase(epochSeconds: account.balanceDate))." }
        return AccountPresentation.row(account, classified: classified, notices: store.syncNotices)
    }
}

struct AccountNameForm: View {
    let account: Account
    let store: SpendableStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What would you like to call this account?").font(.title2)
            TextField("Name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await store.rename(account, to: name); dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 420).onAppear { name = account.displayName }
    }
}
