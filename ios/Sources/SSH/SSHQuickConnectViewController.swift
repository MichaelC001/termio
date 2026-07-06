import SwiftUI
import UIKit

/// A command-palette-style quick connect: a searchable list of every saved SSH
/// host, presented as a sheet. Picking one hands it back via `onSelect` — the
/// presenter dismisses this sheet and opens the terminal, so the session
/// survives the dismissal.
///
/// Built as SwiftUI `List` + `.searchable` inside a `UIHostingController`: the
/// app's own modern idiom (see the theme picker's `UIHostingConfiguration`
/// rows), and the components adopt Liquid Glass automatically on iOS 26 — the
/// HIG way to get the glass search field and toolbar rather than hand-rolling.
final class SSHQuickConnectViewController: UIHostingController<SSHQuickConnectView> {
    init(onSelect: @escaping (SSHHost) -> Void) {
        super.init(rootView: SSHQuickConnectView(onSelect: onSelect))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

struct SSHQuickConnectView: View {
    let onSelect: (SSHHost) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var hosts: [SSHHost] {
        let all = SSHStore.shared.hosts
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.displayName.lowercased().contains(q)
                || $0.host.lowercased().contains(q)
                || $0.username.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(hosts) { host in
                Button { onSelect(host) } label: { row(host) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay {
                if hosts.isEmpty {
                    ContentUnavailableView.search
                }
            }
            .navigationTitle("Quick Connect")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search hosts")
            .autoFocusSearch($searchFocused)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ host: SSHHost) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .foregroundStyle(.primary)
                Text(hostSubtitle(host))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }

    private func hostSubtitle(_ host: SSHHost) -> String {
        let port = host.port == 22 ? "" : ":\(host.port)"
        return "\(host.username)@\(host.host)\(port)"
    }
}

private extension View {
    /// Focus the search field as the palette appears — the keyboard-first
    /// command-palette feel. `searchFocused` is iOS 18+, so older systems just
    /// show the field unfocused.
    @ViewBuilder
    func autoFocusSearch(_ focused: FocusState<Bool>.Binding) -> some View {
        if #available(iOS 18.0, *) {
            searchFocused(focused).onAppear { focused.wrappedValue = true }
        } else {
            self
        }
    }
}
