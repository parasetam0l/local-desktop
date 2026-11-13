import AppKit

/// Shares the Mac's clipboard (plain text or an image) with the clients that turned
/// clipboard sharing on.
///
/// Only what is copied while sharing is on is sent: the pasteboard's change count is
/// remembered when the first client turns sharing on, and only later changes go out.
/// What a client sends is put on the Mac's clipboard (and passed on to the other sharing
/// clients) with its change count remembered, so it isn't echoed back.
/// Clipboard contents are never logged, only their size.
@MainActor
final class ClipboardSync {
    enum Content {
        case text(String)
        /// PNG data, or JPEG (see `RDClipboardImage`).
        case image(Data)

        var byteCount: Int {
            switch self {
            case .text(let text): return text.utf8.count
            case .image(let png): return png.count
            }
        }
    }

    private static let pollInterval: TimeInterval = 0.5

    /// The authenticated sessions that have sharing on.
    private let sharingSessions: () -> [ClientSession]
    private var timer: Timer?
    private var lastChangeCount = 0
    private var nextImageId: UInt32 = 1

    init(sharingSessions: @escaping () -> [ClientSession]) {
        self.sharingSessions = sharingSessions
    }

    /// Starts or stops polling after a session turned sharing on or off, or ended.
    func update() {
        let isSharing = !sharingSessions().isEmpty
        if isSharing, timer == nil {
            lastChangeCount = NSPasteboard.general.changeCount
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.poll()
                }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            HostLog.write("clipboard sharing started")
        } else if !isSharing, let timer {
            timer.invalidate()
            self.timer = nil
            HostLog.write("clipboard sharing stopped")
        }
    }

    /// Puts a sharing client's text or image on the Mac's clipboard and passes it on to
    /// the other sharing clients.
    func receive(_ content: Content, from source: ClientSession) {
        guard timer != nil else { return }
        let pasteboard = NSPasteboard.general
        switch content {
        case .text(let text):
            guard !text.isEmpty else { return }
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            pasteboard.setString(text, forType: .string)
        case .image(let png):
            // Not an image we can read: leave the clipboard alone.
            guard let image = NSImage(data: png) else { return }
            let item = NSPasteboardItem()
            item.setData(png, forType: RDClipboardImage.isPNG(png) ? .png : NSPasteboard.PasteboardType("public.jpeg"))
            if let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            pasteboard.writeObjects([item])
        }
        lastChangeCount = pasteboard.changeCount
        HostLog.write("clipboard from client: \(Self.describe(content))")
        broadcast(content, except: source)
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard let content = Self.content(of: pasteboard) else { return }
        broadcast(content, except: nil)
    }

    private func broadcast(_ content: Content, except source: ClientSession?) {
        let targets = sharingSessions().filter { $0 !== source }
        guard !targets.isEmpty else { return }
        switch content {
        case .text(let text):
            guard let payload = RDClipboardMsg.payload(for: text) else {
                HostLog.write("clipboard not shared: \(Self.describe(content)) is too large")
                return
            }
            for session in targets {
                session.sendClipboard(.clipboard, payload)
            }
        case .image(let png):
            guard let chunks = RDClipboardImage.chunks(of: png, id: nextImageId) else {
                HostLog.write("clipboard not shared: \(Self.describe(content)) is too large")
                return
            }
            nextImageId &+= 1
            for session in targets {
                for chunk in chunks {
                    session.sendClipboard(.clipboardImage, chunk)
                }
            }
        }
        HostLog.write("clipboard to \(targets.count) client(s): \(Self.describe(content))")
    }

    private static func describe(_ content: Content) -> String {
        switch content {
        case .text: return "text, \(content.byteCount) bytes"
        case .image: return "image, \(content.byteCount) bytes"
        }
    }

    /// The clipboard's plain text (a copied URL as its string) or image as PNG, whichever
    /// type the copying app put first; nil for anything else.
    private static func content(of pasteboard: NSPasteboard) -> Content? {
        guard let types = pasteboard.types else { return nil }
        // A copied file in Finder also carries its name and icon; files aren't shared.
        if types.contains(.fileURL) { return nil }
        // Password managers mark what they copy as concealed or transient
        // (nspasteboard.org); such values stay on this Mac.
        let private_ = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        if types.contains(where: { private_.contains($0.rawValue) }) { return nil }
        for type in types {
            switch type {
            case .string, .URL:
                if let text = pasteboard.string(forType: type), !text.isEmpty {
                    return .text(text)
                }
            case .png:
                if let png = pasteboard.data(forType: .png), !png.isEmpty {
                    return .image(png.count <= RDClipboardImage.maxSize ? png : jpeg(from: png) ?? png)
                }
            case .tiff:
                if let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    return .image(png.count <= RDClipboardImage.maxSize
                                  ? png : bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) ?? png)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// An image too large as PNG, as JPEG.
    private static func jpeg(from data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
