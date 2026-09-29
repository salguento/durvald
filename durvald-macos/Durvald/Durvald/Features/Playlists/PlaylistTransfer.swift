import AppKit
import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct PlaylistImportReport: Identifiable {
    let id = UUID()
    let playlist: Playlist
    let importedCount: Int
    let missingPaths: [String]
    let failures: [String]
}

enum PlaylistTransferError: LocalizedError {
    case invalidUTF8
    case emptyPlaylist
    case cannotCreatePlaylist
    case exportCancelled

    var errorDescription: String? {
        switch self {
        case .invalidUTF8: "O arquivo M3U8 não contém texto UTF-8 válido."
        case .emptyPlaylist: "O arquivo não contém caminhos de mídia."
        case .cannotCreatePlaylist: "Não foi possível criar a playlist."
        case .exportCancelled: "A exportação foi cancelada."
        }
    }
}

struct M3U8Playlist {
    let paths: [String]

    init(data: Data) throws {
        guard var text = String(data: data, encoding: .utf8) else {
            throw PlaylistTransferError.invalidUTF8
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        paths = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !paths.isEmpty else { throw PlaylistTransferError.emptyPlaylist }
    }

    func resolvedURLs(relativeTo playlistURL: URL) -> [URL] {
        let base = playlistURL.deletingLastPathComponent()
        return paths.map { path in
            if let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
            if NSString(string: path).isAbsolutePath {
                return URL(fileURLWithPath: path).standardizedFileURL
            }
            return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        }
    }
}

enum PlaylistTransferService {
    static let m3u8Type = UTType(filenameExtension: "m3u8") ?? .plainText

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func m3u8(tracks: [Track], destination: URL, relativePaths: Bool) -> String {
        var lines = ["#EXTM3U"]
        for track in tracks {
            let seconds = max(0, Int(track.durationSeconds.rounded()))
            let label = track.artist.isEmpty ? track.title : "\(track.artist) - \(track.title)"
            lines.append("#EXTINF:\(seconds),\(label.replacingOccurrences(of: "\n", with: " "))")
            let fileURL = URL(fileURLWithPath: track.filePath).standardizedFileURL
            lines.append(relativePaths
                ? relativePath(from: destination.deletingLastPathComponent(), to: fileURL)
                : fileURL.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func chooseExportURL(defaultName: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [m3u8Type]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = sanitizedFilename(defaultName) + ".m3u8"
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    static func write(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else { throw PlaylistTransferError.invalidUTF8 }
        try data.write(to: url, options: .atomic)
    }

    private static func relativePath(from base: URL, to target: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(baseComponents.count, targetComponents.count),
              baseComponents[common] == targetComponents[common] {
            common += 1
        }
        let parents = Array(repeating: "..", count: baseComponents.count - common)
        let remainder = Array(targetComponents.dropFirst(common))
        let result = (parents + remainder).joined(separator: "/")
        return result.isEmpty ? target.lastPathComponent : result
    }

    private static func sanitizedFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let result = value.components(separatedBy: invalid).joined(separator: "-")
        return result.isEmpty ? "Playlist" : result
    }
}

struct PlaylistImportReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: PlaylistImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Importação concluída").font(.title2.weight(.semibold))
            LabeledContent("Playlist", value: report.playlist.name)
            LabeledContent("Faixas importadas", value: "\(report.importedCount)")
            if report.missingPaths.isEmpty && report.failures.isEmpty {
                Label("Todos os caminhos foram resolvidos.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                if !report.missingPaths.isEmpty {
                    reportSection("Arquivos ausentes ou não indexados", values: report.missingPaths)
                }
                if !report.failures.isEmpty {
                    reportSection("Falhas ao adicionar", values: report.failures)
                }
            }
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 440)
    }

    private func reportSection(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) (\(values.count))").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        Text(value).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 130)
        }
    }
}
