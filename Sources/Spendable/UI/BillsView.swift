import GRDB
import SwiftUI

/// Pages the Bills & subscriptions list from SQL (milestone-5-review decision 25). Rows arrive 50 at
/// a time into a `LazyVStack`; the total and the sections come from SQL, so they never depend on
/// how far the owner has scrolled.
@MainActor
@Observable
final class BillsPager {
    private(set) var page = BillsQueries.Page(rows: [], hasMore: false)
    private(set) var monthlyTotal: Int64 = 0
    private(set) var coverage: [String] = []
    private(set) var notices = BillsQueries.Notices()
    private var loaded = BillsQueries.pageSize
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    /// Re-reads everything loaded so far. Called whenever the store's bills change.
    func reload() async {
        let count = loaded
        guard let read = try? await database.reader.read({ db in
            (try BillsQueries.rows(db, count: count), try BillsQueries.monthlyTotal(db),
             try BillsQueries.coverageLines(db), try BillsQueries.notices(db))
        }) else { return }
        page = read.0
        monthlyTotal = read.1
        coverage = read.2
        notices = read.3
    }

    func loadMore() async {
        guard page.hasMore else { return }
        loaded += BillsQueries.pageSize
        await reload()
    }
}

/// The bills the owner has told the app about, the ones it found, and the ways to change them.
struct BillsView: View {
    let store: SpendableStore
    let database: AppDatabase

    @State private var pager: BillsPager?
    @State private var editing: RecurringCharge?
    @State private var adding = false
    @State private var markingPaid: RecurringCharge?

