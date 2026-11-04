import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// Layout and visual treatment adapted from Tendedero (MIT), see THIRD_PARTY_NOTICES.md.
enum CaptureLineLayout {
    static let height: CGFloat = 210
    static let spacing: CGFloat = 174
    static func adaptiveCapacity(width: CGFloat) -> Int {
        max(1, Int(floor(max(0, width - 200) / spacing)) + 1)
    }
    static func adaptiveSpacing(itemCount: Int, width: CGFloat) -> CGFloat {
        // Keep a few photos together in the middle. Only a full row needs the
        // small spacing adjustment that distributes it across the screen.
        guard itemCount > 1, itemCount == adaptiveCapacity(width: width) else { return spacing }
        return max(0, width - 200) / CGFloat(itemCount - 1)
    }
    static func adaptiveCardX(index: Int, itemCount: Int, width: CGFloat) -> CGFloat {
        guard itemCount > 1 else { return width / 2 }
        let gap = adaptiveSpacing(itemCount: itemCount, width: width)
        return width / 2 + (CGFloat(index) - CGFloat(itemCount - 1) / 2) * gap
    }
    static func overflow(itemCount: Int, width: CGFloat) -> CGFloat {
        max(0, CGFloat(max(0, itemCount - 1)) * spacing + 200 - width)
    }
    static func clampedScroll(_ value: CGFloat, overflow: CGFloat) -> CGFloat {
        min(overflow, max(0, value))
    }
    static func cardX(index: Int, itemCount: Int, width: CGFloat, scroll: CGFloat) -> CGFloat {
        let contentWidth = CGFloat(max(0, itemCount - 1)) * spacing
        let overflow = overflow(itemCount: itemCount, width: width)
        let base = overflow > 0 ? width - 100 - contentWidth : (width - contentWidth) / 2
        return base + CGFloat(index) * spacing + clampedScroll(scroll, overflow: overflow)
    }
    static func ropeY(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let f = x / max(1, width)
        return 10 + 4 * min(30, width * 0.018) * f * (1 - f)
    }
    static func photoSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 136, height: 104) }
        let scale = min(136 / size.width, 104 / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

struct CaptureShelfView: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var library: CaptureLibrary
    @AppStorage("appLanguage") private var language: AppLanguage = .zh
    @ViewState private var targeted = false
    @ViewState private var scroll: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            let items = library.shelfItems
            let overflow = CaptureLineLayout.overflow(itemCount: items.count, width: geo.size.width)
            let base = CaptureLineLayout.cardX(index: 0, itemCount: items.count, width: geo.size.width, scroll: 0)
            ZStack(alignment: .topLeading) {
                ZStack {
                    CaptureRope().stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
                    CaptureRope().stroke(Color(white: 0.55), lineWidth: 1.2)
                    CaptureRope().stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                .allowsHitTesting(false)
                if items.isEmpty {
                    Button(action: controller.takeScreenshot) {
                        Text(C("点击框选截图，挂到这里", "Click to take a screenshot and hang it here"))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .pastesGlass(cornerRadius: 100, interactive: true)
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    }.buttonStyle(.plain)
                        .captureControlRegion()
                        .position(x: geo.size.width / 2, y: CaptureLineLayout.ropeY(geo.size.width / 2, width: geo.size.width) + 34)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let x = controller.adaptiveRetention && overflow == 0
                        ? CaptureLineLayout.adaptiveCardX(index: index, itemCount: items.count, width: geo.size.width)
                        : CaptureLineLayout.cardX(index: index, itemCount: items.count, width: geo.size.width, scroll: scroll)
                    let y = CaptureLineLayout.ropeY(x, width: geo.size.width)
                    CaptureCard(item: item, url: library.url(for: item), controller: controller,
                                arrivalToken: library.arrivalTokens[item.id])
                        .frame(width: 150, height: 170, alignment: .top)
                        .position(x: x, y: y - 9.5 + 85)
                        .opacity(min(1, max(0, min(x, geo.size.width - x) / 80)))
                        .allowsHitTesting(x > 65 && x < geo.size.width - 65)
                        .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.96))))
                }
                if let last = items.lastIndex(where: \.isPinned) {
                    let x = controller.adaptiveRetention && overflow == 0
                        ? CaptureLineLayout.adaptiveCardX(index: last, itemCount: items.count, width: geo.size.width) + (items.count > 1 ? CaptureLineLayout.adaptiveSpacing(itemCount: items.count, width: geo.size.width) / 2 : 0)
                        : base + (CGFloat(last) + 0.5) * CaptureLineLayout.spacing + min(overflow, max(0, scroll))
                    CaptureKnot().position(x: x, y: CaptureLineLayout.ropeY(x, width: geo.size.width) + 3)
                }
                if !items.isEmpty {
                    Button(action: controller.takeScreenshot) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 28, height: 26)
                            .background { Circle().fill(.white.opacity(0.88)).frame(width: 24, height: 24) }
                    }
                    .buttonStyle(.borderless)
                    .pastesGlass(cornerRadius: 18, interactive: true)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                    .help(C("框选截图", "Take screenshot"))
                    .accessibilityLabel(C("框选截图", "Take screenshot"))
                    .captureControlRegion()
                    .position(x: geo.size.width - 28, y: 185)
                }
                if overflow > 0 {
                    HStack(spacing: 14) {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                scroll = CaptureLineLayout.clampedScroll(scroll + max(CaptureLineLayout.spacing, geo.size.width - 200), overflow: overflow)
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.blue)
                                .frame(width: 28, height: 24)
                                .background { Circle().fill(.white.opacity(0.82)).frame(width: 22, height: 22) }
                                .opacity(scroll >= overflow ? 0.35 : 1)
                        }
                        .disabled(scroll >= overflow)
                        .help(C("查看左侧图片", "Show images to the left"))
                        .accessibilityLabel(C("查看左侧图片", "Show images to the left"))
                        Text(C("共 \(items.count) 项 · 左右滚动", "\(items.count) items · Scroll to browse"))
                            .font(.system(size: 11)).monospacedDigit()
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                scroll = CaptureLineLayout.clampedScroll(scroll - max(CaptureLineLayout.spacing, geo.size.width - 200), overflow: overflow)
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.blue)
                                .frame(width: 28, height: 24)
                                .background { Circle().fill(.white.opacity(0.82)).frame(width: 22, height: 22) }
                                .opacity(scroll <= 0 ? 0.35 : 1)
                        }
                        .disabled(scroll <= 0)
                        .help(C("查看右侧图片", "Show images to the right"))
                        .accessibilityLabel(C("查看右侧图片", "Show images to the right"))
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .pastesGlass(cornerRadius: 100)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .captureControlRegion()
                    .position(x: geo.size.width / 2, y: 185)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onChange(of: library.latestArrival) { _, arrival in
                guard let arrival, let index = items.firstIndex(where: { $0.id == arrival.itemID }) else { return }
                // Bring the arriving card into view even when browsing older images.
                let x = CaptureLineLayout.cardX(index: index, itemCount: items.count, width: geo.size.width, scroll: 0)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    scroll = CaptureLineLayout.clampedScroll(geo.size.width - 100 - x, overflow: overflow)
                }
            }
            .onChange(of: overflow) { _, value in scroll = CaptureLineLayout.clampedScroll(scroll, overflow: value) }
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.78), value: items.map(\.id))
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.78), value: items.map(\.isPinned))
            .onReceive(NotificationCenter.default.publisher(for: .captureShelfScroll)) { notification in
                guard let delta = notification.object as? CGFloat else { return }
                scroll = CaptureLineLayout.clampedScroll(scroll + delta, overflow: overflow)
            }
        }
        .coordinateSpace(name: "captureLine")
        .onPreferenceChange(CaptureHitRects.self) { controller.shelf?.hitRects = $0 }
        .onPreferenceChange(CaptureControlRects.self) { controller.shelf?.controlRects = $0 }
        .offset(y: controller.lineRevealed ? 0 : -(CaptureLineLayout.height + 12))
        .animation(reduceMotion ? nil : (controller.lineRevealed ? .spring(response: 0.42, dampingFraction: 0.82) : .easeIn(duration: 0.22)), value: controller.lineRevealed)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { controller.importFiles([url]) }
                }
            }
            return !providers.isEmpty
        }
        .onExitCommand { controller.shelf?.hide() }
        .alert(C("截图架", "Capture shelf"), isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK") { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }
}

