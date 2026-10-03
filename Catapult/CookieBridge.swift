import Foundation
import CommonCrypto
import SQLite3
import CryptoKit

// Helium (imput's privacy-focused Chromium fork) isn't in yt-dlp's
// `--cookies-from-browser` list, so passing that name upstream fails with
// "unsupported browser". We do the extraction ourselves instead: copy
// Helium's Chromium cookie database, decrypt it with the "Helium Safe
// Storage" login-keychain key, and write a Netscape cookies.txt that
// yt-dlp consumes via `--cookies`. Same v10 crypto as every other
// Chromium browser on macOS (see yt-dlp's MacChromeCookieDecryptor).

/// Shared cookie-flag resolution for every yt-dlp invocation. Native
/// browsers map straight to `--cookies-from-browser`; Helium goes through
/// the exported Netscape file.
struct CookieImport {
    let arguments: [String]
    let profile: String?
    let error: String?
    let temporaryFile: URL?
    func cleanup() { if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) } }
}

enum CookieArgs {
    static func resolve(for url: String, source: CookieSource? = nil, refresh: Bool = false) async -> CookieImport {
        let resolved = source ?? AppSettings.shared.cookieSource(for: url)
        if resolved == .off { return CookieImport(arguments: [], profile: nil, error: nil, temporaryFile: nil) }
        if resolved == .helium {
            let profile = AppSettings.shared.heliumProfile
            let result = await Task.detached(priority: .userInitiated) {
                HeliumCookieBridge.operationExport(profile: profile, maxAge: refresh ? 0 : 30)
            }.value
            return CookieImport(arguments: result.file.map { ["--cookies", $0.path] } ?? [],
                                profile: result.profile, error: result.error, temporaryFile: result.file)
        }
        return CookieImport(arguments: ["--cookies-from-browser", resolved.ytdlpName!],
                            profile: resolved.label, error: nil, temporaryFile: nil)
    }
}

