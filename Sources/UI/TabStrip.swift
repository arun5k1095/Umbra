import SwiftUI
import UniformTypeIdentifiers

struct TabStrip: View {
    @ObservedObject var browser: BrowserState
    @State private var dragging: Tab?

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width - 76 - 44 - 24
            let width = min(230, max(64, available / CGFloat(max(browser.tabs.count, 1))))
            HStack(spacing: 2) {
                Color.clear.frame(width: 76)                     // room for the window buttons
                ForEach(browser.tabs) { tab in
                    TabItem(tab: tab, selected: tab.id == browser.selected?.id, width: width,
                            onSelect: { browser.select(tab) }, onClose: { browser.close(tab) })
                        .onDrag { dragging = tab; return NSItemProvider(object: tab.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, browser: browser, dragging: $dragging))
                        .contextMenu {
                            Button("New Tab") { browser.newTab(after: tab) }
                            Button("Duplicate Tab") { if let u = tab.url { browser.newTab(url: u, after: tab) } }
                            Divider()
                            Button("Close Tab") { browser.close(tab) }
                            Button("Close Other Tabs") { browser.tabs.filter { $0 !== tab }.forEach(browser.close) }
                        }
                }
                Button { browser.newTab() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(ChromeButtonStyle())
                .help("New Tab (⌘T)")
                Spacer(minLength: 0)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 38)
        .padding(.top, 2)
        .background(WindowDragArea())
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: Tab
    let browser: BrowserState
    @Binding var dragging: Tab?
    func dropEntered(info: DropInfo) {
        guard let d = dragging, d !== target, let to = browser.tabs.firstIndex(where: { $0 === target }) else { return }
        withAnimation(.easeOut(duration: 0.15)) { browser.move(d, to: to) }
    }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

struct TabItem: View {
    @ObservedObject var tab: Tab
    let selected: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if tab.isLoading && tab.favicon == nil {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                } else if let icon = tab.favicon {
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: tab.url == nil ? "shield.lefthalf.filled" : "globe")
                        .foregroundStyle(tab.url == nil ? Color.umbra : .secondary)
                }
            }
            .frame(width: 15, height: 15)
            if width > 90 {
                Text(tab.title).font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            if (hover || selected) && width > 70 {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(ChromeButtonStyle(corner: 4))
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.surface : (hover ? Color.primary.opacity(0.06) : .clear))
                .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 1.5, y: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        .help(tab.url?.absoluteString ?? tab.title)
    }
}

struct ChromeButtonStyle: ButtonStyle {
    var corner: CGFloat = 7
    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, corner: corner)
    }
}

private struct ChromeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let corner: CGFloat
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .foregroundStyle(enabled ? .secondary : .quaternary)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hover && enabled ? 0.07 : 0))))
            .onHover { hover = $0 }
    }
}
