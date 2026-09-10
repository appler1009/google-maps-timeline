import SwiftUI

struct VisitPhotoStrip: View {
    let photos: [LuxVisitPhoto]
    @State private var hoveredID: String?

    var body: some View {
        if photos.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        Button {
                            LuxPhotoLink.shared.presentViewer(photos: photos, index: index)
                        } label: {
                            thumb(photo, hovered: hoveredID == photo.id)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveredID = hovering ? photo.id : (hoveredID == photo.id ? nil : hoveredID)
                        }
                    }
                }
                .padding(.leading, LegendLayout.photoStripLeadingInset)
                .padding(.trailing, LegendLayout.rowHorizontalPadding)
                .padding(.bottom, 4)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func thumb(_ photo: LuxVisitPhoto, hovered: Bool) -> some View {
        ZStack {
            if let data = photo.thumbnail {
                StripThumbImage(data: data)
            } else {
                Palette.inkLift
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    Palette.parchment.opacity(hovered ? 0.85 : 0.18),
                    lineWidth: 1
                )
        )
        .scaleEffect(hovered ? 1.08 : 1)
        .shadow(color: Palette.parchment.opacity(hovered ? 0.22 : 0), radius: hovered ? 5 : 0, y: hovered ? 1 : 0)
        .zIndex(hovered ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .contentShape(Rectangle())
        .help(photoHelp(photo))
        .accessibilityLabel(photo.item.filename)
        .accessibilityHint("Shows a larger preview")
    }

    private func photoHelp(_ photo: LuxVisitPhoto) -> String {
        if photo.libraryName.isEmpty {
            return photo.item.filename
        }
        return "\(photo.item.filename) · \(photo.libraryName)"
    }
}

/// Decodes JPEG once and keeps it in `@State` so hover redraws don’t flash.
private struct StripThumbImage: View {
    let data: Data
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
            } else {
                Palette.inkLift
            }
        }
        .onAppear {
            if image == nil {
                image = PlatformImage(data: data)
            }
        }
        .onChange(of: data) { _, newData in
            image = PlatformImage(data: newData)
        }
    }
}

/// Full-window dimmed photo viewer — tap outside or Esc to dismiss.
struct LuxPhotoViewerOverlay: View {
    @Bindable private var lux = LuxPhotoLink.shared

    var body: some View {
        if let photos = lux.viewerPhotos, !photos.isEmpty {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        lux.dismissViewer()
                    }

                VisitPhotoViewer(
                    photos: photos,
                    index: $lux.viewerIndex,
                    onDismiss: { lux.dismissViewer() }
                )
            }
            .transition(.opacity)
        }
    }
}

private struct VisitPhotoViewer: View {
    let photos: [LuxVisitPhoto]
    @Binding var index: Int
    var onDismiss: () -> Void
    @State private var imageData: Data?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var sheetSize: CGSize = CGSize(width: 840, height: 560)
    @State private var navDirection: NavDirection = .none
    @FocusState private var isFocused: Bool

    private enum NavDirection {
        case none, forward, backward
    }

    private var photo: LuxVisitPhoto {
        photos[min(max(index, 0), photos.count - 1)]
    }