private struct CaptureRope: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: -20, y: 10))
            p.addQuadCurve(to: CGPoint(x: rect.width + 20, y: 10), control: CGPoint(x: rect.midX, y: 10 + 2 * min(30, rect.width * 0.018)))
        }
    }
}
private struct CaptureKnot: View {
    var body: some View {
        ZStack {
            Ellipse().fill(Color(white: 0.5)).frame(width: 7, height: 5.5)
            Path { p in
                p.move(to: CGPoint(x: 3.5, y: 3)); p.addQuadCurve(to: CGPoint(x: 1.5, y: 11), control: CGPoint(x: 3.8, y: 7))
                p.move(to: CGPoint(x: 4, y: 3)); p.addQuadCurve(to: CGPoint(x: 6.5, y: 10), control: CGPoint(x: 4.5, y: 7))
            }.stroke(Color(white: 0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round)).frame(width: 8, height: 12).offset(y: 5)
        }.allowsHitTesting(false)
    }
}
private struct CaptureClip: View {
    let pinned: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 3.5)
            .fill(LinearGradient(colors: pinned
                ? [Color(red: 0.65, green: 0.40, blue: 0.12), Color(red: 1, green: 0.84, blue: 0.45), Color(red: 0.86, green: 0.61, blue: 0.22), Color(red: 0.60, green: 0.36, blue: 0.10)]
                : [0.70, 0.93, 0.82, 0.62].map { Color(white: $0) }, startPoint: .leading, endPoint: .trailing))
            .frame(width: 9, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(LinearGradient(colors: [.white.opacity(pinned ? 0.45 : 0.9), .black.opacity(0.18)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
            .overlay(alignment: .top) { Capsule().fill(.black.opacity(0.32)).frame(width: 5, height: 1.4).padding(.top, 8.5) }
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1.5).allowsHitTesting(false)
    }
}
private struct CaptureCard: View {
    let item: CaptureItem
    let url: URL
    @ObservedObject var controller: CaptureController
    let arrivalToken: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var thumbnail: NSImage?
    @ViewState private var thumbnailLoaded = false
    @ViewState private var hovering = false
    @ViewState private var swing = 0.0
    @ViewState private var lastArrival: UUID?
    @ViewState private var activeHang: UUID?
    @ViewState private var hanging = false
    @ViewState private var arrivalScale: CGFloat = 1
    @ViewState private var arrivalOpacity = 1.0
    private var hangRequest: CaptureHangRequest {
        CaptureHangRequest(token: arrivalToken, revealed: controller.lineRevealed, imageReady: thumbnailLoaded)
    }
    private var tilt: Double { Double(item.id.uuid.0 % 7) - 3 }
    var body: some View {
        let photo = CaptureLineLayout.photoSize(thumbnail?.size ?? CGSize(width: 136, height: 104))
        VStack(spacing: -12) {
            CaptureClip(pinned: item.isPinned).zIndex(1)
            ZStack {
                if let thumbnail { Image(nsImage: thumbnail).resizable().interpolation(.high).frame(width: photo.width, height: photo.height).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) }
                else { Color.clear.frame(width: photo.width, height: photo.height) }
                if item.kind == .movie {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.blue)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.9), in: Circle())
                        .pastesGlass(cornerRadius: 14)
                }
            }
            .padding(4)
            .pastesGlass(cornerRadius: 20)
            .overlay {
                if item.isPinned {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color(red: 1, green: 0.86, blue: 0.49), Color(red: 0.83, green: 0.58, blue: 0.21)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                        .allowsHitTesting(false)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.blue.opacity(0.48), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.2 : 0.12), radius: hovering ? 18 : 12, y: hovering ? 7 : 5)
            .overlay(CaptureInteraction(item: item, url: url, controller: controller))
            .overlay(alignment: .topLeading) {
                Button { controller.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 20, height: 20)
                        .pastesGlass(cornerRadius: 10, interactive: true)
                }.buttonStyle(.plain).padding(3).opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isPinned {
                    Label(C("已固定", "Pinned"), systemImage: "pin.fill")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .fixedSize()
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .pastesGlass(cornerRadius: 100, tint: Color(red: 1, green: 0.78, blue: 0.34).opacity(0.38))
                        .padding(5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if controller.copiedCaptureID == item.id {
                    Label(C("已复制", "Copied"), systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .pastesGlass(cornerRadius: 100, tint: .blue.opacity(0.18))
                        .offset(y: 16).allowsHitTesting(false)
                }
            }
            .scaleEffect(hovering ? 1.035 : 1, anchor: .top)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
            .onHover { hovering = $0; controller.shelf?.hoveredItem = $0 ? item.id : nil }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: CaptureHitRects.self, value: [item.id: geometry.frame(in: .named("captureLine"))])
            })
            .opacity(controller.liftingCaptureIDs.contains(item.id) ? 0 : 1)
            .animation(.easeOut(duration: 0.1), value: controller.liftingCaptureIDs.contains(item.id))
        }
        .allowsHitTesting(!controller.liftingCaptureIDs.contains(item.id))
        .accessibilityValue(item.isPinned ? C("已固定", "Pinned") : C("未固定", "Not pinned"))
        .rotationEffect(.degrees(reduceMotion ? 0 : tilt + swing), anchor: .top)
        .scaleEffect(arrivalScale, anchor: .top)
        .opacity(arrivalToken != nil && lastArrival != arrivalToken && !hanging ? 0 : arrivalOpacity)
        .task(id: hangRequest) { await hangImage() }
        .onChange(of: controller.lineRevealed) { _, revealed in if revealed { nudge(3) } }
        .onChange(of: controller.copiedCaptureID) { _, id in if id == item.id { nudge(3) } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 + Double(item.id.uuid.1 % 4)))
                guard !Task.isCancelled else { return }
                if controller.lineRevealed && !hovering { nudge(2) }
            }
        }
        .task(id: item.digest) {
            defer { thumbnailLoaded = true }
            if item.kind == .image {
                let fileURL = url
                thumbnail = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil as NSImage? }
                    return NSImage(cgImage: cg, size: .zero)
                }.value
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 400, height: 300)
                if let result = try? await generator.image(at: .zero) { thumbnail = NSImage(cgImage: result.image, size: .zero) }
            }
        }
    }
    private func hangImage() async {
        guard hangRequest.shouldAnimate(after: lastArrival) else {
            if !controller.lineRevealed {
                activeHang = nil
                hanging = false; arrivalScale = 1; arrivalOpacity = 1; swing = 0
            }
            return
        }
        guard let token = arrivalToken else { return }
        let run = UUID()
        activeHang = run
        hanging = true
        defer { if activeHang == run { hanging = false; activeHang = nil } }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            arrivalScale = 1; arrivalOpacity = 0; swing = 0
        }
        do {
            // Let the shelf and surrounding cards settle before reading the destination.
            try await Task.sleep(for: .milliseconds(reduceMotion ? 30 : 420))
            if !reduceMotion, let image = thumbnail {
                try await controller.shelf?.flyImage(image, itemID: item.id, token: token) {
                    guard activeHang == run, controller.library.arrivalTokens[item.id] == token else { return }
                    lastArrival = token
                    withAnimation(.easeOut(duration: 0.16)) { arrivalOpacity = 1 }
                }
            }
            try Task.checkCancellation()
            guard activeHang == run, controller.library.arrivalTokens[item.id] == token else { return }
            lastArrival = token
            withTransaction(transaction) { arrivalScale = reduceMotion ? 1 : 0.98 }
            withAnimation(.easeOut(duration: 0.18)) {
                arrivalScale = 1; arrivalOpacity = 1
            }
            try await Task.sleep(for: .milliseconds(180))
        } catch {
            guard activeHang == run, controller.library.arrivalTokens[item.id] == token else { return }
            // A visible card without usable flight geometry still needs a
            // fade-in fallback. Actual task cancellation leaves it pending.
            if !Task.isCancelled && controller.lineRevealed { lastArrival = token }
            withTransaction(transaction) {
                arrivalScale = 1; arrivalOpacity = 1; swing = 0
            }
        }
    }
    private func nudge(_ angle: Double) {
        guard !reduceMotion, !hanging, arrivalToken == nil || lastArrival == arrivalToken else { return }
        withAnimation(.easeOut(duration: 0.15)) { swing = angle }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.interpolatingSpring(stiffness: 60, damping: 8)) { swing = 0 }
        }
    }
}

