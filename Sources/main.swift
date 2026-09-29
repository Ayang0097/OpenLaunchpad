import AppKit
import Carbon
import Darwin

private var activeDelegate: AppDelegate?
private let shortcutHandler: EventHandlerUPP = { _, _, _ in
    DispatchQueue.main.async { activeDelegate?.toggle() }
    return noErr
}

struct AppEntry {
    let id: String
    let name: String
    let url: URL
    let icon: NSImage
}

struct LaunchNode: Codable, Equatable {
    var kind: String
    var id: String
    var name: String
    var children: [LaunchNode]
}

struct LaunchLayout: Codable, Equatable {
    var version: Int
    var pages: [[LaunchNode]]
    var hiddenIDs: [String]
    var knownIDs: [String]
}

// Preserve explicit page boundaries while keeping every item reachable.
func normalizeLayout(_ model: inout LaunchLayout, capacity: Int) {
    var seen = Set<String>()
    model.pages = model.pages.map { nodes in
        nodes.compactMap { node in
            var node = node
            guard seen.insert(node.id).inserted else { return nil }
            if node.kind == "group" {
                node.children = node.children.filter { seen.insert($0.id).inserted }
                if node.children.isEmpty { return nil }
                if node.children.count == 1 { return node.children[0] }
            }
            return node
        }
    }
    var index = 0
    while index < model.pages.count {
        if model.pages[index].count > capacity {
            let overflow = Array(model.pages[index].dropFirst(capacity))
            model.pages[index] = Array(model.pages[index].prefix(capacity))
            if index + 1 == model.pages.count { model.pages.append([]) }
            model.pages[index + 1].insert(contentsOf: overflow, at: 0)
        }
        index += 1
    }
    while model.pages.count > 1 && model.pages.last!.isEmpty { model.pages.removeLast() }
    if model.pages.isEmpty { model.pages = [[]] }
}

final class LaunchpadWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}

final class FolderBackdrop: NSView {
    var onClose: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClose?() }
}

final class FolderTitle: NSTextField {
    var onRename: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onRename?() }
}

final class GroupTile: NSView {
    let panel = NSView()
    var miniIcons: [NSImageView] = []
    let label = NSTextField(labelWithString: "")
    var onOpen: (() -> Void)?
    var onRename: (() -> Void)?
    var onUngroup: (() -> Void)?
    init(node: LaunchNode, appByID: [String: AppEntry]) {
        super.init(frame: .zero)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        panel.layer?.cornerRadius = 20
        addSubview(panel)
        for child in node.children.prefix(4) {
            let image = NSImageView()
            image.image = appByID[child.id]?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            image.imageScaling = .scaleProportionallyUpOrDown
            panel.addSubview(image)
            miniIcons.append(image)
        }
        label.stringValue = node.name
        label.textColor = .white
        label.alignment = .center
        label.font = .systemFont(ofSize: 14)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func layout() {
        super.layout()
        let size = min(124, bounds.width * 0.62, bounds.height - 36)
        panel.frame = NSRect(x: (bounds.width-size)/2, y: bounds.height-size-15, width: size, height: size)
        let iconSize = size * 0.38
        for (index, icon) in miniIcons.enumerated() {
            let col = index % 2, row = index / 2
            icon.frame = NSRect(x: size*0.08 + CGFloat(col)*size*0.47,
                                y: size*0.55 - CGFloat(row)*size*0.47,
                                width: iconSize, height: iconSize)
        }
        label.frame = NSRect(x: 2, y: bounds.height-size-49, width: bounds.width-4, height: 21)
    }
    override func mouseUp(with event: NSEvent) { onOpen?() }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "重命名文件夹…", action: #selector(rename), keyEquivalent: "").target = self
        menu.addItem(withTitle: "解散文件夹", action: #selector(ungroup), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc func rename() { onRename?() }
    @objc func ungroup() { onUngroup?() }
}

class AppTile: NSView {
    let entry: AppEntry
    let imageView = NSImageView()
    let label = NSTextField(labelWithString: "")
    var onOpen: (() -> Void)?
    var onDrag: ((AppTile, NSPoint) -> Void)?
    var onDrop: ((NSPoint) -> Void)?
    var onLongPress: (() -> Void)?
    var onDelete: (() -> Void)?
    private let deleteButton = NSButton()
    private var longPressTimer: Timer?
    private var longPressed = false
    private var down: NSPoint?
    private var dragging = false

    init(entry: AppEntry) {
        self.entry = entry
        super.init(frame: .zero)
        imageView.image = entry.icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        label.stringValue = entry.name
        label.textColor = .white
        label.alignment = .center
        label.font = .systemFont(ofSize: 14)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        deleteButton.title = "×"
        deleteButton.font = .systemFont(ofSize: 20, weight: .medium)
        deleteButton.isBordered = false
        deleteButton.wantsLayer = true
        deleteButton.layer?.backgroundColor = NSColor.darkGray.cgColor
        deleteButton.layer?.cornerRadius = 12
        deleteButton.contentTintColor = .white
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isHidden = true
        addSubview(deleteButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !deleteButton.isHidden && deleteButton.frame.contains(convert(point, from: superview)) { return deleteButton }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func layout() {
        super.layout()
        let size = min(124, bounds.width * 0.62, bounds.height - 36)
        imageView.frame = NSRect(x: (bounds.width - size)/2, y: bounds.height - size - 15, width: size, height: size)
        label.frame = NSRect(x: 2, y: bounds.height - size - 49, width: bounds.width - 4, height: 21)
        deleteButton.frame = NSRect(x: imageView.frame.minX - 6, y: imageView.frame.maxY - 18, width: 24, height: 24)
    }
    func setEditing(_ editing: Bool) {
        deleteButton.isHidden = !editing || onDelete == nil
        imageView.wantsLayer = true
        imageView.layer?.removeAnimation(forKey: "jiggle")
        if editing {
            let jiggle = CABasicAnimation(keyPath: "transform.rotation.z")
            jiggle.fromValue = -0.018
            jiggle.toValue = 0.018
            jiggle.duration = 0.17 + Double(abs(entry.id.hashValue % 5)) * 0.012
            jiggle.autoreverses = true
            jiggle.repeatCount = .infinity
            imageView.layer?.add(jiggle, forKey: "jiggle")
        }
    }
    @objc private func deleteTapped() { onDelete?() }
    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        dragging = false
        longPressed = false
        longPressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.55, repeats: false) { [weak self] _ in
            guard let self, self.down != nil, !self.dragging else { return }
            self.longPressed = true
            self.onLongPress?()
        }
        longPressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    override func mouseDragged(with event: NSEvent) {
        if let down, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) > 8 {
            longPressTimer?.invalidate()
            dragging = true
            onDrag?(self, event.locationInWindow)
        }
    }
    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        if dragging { onDrop?(event.locationInWindow) }
        else if !longPressed { onOpen?() }
        down = nil
        dragging = false
        longPressed = false
    }
}

final class DragPreviewTile: AppTile {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class LaunchpadView: NSView, NSSearchFieldDelegate {
    var apps: [AppEntry] = []
    private var iconCache: [String: NSImage] = [:]
    private var cachedPageHosts: [Int: NSView] = [:]
    private var cachedGridSize = NSSize.zero
    private var currentGridHost: NSView?
    private var lastGridSignature = ""
    private var renderRevision = 0
    var filtered: [AppEntry] = []
    var layoutModel = LaunchLayout(version: 1, pages: [], hiddenIDs: [], knownIDs: [])
    var activeGroupID: String?
    private var editMode = false
    var page = 0
    var underlyingPage = 0
    let search = NSSearchField()
    let searchBackdrop = NSView()
    let searchGlyph = NSImageView()
    let searchMoreButton = NSButton()
    let backButton = NSButton(title: "‹ 返回", target: nil, action: nil)
    let grid = NSView()
    let dots = NSView()
    let folderBackdrop = FolderBackdrop()
    let folderPanel = NSView()
    let folderTitle = FolderTitle(labelWithString: "")
    let folderGrid = NSView()
    var onHide: (() -> Void)?
    var onSettings: (() -> Void)?
    let defaults = UserDefaults.standard
    private var lastPageScroll = Date.distantPast
    private var scrollAccumulation: CGFloat = 0
    private var changedPageInGesture = false
    private var swipeNeighbor: NSView?
    private var swipeDirection = 0
    private var swipeOffset: CGFloat = 0
    private var isSettlingSwipe = false
    private var transitionRevision = 0
    private var draggedTile: AppTile?
    private weak var dragSourceTile: AppTile?
    private var draggedNode: LaunchNode?
    private var dragPointerOffset = NSPoint.zero
    private var dragHoverIndex = -1
    private weak var dragFolderTarget: NSView?
    private var dragFolderCandidateID: String?
    private var dragFolderArmedID: String?
    private var dragFolderHoverTimer: Timer?
    private var dragEdge = 0
    private var dragEdgeTimer: Timer?
    private var dragEventMonitor: Any?

