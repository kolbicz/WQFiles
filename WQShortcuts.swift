//
//  WQShortcuts.swift
//  WQ Files
//
//  The Shortcuts actions. App Intents exist in Swift only, so this is the one
//  Swift file of the app: it declares the actions and their parameters and
//  hands the work to WQShortcuts.h (Objective-C), which runs the same code as
//  the app's own file actions and applies the same rules.
//
//  build.sh compiles it with swiftc and writes Metadata.appintents into the
//  app; without that folder the Shortcuts app lists no actions.
//
//  GPL-3.0-or-later.
//

import AppIntents
import Foundation

// What an action shows when it fails: the same text the app would show.
struct WQShortcutFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

// File work blocks (it waits for the app's I/O queue): keep it off Swift's
// cooperative threads.
private func wqRun(_ work: @escaping () -> WQShortcutResult) async throws -> WQShortcutResult {
    let result: WQShortcutResult = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
    guard result.ok else { throw WQShortcutFailure(message: result.message ?? "Failed") }
    return result
}

struct WQListFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "List Folder"
    static let description = IntentDescription("Gives the paths of everything in a folder, in any app's container.",
                                               categoryName: "Files")
    static let openAppWhenRun = false

    @Parameter(title: "Folder", description: "The full path of the folder.")
    var folder: String

    static var parameterSummary: some ParameterSummary { Summary("List \(\.$folder)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let folder = self.folder
        let result = try await wqRun { wq_shortcut_list(folder) }
        return .result(value: result.paths ?? [])
    }
}

struct WQGetFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Get File"
    static let description = IntentDescription("Gives a file from any app's container to the next action.",
                                               categoryName: "Files")
    static let openAppWhenRun = false

    @Parameter(title: "File", description: "The full path of the file.")
    var path: String

    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$path)") }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let path = self.path
        let result = try await wqRun { wq_shortcut_export(path) }
        let url = URL(fileURLWithPath: result.path ?? "")
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent))
    }
}

struct WQSaveFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Save File"
    static let description = IntentDescription(
        "Saves a file into a folder of any app's container. Without Replace, a file of the same name is kept and the new one gets a number. Needs Allow Shortcuts to Change Files in WQ Files' settings.",
        categoryName: "Files")
    static let openAppWhenRun = false

    @Parameter(title: "File")
    var file: IntentFile

    @Parameter(title: "Folder", description: "The full path of the folder to save into.")
    var folder: String

    @Parameter(title: "Name", description: "Leave empty to keep the file's name.")
    var name: String?

    @Parameter(title: "Replace Existing", description: "The file from before is kept in WQ Files' Backups.", default: false)
    var replace: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$file) in \(\.$folder)") {
            \.$name
            \.$replace
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let wanted = (name?.isEmpty == false ? name! : file.filename)
        // The shortcut's file as a file of WQ Files' own first (swept at launch).
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("wq-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let local = staging.appendingPathComponent("file")
        try file.data.write(to: local)
        let folder = self.folder, replace = self.replace, localPath = local.path
        let result = try await wqRun { wq_shortcut_save(localPath, folder, wanted, replace) }
        return .result(value: result.path ?? "")
    }
}

struct WQCopyIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy File or Folder"
    static let description = IntentDescription(
        "Copies a file or folder into another folder, also between apps. A name that is taken is kept and the copy gets a number. Needs Allow Shortcuts to Change Files in WQ Files' settings.",
        categoryName: "Files")
    static let openAppWhenRun = false

    @Parameter(title: "Item", description: "The full path of the file or folder.")
    var path: String

    @Parameter(title: "To Folder", description: "The full path of the folder to copy into.")
    var folder: String

    static var parameterSummary: some ParameterSummary { Summary("Copy \(\.$path) to \(\.$folder)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let path = self.path, folder = self.folder
        let result = try await wqRun { wq_shortcut_copy(path, folder) }
        return .result(value: result.path ?? "")
    }
}

