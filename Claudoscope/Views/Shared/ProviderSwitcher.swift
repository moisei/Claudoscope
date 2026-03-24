import SwiftUI

/// Compact segmented control for switching between AI providers (Claude Code / Cursor).
struct ProviderSwitcher: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                let isActive = store.activeProvider == provider
                Button {
                    store.setActiveProvider(provider)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: provider.icon)
                            .font(.system(size: 9))
                        Text(provider.shortLabel)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isActive ? Color.accentColor : Color.clear)
                    .foregroundStyle(isActive ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 1))
    }
}
