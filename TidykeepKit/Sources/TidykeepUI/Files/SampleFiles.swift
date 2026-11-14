import CoreGraphics
import CoreText
import Foundation

/// The sample folder UI tests and screenshots check: two identical PDFs, a small note and a
/// 120 MB export, all dated about two months ago so the 7-day rule leaves them in.
///
/// Every byte is really written. The two PDFs are written separately from the same data, not
/// copied: a copy on APFS is a clone that shares its blocks, so it would give nothing back.
enum SampleFiles {
    static let original = Copy.Files.Sample.original
    static let copy = Copy.Files.Sample.copy
    static let note = Copy.Files.Sample.note
    static let export = Copy.Files.Sample.export
    static let exportBytes = 120_000_000

    static func write(to folder: URL, now: Date) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let pdf = tripNotesPDF()
        try pdf.write(to: folder.appendingPathComponent(original))
        try pdf.write(to: folder.appendingPathComponent(copy))
        try Data(Copy.Files.Sample.noteText.utf8).write(to: folder.appendingPathComponent(note))
        try writeFilled(folder.appendingPathComponent(export), bytes: exportBytes)

        // The original is the older one, so it is the copy that stays.
        try date(folder.appendingPathComponent(original), daysAgo: 62, now: now)
        try date(folder.appendingPathComponent(copy), daysAgo: 60, now: now)
        try date(folder.appendingPathComponent(note), daysAgo: 61, now: now)
        try date(folder.appendingPathComponent(export), daysAgo: 59, now: now)
    }

    /// A one-page PDF of a few kilobytes with real text on it.
    static func tripNotesPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        let title = CTFontCreateWithName("Helvetica-Bold" as CFString, 22, nil)
        let body = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        var y: CGFloat = 720
        draw(Copy.Files.Sample.pdfTitle, font: title, at: CGPoint(x: 64, y: y), in: context)
        y -= 36
        for line in Copy.Files.Sample.pdfLines {
            draw(line, font: body, at: CGPoint(x: 64, y: y), in: context)
            y -= 20
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func draw(_ text: String, font: CTFont, at point: CGPoint, in context: CGContext) {
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(string)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// Writes `bytes` of a repeating, non-zero pattern in 1 MB pieces, so the file takes its
    /// full size on disk.
    private static func writeFilled(_ url: URL, bytes: Int) throws {
        let chunkSize = 1_000_000
        var chunk = Data(count: chunkSize)
        chunk.withUnsafeMutableBytes { buffer in
            for i in 0..<chunkSize { buffer[i] = UInt8(truncatingIfNeeded: i % 251 + 1) }
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written = 0
        while written < bytes {
            let piece = min(chunkSize, bytes - written)
            try handle.write(contentsOf: piece == chunkSize ? chunk : chunk.prefix(piece))
            written += piece
        }
    }

    private static func date(_ url: URL, daysAgo: Double, now: Date) throws {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        // Modification first: setting it can also move the creation date.
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
    }
}