struct WQMoveIntent: AppIntent {
    static let title: LocalizedStringResource = "Move File or Folder"
    static let description = IntentDescription(
        "Moves a file or folder into another folder. Nothing is replaced: if the name is taken there, the move is refused. Needs Allow Shortcuts to Change Files in WQ Files' settings.",
        categoryName: "Files")
    static let openAppWhenRun = false

    @Parameter(title: "Item", description: "The full path of the file or folder.")
    var path: String

    @Parameter(title: "To Folder", description: "The full path of the folder to move into.")
    var folder: String

    static var parameterSummary: some ParameterSummary { Summary("Move \(\.$path) to \(\.$folder)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let path = self.path, folder = self.folder
        let result = try await wqRun { wq_shortcut_move(path, folder) }
        return .result(value: result.path ?? "")
    }
}

struct WQRenameIntent: AppIntent {
    static let title: LocalizedStringResource = "Rename File or Folder"
    static let description = IntentDescription(
        "Gives a file or folder a new name. Needs Allow Shortcuts to Change Files in WQ Files' settings.",
        categoryName: "Files")
    static let openAppWhenRun = false

    @Parameter(title: "Item", description: "The full path of the file or folder.")
    var path: String

    @Parameter(title: "New Name")
    var name: String

    static var parameterSummary: some ParameterSummary { Summary("Rename \(\.$path) to \(\.$name)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let path = self.path, name = self.name
        let result = try await wqRun { wq_shortcut_rename(path, name) }
        return .result(value: result.path ?? "")
    }
}

struct WQNewFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "New Folder"
    static let description = IntentDescription(
        "Makes a folder inside a folder. Needs Allow Shortcuts to Change Files in WQ Files' settings.",
        categoryName: "Files")
    static let openAppWhenRun = false

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "In Folder", description: "The full path of the folder to make it in.")
    var folder: String

    static var parameterSummary: some ParameterSummary { Summary("New folder \(\.$name) in \(\.$folder)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let name = self.name, folder = self.folder
        let result = try await wqRun { wq_shortcut_new_folder(folder, name) }
        return .result(value: result.path ?? "")
    }
}

struct WQDeleteIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete File or Folder"
    static let description = IntentDescription(
        "Deletes a file or a folder with everything in it. Files are kept in WQ Files' Recently Deleted first. Needs Allow Shortcuts to Change Files and Allow Deleting in WQ Files.",
        categoryName: "Files")
    static let openAppWhenRun = false

    @Parameter(title: "Item", description: "The full path of the file or folder.")
    var path: String

    static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$path)") }

    func perform() async throws -> some IntentResult {
        let path = self.path
        _ = try await wqRun { wq_shortcut_delete(path) }
        return .result()
    }
}

struct WQCleanCachesIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean App Caches"
    static let description = IntentDescription(
        "Clears Library/Caches and tmp of one app, like the Cache Cleaner, and gives the number of bytes freed. Needs Allow Shortcuts to Change Files and Allow Deleting in WQ Files.",
        categoryName: "Apps")
    static let openAppWhenRun = false

    @Parameter(title: "App", description: "The app's bundle identifier, for example com.example.app.")
    var bundleID: String

    static var parameterSummary: some ParameterSummary { Summary("Clean the caches of \(\.$bundleID)") }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let bundleID = self.bundleID
        let result = try await wqRun { wq_shortcut_clean_caches(bundleID) }
        return .result(value: Int(clamping: result.bytes))
    }
}

struct WQBackUpAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Back Up App Data"
    static let description = IntentDescription(
        "Backs up an app's Documents and Library like Apps → Back Up, and gives the backup's folder. Restoring stays in WQ Files. Needs Allow Shortcuts to Change Files in WQ Files' settings.",
        categoryName: "Apps")
    static let openAppWhenRun = false

    @Parameter(title: "App", description: "The app's bundle identifier, for example com.example.app.")
    var bundleID: String

    static var parameterSummary: some ParameterSummary { Summary("Back up \(\.$bundleID)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let bundleID = self.bundleID
        let result = try await wqRun { wq_shortcut_backup_app(bundleID) }
        return .result(value: result.path ?? "")
    }
}
