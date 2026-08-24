import AppKit

// MARK: - 面板配置与事件

extension NotchPanelController {
    /// 接入每个屏幕面板对的交互事件（点击展开、Escape 收起等）。
    func wirePairEvents(_ pair: ScreenPanelPair) {
        pair.hotPanel.onMouseEvent = { [weak self, weak pair] event in
            guard let self, let pair else { return }
            guard event.type == .leftMouseDown else { return }
            // 块视图自身处理点击；仅当点击落在槽位之外才视为面板级展开。
            let location = NSEvent.mouseLocation
            if !self.isPointInAnyCompactSlot(location, layout: pair.layout, hotFrame: pair.hotFrame) {
                self.expand(animated: true, activate: true)
            }
        }

        pair.drawerPanel.onMouseEvent = { [weak pair] event in
            guard event.type == .leftMouseDown else { return }
            NSApp.activate(ignoringOtherApps: true)
            pair?.drawerPanel.makeKeyAndOrderFront(nil)
        }

        pair.hotPanel.onEscape = { [weak self] in self?.collapse(animated: true) }
        pair.drawerPanel.onEscape = { [weak self] in self?.collapse(animated: true) }
    }

    func observeGlobalMouseEvents() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      !self.isExpanded,
                      self.settingsStore.triggerMode == .click,
                      self.pairContainingLocation(NSEvent.mouseLocation) != nil else {
                    return
                }
                self.expand(animated: true, activate: true)
            }
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRevealedForFileDrag = false
                let location = NSEvent.mouseLocation
                if self.isExpanded {
                    self.handleMouseLocation(location)
                }
            }
        }
    }

    func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func startMousePolling() {
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(mousePollingTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        mousePollingTimer = timer
    }

    @objc private func mousePollingTick(_ timer: Timer) {
        handleMouseLocation(NSEvent.mouseLocation)
        updateDrawerMouseEvents(cursor: NSEvent.mouseLocation)
    }

    /// 可见抽屉矩形（紧凑带 + 当前面板高度，顶贴屏幕）：穿透命中与停留
    /// 判定共用同一公式（方案 E 窗口为固定满高，不能用窗口 frame——
    /// 按内容状态计算可见矩形）。
    private func visibleDrawerFrame(for pair: ScreenPanelPair) -> NSRect {
        var size = uiState.drawerWindowSize
        size.height += pair.layout.compactHeight
        return NotchGeometry.topCenteredFrame(
            for: size,
            topY: pair.screenFrame.maxY,
            in: pair.screenFrame
        )
    }

    /// 参考codex-island 的双机制穿透：满高抽屉窗口常开 `ignoresMouseEvents`，
    /// 按光标是否在可见面板矩形内翻转——hitTest 穿透必要但不充分（窗口
    /// 仍会在点击时抢焦点），必须配合窗口级开关。
    private func updateDrawerMouseEvents(cursor: NSPoint) {
        guard isExpanded, let pair = activePair else { return }
        let visibleFrame = visibleDrawerFrame(for: pair)
        let inside = visibleFrame.contains(cursor)
        #if DEBUG
        if ResizeProbeLog.isEnabled {
            NSLog(
                "click-probe cursor=%@ visible=%@ inside=%@ ignoring=%@",
                NSStringFromPoint(cursor),
                NSStringFromRect(visibleFrame),
                String(describing: inside),
                String(describing: pair.drawerPanel.ignoresMouseEvents)
            )
        }
        #endif
        if pair.drawerPanel.ignoresMouseEvents == inside {
            pair.drawerPanel.ignoresMouseEvents = !inside
        }
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        cancelCollapse()
        syncScreens()
        updateScreenConstraint()
        rebuildContent()
    }

    @objc private func menuTrackingDidBegin(_ notification: Notification) {
        activeMenuTrackingCount += 1
        cancelCollapse()
    }

    @objc private func menuTrackingDidEnd(_ notification: Notification) {
        activeMenuTrackingCount = max(0, activeMenuTrackingCount - 1)
        guard activeMenuTrackingCount == 0 else { return }
        handleMouseLocation(NSEvent.mouseLocation)
    }

    // MARK: - 展开/收起协调（文档 §6）

    func handleMouseLocation(_ point: NSPoint) {
        if !isExpanded {
            if isFileDrag(at: point) {
                if !isRevealedForFileDrag {
                    isRevealedForFileDrag = true
                    expand(animated: true, activate: false)
                }
                return
            }

            if settingsStore.triggerMode == .hover,
               NSEvent.pressedMouseButtons & 1 == 0,
               pairContainingLocation(point) != nil {
                expand(animated: true, activate: false)
            }
            return
        }

        // 已展开。
        if activeMenuTrackingCount > 0 {
            cancelCollapse()
            return
        }
        if isEditing || isEditEntryPending || isPinned {
            cancelCollapse()
            return
        }
        if settingsStore.triggerMode == .click {
            cancelCollapse()
            return
        }
        if isPointInExpandedStayRegion(point) {
            cancelCollapse()
        } else {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        guard activeMenuTrackingCount == 0 else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseTask = nil
            guard self.activeMenuTrackingCount == 0 else { return }
            guard !self.isEditing, !self.isPinned else { return }
            guard !self.isPointInExpandedStayRegion(NSEvent.mouseLocation) else { return }
            self.collapse(animated: true)
        }

        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    /// 停留区域：当前抽屉可见矩形附近，或任一屏幕的紧凑热区。
    private func isPointInExpandedStayRegion(_ point: NSPoint) -> Bool {
        let margin: CGFloat = 10
        if let pair = activePair {
            let visibleFrame = visibleDrawerFrame(for: pair)
            if visibleFrame.insetBy(dx: -margin, dy: -margin).contains(point) {
                return true
            }
        }
        return pairs.contains { $0.hotFrame.contains(point) }
    }

    private func isPointInAnyCompactSlot(_ point: NSPoint, layout: NotchLayout, hotFrame: NSRect) -> Bool {
        let slots = (0..<layoutEngine.compactSlots.count).map { index -> NSRect in
            let slot = compactSlotFrame(index: index, layout: layout)
            // 槽位 frame 是内容坐标（左上原点）；换算到屏幕坐标。
            return NSRect(
                x: hotFrame.minX + slot.minX,
                y: hotFrame.maxY - slot.maxY,
                width: slot.width,
                height: slot.height
            )
        }
        return slots.contains { $0.contains(point) }
    }

    private func isFileDrag(at point: NSPoint) -> Bool {
        guard NSEvent.pressedMouseButtons & 1 == 1,
              FileDragDetector.containsFileURLs(NSPasteboard(name: .drag)) else {
            return false
        }
        return pairContainingLocation(point) != nil
    }
}
