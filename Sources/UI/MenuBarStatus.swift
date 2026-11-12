import AppKit
import SwiftUI

/// The menu-bar label, isolated from the rest of `HogStore`.
///
/// The app body reads this object, not the sampler's published rows.  A new
/// bitmap is built only when the quantized picture changes, at most once a
/// second unless the mode, the words, or the appearance changed.  Sampling
/// stays on the store's utility queue; the bitmap here is a few thousand
/// pixels and is drawn on the main actor with AppKit, which is where text
/// and template colours have to be resolved.
@MainActor
final class MenuBarStatus: ObservableObject {
    static let minimumInterval: TimeInterval = 1

    struct Presentation: Equatable {
        var revision: Int
        var mode: MenuBarLabelMode
        var image: NSImage?
        var label: String
        var showIcon: Bool
        var showPercent: Bool
        var help: String
        var accessibility: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.revision == rhs.revision
        }
    }

    @Published private(set) var presentation: Presentation
    /// How many bitmaps have been allocated.  Tests use it to prove a refresh
    /// that does not change the picture does not draw again.
    private(set) var rasterCount = 0
    /// Tests that want to drive the one-second cap themselves set this false
    /// and call `flushDue(now:)`.
    var schedulesDelayedFlush = true

    private var applied: MenuBarPicture?
    private var appliedAt = Date.distantPast
    private var queued: MenuBarPicture?
    private var flushTask: Task<Void, Never>?
    private var cacheKey: CacheKey?
    private var cachedImage: NSImage?

    private struct CacheKey: Equatable {
        var graphic: MenuBarPicture.Graphic
        var appearance: MenuBarChrome
    }

    init() {
        presentation = Presentation(
            revision: 0,
            mode: .historyBars,
            image: nil,
            label: "",
            showIcon: false,
            showPercent: true,
            help: "",
            accessibility: ""
        )
    }

    func submit(_ picture: MenuBarPicture, now: Date = Date()) {
        if picture == applied {
            queued = nil
            cancelFlush()
            return
        }
        if picture == queued { return }
        if shouldApplyImmediately(picture, now: now) {
            queued = nil
            cancelFlush()
            apply(picture, now: now)
            return
        }
        queued = picture
        scheduleFlush(now: now)
    }

    /// Publishes a picture held back by `minimumInterval`, once that interval
    /// has elapsed.
    func flushDue(now: Date = Date()) {
        guard let queued else { return }
        guard now.timeIntervalSince(appliedAt) >= Self.minimumInterval else { return }
        let picture = queued
        self.queued = nil
        cancelFlush()
        apply(picture, now: now)
    }

    private func shouldApplyImmediately(_ picture: MenuBarPicture, now: Date) -> Bool {
        guard let applied else { return true }
        if now.timeIntervalSince(appliedAt) >= Self.minimumInterval { return true }
        return !isGraphicOnlyChange(from: applied, to: picture)
    }

    /// A sparkline or history bar moved, and nothing a person reads as text
    /// or as a setting changed.  Those are the updates worth coalescing.
    private func isGraphicOnlyChange(from applied: MenuBarPicture, to picture: MenuBarPicture) -> Bool {
        applied.mode == picture.mode
            && applied.showIcon == picture.showIcon
            && applied.showPercent == picture.showPercent
            && applied.appearance == picture.appearance
            && applied.label == picture.label
            && applied.help == picture.help
            && applied.accessibility == picture.accessibility
            && applied.graphic != picture.graphic
    }

    private func scheduleFlush(now: Date) {
        guard schedulesDelayedFlush, flushTask == nil else { return }
        let delay = max(0, Self.minimumInterval - now.timeIntervalSince(appliedAt))
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushDue(now: Date())
        }
    }

    private func cancelFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    private func apply(_ picture: MenuBarPicture, now: Date) {
        let image = image(for: picture)
        applied = picture
        appliedAt = now
        var next = presentation
        next.revision += 1
        next.mode = picture.mode
        next.image = image
        next.label = picture.label
        next.showIcon = picture.showIcon
        next.showPercent = picture.showPercent
        next.help = picture.help
        next.accessibility = picture.accessibility
        presentation = next
    }

    private func image(for picture: MenuBarPicture) -> NSImage? {
        switch picture.graphic {
        case .none:
            return nil
        case .historyBars(let percent, let bars, let showPercent):
            return cached(picture) {
                MenuBarCpuBarsView.render(
                    percent: percent,
                    bars: bars,
                    showPercent: showPercent,
                    appearance: picture.appearance
                )
            }
        case .sparkline(let samples, let showIcon):
            return cached(picture) {
                if showIcon {
                    return CpuSparklineView.renderHogAndSparkline(
                        samples: samples,
                        appearance: picture.appearance
                    )
                }
                return CpuSparklineView.renderSparkline(
                    samples: samples,
                    appearance: picture.appearance
                )
            }
        }
    }

    private func cached(_ picture: MenuBarPicture, make: () -> NSImage) -> NSImage {
        let key = CacheKey(graphic: picture.graphic, appearance: picture.appearance)
        if key == cacheKey, let cachedImage { return cachedImage }
        let image = make()
        rasterCount += 1
        cacheKey = key
        cachedImage = image
        return image
    }
}

/// Menu-bar label.  `Equatable` so a store publish that did not change this
/// picture does not rebuild the status item.  Rebuilding it is what schedules
/// `NSStatusItem`'s replicant snapshot.
struct MenuBarStatusLabel: View {
    @ObservedObject var status: MenuBarStatus

    var body: some View {
        MenuBarStatusContent(presentation: status.presentation)
            .equatable()
    }
}

private struct MenuBarStatusContent: View, Equatable {
    var presentation: MenuBarStatus.Presentation

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentation == rhs.presentation
    }

    var body: some View {
        content
            .fixedSize()
            .help(presentation.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hog Hunter")
            .accessibilityValue(presentation.accessibility)
            .transaction { $0.animation = nil }
    }

    @ViewBuilder private var content: some View {
        switch presentation.mode {
        case .historyBars:
            framed(presentation.image, fallback: MenuBarCpuBarsView.pointSize)
        case .sparkline:
            HStack(spacing: 4) {
                framed(
                    presentation.image,
                    fallback: presentation.showIcon
                        ? CpuSparklineView.hogPointSize
                        : CpuSparklineView.sparklinePointSize
                )
                if presentation.showPercent {
                    Text(presentation.label)
                        .monospacedDigit()
                }
            }
        case .machinePercent, .topHogName:
            HStack(spacing: 5) {
                if presentation.showIcon {
                    Image("HogProfile")
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 15)
                }
                if presentation.showPercent || !presentation.showIcon {
                    Text(presentation.label)
                        .monospacedDigit()
                }
            }
        }
    }

    private func framed(_ image: NSImage?, fallback: NSSize) -> some View {
        let size = image?.size ?? fallback
        return Group {
            if let image {
                Image(nsImage: image)
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