    private var canGoPrevious: Bool { index > 0 }
    private var canGoNext: Bool { index < photos.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Palette.ink
                content
                    .id(photo.id)
                    .transition(imageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if photos.count > 1 {
                Text("\(index + 1) of \(photos.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.parchment.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Palette.ink)
            }
        }
        .background(Palette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        #if os(macOS)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.parchment.opacity(0.12), lineWidth: 1)
        )
        .frame(width: sheetSize.width, height: sheetSize.height)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: sheetSize)
        #else
        .frame(maxWidth: 720, maxHeight: 640)
        .padding(20)
        #endif
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onExitCommand {
            onDismiss()
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard canGoPrevious else { return .ignored }
            goPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard canGoNext else { return .ignored }
            goNext()
            return .handled
        }
        .onAppear {
            isFocused = true
            seedSize(from: photo.thumbnail)
        }
        .task(id: photo.id) {
            await load()
        }
        #if os(iOS)
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    if value.translation.width < -60 {
                        goNext()
                    } else if value.translation.width > 60 {
                        goPrevious()
                    }
                }
        )
        #endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Done") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(Palette.parchment)
                .font(.system(size: 13, weight: .semibold))

            Text(photo.item.filename)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.parchment)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                Button {
                    goPrevious()
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 28, height: 28)
                }
                .disabled(!canGoPrevious)
                .help("Previous photo (←)")
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button {
                    goNext()
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 28, height: 28)
                }
                .disabled(!canGoNext)
                .help("Next photo (→)")
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.parchment)
            .opacity(photos.count > 1 ? 1 : 0)
            .allowsHitTesting(photos.count > 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.inkLift)
    }

    private var imageTransition: AnyTransition {
        switch navDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        case .none:
            return .opacity
        }
    }

    @ViewBuilder
    private var content: some View {
        if let imageData, let image = PlatformImage(data: imageData) {
            Image(platformImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .padding(16)
        } else if isLoading {
            ProgressView()
                .controlSize(.regular)
                .tint(Palette.parchment)
        } else if let errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                Text(errorMessage)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Palette.parchment)
            .padding(24)
        }
    }

    private func goPrevious() {
        guard canGoPrevious else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            navDirection = .backward
            index -= 1
            imageData = photos[index].thumbnail
            errorMessage = nil
            isLoading = false
            seedSize(from: photos[index].thumbnail)
        }
    }

    private func goNext() {
        guard canGoNext else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            navDirection = .forward
            index += 1
            imageData = photos[index].thumbnail
            errorMessage = nil
            isLoading = false
            seedSize(from: photos[index].thumbnail)
        }
    }

    private func load() async {
        errorMessage = nil
        let current = photo
        if imageData == nil, let thumb = current.thumbnail {
            imageData = thumb
            seedSize(from: thumb)
        }

        if let cached = await LuxPhotoLink.shared.cachedOriginal(for: current) {
            guard current.id == photo.id else { return }
            imageData = cached
            isLoading = false
            resizeToPhoto(cached)
            return
        }

        if imageData == nil {
            isLoading = true
        }
        do {
            if let original = try await LuxPhotoLink.shared.fetchOriginal(for: current) {
                guard current.id == photo.id else { return }
                imageData = original
                resizeToPhoto(original)
            } else if imageData == nil {
                errorMessage = "Lux doesn’t have this original available right now."
            }
        } catch {
            TimelineLog.warning("lux original failed", ["error": error.localizedDescription])
            if imageData == nil {
                errorMessage = error.localizedDescription
            }
        }
        if current.id == photo.id {
            isLoading = false
        }
    }

    private func seedSize(from data: Data?) {
        #if os(macOS)
        guard let data, let image = PlatformImage(data: data) else { return }
        sheetSize = Self.idealSheetSize(for: image.size)
        #endif
    }

    private func resizeToPhoto(_ data: Data) {
        #if os(macOS)
        guard let image = PlatformImage(data: data) else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            sheetSize = Self.idealSheetSize(for: image.size)
        }
        #endif
    }

    #if os(macOS)
    private static func idealSheetSize(for pixelSize: CGSize) -> CGSize {
        let aspect = max(pixelSize.width, 1) / max(pixelSize.height, 1)
        let maxWidth: CGFloat = 1100
        let maxHeight: CGFloat = 780
        let minWidth: CGFloat = 640
        let minHeight: CGFloat = 480
        // Chrome for nav title + bottom caption.
        let chrome: CGFloat = 88
        let padding: CGFloat = 32

        var width = min(maxWidth, max(minWidth, pixelSize.width * 0.45 + padding))
        var height = width / aspect + chrome
        if height > maxHeight {
            height = maxHeight
            width = max(minWidth, (height - chrome) * aspect)
        }
        if height < minHeight {
            height = minHeight
            width = max(minWidth, min(maxWidth, (height - chrome) * aspect))
        }
        if width > maxWidth {
            width = maxWidth
            height = max(minHeight, min(maxHeight, width / aspect + chrome))
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
    #endif
}

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
private extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#else
import AppKit
typealias PlatformImage = NSImage
private extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif
