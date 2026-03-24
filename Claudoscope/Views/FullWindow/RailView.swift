import SwiftUI

struct RailView: View {
    @Environment(SessionStore.self) private var store
    @Binding var selected: RailItem

    var body: some View {
        VStack(spacing: 4) {
            // Provider switcher
            RailProviderToggle()
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)

            // Primary items
            ForEach(RailItem.primaryItems, id: \.self) { item in
                RailButton(item: item, isSelected: selected == item) {
                    selected = item
                }
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            // Config items
            ForEach(RailItem.configItems, id: \.self) { item in
                RailButton(item: item, isSelected: selected == item) {
                    selected = item
                }
            }

            Spacer()

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            // Settings
            RailButton(item: .settings, isSelected: selected == .settings) {
                selected = .settings
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .frame(width: 56)
        .background(.bar)
    }
}

/// Vertical provider toggle for the dashboard rail.
private struct RailProviderToggle: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 2) {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                let isActive = store.activeProvider == provider
                Button {
                    store.setActiveProvider(provider)
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: provider.icon)
                            .font(.system(size: 13))
                            .frame(width: 28, height: 20)
                        Text(provider.shortLabel)
                            .font(.system(size: 8, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(width: 48, height: 36)
                    .background(isActive ? Color.accentColor.opacity(0.2) : .clear)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(provider.label)
            }
        }
    }
}

private struct RailButton: View {
    let item: RailItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .frame(width: 28, height: 22)
                Text(item.label)
                    .font(Typography.caption)
                    .lineLimit(1)
            }
            .frame(width: 48, height: 40)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.label == "MCPs" ? "MCP Servers (Model Context Protocol)" : item.label)
    }
}
