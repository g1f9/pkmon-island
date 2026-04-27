//
//  SessionTagBadge.swift
//  ClaudeIsland
//
//  Small pill rendering one SessionTag. Used in session list rows.
//

import SwiftUI

struct SessionTagBadge: View {
    let tag: SessionTag

    var body: some View {
        Text(tag.label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tag.tint.opacity(0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tag.tint.opacity(0.4), lineWidth: 0.5)
            )
            .lineLimit(1)
            .fixedSize()
    }
}
