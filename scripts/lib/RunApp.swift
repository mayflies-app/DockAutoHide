// Development CLI: inspect, launch and stop an explicitly supplied, validated .app.
import AppKit
import Darwin

func processExists(_ pid: pid_t) -> Bool {
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno != ESRCH // Permission or observation errors do not prove exit.
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct Request {
    enum Operation { case inspect, stop, launch }
    let operation: Operation
    let path: String
    let verify: Bool
    let arguments: [String]

    init(_ input: [String]) throws {
        guard input.count >= 2, ["--inspect", "--stop", "--launch"].contains(input[0]) else {
            throw Failure("Usage: RunApp --inspect <absolute-app-path> | --stop <absolute-app-path> | --launch <absolute-app-path> [--verify] [-- <app args...>]")
        }
        operation = input[0] == "--inspect" ? .inspect : input[0] == "--stop" ? .stop : .launch
        path = input[1]
        guard (path as NSString).isAbsolutePath else { throw Failure("App path must be absolute.") }
        var remaining = Array(input.dropFirst(2))
        var shouldVerify = false
        if operation == .launch, remaining.first == "--verify" {
            shouldVerify = true
            remaining.removeFirst()
        }
        if operation == .launch, remaining.first == "--" {
            remaining.removeFirst()
            arguments = remaining
        } else {
            guard remaining.isEmpty else { throw Failure("Unknown or invalid CLI arguments. App arguments must follow --.") }
            arguments = []
        }
        verify = shouldVerify
    }
}

func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

struct Application {
    let url: URL
    let executable: URL
    let identifier: String

    init(path: String) throws {
        url = canonical(URL(fileURLWithPath: path))
        var directory: ObjCBool = false
        guard url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw Failure("Expected an existing .app directory: \(path)")
        }
        guard let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let id = bundle.bundleIdentifier, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let executableURL = bundle.executableURL else {
            throw Failure("App must have an APPL Info.plist, bundle identifier and executable: \(url.path)")
        }
        identifier = id
        executable = canonical(executableURL)
        var executableIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &executableIsDirectory),
              !executableIsDirectory.boolValue, FileManager.default.isExecutableFile(atPath: executable.path),
              executable.path.hasPrefix(url.appendingPathComponent("Contents/MacOS").path + "/") else {
            throw Failure("App executable is missing, not executable or outside Contents/MacOS: \(executable.path)")
        }
    }

    var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == identifier && !$0.isTerminated && processExists($0.processIdentifier)
        }
    }

    func matches(_ process: NSRunningApplication) -> Bool {
        process.bundleIdentifier == identifier &&
        process.bundleURL.map { canonical($0).path } == url.path &&
        process.executableURL.map { canonical($0).path } == executable.path
    }

    func stop() throws {
        let processes = running
        guard !processes.contains(where: { !matches($0) }) else {
            throw Failure("Another running app has bundle identifier \(identifier) at a different or unverified path. Quit that app manually, then retry. No termination was requested.")
        }
        for process in processes {
            guard process.terminate() else {
                throw Failure("Termination request refused for pid=\(process.processIdentifier). Quit this app manually; no force termination was attempted.")
            }
        }
        let deadline = Date().addingTimeInterval(10)
        // AppKit can retain isTerminated=false after the process has exited.
        // Observe only the exact PIDs captured before normal termination.
        while processes.contains(where: { processExists($0.processIdentifier) }) && Date() < deadline { pump() }
        guard processes.allSatisfy({ !processExists($0.processIdentifier) }) else {
            throw Failure("App did not exit within 10 seconds (termination may have been cancelled). Quit it manually, then retry; no force termination was attempted.")
        }
        print("stopped count=\(processes.count) bundle=\(url.path)")
    }

    func inspect() throws {
        let processes = running
        guard processes.allSatisfy(matches) else {
            throw Failure("Another running app has bundle identifier \(identifier) at a different or unverified path. No action was requested.")
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "runningCount": processes.count, "pids": processes.map(\.processIdentifier),
            "bundle": url.path, "executable": executable.path,
        ], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    func launch(arguments: [String], verify: Bool) throws {
        guard running.isEmpty else {
            throw Failure("An app with bundle identifier \(identifier) is already running. Stop the matching app first or quit a different installation manually. No launch was requested.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = arguments
        var completed = false
        var returnedProcess: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { process, error in
            returnedProcess = process
            launchError = error
            completed = true
        }
        let deadline = Date().addingTimeInterval(15)
        while !completed && Date() < deadline { pump() }
        guard completed else { throw Failure("Launch did not complete within 15 seconds. Inspect the specified app manually before retrying.") }
        if let error = launchError { throw Failure("Launch failed: \(error.localizedDescription)") }
        guard let process = returnedProcess, process.processIdentifier > 0,
              matches(process), !process.isTerminated else {
            throw Failure("Launch did not return a live process matching the exact app and executable URLs.")
        }
        if verify {
            let verificationDeadline = Date().addingTimeInterval(2)
            while Date() < verificationDeadline {
                guard !process.isTerminated, matches(process) else {
                    throw Failure("Launched app exited or changed identity during the 2-second process verification.")
                }
                pump()
            }
        }
        guard !process.isTerminated, matches(process) else {
            throw Failure("Launched app is no longer a live matching process.")
        }
        print("launched pid=\(process.processIdentifier) bundle=\(url.path) executable=\(executable.path) verification=\(verify ? "process-alive-2s-only" : "process-start-only") (UI not verified)")
    }
}

func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

do {
    let request = try Request(Array(CommandLine.arguments.dropFirst()))
    let app = try Application(path: request.path)
    switch request.operation {
    case .inspect: try app.inspect()
    case .stop: try app.stop()
    case .launch: try app.launch(arguments: request.arguments, verify: request.verify)
    }
} catch {
    FileHandle.standardError.write(Data("RunApp: \(error)\n".utf8))
    exit(1)
}
