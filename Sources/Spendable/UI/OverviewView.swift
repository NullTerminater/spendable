import SwiftUI

/// The screen that answers the question the app exists for.
struct OverviewView: View {
    let store: SpendableStore
    @Bindable var state: MainWindowState

    @State private var showingWorkings = true
    @State private var settingPayday = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch store.result {
                case .noAccountsYet:
                    dontKnowYet
                case .nothingCountable(let accounts):
                    cannotWorkOut(accounts)
                case .figures(let report):
                    figures(report)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $settingPayday) {
            PaydayForm(store: store)
        }
    }

    // MARK: States with no number

    private var dontKnowYet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("I don't know yet.")
                .font(.system(size: 34, weight: .semibold))
            Text("Add an account and I'll work out what you can spend.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Add an account by hand") { state.addingAccount = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func cannotWorkOut(_ accounts: [ClassifiedAccount]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("I can't work this out right now.")
                .font(.system(size: 30, weight: .semibold))
            ForEach(accounts) { account in
                Text(cannotWorkOutLine(account))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cannotWorkOutLine(_ account: ClassifiedAccount) -> String {
        let amount = Cents.format(account.balanceCents)
        switch account.standing {
        case .heldOut(.stoppedUpdating):
            return account.source == .manual
                ? "\(account.name) was \(amount) when you last updated it on \(account.asOf.shortPhrase()) — update it and I'll work this out."
                : "\(account.name) was \(amount) when your bank last sent a balance, on \(account.asOf.shortPhrase())."
        case .heldOut(.typeNotSet):
            return "\(account.name) holds \(amount), but I don't know what kind of account it is yet."
        case .heldOut(.savingsNotCounted):
            return "\(account.name) holds \(amount) in savings, which you haven't asked me to count."
        case .heldOut(.notUSDollars):
            return "\(account.name) isn't in US dollars, so I can't count it."
        case .heldOut(.holdsInvestments):
            return "\(account.name) holds investments worth \(amount), which isn't money I can count as spendable."
        case .creditCard:
            return "\(account.name) is a card, so what's on it is money you owe, not money you have."
        case .archived, .counted:
            return "\(account.name): \(amount)."
        }
    }

    // MARK: The number

    @ViewBuilder
    private func figures(_ report: SafeToSpendReport) -> some View {
        let figure = report.figure(store.shownFigure) ?? report.month

        if report.untilPayday != nil {
            Picker("", selection: Binding(
                get: { store.shownFigure },
                set: { store.shownFigure = $0 })) {
                    Text("This month").tag(FigureKind.calendarMonth)
                    Text("Until payday").tag(FigureKind.untilPayday)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text(SafeToSpendNarrative.label(for: figure))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(SafeToSpendDisplay.headline(figure.remainderCents))
                .font(.system(size: 52, weight: .semibold))
                .monospacedDigit()
                .textSelection(.enabled)

            ForEach(Array(SafeToSpendNarrative.linesUnderTheNumber(report: report, figure: figure).enumerated()), id: \.offset) { _, line in
                Label {
                    Text(line)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }

        if report.untilPayday == nil {
            HStack(spacing: 8) {
                Text("Tell me the day of your next payday and I'll work out what you have until then.")
                    .font(.callout)
                Button("Set payday") { settingPayday = true }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }

        DisclosureGroup("How is this worked out?", isExpanded: $showingWorkings) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SafeToSpendNarrative.disclosure(report: report, figure: figure)) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        if let heading = section.heading {
                            Text(heading).font(.subheadline.weight(.semibold))
                        }
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout).foregroundStyle(section.heading == nil ? .primary : .secondary)
                        }
                    }
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.headline)

        if report.untilPayday != nil {
            Button("Change payday") { settingPayday = true }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

/// Asking for one date: a day the owner was paid. Every other payday follows from it.
struct PaydayForm: View {
    let store: SpendableStore
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("When were you last paid?")
                .font(.title2)
            Text("You're paid every two weeks, so one date is enough — I'll work out the rest.")
                .font(.callout)
                .foregroundStyle(.secondary)
            DatePicker("Payday", selection: $date, displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        await store.savePayAnchor(CalendarDay(date))
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let anchor = store.paySchedule?.anchor {
                date = anchor.startOfDay()
            }
        }
    }
}
