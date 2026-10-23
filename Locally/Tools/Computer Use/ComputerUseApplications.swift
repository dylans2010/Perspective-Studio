import Foundation
#if os(macOS)
#if canImport(AppKit)
import AppKit
#endif
#endif

/// A running application, as reported by NSWorkspace.
public struct ComputerUseAppInfo: Codable, Sendable {
    public var pid: Int32
    public var name: String
    public var bundleIdentifier: String?
    public var isActive: Bool
    public var isHidden: Bool

    public var summary: String {
        let bundle = bundleIdentifier ?? "no bundle id"
        return "\(name) (pid \(pid), \(bundle))\(isActive ? " [frontmost]" : "")\(isHidden ? " [hidden]" : "")"
    }

    public var jsonObject: [String: Any] {
        var dict: [String: Any] = [
            "pid": Int(pid), "name": name, "isActive": isActive, "isHidden": isHidden
        ]
        if let bundleIdentifier { dict["bundleIdentifier"] = bundleIdentifier }
        return dict
    }
}

/// Application control via NSWorkspace / NSRunningApplication.
///
/// Launching resolves an *installed* application (by bundle id through
/// NSWorkspace, or by name through the standard Applications folders)
/// — paths are never invented: an app that cannot be found is a
/// structured `notFound`, and a launch that macOS refuses is a
/// structured failure, never a reported success.
public enum ComputerUseApplications {

    #if os(macOS) && canImport(AppKit)
    private static func info(for app: NSRunningApplication) -> ComputerUseAppInfo {
        ComputerUseAppInfo(
            pid: app.processIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            bundleIdentifier: app.bundleIdentifier,
            isActive: app.isActive,
            isHidden: app.isHidden
        )
    }

    /// All running regular/accessory applications.
    public static func listRunning() async -> [ComputerUseAppInfo] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
                .map { info(for: $0) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// The frontmost application, if any.
    public static func frontmost() async -> ComputerUseAppInfo? {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map { info(for: $0) }
        }
    }

    /// Resolves a running app from exactly one identifier style.
    public static func resolveRunning(bundleIdentifier: String?, name: String?, pid: Int32?) async throws -> (app: NSRunningApplication, info: ComputerUseAppInfo) {
        let running = await MainActor.run { NSWorkspace.shared.runningApplications }
        if let pid {
            guard let app = running.first(where: { $0.processIdentifier == pid }) else {
                throw ComputerUseError.notFound("running application with pid \(pid)")
            }
            return (app, info(for: app))
        }
        if let bundleIdentifier {
            let matches = running.filter { $0.bundleIdentifier == bundleIdentifier }
            guard let app = matches.first else {
                throw ComputerUseError.notFound("running application with bundle identifier \(bundleIdentifier). Use computer_list_applications to see what is running, or computer_open_application to launch it.")
            }
            return (app, info(for: app))
        }
        if let name {
            let matches = running.filter { ($0.localizedName ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame }
            if matches.count > 1 {
                throw ComputerUseError.ambiguous(
                    "\(matches.count) running applications are named \"\(name)\"",
                    candidates: matches.map { info(for: $0).summary }
                )
            }
            guard let app = matches.first else {
                throw ComputerUseError.notFound("running application named \"\(name)\". Use computer_list_applications to see what is running.")
            }
            return (app, info(for: app))
        }
        throw ComputerUseError.invalidArgument("Provide one of bundleId, name or pid to identify the application.")
    }

    /// Finds an installed application's URL without inventing a path.
    public static func installedApplicationURL(bundleIdentifier: String?, name: String?) -> URL? {
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        guard let name else { return nil }
        let fm = FileManager.default
        let searchDirs = [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
            fm.homeDirectoryForCurrentUser.appending(path: "Applications").path
        ]
        let wanted = name.lowercased().hasSuffix(".app") ? name.lowercased() : name.lowercased() + ".app"
        for dir in searchDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let match = entries.first(where: { $0.lowercased() == wanted }) {
                return URL(fileURLWithPath: dir).appending(path: match)
            }
        }
        return nil
    }

