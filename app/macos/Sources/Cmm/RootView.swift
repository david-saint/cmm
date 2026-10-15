import AppKit
import CmmKit
import SwiftUI

/// The window's content: one screen per state of the model, and the confirmation sheet on top of the plan.
struct RootView: View {
    let model: AppModel
    var home = NSHomeDirectory()
    /// Groups that start open in the list (closed unless a test or a preview says otherwise).
    var expanded: Set<String> = []

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .scanning:
                ScanningView()
            case .ready:
                ReadyView(model: model, home: home, expanded: expanded)
            case .empty:
                NothingToCleanView(model: model)
            case .cleaning:
                CleaningView(model: model, home: home)
            case .done:
                DoneView(model: model, home: home)
            case .failed:
                ErrorView(model: model, home: home)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: confirmation) { pending in
            ConfirmSheet(
                confirmation: pending,
                cancel: { model.cancelClean() },
                clean: { Task { await model.confirmClean(pending) } }
            )
        }
    }

    /// The sheet is open exactly while the model has a pending confirmation; dismissing it any other way than
    /// "Clean" (Cancel, Esc) cancels it.
    private var confirmation: Binding<CleanConfirmation?> {
        Binding(
            get: { model.confirmation },
            set: { if $0 == nil { model.cancelClean() } }
        )
    }
}

/// Plan on screen: header cards, the groups, and the footer with the totals and the buttons.
struct ReadyView: View {
    let model: AppModel
    let home: String
    var expanded: Set<String> = []

    var body: some View {
        if let plan = model.plan, let selection = model.selection {
            VStack(spacing: 0) {
                HeaderView(plan: plan, selection: selection)
                Divider()
                PlanListView(model: model, selection: selection, home: home, expanded: expanded)
                Divider()
                FooterView(model: model, selection: selection)
            }
        }
    }
}