    func cancelPageTransition() {
        transitionRevision += 1
        swipeNeighbor?.removeFromSuperview()
        swipeNeighbor = nil
        for host in grid.subviews {
            host.layer?.removeAnimation(forKey: "pageSlide")
            if host !== currentGridHost { host.removeFromSuperview() }
            setPageOffset(0, for: host)
        }
        swipeDirection = 0
        swipeOffset = 0
        isSettlingSwipe = false
        lastGridSignature = ""
    }

    private func setPageOffset(_ offset: CGFloat, for host: NSView) {
        guard let layer = host.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(translationX: offset, y: 0))
        CATransaction.commit()
    }

    private func normalizeGridHost(_ host: NSView, pageIndex: Int, columns: Int, rows: Int) {
        guard layoutModel.pages.indices.contains(pageIndex) else { return }
        let contentX = grid.bounds.width * 0.105
        let cellW = grid.bounds.width * 0.79 / CGFloat(columns)
        let cellH = grid.bounds.height / CGFloat(rows)
        let positions = Dictionary(uniqueKeysWithValues: layoutModel.pages[pageIndex].enumerated().map { ($0.element.id, $0.offset) })
        for child in host.subviews {
            guard let id = child.identifier?.rawValue, let index = positions[id] else { continue }
            child.layer?.removeAllAnimations()
            child.frame = NSRect(x: contentX + CGFloat(index % columns) * cellW,
                                 y: grid.bounds.height - CGFloat(index / columns + 1) * cellH,
                                 width: cellW, height: cellH)
        }
        host.layer?.removeAnimation(forKey: "pageSlide")
        setPageOffset(0, for: host)
    }