    /// Launches (or activates, if already running) an application and
    /// verifies the outcome by observing NSWorkspace afterwards.
    public static func open(bundleIdentifier: String?, name: String?) async throws -> (info: ComputerUseAppInfo, wasAlreadyRunning: Bool) {
        // Already running? Activating is the honest "open".
        if bundleIdentifier != nil || name != nil {
            if let existing = try? await resolveRunning(bundleIdentifier: bundleIdentifier, name: name, pid: nil) {
                _ = existing.app.activate(options: [.activateAllWindows])
                // Give activation a moment, then verify frontmost state.
                try await Task.sleep(for: .milliseconds(300))
                let refreshed = await frontmost()
                var result = existing.info
                if let refreshed, refreshed.pid == result.pid { result.isActive = true }
                return (result, true)
            }
        }
        guard let url = installedApplicationURL(bundleIdentifier: bundleIdentifier, name: name) else {
            throw ComputerUseError.notFound("installed application for \(bundleIdentifier ?? name ?? "?"). Check the bundle identifier / name spelling; Locally only launches applications that are actually installed.")
        }
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return (info(for: app), false)
        } catch {
            throw ComputerUseError.executionFailed("NSWorkspace could not launch \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Activates a running application and verifies it became frontmost.
    public static func activate(bundleIdentifier: String?, name: String?, pid: Int32?) async throws -> (info: ComputerUseAppInfo, verifiedFrontmost: Bool) {
        let resolved = try await resolveRunning(bundleIdentifier: bundleIdentifier, name: name, pid: pid)
        let accepted = resolved.app.activate(options: [.activateAllWindows])
        guard accepted else {
            throw ComputerUseError.executionFailed("macOS refused to activate \(resolved.info.name).")
        }
        try await Task.sleep(for: .milliseconds(300))
        let front = await frontmost()
        var result = resolved.info
        let verified = front?.pid == result.pid
        if verified { result.isActive = true }
        return (result, verified)
    }

    /// Asks an application to terminate gracefully and observes the
    /// outcome. Never force-terminates: if the app is still alive
    /// after a short grace period it is reported as still running
    /// (typically an unsaved-work or confirmation dialog that belongs
    /// to the user), with `terminated == false`.
    public static func close(bundleIdentifier: String?, name: String?, pid: Int32?) async -> (info: ComputerUseAppInfo, terminated: Bool) {
        guard let resolved = try? await resolveRunning(bundleIdentifier: bundleIdentifier, name: name, pid: pid) else {
            // Nothing running with that identity: closing is a no-op
            // failure the caller turns into a notFound result.
            return (ComputerUseAppInfo(pid: pid ?? -1, name: name ?? bundleIdentifier ?? "unknown", bundleIdentifier: bundleIdentifier, isActive: false, isHidden: false), false)
        }
        let accepted = resolved.app.terminate()
        if !accepted { return (resolved.info, false) }
        for _ in 0..<10 {
            if resolved.app.isTerminated { return (resolved.info, true) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return (resolved.info, resolved.app.isTerminated)
    }
    #else
    public static func listRunning() async -> [ComputerUseAppInfo] { [] }
    public static func frontmost() async -> ComputerUseAppInfo? { nil }
    public static func resolveRunning(bundleIdentifier: String?, name: String?, pid: Int32?) async throws -> (app: Any, info: ComputerUseAppInfo) {
        throw ComputerUseError.platformUnavailable
    }
    public static func installedApplicationURL(bundleIdentifier: String?, name: String?) -> URL? { nil }
    public static func open(bundleIdentifier: String?, name: String?) async throws -> (info: ComputerUseAppInfo, wasAlreadyRunning: Bool) {
        throw ComputerUseError.platformUnavailable
    }
    public static func activate(bundleIdentifier: String?, name: String?, pid: Int32?) async throws -> (info: ComputerUseAppInfo, verifiedFrontmost: Bool) {
        throw ComputerUseError.platformUnavailable
    }
    public static func close(bundleIdentifier: String?, name: String?, pid: Int32?) async -> (info: ComputerUseAppInfo, terminated: Bool) {
        (ComputerUseAppInfo(pid: pid ?? -1, name: name ?? bundleIdentifier ?? "unknown", bundleIdentifier: bundleIdentifier, isActive: false, isHidden: false), false)
    }
    #endif
}
