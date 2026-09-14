import SwiftUI

/// The bills the owner has told the app about, and the ways to change them.
struct BillsView: View {
    let store: SpendableStore

    @State private var editing: RecurringCharge?
    @State private var adding = false
    @State private var markingPaid: RecurringCharge?

    private var bills: [RecurringCharge] {
        store.charges
            .filter { $0.status == .confirmed || $0.status == .suggested }
            .sorted { $0.cadence.monthlyEquivalentCents(of: $0.amountCents) > $1.cadence.monthlyEquivalentCents(of: $1.amountCents) }
    }

    private var monthlyTotal: Int64 {
        bills.filter { $0.status == .confirmed }
            .reduce(Int64(0)) { $0 + $1.cadence.monthlyEquivalentCents(of: $1.amountCents) }
    }

    var body: some View {
        Group {
            if bills.isEmpty {
                ContentUnavailableView {
                    Label("No bills yet", systemImage: "calendar")
                } description: {
                    Text("Add your rent and anything that comes out automatically. Until you do, the number on the first screen is just what's in your accounts.")
                } actions: {
                    Button("Add a bill") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        Text("Your bills come to \(Cents.format(monthlyTotal)) a month.")
                            .font(.headline)
                    }
                    ForEach(bills) { bill in
                        BillRow(bill: bill, accountName: name(of: bill.payingAccountId))
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Edit…") { editing = bill }
                                Button("I've paid this") { markingPaid = bill }
                                Divider()
                                Button("Delete", role: .destructive) { Task { await store.delete(bill) } }
                            }
                            .onTapGesture(count: 2) { editing = bill }
                            .swipeActions {
                                Button("Paid") { markingPaid = bill }.tint(.green)
                            }
                    }
                }
                .listStyle(.inset)
            }
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
    let accountName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(bill.name).font(.headline)
                if bill.status == .suggested {
                    Text("might be a bill")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(Cents.format(bill.amountCents)).monospacedDigit()
            }
            Text(sentence).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
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
        let monthly = bill.cadence.monthlyEquivalentCents(of: bill.amountCents)
        if bill.cadence != .monthly {
            parts.append("\(Cents.format(monthly)) a month")
        }
        return parts.joined(separator: " · ")
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
        if var charge = existing {
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
            await store.save(charge)
        } else {
            let charge = RecurringCharge.manual(
                name: trimmed, kind: kind, amountCents: cents, cadence: cadence, nextDue: due,
                payingAccountId: payingAccountId,
                destinationAccountId: kind == .transfer ? destinationAccountId : nil)
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
                        await store.markPaid(bill, alsoReduceBalance: shouldReduce)
                        dismiss()
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