    private func animatePageOffset(_ offset: CGFloat, for host: NSView, duration: CFTimeInterval) {
        guard let layer = host.layer else { return }
        let start = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
            ?? layer.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = start
        animation.toValue = offset
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        setPageOffset(offset, for: host)
        layer.add(animation, forKey: "pageSlide")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        search.placeholderString = "搜索"
        search.delegate = self
        search.focusRingType = .none
        search.appearance = NSAppearance(named: .darkAqua)
        search.font = .systemFont(ofSize: 13)
        (search.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        search.isBezeled = false
        search.drawsBackground = false
        search.textColor = .white
        search.placeholderAttributedString = NSAttributedString(
            string: "搜索", attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.68),
                .font: NSFont.systemFont(ofSize: 13)
            ])
        backButton.isBordered = false
        backButton.contentTintColor = .white
        backButton.target = self
        backButton.action = #selector(closeGroup)
        backButton.isHidden = true
        addSubview(backButton)
        grid.wantsLayer = true
        grid.layer?.masksToBounds = true
        addSubview(grid)
        searchBackdrop.wantsLayer = true
        searchBackdrop.layer?.backgroundColor = NSColor(srgbRed: 0.55, green: 0.78, blue: 0.88, alpha: 0.24).cgColor
        searchBackdrop.layer?.borderColor = NSColor(srgbRed: 0.45, green: 0.91, blue: 0.98, alpha: 0.30).cgColor
        searchBackdrop.layer?.borderWidth = 1
        addSubview(searchBackdrop)
        searchGlyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchGlyph.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        searchGlyph.imageScaling = .scaleProportionallyDown
        addSubview(searchGlyph)
        addSubview(search)
        searchMoreButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多选项")
        searchMoreButton.imagePosition = .imageOnly
        searchMoreButton.isBordered = false
        searchMoreButton.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        searchMoreButton.target = self
        searchMoreButton.action = #selector(showSearchOptions(_:))
        addSubview(searchMoreButton)
        addSubview(dots)
        folderBackdrop.wantsLayer = true
        folderBackdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.36).cgColor
        folderBackdrop.onClose = { [weak self] in self?.closeGroup() }
        folderBackdrop.isHidden = true
        addSubview(folderBackdrop)
        folderPanel.wantsLayer = true
        folderPanel.layer?.backgroundColor = NSColor(calibratedWhite: 0.25, alpha: 0.8).cgColor
        folderPanel.layer?.cornerRadius = 24
        folderPanel.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        folderPanel.layer?.borderWidth = 1
        folderPanel.isHidden = true
        folderTitle.textColor = .white
        folderTitle.alignment = .center
        folderTitle.font = .systemFont(ofSize: 24, weight: .medium)
        folderTitle.onRename = { [weak self] in
            if let id = self?.activeGroupID { self?.renameGroup(id) }
        }
        folderPanel.addSubview(folderTitle)
        folderPanel.addSubview(folderGrid)
        addSubview(folderPanel)
        addSubview(dots, positioned: .above, relativeTo: folderPanel)
        loadApps()
    }
    required init?(coder: NSCoder) { fatalError() }

    func loadApps() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications")]
        var urls: [URL] = []
        for root in roots {
            if let directChildren = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                urls.append(contentsOf: directChildren.filter { $0.pathExtension.lowercased() == "app" })
            }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "app" {
                    urls.append(url)
                    enumerator.skipDescendants()
                }
            }
        }
        var seen = Set<String>()
        apps = urls.compactMap { url in
            let bundle = Bundle(url: url)
            let id = bundle?.bundleIdentifier ?? url.path
            guard id != "local.ayang.OpenLaunchpad", id != "com.drbuho.BuhoLaunchpad.Launcher" else { return nil }
            guard seen.insert(id).inserted else { return nil }
            let bundleName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let preferredNames = ["com.microsoft.VSCode": "Visual Studio Code",
                                  "com.work.pc.doubao": "豆包工作",
                                  "com.volcengine.corplink": "飞连"]
            let name = preferredNames[id] ?? bundleName
            let icon: NSImage
            if let cached = iconCache[url.path] {
                icon = cached
            } else {
                icon = NSWorkspace.shared.icon(forFile: url.path)
                _ = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
                iconCache[url.path] = icon
            }
            return AppEntry(id: id, name: name, url: url, icon: icon)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let order = defaults.stringArray(forKey: "appOrder") ?? []
        let positions = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        apps.sort {
            let a = positions[$0.url.path] ?? Int.max
            let b = positions[$1.url.path] ?? Int.max
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
        }
        loadLayout()
        filtered = apps
        renderRevision += 1
        cachedPageHosts.removeAll()
        lastGridSignature = ""
        render()
    }

    var layoutURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenLaunchpad/layout.json")
    }
    func loadLayout() {
        if let data = try? Data(contentsOf: layoutURL),
           let model = try? JSONDecoder().decode(LaunchLayout.self, from: data) {
            layoutModel = model
        } else {
            if FileManager.default.fileExists(atPath: layoutURL.path) {
                let backup = layoutURL.deletingLastPathComponent().appendingPathComponent("layout-unreadable-\(UUID().uuidString).json")
                do { try FileManager.default.copyItem(at: layoutURL, to: backup) }
                catch { NSLog("Cannot preserve unreadable layout: %@", error.localizedDescription); return }
            }
            let pageSize = 35
            let nodes = apps.map { LaunchNode(kind: "app", id: $0.id, name: "", children: []) }
            layoutModel.pages = stride(from: 0, to: nodes.count, by: pageSize).map {
                Array(nodes[$0..<min($0+pageSize, nodes.count)])
            }
            layoutModel.knownIDs = apps.map(\.id)
            saveLayout()
        }
        let available = Set(apps.map(\.id))
        var removedMissingApps = false
        for pageIndex in layoutModel.pages.indices {
            let oldCount = layoutModel.pages[pageIndex].count
            layoutModel.pages[pageIndex].removeAll { $0.kind == "app" && !available.contains($0.id) }
            removedMissingApps = removedMissingApps || oldCount != layoutModel.pages[pageIndex].count
            for nodeIndex in layoutModel.pages[pageIndex].indices {
                guard layoutModel.pages[pageIndex][nodeIndex].kind == "group" else { continue }
                let oldChildren = layoutModel.pages[pageIndex][nodeIndex].children.count
                layoutModel.pages[pageIndex][nodeIndex].children.removeAll { !available.contains($0.id) }
                removedMissingApps = removedMissingApps || oldChildren != layoutModel.pages[pageIndex][nodeIndex].children.count
            }
        }
        if removedMissingApps {
            layoutModel.knownIDs.removeAll { !available.contains($0) }
            saveLayout()
        }
        let beforeNormalization = layoutModel
        let capacity = max(3, defaults.integer(forKey: "columns") == 0 ? 7 : defaults.integer(forKey: "columns"))
            * max(2, defaults.integer(forKey: "rows") == 0 ? 5 : defaults.integer(forKey: "rows"))
        normalizeLayout(&layoutModel, capacity: capacity)
        let represented = layoutModel.pages.flatMap { $0 }.flatMap { $0.kind == "group" ? $0.children.map(\.id) : [$0.id] }
        layoutModel.knownIDs = Array(Set(layoutModel.knownIDs + represented)).sorted()
        if beforeNormalization != layoutModel { saveLayout() }
        let known = Set(layoutModel.knownIDs)
        let hidden = Set(layoutModel.hiddenIDs)
        let additions = apps.filter { !known.contains($0.id) && !hidden.contains($0.id) }
        if !additions.isEmpty {
            if layoutModel.pages.isEmpty { layoutModel.pages = [[]] }
            let capacity = max(3, defaults.integer(forKey: "columns") == 0 ? 7 : defaults.integer(forKey: "columns"))
                * max(2, defaults.integer(forKey: "rows") == 0 ? 5 : defaults.integer(forKey: "rows"))
            for app in additions {
                let category = Bundle(url: app.url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
                if category == "public.app-category.games",
                   let groupPage = layoutModel.pages.firstIndex(where: { $0.contains(where: { $0.kind == "group" && $0.name == "游戏" }) }),
                   let groupIndex = layoutModel.pages[groupPage].firstIndex(where: { $0.kind == "group" && $0.name == "游戏" }) {
                    layoutModel.pages[groupPage][groupIndex].children.append(LaunchNode(kind: "app", id: app.id, name: "", children: []))
                    layoutModel.knownIDs.append(app.id)
                    continue
                }
                if layoutModel.pages[layoutModel.pages.count-1].count >= capacity { layoutModel.pages.append([]) }
                layoutModel.pages[layoutModel.pages.count-1].append(LaunchNode(kind: "app", id: app.id, name: "", children: []))
                layoutModel.knownIDs.append(app.id)
            }
            saveLayout()
        }
    }
    func saveLayout() {
        let capacity = max(3, defaults.integer(forKey: "columns") == 0 ? 7 : defaults.integer(forKey: "columns"))
            * max(2, defaults.integer(forKey: "rows") == 0 ? 5 : defaults.integer(forKey: "rows"))
        normalizeLayout(&layoutModel, capacity: capacity)
        guard let data = try? JSONEncoder().encode(layoutModel) else { return }
        do {
            try FileManager.default.createDirectory(at: layoutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: layoutURL, options: .atomic)
        } catch {
            NSLog("Cannot save Launchpad layout: %@", error.localizedDescription)
        }
        renderRevision += 1
        cachedPageHosts.removeAll()
        lastGridSignature = ""
    }
    func reflow() {
        let capacity = max(3, defaults.integer(forKey: "columns") == 0 ? 7 : defaults.integer(forKey: "columns"))
            * max(2, defaults.integer(forKey: "rows") == 0 ? 5 : defaults.integer(forKey: "rows"))
        let nodes = layoutModel.pages.flatMap { $0 }
        layoutModel.pages = stride(from: 0, to: nodes.count, by: capacity).map {
            Array(nodes[$0..<min($0+capacity, nodes.count)])
        }
        if layoutModel.pages.isEmpty { layoutModel.pages = [[]] }
        page = 0
        saveLayout()
        render()
    }

    func controlTextDidChange(_ obj: Notification) {
        cancelPageTransition()
        cancelDrag(renderAfter: false)
        let q = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleIDs = Set(layoutModel.pages.flatMap { $0 }.flatMap { node in
            node.kind == "group" ? node.children.map(\.id) : [node.id]
        })
        filtered = q.isEmpty ? apps : apps.filter { visibleIDs.contains($0.id) && $0.name.localizedStandardContains(q) }
        activeGroupID = nil
        underlyingPage = 0
        page = 0
        render()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), !search.stringValue.isEmpty {
            if let first = filtered.first { NSWorkspace.shared.open(first.url); onHide?() }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            escape()
            return true
        }
        return false
    }
    func escape() {
        cancelPageTransition()
        if draggedTile != nil {
            cancelDrag()
        } else if editMode {
            setEditMode(false)
        } else if !search.stringValue.isEmpty {
            search.stringValue = ""
            filtered = apps
            page = 0
            render()
        } else if activeGroupID != nil {
            closeGroup()
        } else {
            onHide?()
        }
    }

    override func layout() {
        super.layout()
        let searchWidth = min(280, bounds.width * 0.42)
        searchBackdrop.frame = NSRect(x: (bounds.width - searchWidth)/2,
                                      y: bounds.height - 80, width: searchWidth, height: 30)
        searchBackdrop.layer?.cornerRadius = 15
        searchGlyph.frame = NSRect(x: searchBackdrop.frame.minX + 12,
                                    y: searchBackdrop.frame.minY + 8.5,
                                    width: 13, height: 13)
        search.frame = NSRect(x: searchBackdrop.frame.minX + 31,
                              y: searchBackdrop.frame.minY + 6.5,
                              width: searchWidth - 65, height: 17)
        searchMoreButton.frame = NSRect(x: searchBackdrop.frame.maxX - 30,
                                        y: searchBackdrop.frame.minY + 5,
                                        width: 20, height: 20)
        backButton.frame = NSRect(x: bounds.width * 0.105, y: bounds.height - 58, width: 100, height: 34)
        grid.frame = NSRect(x: 0, y: 71, width: bounds.width, height: bounds.height - 145)
        dots.frame = NSRect(x: (bounds.width - 200)/2, y: 27, width: 200, height: 20)
        folderBackdrop.frame = bounds
        render()
    }

    func folderDimensions(for count: Int) -> (columns: Int, rows: Int) {
        let columns = min(5, max(2, count))
        return (columns, min(5, max(1, Int(ceil(Double(count) / Double(columns))))))
    }

    func layoutFolder(for count: Int) {
        let dimensions = folderDimensions(for: count)
        let width = min(bounds.width * 0.8, max(420, CGFloat(dimensions.columns) * 170 + 70))
        let height = min(bounds.height * 0.72, max(300, CGFloat(dimensions.rows) * 190 + 115))
        folderPanel.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                                   width: width, height: height)
        folderTitle.frame = NSRect(x: 30, y: height - 62, width: width - 60, height: 36)
        folderGrid.frame = NSRect(x: 35, y: 28, width: width - 70, height: height - 105)
    }

    func render(animatedFrom previousPage: Int? = nil) {
        guard grid.bounds.width > 0 else { return }
        if grid.bounds.size != cachedGridSize {
            cachedGridSize = grid.bounds.size
            cachedPageHosts.removeAll()
            lastGridSignature = ""
        }
        dots.subviews.forEach { $0.removeFromSuperview() }
        folderGrid.subviews.forEach { $0.removeFromSuperview() }
        let columns = max(3, defaults.integer(forKey: "columns") == 0 ? 7 : defaults.integer(forKey: "columns"))
        let rows = max(2, defaults.integer(forKey: "rows") == 0 ? 5 : defaults.integer(forKey: "rows"))
        let perPage = columns * rows
        let searching = !search.stringValue.isEmpty
        let group = layoutModel.pages.flatMap { $0 }.first { $0.id == activeGroupID }
        if let group { layoutFolder(for: group.children.count) }
        backButton.isHidden = group == nil
        folderBackdrop.isHidden = group == nil
        folderPanel.isHidden = group == nil
        folderTitle.stringValue = group?.name ?? ""
        let nodes: [LaunchNode] = searching
            ? filtered.map { LaunchNode(kind: "app", id: $0.id, name: "", children: []) }
            : (group?.children ?? [])
        let folderPageSize = group.map { value -> Int in
            let dimensions = folderDimensions(for: value.children.count)
            return dimensions.columns * dimensions.rows
        } ?? perPage
        let pages = searching
            ? max(1, Int(ceil(Double(nodes.count) / Double(perPage))))
            : (group != nil
                ? max(1, Int(ceil(Double(nodes.count) / Double(folderPageSize))))
                : max(1, layoutModel.pages.count))
        page = min(max(0, page), pages - 1)
        let basePage = group == nil ? page : underlyingPage
        let displayNodes = searching
            ? Array(nodes.dropFirst(page * perPage).prefix(perPage))
            : (basePage < layoutModel.pages.count ? layoutModel.pages[basePage] : [])
        let appByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let signature = "\(renderRevision)|\(page)|\(underlyingPage)|\(activeGroupID ?? "")|\(search.stringValue)|\(grid.bounds.width)x\(grid.bounds.height)|\(columns)x\(rows)"
        if signature != lastGridSignature {
            let host: NSView
            if !searching && group == nil, let cached = cachedPageHosts[page] {
                host = cached
                if host !== currentGridHost { normalizeGridHost(host, pageIndex: page, columns: columns, rows: rows) }
            } else {
                host = makeGridHost(nodes: displayNodes, columns: columns, rows: rows, appByID: appByID)
                if !searching && group == nil { cachedPageHosts[page] = host }
            }
            let oldHost = currentGridHost
            grid.subviews.filter { $0 !== oldHost && $0 !== host }.forEach { $0.removeFromSuperview() }
            let shouldAnimate = previousPage != nil && previousPage != page && group == nil && !searching && oldHost != nil
            if shouldAnimate, let oldHost, let previousPage {
                let direction: CGFloat = page > previousPage ? 1 : -1
                let width = grid.bounds.width
                host.removeFromSuperview()
                host.frame = grid.bounds
                grid.addSubview(host)
                host.layoutSubtreeIfNeeded()
                setPageOffset(direction * width, for: host)
                currentGridHost = host
                isSettlingSwipe = true
                let revision = transitionRevision
                CATransaction.begin()
                CATransaction.setCompletionBlock {
                    guard self.transitionRevision == revision else { return }
                    if self.currentGridHost !== oldHost { oldHost.removeFromSuperview() }
                    oldHost.layer?.removeAnimation(forKey: "pageSlide")
                    self.setPageOffset(0, for: oldHost)
                    self.isSettlingSwipe = false
                }
                animatePageOffset(-direction * width, for: oldHost, duration: 0.24)
                animatePageOffset(0, for: host, duration: 0.24)
                CATransaction.commit()
            } else {
                grid.subviews.filter { $0 !== host }.forEach { $0.removeFromSuperview() }
                host.frame = grid.bounds
                if host.superview !== grid { grid.addSubview(host) }
                if host.layer?.animation(forKey: "pageSlide") == nil { setPageOffset(0, for: host) }
                currentGridHost = host
            }
            lastGridSignature = signature
        }
        if let group {
            let dimensions = folderDimensions(for: group.children.count)
            let folderCellW = folderGrid.bounds.width / CGFloat(dimensions.columns)
            let folderCellH = folderGrid.bounds.height / CGFloat(dimensions.rows)
            let children = Array(group.children.dropFirst(page * folderPageSize).prefix(folderPageSize))
            for (index, child) in children.enumerated() {
                guard let entry = appByID[child.id] else { continue }
                let row = index / dimensions.columns, col = index % dimensions.columns
                let tile = AppTile(entry: entry)
                tile.frame = NSRect(x: CGFloat(col) * folderCellW,
                                    y: folderGrid.bounds.height - CGFloat(row + 1) * folderCellH,
                                    width: folderCellW, height: folderCellH)
                tile.onOpen = { [weak self] in NSWorkspace.shared.open(entry.url); self?.onHide?() }
                tile.onDrag = { [weak self] tile, point in self?.updateDrag(tile, node: child, at: point) }
                tile.onDrop = { [weak self] point in self?.finishDrag(child, at: point) }
                tile.onLongPress = { [weak self] in self?.setEditMode(true) }
                if FileManager.default.fileExists(atPath: entry.url.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
                    tile.onDelete = { [weak self] in self?.deleteApp(entry) }
                }
                tile.setEditing(editMode)
                folderGrid.addSubview(tile)
            }
        }
        let dotSpacing: CGFloat = 18
        let start = (dots.bounds.width - CGFloat(pages - 1) * dotSpacing) / 2
        for p in 0..<pages {
            let dot = NSButton(frame: NSRect(x: start + CGFloat(p) * dotSpacing - 9, y: 1, width: 18, height: 18))
            dot.isBordered = false
            dot.title = ""
            dot.tag = p
            dot.target = self
            dot.action = #selector(selectPage(_:))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.clear.cgColor
            let visibleSize: CGFloat = p == page ? 7 : 6
            let marker = CALayer()
            marker.frame = NSRect(x: (18 - visibleSize) / 2, y: (18 - visibleSize) / 2,
                                  width: visibleSize, height: visibleSize)
            marker.cornerRadius = visibleSize / 2
            marker.backgroundColor = (p == page ? NSColor.white : NSColor.white.withAlphaComponent(0.42)).cgColor
            dot.layer?.addSublayer(marker)
            dots.addSubview(dot)
        }
    }

    private func makeGridHost(nodes: [LaunchNode], columns: Int, rows: Int, appByID: [String: AppEntry]) -> NSView {
        let host = NSView(frame: grid.bounds)
        host.wantsLayer = true
        let contentX = grid.bounds.width * 0.105
        let cellW = grid.bounds.width * 0.79 / CGFloat(columns)
        let cellH = grid.bounds.height / CGFloat(rows)
        for (index, node) in nodes.enumerated() {
            let row = index / columns, col = index % columns
            let frame = NSRect(x: contentX + CGFloat(col) * cellW, y: grid.bounds.height - CGFloat(row + 1) * cellH, width: cellW, height: cellH)
            if node.kind == "group" {
                let tile = GroupTile(node: node, appByID: appByID)
                tile.identifier = NSUserInterfaceItemIdentifier(node.id)
                tile.frame = frame
                tile.onOpen = { [weak self] in
                    guard let self else { return }
                    self.cancelPageTransition()
                    self.underlyingPage = self.page
                    self.activeGroupID = node.id
                    self.page = 0
                    self.render()
                }
                tile.onRename = { [weak self] in self?.renameGroup(node.id) }
                tile.onUngroup = { [weak self] in self?.ungroup(node.id) }
                host.addSubview(tile)
            } else if let entry = appByID[node.id] {
                let tile = AppTile(entry: entry)
                tile.identifier = NSUserInterfaceItemIdentifier(node.id)
                tile.frame = frame
                tile.onOpen = { [weak self] in
                    NSWorkspace.shared.open(entry.url)
                    self?.onHide?()
                }
                tile.onDrag = { [weak self] tile, point in self?.updateDrag(tile, node: node, at: point) }
                tile.onDrop = { [weak self] point in self?.finishDrag(node, at: point) }
                tile.onLongPress = { [weak self] in self?.setEditMode(true) }
                if FileManager.default.fileExists(atPath: entry.url.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
                    tile.onDelete = { [weak self] in self?.deleteApp(entry) }
                }
                tile.setEditing(editMode)
                host.addSubview(tile)
            }
        }
        return host
    }
    func changePage(to target: Int) {
        guard !isSettlingSwipe, swipeDirection == 0 else { return }
        let oldPage = page
        page = max(0, target)
        render(animatedFrom: oldPage)
    }
    func prewarmPages() {
        guard grid.bounds.width > 0, search.stringValue.isEmpty, activeGroupID == nil else { return }
        let columns = max(3, defaults.integer(forKey: "columns") == 0 ? 7 : defaults.integer(forKey: "columns"))
        let rows = max(2, defaults.integer(forKey: "rows") == 0 ? 5 : defaults.integer(forKey: "rows"))
        let appByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        for index in layoutModel.pages.indices where cachedPageHosts[index] == nil {
            cachedPageHosts[index] = makeGridHost(nodes: layoutModel.pages[index], columns: columns, rows: rows, appByID: appByID)
        }
    }
    func setEditMode(_ enabled: Bool) {
        guard editMode != enabled else { return }
        editMode = enabled
        for host in Array(cachedPageHosts.values) + [currentGridHost].compactMap({ $0 }) {
            for case let tile as AppTile in host.subviews { tile.setEditing(enabled) }
        }
        for case let tile as AppTile in folderGrid.subviews { tile.setEditing(enabled) }
    }
    private func deleteApp(_ entry: AppEntry) {
        let alert = NSAlert()
        alert.messageText = "将“\(entry.name)”移到废纸篓？"
        alert.informativeText = "此操作会从“应用程序”中移走该应用。你可以在废纸篓中恢复。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([entry.url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    let failure = NSAlert(error: error)
                    failure.runModal()
                    return
                }
                for pageIndex in self.layoutModel.pages.indices {
                    self.layoutModel.pages[pageIndex].removeAll { $0.id == entry.id }
                    for nodeIndex in self.layoutModel.pages[pageIndex].indices {
                        self.layoutModel.pages[pageIndex][nodeIndex].children.removeAll { $0.id == entry.id }
                    }
                    for nodeIndex in self.layoutModel.pages[pageIndex].indices.reversed()
                    where self.layoutModel.pages[pageIndex][nodeIndex].kind == "group" {
                        let children = self.layoutModel.pages[pageIndex][nodeIndex].children
                        if children.count == 1 { self.layoutModel.pages[pageIndex][nodeIndex] = children[0] }
                        else if children.isEmpty { self.layoutModel.pages[pageIndex].remove(at: nodeIndex) }
                    }
                }
                self.layoutModel.knownIDs.removeAll { $0 == entry.id }
                self.saveLayout()
                self.loadApps()
                self.prewarmPages()
            }
        }
    }
    @objc func selectPage(_ sender: NSButton) { changePage(to: sender.tag) }
    func renameGroup(_ id: String) {
        guard let pageIndex = layoutModel.pages.firstIndex(where: { $0.contains(where: { $0.id == id }) }),
              let index = layoutModel.pages[pageIndex].firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "重命名文件夹"
        let field = NSTextField(string: layoutModel.pages[pageIndex][index].name)
        field.frame = NSRect(x: 0, y: 0, width: 250, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { layoutModel.pages[pageIndex][index].name = name; saveLayout(); render() }
        }
    }
    func ungroup(_ id: String) {
        guard let pageIndex = layoutModel.pages.firstIndex(where: { $0.contains(where: { $0.id == id }) }),
              let index = layoutModel.pages[pageIndex].firstIndex(where: { $0.id == id }) else { return }
        let children = layoutModel.pages[pageIndex].remove(at: index).children
        layoutModel.pages[pageIndex].insert(contentsOf: children, at: index)
        reflow()
    }
    private func updateDrag(_ tile: AppTile, node: LaunchNode, at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        if draggedTile == nil {
            let tileFrame = convert(tile.bounds, from: tile)
            dragPointerOffset = NSPoint(x: point.x - tileFrame.minX, y: point.y - tileFrame.minY)
            let preview = DragPreviewTile(entry: tile.entry)
            preview.frame = tileFrame
            preview.alphaValue = 0.92
            tile.alphaValue = 0
            addSubview(preview, positioned: .above, relativeTo: nil)
            draggedTile = preview
            dragSourceTile = tile
            draggedNode = node
            dragEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self, weak tile] event in
                guard let self, let tile, self.dragSourceTile === tile, event.window === self.window else { return event }
                if event.type == .leftMouseUp { self.finishDrag(node, at: event.locationInWindow) }
                else { self.updateDrag(tile, node: node, at: event.locationInWindow) }
                return nil
            }
        }
        guard dragSourceTile === tile, let draggedTile else { return }
        draggedTile.frame.origin = NSPoint(x: point.x - dragPointerOffset.x, y: point.y - dragPointerOffset.y)
        if activeGroupID != nil { return }
        let local = grid.convert(windowPoint, from: nil)
        let inset = grid.bounds.width * 0.105
        let edge = local.x < inset ? -1 : (local.x > grid.bounds.width - inset ? 1 : 0)
        if edge != dragEdge {
            clearDragFolderTarget()
            dragEdgeTimer?.invalidate()
            dragEdge = edge
            if edge != 0, layoutModel.pages.indices.contains(page + edge) {
                let timer = Timer(timeInterval: 0.55, repeats: false) { [weak self] _ in
                    guard let self, self.draggedTile != nil, self.dragEdge == edge else { return }
                    self.dragHoverIndex = -1
                    self.changePage(to: self.page + edge)
                }
                dragEdgeTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        guard edge == 0, activeGroupID == nil, !isSettlingSwipe,
              grid.bounds.contains(local), let host = currentGridHost,
              layoutModel.pages.indices.contains(page) else { return }
        let columns = max(3, defaults.integer(forKey: "columns") == 0 ? 7 : defaults.integer(forKey: "columns"))
        let rows = max(2, defaults.integer(forKey: "rows") == 0 ? 5 : defaults.integer(forKey: "rows"))
        let cellW = grid.bounds.width * 0.79 / CGFloat(columns)
        let cellH = grid.bounds.height / CGFloat(rows)
        let col = min(columns - 1, max(0, Int((local.x - inset) / cellW)))
        let row = min(rows - 1, max(0, Int((grid.bounds.height - local.y) / cellH)))
        let nodes = layoutModel.pages[page].filter { $0.id != node.id }
        let target = min(nodes.count, row * columns + col)
        let centerX = inset + (CGFloat(col) + 0.5) * cellW
        let centerY = grid.bounds.height - (CGFloat(row) + 0.5) * cellH
        let originalNodes = layoutModel.pages[page]
        let slot = row * columns + col
        let folderTargetID = originalNodes.indices.contains(slot) && originalNodes[slot].id != node.id ? originalNodes[slot].id : nil
        let folderTarget = hypot(local.x - centerX, local.y - centerY) < min(cellW, cellH) * 0.18 && folderTargetID != nil
            ? host.subviews.first(where: { $0.identifier?.rawValue == folderTargetID })
            : nil
        let candidateID = folderTarget == nil ? nil : folderTargetID
        if candidateID != dragFolderCandidateID {
            clearDragFolderTarget()
            if let folderTarget, let folderTargetID {
                dragFolderCandidateID = folderTargetID
                let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self, weak folderTarget] _ in
                    guard let self, self.draggedTile != nil,
                          self.dragFolderCandidateID == folderTargetID,
                          let folderTarget else { return }
                    self.dragFolderArmedID = folderTargetID
                    self.dragFolderTarget = folderTarget
                    folderTarget.wantsLayer = true
                    folderTarget.layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
                    folderTarget.layer?.borderWidth = 2
                    folderTarget.layer?.cornerRadius = 18
                }
                dragFolderHoverTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        if folderTarget != nil {
            if dragHoverIndex >= 0 {
                dragHoverIndex = -1
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    for child in host.subviews {
                        guard let id = child.identifier?.rawValue,
                              let index = layoutModel.pages[page].firstIndex(where: { $0.id == id }) else { continue }
                        child.animator().frame = NSRect(x: inset + CGFloat(index % columns) * cellW,
                                                        y: grid.bounds.height - CGFloat(index / columns + 1) * cellH,
                                                        width: cellW, height: cellH)
                    }
                }
            }
            return
        }
        guard target != dragHoverIndex else { return }
        dragHoverIndex = target
        var order = nodes.map(\.id)
        order.insert(node.id, at: target)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for child in host.subviews {
                guard let id = child.identifier?.rawValue, let index = order.firstIndex(of: id) else { continue }
                let targetFrame = NSRect(x: inset + CGFloat(index % columns) * cellW,
                                         y: grid.bounds.height - CGFloat(index / columns + 1) * cellH,
                                         width: cellW, height: cellH)
                child.animator().frame = targetFrame
            }
        }
    }
    private func clearDragFolderTarget() {
        dragFolderHoverTimer?.invalidate()
        dragFolderHoverTimer = nil
        dragFolderCandidateID = nil
        dragFolderArmedID = nil
        dragFolderTarget?.layer?.borderWidth = 0
        dragFolderTarget = nil
    }
    func cancelDrag(renderAfter: Bool = true) {
        guard draggedTile != nil else { return }
        if let dragEventMonitor { NSEvent.removeMonitor(dragEventMonitor) }
        dragEventMonitor = nil
        clearDragFolderTarget()
        dragEdgeTimer?.invalidate()
        dragEdgeTimer = nil
        dragEdge = 0
        dragHoverIndex = -1
        draggedTile?.removeFromSuperview()
        draggedTile = nil
        dragSourceTile?.alphaValue = 1
        dragSourceTile = nil
        draggedNode = nil
        cachedPageHosts.removeAll()
        lastGridSignature = ""
        if renderAfter { render() }
    }
    private func finishDrag(_ node: LaunchNode, at point: NSPoint) {
        let armedFolderTargetID = dragFolderArmedID
        cancelDrag(renderAfter: false)
        move(node, toWindowPoint: point, armedFolderTargetID: armedFolderTargetID)
        render()
    }
    func move(_ node: LaunchNode, toWindowPoint point: NSPoint, armedFolderTargetID: String? = nil) {
        guard search.stringValue.isEmpty else { return }
        let local = grid.convert(point, from: nil)
        let contentX = grid.bounds.width * 0.105
        let contentWidth = grid.bounds.width * 0.79
        let columns = max(3, defaults.integer(forKey: "columns") == 0 ? 7 : defaults.integer(forKey: "columns"))
        let rows = max(2, defaults.integer(forKey: "rows") == 0 ? 5 : defaults.integer(forKey: "rows"))
        if let activeGroupID,
           let groupPage = layoutModel.pages.firstIndex(where: { $0.contains(where: { $0.id == activeGroupID }) }),
           let groupIndex = layoutModel.pages[groupPage].firstIndex(where: { $0.id == activeGroupID }),
           let childIndex = layoutModel.pages[groupPage][groupIndex].children.firstIndex(where: { $0.id == node.id }) {
            let moved = layoutModel.pages[groupPage][groupIndex].children.remove(at: childIndex)
            let folderLocal = folderGrid.convert(point, from: nil)
            if folderGrid.bounds.contains(folderLocal) {
                let dimensions = folderDimensions(for: layoutModel.pages[groupPage][groupIndex].children.count + 1)
                let col = min(dimensions.columns-1, max(0, Int(folderLocal.x / (folderGrid.bounds.width / CGFloat(dimensions.columns)))))
                let row = min(dimensions.rows-1, max(0, Int((folderGrid.bounds.height-folderLocal.y) / (folderGrid.bounds.height / CGFloat(dimensions.rows)))))
                let index = min(layoutModel.pages[groupPage][groupIndex].children.count,
                                page * dimensions.columns * dimensions.rows + row*dimensions.columns+col)
                layoutModel.pages[groupPage][groupIndex].children.insert(moved, at: index)
            } else {
                layoutModel.pages[groupPage].insert(moved, at: groupIndex+1)
                if layoutModel.pages[groupPage][groupIndex].children.count == 1 {
                    let remaining = layoutModel.pages[groupPage].remove(at: groupIndex).children[0]
                    layoutModel.pages[groupPage].insert(remaining, at: groupIndex)
                }
                self.activeGroupID = nil
                page = underlyingPage
            }
            saveLayout()
            render()
            return
        }
        if local.x < contentX || local.x > contentX + contentWidth {
            guard let sourcePage = layoutModel.pages.firstIndex(where: { $0.contains(where: { $0.id == node.id }) }),
                  let sourceIndex = layoutModel.pages[sourcePage].firstIndex(where: { $0.id == node.id }) else { return }
            let destinationPage = sourcePage == page ? (local.x < contentX ? page - 1 : page + 1) : page
            guard destinationPage >= 0, destinationPage <= layoutModel.pages.count else { return }
            let moved = layoutModel.pages[sourcePage].remove(at: sourceIndex)
            if destinationPage == layoutModel.pages.count { layoutModel.pages.append([]) }
            layoutModel.pages[destinationPage].append(moved)
            page = destinationPage
            saveLayout()
            render()
            return
        }
        guard local.y >= 0, local.y <= grid.bounds.height else { return }
        let col = min(columns - 1, max(0, Int((local.x - contentX) / (contentWidth / CGFloat(columns)))))
        let row = min(rows - 1, max(0, Int((grid.bounds.height - local.y) / (grid.bounds.height / CGFloat(rows)))))
        let cellW = contentWidth / CGFloat(columns)
        let cellH = grid.bounds.height / CGFloat(rows)
        guard page < layoutModel.pages.count else { return }
        let destination = min(layoutModel.pages[page].count, row * columns + col)
        guard let sourcePage = layoutModel.pages.firstIndex(where: { $0.contains(where: { $0.id == node.id }) }),
              let sourceIndex = layoutModel.pages[sourcePage].firstIndex(where: { $0.id == node.id }) else { return }
        let moved = layoutModel.pages[sourcePage].remove(at: sourceIndex)
        var targetIndex = destination
        targetIndex = min(targetIndex, layoutModel.pages[page].count)
        let cellX = contentX + (CGFloat(col) + 0.5) * cellW
        let cellY = grid.bounds.height - (CGFloat(row) + 0.5) * cellH
        let nearCenter = hypot(local.x-cellX, local.y-cellY) < min(cellW,cellH) * 0.18
        if nearCenter, let armedFolderTargetID,
           let folderIndex = layoutModel.pages[page].firstIndex(where: { $0.id == armedFolderTargetID }) {
            if layoutModel.pages[page][folderIndex].kind == "group" {
                layoutModel.pages[page][folderIndex].children.append(moved)
            } else {
                let target = layoutModel.pages[page].remove(at: folderIndex)
                layoutModel.pages[page].insert(LaunchNode(kind: "group", id: UUID().uuidString, name: "文件夹", children: [target, moved]), at: folderIndex)
            }
        } else {
            layoutModel.pages[page].insert(moved, at: targetIndex)
        }
        saveLayout()
        render()
    }
    override func scrollWheel(with event: NSEvent) {
        guard draggedTile == nil else { return }
        if event.momentumPhase != [] { return }
        if event.hasPreciseScrollingDeltas && event.phase != [] && activeGroupID == nil && search.stringValue.isEmpty {
            handleTrackpadSwipe(event)
            return
        }
        if event.phase == .began {
            scrollAccumulation = 0
            changedPageInGesture = false
        }
        if event.phase == .ended || event.phase == .cancelled {
            scrollAccumulation = 0
            changedPageInGesture = false
            return
        }
        if changedPageInGesture && event.phase != [] { return }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaX
            : (abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY)
        scrollAccumulation += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 2
        guard abs(scrollAccumulation) > threshold, Date().timeIntervalSince(lastPageScroll) > 0.35 else { return }
        changePage(to: page + (delta < 0 ? 1 : -1))
        changedPageInGesture = event.phase != []
        scrollAccumulation = 0
        lastPageScroll = Date()
    }
    private func handleTrackpadSwipe(_ event: NSEvent) {
        guard !isSettlingSwipe, let currentGridHost, grid.bounds.width > 0 else { return }
        if event.phase == .began {
            swipeOffset = 0
            swipeDirection = 0
        }
        if event.phase == .ended || event.phase == .cancelled {
            guard swipeDirection != 0, let swipeNeighbor else { return }
            let commit = event.phase == .ended && abs(swipeOffset) > min(100, grid.bounds.width * 0.12)
            let direction = swipeDirection
            let width = grid.bounds.width
            isSettlingSwipe = true
            let revision = transitionRevision
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                guard self.transitionRevision == revision else { return }
                if commit {
                    currentGridHost.removeFromSuperview()
                    currentGridHost.layer?.removeAnimation(forKey: "pageSlide")
                    self.setPageOffset(0, for: currentGridHost)
                    swipeNeighbor.layer?.removeAnimation(forKey: "pageSlide")
                    self.setPageOffset(0, for: swipeNeighbor)
                    self.page += direction
                    self.currentGridHost = swipeNeighbor
                } else {
                    swipeNeighbor.removeFromSuperview()
                    swipeNeighbor.layer?.removeAnimation(forKey: "pageSlide")
                    self.setPageOffset(0, for: swipeNeighbor)
                    currentGridHost.layer?.removeAnimation(forKey: "pageSlide")
                    self.setPageOffset(0, for: currentGridHost)
                }
                self.swipeDirection = 0
                self.swipeOffset = 0
                self.swipeNeighbor = nil
                self.isSettlingSwipe = false
                if commit {
                    self.lastGridSignature = ""
                    self.render()
                }
            }
            animatePageOffset(commit ? CGFloat(-direction) * width : 0, for: currentGridHost, duration: 0.18)
            animatePageOffset(commit ? 0 : CGFloat(direction) * width, for: swipeNeighbor, duration: 0.18)
            CATransaction.commit()
            return
        }
        let delta = event.scrollingDeltaX
        guard abs(delta) > 0.01 else { return }
        let candidate = delta < 0 ? 1 : -1
        if swipeDirection == 0 {
            guard layoutModel.pages.indices.contains(page + candidate) else { return }
            swipeDirection = candidate
            let neighborPage = page + candidate
            let columns = max(3, defaults.integer(forKey: "columns") == 0 ? 7 : defaults.integer(forKey: "columns"))
            let rows = max(2, defaults.integer(forKey: "rows") == 0 ? 5 : defaults.integer(forKey: "rows"))
            let appByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
            let neighbor = cachedPageHosts[neighborPage] ?? makeGridHost(nodes: layoutModel.pages[neighborPage], columns: columns, rows: rows, appByID: appByID)
            cachedPageHosts[neighborPage] = neighbor
            normalizeGridHost(neighbor, pageIndex: neighborPage, columns: columns, rows: rows)
            neighbor.removeFromSuperview()
            neighbor.frame = grid.bounds
            grid.addSubview(neighbor)
            neighbor.layoutSubtreeIfNeeded()
            setPageOffset(CGFloat(candidate) * grid.bounds.width, for: neighbor)
            swipeNeighbor = neighbor
        }
        guard let swipeNeighbor else { return }
        swipeOffset = min(grid.bounds.width, max(-grid.bounds.width, swipeOffset + delta))
        swipeOffset = swipeDirection == 1 ? min(0, swipeOffset) : max(0, swipeOffset)
        setPageOffset(swipeOffset, for: currentGridHost)
        setPageOffset(swipeOffset + CGFloat(swipeDirection) * grid.bounds.width, for: swipeNeighbor)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            if activeGroupID != nil { activeGroupID = nil; page = 0; render() }
            else { onHide?() }
        case 123: changePage(to: page - 1)
        case 124: changePage(to: page + 1)
        default: super.keyDown(with: event)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if activeGroupID != nil {
            menu.addItem(withTitle: "返回", action: #selector(closeGroup), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func mouseDown(with event: NSEvent) {
        if editMode { setEditMode(false) }
        else if activeGroupID != nil { closeGroup() }
        else { onHide?() }
    }
    @objc func openSettings() { onSettings?() }
    @objc private func showSearchOptions(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关闭启动台", action: #selector(hideFromSearchMenu), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: sender.frame.minX, y: sender.frame.minY), in: self)
    }
    @objc private func hideFromSearchMenu() { onHide?() }
    @objc func closeGroup() { activeGroupID = nil; page = underlyingPage; render() }
    override var acceptsFirstResponder: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: LaunchpadView!
    var settingsWindow: NSWindow?
    var appearanceSlider: NSSlider?
    var blurSlider: NSSlider?
    var columnsSlider: NSSlider?
    var rowsSlider: NSSlider?
    var statusItem: NSStatusItem?
    var hotKeyRef: EventHotKeyRef?
    var keyMonitor: Any?
    var scrollMonitor: Any?
    var flagsMonitor: Any?
    private var applicationWatchers: [any DispatchSourceFileSystemObject] = []
    private var applicationRefreshWorkItem: DispatchWorkItem?
    var hotCornerTimer: Timer?
    var appRefreshTimer: Timer?
    var hotCornerWasInside = false
    var hotCornerPicker: NSPopUpButton?
    let wallpaper = NSImageView()
    let tint = NSView()
    private var wallpaperCache: [String: NSImage] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        activeDelegate = self
        NSApp.setActivationPolicy(.accessory)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = LaunchpadWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.autoresizingMask = [.width, .height]
        wallpaper.frame = content.bounds
        wallpaper.autoresizingMask = [.width, .height]
        wallpaper.imageScaling = .scaleAxesIndependently
        wallpaper.image = blurredWallpaper(for: screen)
        content.addSubview(wallpaper)
        tint.frame = content.bounds
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        content.addSubview(tint)
        updateTint()
        view = LaunchpadView(frame: content.bounds)
        view.autoresizingMask = [.width, .height]
        view.onHide = { [weak self] in self?.hide() }
        view.onSettings = { [weak self] in self?.showSettings() }
        (window as? LaunchpadWindow)?.onEscape = { [weak self] in self?.view.escape() }
        content.addSubview(view)
        window.contentView = content
        if !CommandLine.arguments.contains("--background") { show() }
        DispatchQueue.main.async { [weak self] in self?.view.prewarmPages() }
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
        let root = NSMenuItem(); root.submenu = appMenu; menu.addItem(root)
        NSApp.mainMenu = menu
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "打开启动台")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "显示启动台", action: #selector(showFromMenu), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出 OpenLaunchpad", action: #selector(quit), keyEquivalent: "").target = self
        status.menu = statusMenu
        statusItem = status
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), shortcutHandler, 1, &eventType, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4F4C5044, id: 1), GetApplicationEventTarget(), 0, &hotKeyRef)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow === self.window else { return event }
            if (event.keyCode == 123 || event.keyCode == 124),
               event.modifierFlags.contains(.command) || self.view.search.stringValue.isEmpty {
                self.view.changePage(to: self.view.page + (event.keyCode == 124 ? 1 : -1))
                return nil
            }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.view.scrollWheel(with: event)
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let self, NSApp.keyWindow === self.window, event.modifierFlags.contains(.option) {
                self.view.setEditMode(true)
            }
            return event
        }
        hotCornerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkHotCorner()
        }
        appRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, !self.window.isVisible else { return }
            self.view.loadApps()
            self.view.prewarmPages()
        }
        watchApplicationFolders()
    }
    private func watchApplicationFolders() {
        let roots = ["/Applications", "/System/Applications",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for path in roots {
            let descriptor = Darwin.open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            watcher.setEventHandler { [weak self] in
                guard let self else { return }
                self.applicationRefreshWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.window.isVisible else { return }
                    self.view.loadApps()
                    self.view.prewarmPages()
                }
                self.applicationRefreshWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
            watcher.setCancelHandler { Darwin.close(descriptor) }
            watcher.resume()
            applicationWatchers.append(watcher)
        }
    }
    func checkHotCorner() {
        let choice = UserDefaults.standard.integer(forKey: "hotCorner")
        guard choice > 0, !window.isVisible else { hotCornerWasInside = false; return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let frame = screen.frame
        let tolerance: CGFloat = 4
        let inside: Bool
        switch choice {
        case 1: inside = point.x <= frame.minX+tolerance && point.y >= frame.maxY-tolerance
        case 2: inside = point.x >= frame.maxX-tolerance && point.y >= frame.maxY-tolerance
        case 3: inside = point.x <= frame.minX+tolerance && point.y <= frame.minY+tolerance
        default: inside = point.x >= frame.maxX-tolerance && point.y <= frame.minY+tolerance
        }
        if inside && !hotCornerWasInside { show() }
        hotCornerWasInside = inside
    }
    func show() {
        view.cancelPageTransition()
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        wallpaper.image = blurredWallpaper(for: screen)
        view.cancelDrag()
        view.search.stringValue = ""
        view.setEditMode(false)
        view.activeGroupID = nil
        view.underlyingPage = 0
        view.page = 0
        view.render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view.search)
    }
    func hide() {
        view.cancelPageTransition()
        view.cancelDrag(renderAfter: false)
        window.orderOut(nil)
    }
    func toggle() { window.isVisible ? hide() : show() }
    @objc func showFromMenu() { show() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func blurredWallpaper(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let radius = UserDefaults.standard.object(forKey: "blurRadius") as? Double ?? 32.0
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let cacheKey = "\(url.path)|\(modified)|\(radius)|\(screen.frame.size.width)x\(screen.frame.size.height)"
        if let cached = wallpaperCache[cacheKey] { return cached }
        guard let source = CIImage(contentsOf: url),
              let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: source.extent) else { return nil }
        let image = NSImage(cgImage: cgImage, size: screen.frame.size)
        wallpaperCache.removeAll()
        wallpaperCache[cacheKey] = image
        return image
    }
    func updateTint() {
        let value = UserDefaults.standard.object(forKey: "darkTint") as? Double ?? 0.25
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(value).cgColor
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "OpenLaunchpad 设置"
            w.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
            w.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "背景暗色覆盖")
            label.frame = NSRect(x: 28, y: 440, width: 180, height: 24)
            w.contentView?.addSubview(label)
            let slider = NSSlider(value: UserDefaults.standard.object(forKey: "darkTint") as? Double ?? 0.25, minValue: 0, maxValue: 0.8, target: self, action: #selector(tintChanged(_:)))
            slider.frame = NSRect(x: 25, y: 405, width: 350, height: 30)
            w.contentView?.addSubview(slider)
            appearanceSlider = slider
            let blurLabel = NSTextField(labelWithString: "壁纸模糊强度")
            blurLabel.frame = NSRect(x: 28, y: 365, width: 180, height: 24)
            w.contentView?.addSubview(blurLabel)
            let blur = NSSlider(value: UserDefaults.standard.object(forKey: "blurRadius") as? Double ?? 32, minValue: 0, maxValue: 80, target: self, action: #selector(blurChanged(_:)))
            blur.frame = NSRect(x: 25, y: 330, width: 350, height: 30)
            w.contentView?.addSubview(blur)
            blurSlider = blur
            let columnsLabel = NSTextField(labelWithString: "每页列数")
            columnsLabel.frame = NSRect(x: 28, y: 295, width: 180, height: 24)
            w.contentView?.addSubview(columnsLabel)
            let columns = NSSlider(value: Double(UserDefaults.standard.integer(forKey: "columns") == 0 ? 7 : UserDefaults.standard.integer(forKey: "columns")), minValue: 3, maxValue: 10, target: self, action: #selector(gridChanged(_:)))
            columns.numberOfTickMarks = 8
            columns.allowsTickMarkValuesOnly = true
            columns.frame = NSRect(x: 25, y: 260, width: 350, height: 30)
            w.contentView?.addSubview(columns)
            columnsSlider = columns
            let rowsLabel = NSTextField(labelWithString: "每页行数")
            rowsLabel.frame = NSRect(x: 28, y: 225, width: 180, height: 24)
            w.contentView?.addSubview(rowsLabel)
            let rows = NSSlider(value: Double(UserDefaults.standard.integer(forKey: "rows") == 0 ? 5 : UserDefaults.standard.integer(forKey: "rows")), minValue: 2, maxValue: 7, target: self, action: #selector(gridChanged(_:)))
            rows.numberOfTickMarks = 6
            rows.allowsTickMarkValuesOnly = true
            rows.frame = NSRect(x: 25, y: 190, width: 350, height: 30)
            w.contentView?.addSubview(rows)
            rowsSlider = rows
            let cornerLabel = NSTextField(labelWithString: "唤出热角")
            cornerLabel.frame = NSRect(x: 28, y: 150, width: 180, height: 24)
            w.contentView?.addSubview(cornerLabel)
            let corner = NSPopUpButton(frame: NSRect(x: 25, y: 110, width: 350, height: 30), pullsDown: false)
            corner.addItems(withTitles: ["关闭", "左上", "右上", "左下", "右下"])
            corner.selectItem(at: UserDefaults.standard.integer(forKey: "hotCorner"))
            corner.target = self
            corner.action = #selector(hotCornerChanged(_:))
            w.contentView?.addSubview(corner)
            hotCornerPicker = corner
            let tip = NSTextField(wrappingLabelWithString: "背景取自当前系统壁纸，模糊后加半透明暗色层。调整后立即生效。")
            tip.frame = NSRect(x: 28, y: 36, width: 355, height: 55)
            w.contentView?.addSubview(tip)
            settingsWindow = w
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func tintChanged(_ sender: NSSlider) { UserDefaults.standard.set(sender.doubleValue, forKey: "darkTint"); updateTint() }
    @objc func blurChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "blurRadius")
        wallpaperCache.removeAll()
        if let screen = window.screen { wallpaper.image = blurredWallpaper(for: screen) }
    }
    @objc func gridChanged(_ sender: NSSlider) {
        if let columnsSlider { UserDefaults.standard.set(Int(columnsSlider.doubleValue), forKey: "columns") }
        if let rowsSlider { UserDefaults.standard.set(Int(rowsSlider.doubleValue), forKey: "rows") }
        view.reflow()
    }
    @objc func hotCornerChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "hotCorner")
        hotCornerWasInside = false
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
