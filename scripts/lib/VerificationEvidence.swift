import Foundation
import CryptoKit
import Darwin
import CoreFoundation

// A standalone recorder for a fixture command. Provenance is observed, never inferred.
struct RecorderError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
let fm = FileManager.default
func canonical(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() }
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var digest = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func observedSkips(in url: URL, stream: String) throws -> [[String: Any]] {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    let regex = try NSRegularExpression(pattern: "^\\s*SKIP(?=[:\\s])")
    var pending = Data(); var lineNumber = 0; var found: [[String: Any]] = []
    func consume(_ data: Data) {
        lineNumber += 1
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            found.append(["stream": stream, "lineNumber": lineNumber, "text": line])
        }
    }
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 10) {
            consume(pending.prefix(upTo: newline)); pending.removeSubrange(...newline)
        }
    }
    if !pending.isEmpty { consume(pending) }
    return found
}
func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }
func isDirectory(_ url: URL) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue }
func runReadOnly(_ argv: [String], repo: URL? = nil) throws -> Data {
    let p = Process(); p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = Array(argv.dropFirst()); p.currentDirectoryURL = repo
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw RecorderError("Observation command failed: \(argv[0]) \(argv.dropFirst().joined(separator: " "))") }
    return data
}
func sourceSnapshot(_ repo: URL, excluding output: URL) throws -> [String: Any] {
    let excluded = output.path.hasPrefix(repo.path + "/") ? String(output.path.dropFirst(repo.path.count + 1)) : nil
    let pathspec = ["--", "."] + (excluded.map { [":(exclude,literal)" + $0] } ?? [])
    func git(_ args: [String]) throws -> Data { try runReadOnly(["/usr/bin/git", "-C", repo.path] + args) }
    let inside = String(decoding: try git(["rev-parse", "--is-inside-work-tree"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard inside == "true" else { throw RecorderError("repo must be a Git work tree") }
    let head = String(decoding: try git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let status = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all"] + pathspec)
    let diff = try git(["diff", "HEAD", "--binary", "--no-ext-diff", "--no-textconv"] + pathspec)
    let names = try git(["ls-files", "--others", "--exclude-standard", "-z"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { name in excluded.map { name != $0 && !name.hasPrefix($0 + "/") } ?? true }.sorted()
    var untracked: [[String: String]] = []
    for name in names {
        let url = repo.appendingPathComponent(name)
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let type = attrs[.type] as? FileAttributeType
        let digest: String
        if type == .typeSymbolicLink { digest = hash(Data(try fm.destinationOfSymbolicLink(atPath: url.path).utf8)) }
        else if type == .typeRegular { digest = try hashFile(url) }
        else { throw RecorderError("Unsupported untracked entry: \(name)") }
        untracked.append(["path": name, "sha256": digest, "kind": type == .typeSymbolicLink ? "symlink-target" : "file"])
    }
    let components: [String: Any] = ["head": head, "trackedDiffSHA256": hash(diff), "statusSHA256": hash(status), "untracked": untracked]
    let fingerprint = hash(try JSONSerialization.data(withJSONObject: components, options: [.sortedKeys]))
    return ["repo": repo.path, "head": head, "dirty": !status.isEmpty, "trackedDiffSHA256": hash(diff), "untracked": untracked, "fingerprintSHA256": fingerprint, "excludedDirectories": excluded.map { [$0] } ?? [], "observation": "run-time-working-tree; ignored files excluded"]
}
func artifactSnapshot(_ app: URL) throws -> [String: Any] {
    guard app.pathExtension == "app", isDirectory(app) else { throw RecorderError("app must be an existing .app directory") }
    let info = canonical(app.appendingPathComponent("Contents/Info.plist").path)
    guard info.path.hasPrefix(app.path + "/") else { throw RecorderError("Info.plist must resolve within bundle") }
    let raw = try Data(contentsOf: info)
    guard let dict = try PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any],
          dict["CFBundlePackageType"] as? String == "APPL",
          let executable = dict["CFBundleExecutable"] as? String, !executable.isEmpty,
          !executable.contains("/"), executable != ".", executable != "..",
          let identifier = dict["CFBundleIdentifier"] as? String, !identifier.isEmpty else { throw RecorderError("app requires APPL, bundle identifier and executable metadata") }
    let bin = canonical(app.appendingPathComponent("Contents/MacOS/\(executable)").path)
    guard bin.path.hasPrefix(app.path + "/"), fm.isExecutableFile(atPath: bin.path),
          try fm.attributesOfItem(atPath: bin.path)[.type] as? FileAttributeType == .typeRegular else { throw RecorderError("bundle executable must be a contained executable regular file") }
    var entries: [[String: String]] = []
    // Build paths from relative entry names. URL enumeration may normalize /var to
    // /private/var; slicing an absolute item path by app.path.count is not valid.
    func captureDirectory(_ relativeDirectory: String) throws {
        let directory = relativeDirectory.isEmpty ? app : app.appendingPathComponent(relativeDirectory)
        for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
            let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
            let item = app.appendingPathComponent(relative)
            let attrs = try fm.attributesOfItem(atPath: item.path)
            let type = attrs[.type] as? FileAttributeType
            if type == .typeRegular { entries.append(["path": relative, "sha256": try hashFile(item), "kind": "file"]) }
            else if type == .typeSymbolicLink { entries.append(["path": relative, "target": try fm.destinationOfSymbolicLink(atPath: item.path), "kind": "symlink"]) }
            else if type == .typeDirectory { try captureDirectory(relative) }
            else { throw RecorderError("Unsupported bundle entry: \(relative)") }
        }
    }
    try captureDirectory("")
    entries.sort { $0["path"]! < $1["path"]! }
    let bundleHash = hash(try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]))
    return ["bundleEntries": entries, "bundleFingerprintSHA256": bundleHash, "app": app.path, "executable": bin.path, "identifier": identifier, "executableSHA256": try hashFile(bin), "infoPlistSHA256": hash(raw), "observation": "run-time-artifact; build origin unknown"]
}
func environmentSnapshot() -> [String: Any] {
    func read(_ a: [String]) -> String { guard let d = try? runReadOnly(a) else { return "unknown" }; let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); return s.isEmpty ? "unknown" : s }
    return ["macOS": read(["/usr/bin/sw_vers", "-productVersion"]), "macOSBuild": read(["/usr/bin/sw_vers", "-buildVersion"]), "architecture": read(["/usr/bin/uname", "-m"]), "swiftVersion": read(["/usr/bin/xcrun", "swift", "--version"]), "swiftPath": read(["/usr/bin/xcrun", "--find", "swift"]), "developerDirectory": read(["/usr/bin/xcode-select", "-p"])]
}
struct Options {
    var project = ""; var repo = ""; var app = ""; var output = ""; var report: String?; var field: String?; var expectedID: String?; var cleanupField: String?; var localizationCleanup = false; var timeout = 300.0; var terminationGrace = 2.0; var command: [String] = []
}
func parse(_ args: [String]) throws -> Options {
    var o = Options(); var seen = Set<String>(); var i = 0
    while i < args.count {
        let key = args[i]
        if key == "--" { o.command = Array(args.dropFirst(i + 1)); break }
        guard ["--project", "--repo", "--app", "--output", "--report", "--success-field", "--expected-bundle-id", "--cleanup-field", "--localization-cleanup", "--timeout-seconds", "--termination-grace-seconds"].contains(key) else { throw RecorderError("Unknown argument: \(key)") }
        guard !seen.contains(key) else { throw RecorderError("Duplicate argument: \(key)") }; seen.insert(key)
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--"), !args[i + 1].isEmpty else { throw RecorderError("Missing value: \(key)") }
        let value = args[i + 1]
        switch key {
        case "--project": o.project = value
        case "--repo": o.repo = value
        case "--app": o.app = value
        case "--output": o.output = value
        case "--report": o.report = value
        case "--success-field": o.field = value
        case "--expected-bundle-id": o.expectedID = value
        case "--cleanup-field": o.cleanupField = value
        case "--localization-cleanup": guard value == "true" else { throw RecorderError("localization cleanup requires true") }; o.localizationCleanup = true
        case "--timeout-seconds": guard let n = Double(value), n.isFinite, n > 0, n <= 86400 else { throw RecorderError("timeout must be finite and in (0, 86400]") }; o.timeout = n
        case "--termination-grace-seconds": guard let n = Double(value), n.isFinite, n > 0, n <= 120 else { throw RecorderError("termination grace must be finite and in (0, 120]") }; o.terminationGrace = n
        default: break
        }
        i += 2
    }
    guard !o.project.isEmpty, !o.repo.isEmpty, !o.app.isEmpty, !o.output.isEmpty else { throw RecorderError("Required: --project --repo --app --output") }
    guard !o.command.isEmpty, !o.command[0].isEmpty else { throw RecorderError("Required: -- COMMAND [ARGS...]") }
    guard (o.report == nil) == (o.field == nil) else { throw RecorderError("--report and --success-field must be paired") }
    if let field = o.field, !["passed", "success"].contains(field) { throw RecorderError("success field must be passed or success") }
    guard o.cleanupField == nil || o.report != nil else { throw RecorderError("--cleanup-field requires --report") }
    guard !o.localizationCleanup || o.expectedID != nil else { throw RecorderError("--localization-cleanup requires --expected-bundle-id") }
    for p in [o.repo, o.app, o.output] + [o.report].compactMap({ $0 }) { guard p.hasPrefix("/") else { throw RecorderError("All data paths must be absolute") } }
    return o
}
func trustedOutput(_ originalArgs: [String]) -> URL? {
    let rawArgs = Array(originalArgs.prefix { $0 != "--" })
    let indices = rawArgs.indices.filter { rawArgs[$0] == "--output" }
    guard indices.count == 1, let index = indices.first, index + 1 < rawArgs.count else { return nil }
    let path = rawArgs[index + 1]
    guard path.hasPrefix("/"), !path.isEmpty else { return nil }
    let url = canonical(path)
    if let index = rawArgs.firstIndex(of: "--app"), index + 1 < rawArgs.count {
        let app = canonical(rawArgs[index + 1]); if url == app || url.path.hasPrefix(app.path + "/") { return nil }
    }
    if let index = rawArgs.firstIndex(of: "--repo"), index + 1 < rawArgs.count {
        let git = canonical(rawArgs[index + 1]).appendingPathComponent(".git"); if url == git || url.path.hasPrefix(git.path + "/") { return nil }
    }
    guard url.path != "/", url.path != "/private/tmp", url.path != fm.homeDirectoryForCurrentUser.path else { return nil }
    if fm.fileExists(atPath: url.path) {
        guard isDirectory(url), let contents = try? fm.contentsOfDirectory(atPath: url.path), contents.isEmpty, fm.isWritableFile(atPath: url.path) else { return nil }
    } else {
        // Only a new leaf under a real, writable parent is trustworthy.
        let parent = url.deletingLastPathComponent()
        guard isDirectory(parent), fm.isWritableFile(atPath: parent.path) else { return nil }
    }
    return url
}
func commandExecutable(_ argument: String, repo: URL) throws -> URL {
    let candidates: [URL]
    if argument.contains("/") { candidates = [argument.hasPrefix("/") ? canonical(argument) : canonical(repo.appendingPathComponent(argument).path)] }
    else { candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map { canonical(String($0) + "/" + argument) } }
    guard let executable = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) && !isDirectory($0) }) else { throw RecorderError("Command is not executable: \(argument)") }
    return executable
}
func atomicManifest(_ manifest: [String: Any], at output: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
}
let args = Array(CommandLine.arguments.dropFirst())
var output = trustedOutput(args)
var manifest: [String: Any] = ["schemaVersion": 1, "runID": UUID().uuidString, "startedAt": isoNow(), "status": "failed", "provenance": ["kind": "run-time-observation", "artifactBuiltFromSource": "unknown"], "scope": "input-validation", "errors": [String](), "command": ["argv": [String](), "started": false]]
var exitStatus: Int32 = 1
var outputReserved = false
// These resources are reserved before the verifier starts, rather than learned
// from a report that may never be written after a timeout or interruption.
struct LocalizationFixture {
    let suite: String
    let directory: URL
    let progress: URL
    func cleanup() -> [String: Any] {
        let domain = suite as CFString
        // A fresh preferences client avoids this recorder's cache writing an
        // empty domain back after cleanup. Delete only the reserved test suite.
        let deletion = Process(); let deletionError = Pipe()
        deletion.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        deletion.arguments = ["delete", suite]
        deletion.standardOutput = FileHandle.nullDevice; deletion.standardError = deletionError
        var deletionStatus: Int32 = -1; var deletionMessage = ""; var synchronized = false
        do {
            try deletion.run()
            let deadline = Date().addingTimeInterval(5)
            while deletion.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if deletion.isRunning {
                deletion.terminate()
                let grace = Date().addingTimeInterval(1)
                while deletion.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if deletion.isRunning { kill(deletion.processIdentifier, SIGKILL) }
            }
            deletion.waitUntilExit()
            deletionMessage = String(decoding: deletionError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            deletionStatus = deletion.terminationStatus
            synchronized = deletion.terminationReason == .exit && deletionStatus == 0
        } catch { deletionMessage = String(describing: error) }
        let empty = (CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []).isEmpty
        // The fixture may already have removed the domain on normal exit.
        let domainNotFound = deletionStatus == 1 && deletionMessage == "Error: Domain '\(suite)' not found.\nDefaults have not been changed.\n"
        if domainNotFound && empty { synchronized = true }
        let preferencesFile = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist")
        var errors: [String] = []
        if !synchronized || !empty { errors.append("Isolated preferences cleanup failed") }
        // CFPreferences may retain an empty plist after removing the domain.
        // The suite was reserved empty before launch and the child has exited.
        // Remove only its exact regular file; never follow a preference symlink.
        if synchronized && empty {
            do {
                var metadata = stat()
                let observed = preferencesFile.path.withCString { Darwin.lstat($0, &metadata) }
                if observed == 0 {
                    guard metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == getuid() else { throw RecorderError("Isolated preferences file is not an owned regular file") }
                    try fm.removeItem(at: preferencesFile)
                } else if errno != ENOENT { throw RecorderError("Cannot observe isolated preferences file") }
            } catch { errors.append("Isolated preferences file cleanup failed: \(error)") }
        }
        var preferenceMetadata = stat()
        let preferenceObserved = preferencesFile.path.withCString { Darwin.lstat($0, &preferenceMetadata) }
        let preferenceFileAbsent = preferenceObserved == -1 && errno == ENOENT
        if !preferenceFileAbsent { errors.append("Isolated preferences file absence not established") }
        do { if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) } }
        catch { errors.append("Isolated data cleanup failed: \(error)") }
        var metadata = stat()
        let observed = directory.path.withCString { Darwin.lstat($0, &metadata) }
        let absent = observed == -1 && errno == ENOENT
        if !absent { errors.append("Isolated data directory absence not established") }
        return ["suite": suite, "directory": directory.path, "progress": progress.path,
                "deletionExitCode": deletionStatus, "deletionError": deletionMessage,
                "preferencesEmpty": empty, "preferencesSynchronized": synchronized, "preferencesFileAbsent": preferenceFileAbsent,
                "directoryAbsent": absent, "passed": errors.isEmpty, "errors": errors]
    }
}
var localizationFixture: LocalizationFixture?
// Forward cancellation to the owned verifier, allowing its bounded restoration.
// The recorder never looks up, terminates or kills an application process.
var cancellationSignal: Int32 = 0
signal(SIGINT) { cancellationSignal = $0 }
signal(SIGTERM) { cancellationSignal = $0 }
// Reserve a leaf once; never read or replace a previous run's manifest/logs.
func reserveOutput(_ url: URL) throws {
    if !fm.fileExists(atPath: url.path) { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
    let lock = url.appendingPathComponent(".run-reservation")
    let fd = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { throw RecorderError("Run directory already reserved") }; close(fd)
    outputReserved = true
}
do {
    let options = try parse(args)
    manifest["project"] = options.project
    manifest["command"] = ["argv": options.command, "started": false]
    guard let out = output else { throw RecorderError("Output must be a new directory or existing empty writable directory") }
    // Reserve before potentially expensive observation; no child has been started.
    try reserveOutput(out)
    let repo = canonical(options.repo); let app = canonical(options.app)
    guard isDirectory(repo) else { throw RecorderError("repo must exist") }
    guard !out.path.hasPrefix(app.path + "/"), out != app, !out.path.hasPrefix(repo.path + "/.git/"), out.path != repo.path + "/.git" else { throw RecorderError("Output cannot be inside app or Git metadata") }
    let executable = try commandExecutable(options.command[0], repo: repo)
    var reportURL: URL?
    if let report = options.report {
        let url = canonical(report)
        guard !fm.fileExists(atPath: url.path), !["manifest.json", "stdout.log", "stderr.log", ".run-reservation"].contains(url.lastPathComponent), isDirectory(url.deletingLastPathComponent()), fm.isWritableFile(atPath: url.deletingLastPathComponent().path) else { throw RecorderError("Report must be a fresh path with an existing writable parent and no reserved basename") }
        guard !url.path.hasPrefix(app.path + "/"), !url.path.hasPrefix(repo.path + "/.git/") else { throw RecorderError("Report cannot be inside app or Git metadata") }
        reportURL = url
    }
    let sourceBefore = try sourceSnapshot(repo, excluding: out); let artifactBefore = try artifactSnapshot(app)
    if let expected = options.expectedID, artifactBefore["identifier"] as? String != expected { throw RecorderError("Bundle identifier does not match expected ID") }
    if options.localizationCleanup {
        guard options.expectedID!.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { throw RecorderError("Localization bundle identifier must be a safe preferences namespace") }
        let suite = options.expectedID! + ".localization-test." + hash(Data(out.path.utf8))
        guard (CFPreferencesCopyKeyList(suite as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []).isEmpty else { throw RecorderError("Isolated preferences suite already contains data; refusing reuse") }
        let directory = out.appendingPathComponent("fixture-data")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        localizationFixture = LocalizationFixture(suite: suite, directory: directory, progress: out.appendingPathComponent("localization-progress.json"))
    }
    manifest["expectedBundleIdentifier"] = options.expectedID ?? "unspecified"
    manifest["project"] = options.project; manifest["sourceBefore"] = sourceBefore; manifest["artifactBefore"] = artifactBefore
    manifest["environment"] = environmentSnapshot(); manifest["scope"] = reportURL == nil ? "exit-code-only; no UI acceptance claim" : "command-exit-and-report-bool; report semantics supplied by caller"
    var command: [String: Any] = ["argv": options.command, "resolvedExecutable": executable.path, "currentDirectory": repo.path, "started": false, "timeoutSeconds": options.timeout, "terminationGraceSeconds": options.terminationGrace, "timeoutMechanism": "SIGTERM child PID only; after configured grace SIGKILL same PID only; no process group or app lookup"]
    if let reportURL { manifest["report"] = ["path": reportURL.path, "successField": options.field!, "status": "pending"] }
    let stdoutURL = out.appendingPathComponent("stdout.log"); let stderrURL = out.appendingPathComponent("stderr.log")
    guard fm.createFile(atPath: stdoutURL.path, contents: nil), fm.createFile(atPath: stderrURL.path, contents: nil) else { throw RecorderError("Cannot create log files") }
    let stdout = try FileHandle(forWritingTo: stdoutURL); let stderr = try FileHandle(forWritingTo: stderrURL)
    defer { try? stdout.close(); try? stderr.close() }
    let process = Process(); process.executableURL = executable; process.arguments = Array(options.command.dropFirst()); process.currentDirectoryURL = repo; process.standardOutput = stdout; process.standardError = stderr
    if let fixture = localizationFixture {
        var environment = ProcessInfo.processInfo.environment
        environment["MACOS_LOCALIZATION_TEST_SUITE"] = fixture.suite
        environment["MACOS_LOCALIZATION_TEST_DIRECTORY"] = fixture.directory.path
        environment["MACOS_LOCALIZATION_TEST_PROGRESS"] = fixture.progress.path
        process.environment = environment
        manifest["localizationFixture"] = ["suite": fixture.suite, "directory": fixture.directory.path, "progress": fixture.progress.path, "cleanup": "pending"]
    }
    manifest["command"] = command
    try atomicManifest(manifest, at: out)
    try process.run(); command["started"] = true; command["pid"] = process.processIdentifier; command["startedAt"] = isoNow()
    let deadline = Date().addingTimeInterval(options.timeout); var timedOut = false; var interrupted = false
    while process.isRunning {
        if Date() >= deadline || cancellationSignal != 0 {
            timedOut = Date() >= deadline; interrupted = cancellationSignal != 0
            process.terminate()
            let grace = Date().addingTimeInterval(options.terminationGrace)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            break
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    process.waitUntilExit(); try stdout.synchronize(); try stderr.synchronize()
    command["exitCode"] = process.terminationStatus; command["terminationReason"] = process.terminationReason == .exit ? "exit" : "uncaughtSignal"; command["timedOut"] = timedOut; command["interrupted"] = interrupted; command["endedAt"] = isoNow()
    manifest["command"] = command
    let skips = try observedSkips(in: stdoutURL, stream: "stdout") + observedSkips(in: stderrURL, stream: "stderr")
    manifest["observedSkips"] = skips
    manifest["evidenceQualifications"] = skips.isEmpty ? [] : ["Command emitted SKIP lines; skipped checks are not established as passed"]
    manifest["logs"] = ["stdout": ["path": stdoutURL.path, "sha256": try hashFile(stdoutURL)], "stderr": ["path": stderrURL.path, "sha256": try hashFile(stderrURL)]]
    var errors: [String] = []
    if let fixture = localizationFixture {
        let cleanup = fixture.cleanup(); manifest["localizationFixture"] = cleanup
        localizationFixture = nil
        if !(cleanup["passed"] as? Bool ?? false) { errors.append("Localization fixture cleanup failed") }
    }
    var changed = false
    do { let after = try sourceSnapshot(repo, excluding: out); manifest["sourceAfter"] = after; if after["fingerprintSHA256"] as? String != sourceBefore["fingerprintSHA256"] as? String { changed = true; errors.append("Source changed during command") } }
    catch { changed = true; errors.append("Source after observation failed: \(error)") }
    do { let after = try artifactSnapshot(app); manifest["artifactAfter"] = after; if NSDictionary(dictionary: after) != NSDictionary(dictionary: artifactBefore) { changed = true; errors.append("Artifact changed during command") } }
    catch { changed = true; errors.append("Artifact after observation failed: \(error)") }
    if process.terminationStatus != 0 || process.terminationReason != .exit { errors.append("Child command failed") }
    if timedOut { errors.append("Child command timed out") }
    if interrupted { errors.append("Child command interrupted") }
    if let reportURL {
        var report: [String: Any] = ["path": reportURL.path, "successField": options.field!, "status": "failed"]
        do {
            let data = try Data(contentsOf: reportURL); report["sha256"] = hash(data)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = json[options.field!] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue else { throw RecorderError("Report must contain boolean \(options.field!) = true") }
            if let field = options.cleanupField {
                guard let path = json[field] as? String, path.hasPrefix("/"), path != "/" else { throw RecorderError("Cleanup field must contain an absolute fixture directory") }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                var metadata = stat()
                let observed = url.path.withCString { Darwin.lstat($0, &metadata) }
                let observationErrno = observed == 0 ? 0 : errno
                let absent = observed == -1 && observationErrno == ENOENT
                let state = observed == 0 ? "present" : absent ? "absent" : "unknown"
                report["cleanupObservation"] = ["field": field, "path": url.path, "state": state, "absent": state == "unknown" ? NSNull() : absent as Any, "errno": observationErrno, "method": "lstat; only ENOENT establishes absence", "action": "check-only; no deletion"]
                if state == "unknown" { throw RecorderError("Cleanup path observation unavailable: errno \(observationErrno) (\(String(cString: strerror(observationErrno))))") }
                guard absent else { throw RecorderError("Declared fixture directory still exists") }
            }
            report["status"] = "passed"
        } catch { errors.append("Report invalid: \(error)") }
        manifest["report"] = report
    }
    manifest["errors"] = errors
    manifest["status"] = (process.terminationStatus != 0 || process.terminationReason != .exit || timedOut || interrupted) ? "failed" : changed ? "invalidated" : errors.isEmpty ? "passed" : "failed"
    exitStatus = errors.isEmpty ? 0 : 1
} catch {
    var errors = manifest["errors"] as? [String] ?? []; errors.append(String(describing: error)); manifest["errors"] = errors
    FileHandle.standardError.write(Data("VerificationEvidence: \(error)\n".utf8))
}
if let fixture = localizationFixture {
    let cleanup = fixture.cleanup(); manifest["localizationFixture"] = cleanup
    if !(cleanup["passed"] as? Bool ?? false) {
        var errors = manifest["errors"] as? [String] ?? []; errors.append("Localization fixture cleanup failed"); manifest["errors"] = errors
    }
    // This path is only reached before launch or after the owned child exited.
    manifest["status"] = "failed"; exitStatus = 1
}
manifest["endedAt"] = isoNow()
if let out = output {
    do {
        if !outputReserved { try reserveOutput(out) }
        try atomicManifest(manifest, at: out)
    } catch { FileHandle.standardError.write(Data("Cannot save manifest: \(error)\n".utf8)); exitStatus = 1 }
}
exit(exitStatus)
