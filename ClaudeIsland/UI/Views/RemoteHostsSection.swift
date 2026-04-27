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
    /// Set to the host id while uninstall is mid-flight, so the row can
    /// show a per-row spinner instead of leaving the user wondering
    /// whether the click registered.
    @State private var removingHostId: UUID?
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
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func hostRow(_ host: RemoteHost) -> some View {
        let isRemoving = removingHostId == host.id
        HStack(spacing: 8) {
            // Name (and sshTarget below it, only when they differ — when
            // name was left blank during install we use sshTarget as the
            // fallback name, so duplicating the line is just noise).
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if host.name != host.sshTarget {
                    Text(host.sshTarget)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Take all available width so long names truncate instead of
            // pushing the controls off-row.
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isRemoving ? 0.5 : 1.0)

            if isRemoving {
                // Mid-uninstall: show progress in place of the row's
                // controls. The whole flow is 3 sequential SSH commands
                // (read settings → write stripped settings → rm hook
                // script) so 3-6s on a typical link.
                ProgressView()
                    .controlSize(.small)
                Text("Removing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("", isOn: Binding(
                    get: { host.enabled },
                    set: { newValue in
                        var updated = host
                        updated.enabled = newValue
                        registry.update(updated)
                    }
                ))
                .labelsHidden()
                .disabled(inProgress)

                Button("Remove") {
                    Task { await uninstallAndRemove(host) }
                }
                .disabled(inProgress)
            }
        }
    }

    @ViewBuilder
    private func addForm() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name (optional, defaults to SSH target)", text: $newName)
                .disabled(inProgress)
            TextField("SSH target (e.g. user@host or ~/.ssh/config alias)", text: $newSSHTarget)
                .disabled(inProgress)
            HStack(spacing: 8) {
                if inProgress {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Install") {
                    Task { await install() }
                }
                .disabled(inProgress || newSSHTarget.trimmingCharacters(in: .whitespaces).isEmpty)
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

        let trimmedName = newName.trimmingCharacters(in: .whitespaces)
        let trimmedTarget = newSSHTarget.trimmingCharacters(in: .whitespaces)
        // Empty name → reuse sshTarget. The user-visible name and the
        // SessionHost.remote(name:) tag both end up as the target string,
        // which is fine — short SSH aliases are typically what users want
        // to see anyway.
        let effectiveName = trimmedName.isEmpty ? trimmedTarget : trimmedName

        let host = RemoteHost(name: effectiveName, sshTarget: trimmedTarget)
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
        // inProgress disables the global Add/Toggle/Remove controls so
        // the user can't kick off concurrent SSH ops.
        // removingHostId additionally lights up THIS row's spinner so
        // the user can see which host is being torn down.
        inProgress = true
        removingHostId = host.id
        lastError = nil
        defer {
            inProgress = false
            removingHostId = nil
        }
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