// The project builds with default MainActor isolation; this bridge does
// blocking file/keychain/sqlite work and runs on background tasks.
nonisolated enum HeliumCookieBridge {
    static private(set) var lastError: String?

    /// Test hook — when set, replaces the login-keychain lookup so the
    /// export pipeline can be exercised end-to-end without a real Helium
    /// install. Never set in production code paths.
    nonisolated(unsafe) static var keychainPasswordOverride: String?

    // Chromium os_crypt constants for macOS.
    private static let pbkdfSalt = Data("saltysalt".utf8)
    private static let pbkdfIterations: UInt32 = 1003
    private static let keyLength = 16
    private static let iv = Data(repeating: 0x20, count: 16)  // 16 spaces
    private static let hashPrefixLength = 32                   // SHA-256 prefix, meta version ≥ 24

    private static let dataDirCandidates: [String] = [
        // Helium ships its data under its bundle identifier; older/custom
        // builds may use the display name instead.
        ("~/Library/Application Support/net.imput.helium" as NSString).expandingTildeInPath,
        ("~/Library/Application Support/Helium" as NSString).expandingTildeInPath,
    ]

    struct CacheEntry { let dbMtime: Date; let database: URL; let fingerprint: String; let file: URL; let at: Date }
    private static let exportLock = NSLock()
    struct Profile: Identifiable, Sendable {
        let id: String
        let label: String
        let database: URL
    }
    struct ExportResult: Sendable { let file: URL?; let profile: String?; let error: String? }
    static func profiles(roots: [String]? = nil) -> [Profile] {
        let fm = FileManager.default
        var result: [Profile] = []
        for root in roots ?? dataDirCandidates {
            let rootURL = URL(fileURLWithPath: root)
            guard let children = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { continue }
            let state = (try? Data(contentsOf: rootURL.appendingPathComponent("Local State")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let info = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]
            for child in children where child.lastPathComponent == "Default" || child.lastPathComponent.hasPrefix("Profile ") {
                let candidates = [child.appendingPathComponent("Network/Cookies"), child.appendingPathComponent("Cookies")]
                guard let database = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
                result.append(Profile(id: child.path, label: info?[child.lastPathComponent]?["name"] as? String ?? child.lastPathComponent, database: database))
            }
        }
        return result.sorted { $0.id < $1.id }
    }
    private static func selectedProfile(_ id: String) -> Profile? {
        let available = profiles()
        if !id.isEmpty { return available.first { $0.id == id } }
        for root in dataDirCandidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("Local State")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = (json["profile"] as? [String: Any])?["last_used"] as? String,
                  let match = available.first(where: { $0.id == URL(fileURLWithPath: root).appendingPathComponent(name).path }) else { continue }
            return match
        }
        return available.first
    }
    private static func fingerprint(_ database: URL) -> String {
        [database.path, database.path + "-wal"].map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return "\(path):\(attributes?[.modificationDate] ?? ""):\(attributes?[.size] ?? "")"
        }.joined(separator: "|")
    }
    static func operationExport(profile: String, maxAge: TimeInterval) -> ExportResult {
        exportLock.lock(); defer { exportLock.unlock() }
        let selected = selectedProfile(profile)
        guard let file = exportUnlocked(maxAge: maxAge, selected: selected) else {
            return ExportResult(file: nil, profile: selected?.label, error: lastError)
        }
        let privateFile = file.deletingLastPathComponent().appendingPathComponent("operation-\(UUID().uuidString).txt")
        do {
            try FileManager.default.copyItem(at: file, to: privateFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateFile.path)
            return ExportResult(file: privateFile, profile: selected?.label, error: nil)
        } catch { return ExportResult(file: nil, profile: selected?.label, error: error.localizedDescription) }
    }
    /// SQLite backup includes committed WAL transactions without copying inconsistent sidecars.
    static func snapshot(database: URL, to destination: URL) throws {
        var source: OpaquePointer?, target: OpaquePointer?
        guard sqlite3_open_v2(database.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let source { sqlite3_close(source) }
            throw CookieError.sqlite("Could not open the cookie database.")
        }
        defer { sqlite3_close(source) }
        guard sqlite3_open(destination.path, &target) == SQLITE_OK else {
            if let target { sqlite3_close(target) }
            throw CookieError.sqlite("Could not create the cookie snapshot.")
        }
        defer { sqlite3_close(target) }
        sqlite3_busy_timeout(source, 1500)
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else {
            throw CookieError.sqlite("Could not start the cookie snapshot.")
        }
        var status: Int32 = SQLITE_OK
        for _ in 0..<20 {
            status = sqlite3_backup_step(backup, -1)
            if status == SQLITE_DONE { break }
            if status != SQLITE_BUSY && status != SQLITE_LOCKED { break }
            sqlite3_sleep(50)
        }
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE && finish == SQLITE_OK else { throw CookieError.sqlite("Cookie database is busy. Try refreshing cookies.") }
    }
    private static var cache: CacheEntry?
    private static let cacheLock = NSLock()

    private static func cachedExport(maxAge: TimeInterval, dbMtime: Date, database: URL) -> URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cache,
              Date().timeIntervalSince(cache.at) < maxAge,
              cache.dbMtime == dbMtime, cache.database == database, cache.fingerprint == fingerprint(database),
              FileManager.default.fileExists(atPath: cache.file.path) else { return nil }
        return cache.file
    }

    private static func storeCache(_ entry: CacheEntry) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = entry
    }

    /// Where the Netscape file is written (the catapult-cli.sh wrapper
    /// also picks this path up for `capu` downloads).
    static var exportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base
            .appendingPathComponent("Catapult", isDirectory: true)
            .appendingPathComponent("cookies", isDirectory: true)
            .appendingPathComponent("helium.txt")
    }

    /// Export Helium's cookies to a Netscape-format file. Returns the file
    /// URL, or nil (with `lastError` explaining why). A fresh export is
    /// reused for `maxAge` seconds so the info fetch and the download
    /// don't both pay for the same sqlite copy + keychain round-trip.
    static func exportCookieFile(maxAge: TimeInterval = 30) -> URL? {
        exportLock.lock(); defer { exportLock.unlock() }
        return exportUnlocked(maxAge: maxAge, selected: selectedProfile(""))
    }
    private static func exportUnlocked(maxAge: TimeInterval, selected: Profile?) -> URL? {
        lastError = nil
        let fm = FileManager.default
        guard let selected else {
            lastError = "Helium's cookie database wasn't found — is Helium installed?"
            return nil
        }
        let db = selected.database
        let initialFingerprint = fingerprint(db)
        let mtime = (try? db.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let file = cachedExport(maxAge: maxAge, dbMtime: mtime, database: db) {
            return file
        }

        guard let password = keychainPassword() else {
            lastError = "Couldn't read Helium's encryption key from the login keychain — unlock it or approve access, then retry."
            return nil
        }
        guard let key = deriveKey(password: password) else {
            lastError = "Couldn't derive Helium's cookie decryption key."
            return nil
        }

        // A running browser keeps the cookie database locked — work on a copy.
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("helium-cookies-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn't create a temp folder: \(error.localizedDescription)"
            return nil
        }
        defer { try? fm.removeItem(at: tmp) }

        let dbCopy = tmp.appendingPathComponent("Cookies")
        do {
            try snapshot(database: db, to: dbCopy)
        } catch {
            lastError = "Couldn't copy Helium's cookie database: \(error.localizedDescription)"
            return nil
        }

        let cookies: [NetscapeCookie]
        do {
            cookies = try readCookies(from: dbCopy, key: key)
        } catch {
            lastError = "Couldn't read Helium's cookie database: \(error.localizedDescription)"
            return nil
        }
        if cookies.isEmpty {
            lastError = "Helium had no readable cookies — open Helium and sign in to the site first."
            return nil
        }

        do {
            try writeNetscapeFile(cookies)
        } catch {
            lastError = "Couldn't write the cookie file: \(error.localizedDescription)"
            return nil
        }
        storeCache(CacheEntry(dbMtime: mtime, database: db, fingerprint: initialFingerprint, file: exportURL, at: Date()))
        return exportURL
    }

    // MARK: - Netscape output

    private struct NetscapeCookie {
        let domain: String
        let includeSubdomains: Bool
        let path: String
        let secure: Bool
        let expiry: Int64   // unix seconds; 0 = session cookie
        let name: String
        let value: String
    }

    private static func writeNetscapeFile(_ cookies: [NetscapeCookie]) throws {
        var out = "# Netscape HTTP Cookie File\n"
        out += "# Generated by Catapult from Helium's cookie database. Do not edit.\n"
        for c in cookies {
            let fields = [
                c.domain,
                c.includeSubdomains ? "TRUE" : "FALSE",
                c.path.isEmpty ? "/" : c.path,
                c.secure ? "TRUE" : "FALSE",
                String(c.expiry),
                sanitizeField(c.name),
                sanitizeField(c.value),
            ]
            out += fields.joined(separator: "\t") + "\n"
        }
        try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: exportURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: exportURL.path)
    }

    // Tabs/newlines would corrupt the Netscape record structure.
    private static func sanitizeField(_ s: String) -> String {
        String(s.map { $0 == "\t" || $0 == "\r" || $0 == "\n" ? " " : $0 })
    }

    // MARK: - Database discovery

    // MARK: - Keychain + crypto

    private static func keychainPassword() -> String? {
        if let override = keychainPasswordOverride { return override.isEmpty ? nil : override }
        func query(_ args: [String]) -> (status: Int32, out: String)? {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            t.arguments = args
            let out = Pipe(), err = Pipe()
            t.standardOutput = out
            t.standardError = err
            guard (try? t.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            t.waitUntilExit()
            return (t.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
        // Recent Chromium (and Helium) renamed the keychain service from
        // "<name> Safe Storage" to "<name> Storage Key"; try both.
        for service in ["Helium Storage Key", "Helium Safe Storage"] {
            for args in [
                ["find-generic-password", "-w", "-a", "Helium", "-s", service],
                ["find-generic-password", "-w", "-s", service],
            ] {
                guard let r = query(args), r.status == 0 else { continue }
                var pw = r.out
                while pw.hasSuffix("\n") || pw.hasSuffix("\r") { pw.removeLast() }
                if !pw.isEmpty { return pw }
            }
        }
        return nil
    }

    private static func deriveKey(password: String) -> Data? {
        var key = Data(repeating: 0, count: keyLength)
        let passwordData = Data(password.utf8)
        let salt = pbkdfSalt
        let status = key.withUnsafeMutableBytes { keyPtr in
            passwordData.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        pbkdfIterations,
                        keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return key
    }

    /// Chromium v24 binds each encrypted value to its host with a SHA-256 prefix.
    static func decryptValue(_ encrypted: Data, key: Data, hashPrefixFirst: Bool, domain: String) -> Data? {
        guard encrypted.count > 3 else { return nil }
        let version = String(data: encrypted.prefix(3), encoding: .utf8)
        guard version == "v10" else {
            if version == "v11" || version == "v20" { return nil }
            return encrypted
        }
        guard let cipher = aesCBCDecrypt(Data(encrypted.dropFirst(3)), key: key),
              let plain = pkcs7Unpad(cipher) else { return nil }
        let value: Data
        if hashPrefixFirst {
            let digest = Data(SHA256.hash(data: Data(domain.utf8)))
            guard plain.count >= hashPrefixLength, plain.prefix(hashPrefixLength) == digest else { return nil }
            value = Data(plain.dropFirst(hashPrefixLength))
        } else { value = plain }
        return String(data: value, encoding: .utf8) == nil ? nil : value
    }

    private static func aesCBCDecrypt(_ data: Data, key: Data) -> Data? {
        guard !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else { return nil }
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(0),  // manual PKCS7 so bad padding is detectable
                                keyPtr.baseAddress, keyPtr.count,
                                ivPtr.baseAddress,
                                dataPtr.baseAddress, dataPtr.count,
                                outPtr.baseAddress, outPtr.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        return Data(out.prefix(moved))
    }

    private static func pkcs7Unpad(_ data: Data) -> Data? {
        guard let last = data.last else { return nil }
        let pad = Int(last)
        guard pad >= 1, pad <= 16, pad <= data.count else { return nil }
        guard data.suffix(pad).allSatisfy({ Int($0) == pad }) else { return nil }
        return Data(data.dropLast(pad))
    }

    // MARK: - SQLite reading

    private enum ColumnValue {
        case null
        case int(Int64)
        case bytes(Data)

        var stringValue: String? {
            switch self {
            case .bytes(let d): return String(data: d, encoding: .utf8)
                        ?? String(decoding: d, as: UTF8.self)
            case .int(let i):   return String(i)
            case .null:         return nil
            }
        }
        var intValue: Int64? {
            if case .int(let i) = self { return i }
            return nil
        }
        var bytesValue: Data? {
            if case .bytes(let d) = self { return d }
            return nil
        }
    }

    private enum CookieError: LocalizedError {
        case sqlite(String)
        var errorDescription: String? {
            if case .sqlite(let m) = self { return m }
            return nil
        }
    }

    private static func withDatabase(_ url: URL, _ body: (OpaquePointer?) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "couldn't open database"
            sqlite3_close(db)
            throw CookieError.sqlite(msg)
        }
        defer { sqlite3_close(db) }
        try body(db)
    }

    private static func rows(_ db: OpaquePointer?, _ sql: String) throws -> [[ColumnValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CookieError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [[ColumnValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [ColumnValue] = []
            for i in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_BLOB, SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(stmt, i))
                    if let ptr = sqlite3_column_blob(stmt, i), count > 0 {
                        row.append(.bytes(Data(bytes: ptr, count: count)))
                    } else {
                        row.append(.bytes(Data()))
                    }
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(stmt, i)))
                default:
                    row.append(.null)
                }
            }
            out.append(row)
        }
        return out
    }

    private static func readCookies(from dbURL: URL, key: Data) throws -> [NetscapeCookie] {
        var result: [NetscapeCookie] = []
        try withDatabase(dbURL) { db in
            // Newer Chromium stores the secure flag as `is_secure`; older as `secure`.
            let secureColumn: String? = try {
                let info = try rows(db, "PRAGMA table_info(cookies)")
                let names = info.compactMap { $0.count > 1 ? $0[1].stringValue : nil }
                if names.contains("is_secure") { return "is_secure" }
                if names.contains("secure")    { return "secure" }
                return nil
            }()
            let selectSQL = secureColumn.map {
                "SELECT host_key, name, value, encrypted_value, path, expires_utc, \($0) FROM cookies"
            } ?? "SELECT host_key, name, value, encrypted_value, path, expires_utc FROM cookies"

            let meta = try rows(db, "SELECT value FROM meta WHERE key = 'version'")
            let metaVersion = meta.first?.first?.intValue ?? 0
            let hashPrefixFirst = metaVersion >= 24

            let table = try rows(db, selectSQL)
            for row in table {
                guard row.count >= 6 else { continue }
                let domain = row[0].stringValue ?? ""
                let name = row[1].stringValue ?? ""
                guard !domain.isEmpty, !name.isEmpty else { continue }
                let plainValue = row[2].stringValue
                let expiry = unixSeconds(fromChromiumMicros: row[5].intValue ?? 0)
                let secure = row.count >= 7 && (row[6].intValue ?? 0) != 0

                let value: String?
                if let v = plainValue, !v.isEmpty {
                    value = v
                } else if let enc = row[3].bytesValue, !enc.isEmpty {
                    guard let dec = decryptValue(enc, key: key, hashPrefixFirst: hashPrefixFirst, domain: domain) else {
                        continue
                    }
                    value = String(decoding: dec, as: UTF8.self)
                } else {
                    continue
                }
                result.append(NetscapeCookie(
                    domain: domain,
                    includeSubdomains: domain.hasPrefix("."),
                    path: row[4].stringValue ?? "/",
                    secure: secure,
                    expiry: expiry,
                    name: name,
                    value: value ?? ""))
            }
        }
        return result
    }

    /// Chromium stores expiry as microseconds since 1601-01-01; Netscape
    /// files want unix seconds (0 = session cookie).
    private static func unixSeconds(fromChromiumMicros micros: Int64) -> Int64 {
        guard micros > 0 else { return 0 }
        let unix = micros / 1_000_000 - 11_644_473_600
        return unix > 0 ? unix : 0
    }
}