private struct CaptureHitRects: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct CaptureControlRects: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

private extension View {
    func captureControlRegion() -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: CaptureControlRects.self, value: [geometry.frame(in: .named("captureLine"))])
        })
    }
}

extension Notification.Name { static let captureShelfScroll = Notification.Name("PastesCaptureShelfScroll") }

private struct CaptureInteraction: NSViewRepresentable {
    let item: CaptureItem
    let url: URL
    let controller: CaptureController
    func makeNSView(context: Context) -> CaptureDragView { CaptureDragView() }
    func updateNSView(_ view: CaptureDragView, context: Context) {
        view.item = item; view.url = url; view.controller = controller
    }
}

private final class CaptureDragView: NSView, NSDraggingSource {
    var item: CaptureItem?
    var url: URL?
    weak var controller: CaptureController?
    private var press: DispatchWorkItem?
    private var click: DispatchWorkItem?
    private var downPoint: NSPoint?
    private var held = false
    private var dragging = false
    private var dragFile: CaptureDragFile?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        click?.cancel(); held = false; dragging = false; downPoint = event.locationInWindow
        let work = DispatchWorkItem { [weak self] in
            guard let self, let item else { return }
            held = true; controller?.edit(item)
        }
        press = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
    }
    override func mouseUp(with event: NSEvent) {
        press?.cancel(); press = nil
        guard !held, !dragging, let item else { return }
        if event.clickCount >= 2 { controller?.open(item) }
        else {
            let work = DispatchWorkItem { [weak self] in self?.controller?.copy(item) }
            click = work; DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !held, !dragging, let origin = downPoint, let url, let item else { return }
        guard hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 4 else { return }
        press?.cancel(); click?.cancel(); dragging = true
        do {
            dragFile = try CaptureDragFile(source: url, item: item)
        } catch { controller?.errorMessage = error.localizedDescription; dragging = false; return }
        guard let dragFile else { return }
        controller?.shelf?.isDragging = true
        let drag = NSDraggingItem(pasteboardWriter: dragFile.file as NSURL)
        let image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        drag.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .outsideApplication ? [.copy, .move, .delete] : [] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.shelf?.isDragging = false; dragging = false
        dragFile?.finish(operation: operation, onFiled: { [weak controller] item in controller?.remove(item) },
                         onError: { [weak controller] error in controller?.errorMessage = error.localizedDescription })
        dragFile = nil
    }
    override func keyDown(with event: NSEvent) {
        guard let item else { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { controller?.undo() }
        else if event.keyCode == 51 { controller?.remove(item) }
        else if event.keyCode == 53 { controller?.shelf?.hide() }
        else { super.keyDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        controller?.shelf?.menuOpen = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        controller?.shelf?.menuOpen = false
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let actions: [(String, Selector)] = [
            (C("复制", "Copy"), #selector(copyMedia)),
            (C("悬浮参考", "Float as reference"), #selector(holdMedia)),
            (item.kind == .movie ? C("裁剪录屏…", "Trim recording…") : C("标注图片…", "Mark up image…"), #selector(editMedia)),
            (C("打开文件", "Open file"), #selector(openMedia)),
            (C("另存为…", "Save as…"), #selector(exportMedia)),
            (item.isPinned ? C("取消固定", "Unpin") : C("固定", "Pin"), #selector(pinMedia)),
            (C("移除本图片", "Remove this image"), #selector(removeMedia)),
            (C("移除左侧所有图片", "Remove all images to the left"), #selector(removeLeft)),
            (C("移除右侧所有图片", "Remove all images to the right"), #selector(removeRight))]
        for (title, action) in actions {
            if action == #selector(removeMedia) { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            if action == #selector(removeLeft) { entry.isEnabled = controller?.library.removalIDs(relativeTo: item.id, side: .left).isEmpty == false }
            if action == #selector(removeRight) { entry.isEnabled = controller?.library.removalIDs(relativeTo: item.id, side: .right).isEmpty == false }
            menu.addItem(entry)
        }
        return menu
    }
    @objc private func copyMedia() { if let item { controller?.copy(item) } }
    @objc private func holdMedia() { if let item { controller?.hold(item) } }
    @objc private func editMedia() { if let item { controller?.edit(item) } }
    @objc private func openMedia() { if let item { controller?.open(item) } }
    @objc private func exportMedia() { if let item { controller?.export(item) } }
    @objc private func pinMedia() { if let item { controller?.pin(item) } }
    @objc private func removeMedia() { if let item { controller?.remove(item) } }
    @objc private func removeLeft() { if let item { controller?.removeSide(of: item, side: .left) } }
    @objc private func removeRight() { if let item { controller?.removeSide(of: item, side: .right) } }
    deinit { press?.cancel(); click?.cancel() }
}
