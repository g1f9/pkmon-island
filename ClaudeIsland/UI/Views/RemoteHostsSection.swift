//
//  RemoteHostsSection.swift
//  ClaudeIsland
//
//  Inline section in NotchMenuView for managing remote SSH hosts.
//  Add/remove hosts; install hooks on add; uninstall + remove on delete.
//

import SwiftUI

struct RemoteHostsSection: View {
    @ObservedObject private var registry = RemoteHostRegistry.shared

    @State private var showAdd = false
    @State private var newName: String = ""
    @State private var newSSHTarget: String = ""
    @State private var inProgress = false
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Remote Hosts").font(.headline)
                Spacer()
                Button(showAdd ? "Cancel" : "Add") {
                    showAdd.toggle()
                    lastError = nil
                }
                .disabled(inProgress)
            }

            ForEach(registry.hosts) { host in
                hostRow(host)
            }

            if showAdd {
                addForm()
            }

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func hostRow(_ host: RemoteHost) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(host.name).font(.body)
                Text(host.sshTarget).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { host.enabled },
                set: { newValue in
                    var updated = host
                    updated.enabled = newValue
                    registry.update(updated)
                }
            ))
            .labelsHidden()

            Button("Remove") {
                Task { await uninstallAndRemove(host) }
            }
            .disabled(inProgress)
        }
    }

    @ViewBuilder
    private func addForm() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name (e.g. dev-vm)", text: $newName)
            TextField("SSH target (e.g. user@host or ~/.ssh/config alias)", text: $newSSHTarget)
            HStack {
                Spacer()
                Button("Install") {
                    Task { await install() }
                }
                .disabled(inProgress || newName.isEmpty || newSSHTarget.isEmpty)
            }
        }
        .padding(8)
        .background(.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    private func install() async {
        inProgress = true
        lastError = nil
        defer { inProgress = false }

        let host = RemoteHost(name: newName, sshTarget: newSSHTarget)
        do {
            try await RemoteHookInstaller.install(on: host)
            registry.add(host)
            // Adding to the registry triggers SSHBridgeController.reconcile()
            // via the Combine subscription on RemoteHostRegistry.$hosts —
            // the bridge spins up automatically.
            newName = ""
            newSSHTarget = ""
            showAdd = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func uninstallAndRemove(_ host: RemoteHost) async {
        inProgress = true
        lastError = nil
        defer { inProgress = false }
        do {
            try await RemoteHookInstaller.uninstall(on: host)
        } catch {
            // Continue removing even if uninstall failed — user is
            // explicitly asking to remove. Surface the error.
            lastError = "Uninstall: \(error.localizedDescription)"
        }
        registry.remove(id: host.id)
    }
}
