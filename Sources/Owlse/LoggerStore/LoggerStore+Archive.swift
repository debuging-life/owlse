// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import Foundation
import CoreData

extension LoggerStore {
    /// Opens a log store for viewing, accepting both supported layouts:
    ///
    /// - A store **package** (directory) — opened in place, read-only.
    /// - An exported **archive** (flat file, the default `.owlse` share
    ///   format) — unpacked into a temporary package first.
    ///
    /// When the returned store's ``storeURL`` differs from `url`, it points
    /// to a temporary unpacked copy; remove it after ``close()`` to reclaim
    /// disk space.
    public static func openForViewing(at url: URL) throws -> LoggerStore {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LoggerStore.Error.fileDoesntExist
        }
        if isDirectory.boolValue {
            return try LoggerStore(storeURL: url, options: [.readonly])
        }
        return try unpackArchive(at: url)
    }

    /// Unpacks an archive (see `_exportPackageAsArchive`) into a temporary
    /// store package and opens it read-only.
    private static func unpackArchive(at url: URL) throws -> LoggerStore {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.github.kean.owlse-viewer", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).owlse", isDirectory: true)
        let blobsURL = packageURL.appendingPathComponent(blobsDirectoryName, isDirectory: true)
        try Files.createDirectory(at: blobsURL, withIntermediateDirectories: true)

        // The document is opened with write access (sqlite journaling), so
        // work on a copy — the original may live in a read-only location.
        let temporary = TemporaryDirectory()
        defer { temporary.remove() }
        let copyURL = temporary.url.appendingPathComponent(url.lastPathComponent)
        try Files.copyItem(at: url, to: copyURL)

        let document = try OwlseDocument(documentURL: copyURL)
        defer { try? document.close() }

        var storeId = UUID()
        try document.context.performAndReturn {
            let request = NSFetchRequest<OwlseBlobEntity>(entityName: "\(OwlseBlobEntity.self)")
            var didFindDatabase = false
            for blob in try document.context.fetch(request) {
                switch blob.key {
                case "database":
                    try blob.data.decompressed()
                        .write(to: packageURL.appendingPathComponent(databaseFilename))
                    didFindDatabase = true
                case "info":
                    if let info = try? JSONDecoder().decode(LoggerStore.Info.self, from: blob.data) {
                        storeId = info.storeId
                    }
                default:
                    try blob.data.write(to: blobsURL.appendingPathComponent(blob.key))
                }
            }
            guard didFindDatabase else {
                throw LoggerStore.Error.storeInvalid
            }
        }

        let manifest = Manifest(storeId: storeId, version: .currentStoreVersion)
        try JSONEncoder().encode(manifest)
            .write(to: packageURL.appendingPathComponent(manifestFilename))

        return try LoggerStore(storeURL: packageURL, options: [.readonly])
    }
}
