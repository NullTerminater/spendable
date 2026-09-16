import SwiftUI

/// The screen that answers the question the app exists for.
struct OverviewView: View {
    let store: SpendableStore
    @Bindable var state: MainWindowState
    var connect: () -> Void = {}

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
            Button("Connect your bank through SimpleFIN") { connect() }
        }
    }

    private func cannotWorkOut(_ accounts: [ClassifiedAccount]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("I can't work this out right now.")
                .font(.system(size: 30, weight: .semibold))
            ForEach(Array(store.accountLinesUnderNumber.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout)
            }
            // An account that has been put away is never named under the number and never raises a
            // warning — including here, where it would be the one line with no explanation attached.
            ForEach(accounts.filter { $0.standing != .archived }) { account in
                Text(cannotWorkOutLine(account))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cannotWorkOutLine(_ account: ClassifiedAccount) -> String {
        guard let source = store.accounts.first(where: { $0.id == account.id }) else { return account.name }
        return AccountPresentation.row(source, classified: account, notices: store.syncNotices)
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
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .monospacedDigit()
                .textSelection(.enabled)

            ForEach(Array(linesUnderNumber(report: report, figure: figure).enumerated()), id: \.offset) { _, line in
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

    private func linesUnderNumber(report: SafeToSpendReport, figure: SpendableFigure) -> [String] {
        let troubledNames = store.accounts.filter { AccountPresentation.notice(for: $0, in: store.syncNotices) != nil }.map(\.displayName)
        let standard = SafeToSpendNarrative.linesUnderTheNumber(report: report, figure: figure).filter { line in
            !troubledNames.contains(where: { line.contains($0) && (line.contains("stopped") || line.contains("last")) })
        }
        return store.accountLinesUnderNumber + standard
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
