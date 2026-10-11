import AppKit
import CryptoKit

/// Resolves and installs official macOS applications safely.
@MainActor
final class AppInstaller {
    var progress: ((String) -> Void)?

    func install(_ name: String) async throws -> String {
        if AppLookup.url(name) != nil { return "\(name) is already installed." }
        progress?("Resolving \(name)…")
        let cask = try await resolve(name)
        guard let urlText = cask["url"] as? String, let url = URL(string: urlText), url.scheme == "https",
              let token = cask["token"] as? String else {
            throw ActionError.failed("No verified HTTPS download was found for \(name).")
        }

        let explicitExt = cask["ext"] as? String
        let delegate = DownloadProgress { [weak self] fraction in
            Task { @MainActor [weak self] in self?.progress?("Downloading \(name)… \(Int(fraction * 100))%") }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        progress?("Downloading \(name)…")
        let (temporary, response) = try await session.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ActionError.failed("Download failed for \(name).")
        }

        // Determine extension
        var ext = explicitExt ?? response.url?.pathExtension.lowercased() ?? url.pathExtension.lowercased()
        if ext.isEmpty, let suggested = response.suggestedFilename {
            ext = (suggested as NSString).pathExtension.lowercased()
        }
        if ext.isEmpty { ext = "dmg" }

        guard ["dmg", "pkg", "zip"].contains(ext) else {
            throw ActionError.failed("\(name)'s installer format isn't supported. Wave supports vendor DMG, ZIP, and PKG downloads.")
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safeName = token.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let archive = downloads.appendingPathComponent("\(safeName)-Wave-\(UUID().uuidString.prefix(8)).\(ext)")
        try FileManager.default.moveItem(at: temporary, to: archive)

        if let hash = cask["sha256"] as? String, hash != "no_check" {
            progress?("Verifying \(name)…")
            try await verifyHash(archive, expected: hash)
        }
        try Task.checkCancellation()
        progress?("Installing \(name)…")

        if ext == "pkg" { return try await installPackage(archive, name: name) }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Wave-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var mountedMountPoint: String? = nil

        do {
            if ext == "dmg" {
                // First try attaching to our explicit staging mountpoint
                let attachResult = try await MacCommand.run(.disk, ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", staging.path, archive.path], timeout: 120)
                if attachResult.status == 0 {
                    mountedMountPoint = staging.path
                } else {
                    // Try attaching without explicit mountpoint
                    let fallbackResult = try await MacCommand.run(.disk, ["attach", "-readonly", "-nobrowse", "-noautoopen", archive.path], timeout: 120)
                    guard fallbackResult.status == 0 else { throw ActionError.failed("Couldn't mount \(name)'s disk image.") }
                    let outputStr = String(decoding: fallbackResult.output, as: UTF8.self)
                    for line in outputStr.split(separator: "\n") {
                        if let mountIdx = line.range(of: "/Volumes/") {
                            mountedMountPoint = String(line[mountIdx.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                }
            } else {
                let result = try await MacCommand.run(.ditto, ["-x", "-k", archive.path, staging.path], timeout: 120)
                guard result.status == 0 else { throw ActionError.failed("Couldn't expand \(name)'s download.") }
            }

            let searchDir = URL(fileURLWithPath: mountedMountPoint ?? staging.path)
            let contents = (try? FileManager.default.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
            let apps = contents.filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }

            if let app = apps.first {
                let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(app.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    let copy = try await MacCommand.run(.ditto, [app.path, destination.path], timeout: 300)
                    guard copy.status == 0, Bundle(url: destination)?.bundleIdentifier != nil else {
                        throw ActionError.failed("Couldn't copy to Applications. Check folder permissions; the download is in Downloads.")
                    }
                }
            } else if let pkg = contents.first(where: { $0.pathExtension == "pkg" }) {
                let local = downloads.appendingPathComponent("\(UUID().uuidString)-\(pkg.lastPathComponent)")
                try FileManager.default.copyItem(at: pkg, to: local)
                if let mp = mountedMountPoint { _ = try await MacCommand.run(.disk, ["detach", mp]); mountedMountPoint = nil }
                return try await installPackage(local, name: name)
            } else {
                throw ActionError.failed("No single installable app was found. The vendor download is in Downloads.")
            }
        } catch {
            if let mp = mountedMountPoint { _ = try? await MacCommand.run(.disk, ["detach", mp, "-force"]) }
            throw error
        }

        if let mp = mountedMountPoint {
            _ = try? await MacCommand.run(.disk, ["detach", mp, "-force"])
        }
        try? FileManager.default.removeItem(at: staging)
        return "\(name) is installed in Applications."
    }

    private func resolve(_ name: String) async throws -> [String: Any] {
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let query = normalized(name)
        guard !query.isEmpty else { throw ActionError.failed("Please name an app to install.") }

        // Fast-path curated dictionary for popular vendor downloads
        let popular: [String: (url: String, token: String, ext: String)] = [
            "docker": ("https://desktop.docker.com/mac/main/arm64/Docker.dmg", "docker", "dmg"),
            "dockerdesktop": ("https://desktop.docker.com/mac/main/arm64/Docker.dmg", "docker", "dmg"),
            "chrome": ("https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg", "google-chrome", "dmg"),
            "googlechrome": ("https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg", "google-chrome", "dmg"),
            "firefox": ("https://download.mozilla.org/?product=firefox-latest-ssl&os=osx&lang=en-US", "firefox", "dmg"),
            "vscode": ("https://code.visualstudio.com/sha/download?build=stable&os=darwin-arm64", "visual-studio-code", "zip"),
            "visualstudiocode": ("https://code.visualstudio.com/sha/download?build=stable&os=darwin-arm64", "visual-studio-code", "zip")
        ]

        if let match = popular[query] {
            return ["url": match.url, "token": match.token, "sha256": "no_check", "ext": match.ext]
        }

        // Fallback: Query Homebrew Cask API
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://formulae.brew.sh/api/cask.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ActionError.failed("Couldn't reach the official-download directory.")
        }

        let matches = items.filter { item in
            let names = (item["name"] as? [String] ?? []) + [item["token"] as? String ?? ""]
            return names.contains { normalized($0) == query }
        }

        // 1. Exact token match
        if let match = matches.first(where: { normalized($0["token"] as? String ?? "") == query }),
           match["disabled"] as? Bool != true {
            return match
        }

        // 2. Exact name match
        let nameMatches = matches.filter { item in
            (item["name"] as? [String] ?? []).contains { normalized($0) == query }
        }
        if let match = nameMatches.first, match["disabled"] as? Bool != true {
            return match
        }

        // 3. First non-disabled match
        if let match = matches.first(where: { $0["disabled"] as? Bool != true }) {
            return match
        }

        throw ActionError.failed("I couldn't resolve an official download for \(name). Try its full app name.")
    }

    private func verifyHash(_ file: URL, expected: String) async throws {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw ActionError.failed("Download checksum mismatch. Nothing was installed.") }
        }.value
    }

    private func installPackage(_ file: URL, name: String) async throws -> String {
        guard NSWorkspace.shared.open(file) else { throw ActionError.failed("Couldn't open Installer.") }
        progress?("Installing \(name)… complete macOS Installer if prompted")
        for _ in 0..<300 {
            try await Task.sleep(for: .seconds(1))
            if AppLookup.url(name) != nil { return "\(name) is installed in Applications." }
        }
        throw ActionError.failed("The installer is open, but installation isn't verified yet. Finish the macOS Installer prompts.")
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    let update: @Sendable (Double) -> Void
    init(update: @escaping @Sendable (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { update(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