    var body: some View {
        Group {
            if let pager, !pager.page.rows.isEmpty {
                list(pager)
            } else if pager != nil {
                ContentUnavailableView {
                    Label("No bills yet", systemImage: "calendar")
                } description: {
                    Text("Add your rent and anything that comes out automatically. Until you do, the number on the first screen is just what's in your accounts. Bills I find in your bank's history show up here too.")
                } actions: {
                    Button("Add a bill") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            let created = pager ?? BillsPager(database: database)
            pager = created
            await created.reload()
            await store.markNewBillsSeen()
        }
        .onChange(of: store.charges) { _, _ in
            Task { await pager?.reload() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    adding = true
                } label: {
                    Label("Add a bill", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $adding) { BillForm(store: store, existing: nil) }
        .sheet(item: $editing) { bill in BillForm(store: store, existing: bill) }
        .sheet(item: $markingPaid) { bill in
            MarkPaidForm(store: store, bill: bill, payingAccount: account(bill.payingAccountId))
        }
    }

    private func list(_ pager: BillsPager) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                header(pager)
                ForEach(pager.page.rows.indices, id: \.self) { index in
                    let entry = pager.page.rows[index]
                    if index == 0 || pager.page.rows[index - 1].section != entry.section {
                        Text(entry.section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                    }
                    let bill = effective(entry.charge)
                    BillRow(bill: bill, section: entry.section, accountName: name(of: bill.payingAccountId),
                            movesTo: name(of: bill.transferEvidenceAccountId))
                        .contentShape(Rectangle())
                        .contextMenu { menu(for: bill) }
                        .onTapGesture(count: 2) { editing = bill }
                        .onAppear {
                            if index == pager.page.rows.count - 1 { Task { await pager.loadMore() } }
                        }
                    Divider()
                }
                ForEach(pager.coverage, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func header(_ pager: BillsPager) -> some View {
        Text("Your bills and subscriptions come to \(Cents.format(pager.monthlyTotal)) a month.")
            .font(.headline)
        if let message = store.billChangedMessage {
            Text(message).font(.callout)
        }
        if let undo = store.lastBillAction {
            HStack {
                Text(undoSentence(undo)).font(.callout)
                Button("Undo") { Task { await store.undoLastBillAction() } }
            }
        }
        if pager.notices.detectionFailed {
            Text("Bill detection couldn't finish. I'll try again after the next refresh.").font(.callout)
        }
        if let since = pager.notices.noNewTransactionsSince {
            Text("Bill detection hasn't seen new transactions since \(since.shortPhrase()). Your balances are still up to date.").font(.callout)
        }
        if !pager.notices.denseMerchants.isEmpty {
            Text("I don't look for bills among places you pay very often, like \(SafeToSpendNarrative.sentenceList(pager.notices.denseMerchants.map(DetectionPass.displayName(for:))))). If one of them is a bill, add it yourself.")
                .font(.callout)
        }
    }

    @ViewBuilder
    private func menu(for bill: RecurringCharge) -> some View {
        switch bill.status {
        case .suggested:
            Button("It's a bill — count it") { Task { await store.apply(.confirm, to: bill) } }
            Button("Not a bill") { Task { await store.apply(.dismiss, to: bill) } }
        default:
            if bill.inferredInactiveSince != nil {
                Button("Still active") { Task { await store.apply(.stillActive, to: bill) } }
                Button("Mark cancelled") { Task { await store.apply(.markCancelled, to: bill) } }
            }
            Button("I've paid this") { markingPaid = bill }
            if bill.source == .detected {
                if bill.confirmedBy == .auto {
                    Button("Not a bill") { Task { await store.apply(.dismiss, to: bill) } }
                }
                if bill.inferredInactiveSince == nil {
                    Button("Mark cancelled") { Task { await store.apply(.markCancelled, to: bill) } }
                }
                Button("The last payment found wasn't this bill") { Task { await store.rejectLatestPayment(bill) } }
                let manual = store.charges.filter { $0.source == .manual && $0.status == .confirmed && $0.cadence == bill.cadence }
                if !manual.isEmpty {
                    Menu("Same bill as…") {
                        ForEach(manual) { other in
                            Button(other.name) { Task { await store.sameBill(detected: bill, manual: other) } }
                        }
                    }
                }
            }
        }
        Button("Edit…") { editing = bill }
        if bill.source == .manual {
            Divider()
            Button("Delete", role: .destructive) { Task { await store.delete(bill) } }
        }
    }

    private func undoSentence(_ undo: BillUndo) -> String {
        let name = store.charges.first { $0.id == undo.chargeId }?.name ?? "That bill"
        switch undo.action {
        case .confirm: return "\(name) is counted now."
        case .dismiss: return "\(name) won't be counted or shown again."
        case .markCancelled: return "\(name) is marked cancelled and isn't counted any more."
        case .stillActive: return "\(name) is still counted."
        }
    }

    /// The row as the engine sees it: next due after any payment the bank has shown.
    private func effective(_ charge: RecurringCharge) -> RecurringCharge {
        store.effectiveCharges.first { $0.id == charge.id } ?? charge
    }

    private func account(_ id: Int64?) -> Account? {
        guard let id else { return nil }
        return store.accounts.first { $0.id == id }
    }

    private func name(of id: Int64?) -> String? {
        account(id)?.displayName
    }
}

struct BillRow: View {
    let bill: RecurringCharge
    var section: BillsQueries.Section = .bills
    let accountName: String?
    var movesTo: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(bill.name).font(.headline)
                if let badge {
                    Text(badge)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(Cents.format(bill.amountCents, currency: bill.currency)).monospacedDigit()
            }
            Text(sentence).font(.caption).foregroundStyle(.secondary)
            ForEach(notes, id: \.self) { note in
                Text(note).font(.caption)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var badge: String? {
        if bill.status == .suggested { return bill.cadence == .annual && section == .yearly ? "yearly?" : "might be a bill" }
        if bill.source == .detected && bill.confirmedBy == .auto { return "auto-detected — not right? Right-click to dismiss" }
        return nil
    }

    private var sentence: String {
        var parts: [String] = []
        if let due = bill.nextExpectedDay {
            parts.append("Next due \(due.shortPhrase())")
        } else {
            parts.append("No date set, so it isn't counted")
        }
        parts.append(bill.cadence.label.lowercased())
        if let accountName {
            parts.append(bill.kind == .transfer ? "from \(accountName)" : "paid from \(accountName)")
        }
        if bill.currency == "USD" {
            let monthly = bill.cadence.monthlyEquivalentCents(of: bill.amountCents)
            if bill.cadence != .monthly {
                parts.append("\(Cents.format(monthly)) a month")
            }
        } else {
            parts.append("in \(bill.currency), not included in the US dollar total")
        }
        parts.append(bill.source == .detected ? "found in your bank's history" : "added by you")
        return parts.joined(separator: " · ")
    }

    private var notes: [String] {
        var notes: [String] = []
        if let from = bill.amountChangedFromCents, from != bill.amountCents, let on = bill.amountChangedOn {
            let verb = bill.amountCents > from ? "went up" : "went down"
            notes.append("It \(verb) from \(Cents.format(from, currency: bill.currency)) to \(Cents.format(bill.amountCents, currency: bill.currency)) in \(CalendarDay(epochSeconds: on).monthName()).")
        }
        if let since = bill.inferredInactiveSince.flatMap(CalendarDay.init(isoString:)) {
            notes.append("I expected a charge around \(since.shortPhrase()) and haven't seen one. I'm still counting it until you tell me it's cancelled.")
        }
        if let movesTo {
            notes.append("The same amount arrives in \(movesTo). If this moves money between your accounts, edit it and say where it goes. Until then I count it as money leaving.")
        }
        if bill.evidenceChanged {
            notes.append("The charges I found this bill from have changed. Check it's still right.")
        }
        if section == .yearly {
            notes.append("I've only seen this once. It looks like a yearly charge. Is it?")
        }
        return notes
    }
}

/// Adding or changing a bill.
struct BillForm: View {
    let store: SpendableStore
    let existing: RecurringCharge?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var amountText: String
    @State private var cadence: Cadence
    @State private var kind: RecurringChargeKind
    @State private var dueDate: Date
    @State private var payingAccountId: Int64?
    @State private var destinationAccountId: Int64?
    @State private var statementMerchant: String
    @State private var problem: String?

    init(store: SpendableStore, existing: RecurringCharge?) {
        self.store = store
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _amountText = State(initialValue: existing.map { Self.plainNumber($0.amountCents) } ?? "")
        _cadence = State(initialValue: existing?.cadence ?? .monthly)
        _kind = State(initialValue: existing?.kind ?? .bill)
        _dueDate = State(initialValue: existing?.nextExpectedDay?.startOfDay() ?? Date())
        _payingAccountId = State(initialValue: existing?.payingAccountId)
        _destinationAccountId = State(initialValue: existing?.destinationAccountId)
        _statementMerchant = State(initialValue: existing?.statementMerchant ?? "")
    }

    private var openAccounts: [Account] {
        store.accounts.filter { $0.archivedAt == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add a bill" : "Edit \(existing?.name ?? "bill")")
                .font(.title2)

            Form {
                TextField("Name", text: $name, prompt: Text("Rent"))

                Picker("What is it?", selection: $kind) {
                    Text("A bill from a company").tag(RecurringChargeKind.bill)
                    Text("A subscription").tag(RecurringChargeKind.subscription)
                    Text("Money moved between my own accounts").tag(RecurringChargeKind.transfer)
                }
                Text(kindGloss)
                    .font(.caption).foregroundStyle(.secondary)

                TextField("Amount", text: $amountText, prompt: Text("500.00"))
                    .monospacedDigit()

                Picker("How often", selection: $cadence) {
                    ForEach(Cadence.allCases) { option in Text(option.label).tag(option) }
                }

                DatePicker("Next due", selection: $dueDate, displayedComponents: .date)

                TextField("How it shows up on your statement", text: $statementMerchant, prompt: Text("Optional, like CITY POWER UTIL"))
                Text("If you tell me, I can match this bill to the charges in your bank's history instead of counting it twice.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Comes out of", selection: $payingAccountId) {
                    Text("I'm not sure").tag(Int64?.none)
                    ForEach(openAccounts) { account in
                        Text(account.displayName).tag(Int64?.some(account.id ?? 0))
                    }
                }

                if kind == .transfer {
                    Picker("Goes into", selection: $destinationAccountId) {
                        Text("Choose an account").tag(Int64?.none)
                        ForEach(openAccounts) { account in
                            Text(account.displayName).tag(Int64?.some(account.id ?? 0))
                        }
                    }
                    Text("Where it lands decides whether it still counts as your money.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var kindGloss: String {
        switch kind {
        case .bill: "Rent, a phone bill, insurance. Money that leaves for good — counted whether or not it pays itself."
        case .subscription: "Something you pay for every month or year, like a streaming service."
        case .transfer: "Moving your own money, like paying a card or putting money into savings."
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let cents = try? Cents.parse(amountText), cents > 0 else {
            problem = "That amount doesn't look right. Use plain digits with an optional decimal point, like 500.00."
            return
        }
        if kind == .transfer && destinationAccountId == nil {
            problem = "Tell me which account this money goes into, or I have to assume it's gone for good."
            return
        }
        let due = CalendarDay(dueDate)
        let statement = statementMerchant.trimmingCharacters(in: .whitespaces)
        if var charge = existing {
            charge.statementMerchant = statement.isEmpty ? nil : statement
            charge.name = trimmed
            charge.amountCents = cents
            charge.kind = kind
            charge.payingAccountId = payingAccountId
            charge.destinationAccountId = kind == .transfer ? destinationAccountId : nil
            // Changing the day or the rhythm makes this a new series: the anchor moves with it.
            if charge.cadence != cadence || charge.nextExpectedDay != due {
                charge.cadence = cadence
                charge.nextExpectedDate = due.epochSeconds()
                charge.anchorDate = due.epochSeconds()
            }
            charge.updatedAt = Int64(Date.now.timeIntervalSince1970)
            let outcome = await store.save(charge)
            if outcome == .changedSinceOpened {
                problem = "This bill changed while you were editing it. Close this and open it again to see the latest details."
                return
            }
        } else {
            var charge = RecurringCharge.manual(
                name: trimmed, kind: kind, amountCents: cents, cadence: cadence, nextDue: due,
                payingAccountId: payingAccountId,
                destinationAccountId: kind == .transfer ? destinationAccountId : nil)
            charge.statementMerchant = statement.isEmpty ? nil : statement
            await store.save(charge)
        }
        dismiss()
    }

    private static func plainNumber(_ cents: Int64) -> String {
        let magnitude = cents.magnitude
        let rest = magnitude % 100
        return "\(cents < 0 ? "-" : "")\(magnitude / 100).\(rest < 10 ? "0" : "")\(rest)"
    }
}

/// Recording that a bill has been paid, and keeping the number honest while the balance catches up.
struct MarkPaidForm: View {
    let store: SpendableStore
    let bill: RecurringCharge
    let payingAccount: Account?

    @Environment(\.dismiss) private var dismiss
    @State private var alsoReduceBalance = true

    private var nextDue: CalendarDay? {
        bill.markingPaidOnce().nextExpectedDay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You've paid \(bill.name)")
                .font(.title2)

            if let nextDue {
                Text("I'll stop counting this one and expect the next on \(nextDue.shortPhrase()).")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let payingAccount, payingAccount.source == .manual {
                Toggle(isOn: $alsoReduceBalance) {
                    Text("Take \(Cents.format(bill.amountCents)) off \(payingAccount.displayName) as well")
                }
                .toggleStyle(.checkbox)
                Text(alsoReduceBalance
                     ? "Its balance becomes \(Cents.format(payingAccount.balanceCents - bill.amountCents))."
                     : "Then I'll keep subtracting this bill until you update that balance yourself, so the number doesn't go up before your money does.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("I've paid it") {
                    Task {
                        let outcome = await store.markPaid(bill, alsoReduceBalance: shouldReduce)
                        if outcome != .changedSinceOpened { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// With no hand-entered account behind it there is nothing to adjust, and nothing to wait for.
    private var shouldReduce: Bool {
        guard let payingAccount, payingAccount.source == .manual else { return true }
        return alsoReduceBalance
    }
}
