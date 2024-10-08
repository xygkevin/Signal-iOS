//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

@objc
public extension OWSFileSystem {
    class func fileOrFolderExists(atPath filePath: String) -> Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    class func fileOrFolderExists(url: URL) -> Bool {
        fileOrFolderExists(atPath: url.path)
    }

    class func fileExistsAndIsNotDirectory(atPath filePath: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: filePath, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    class func fileExistsAndIsNotDirectory(url: URL) -> Bool {
        fileExistsAndIsNotDirectory(atPath: url.path)
    }

    @discardableResult
    class func deleteFile(_ filePath: String) -> Bool {
        deleteFile(filePath, ignoreIfMissing: false)
    }

    @discardableResult
    class func deleteFileIfExists(_ filePath: String) -> Bool {
        return deleteFile(filePath, ignoreIfMissing: true)
    }

    class func deleteFile(url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    class func deleteFileIfExists(url: URL) throws {
        do {
            try deleteFile(url: url)
        } catch POSIXError.ENOENT, CocoaError.fileNoSuchFile {
            // this is fine
        }
    }

    class func moveFile(from fromUrl: URL, to toUrl: URL) throws {
        guard FileManager.default.fileExists(atPath: fromUrl.path) else {
            throw OWSAssertionError("Source file does not exist.")
        }
        guard !FileManager.default.fileExists(atPath: toUrl.path) else {
            throw OWSAssertionError("Destination file already exists.")
        }
        try FileManager.default.moveItem(at: fromUrl, to: toUrl)

        // Ensure all files moved have the proper data protection class.
        // On large directories this can take a while, so we dispatch async
        // since we're in the launch path.
        DispatchQueue.global().async {
            self.protectRecursiveContents(atPath: toUrl.path)
        }

        #if TESTABLE_BUILD
        guard !FileManager.default.fileExists(atPath: fromUrl.path) else {
            throw OWSAssertionError("Source file does not exist.")
        }
        guard FileManager.default.fileExists(atPath: toUrl.path) else {
            throw OWSAssertionError("Destination file already exists.")
        }
        #endif
    }

    class func copyFile(from fromUrl: URL, to toUrl: URL) throws {
        guard FileManager.default.fileExists(atPath: fromUrl.path) else {
            throw OWSAssertionError("Source file does not exist.")
        }
        guard !FileManager.default.fileExists(atPath: toUrl.path) else {
            throw OWSAssertionError("Destination file already exists.")
        }
        try FileManager.default.copyItem(at: fromUrl, to: toUrl)

        // Ensure all files copied have the proper data protection class.
        // On large directories this can take a while, so we dispatch async
        // since we're in the launch path.
        DispatchQueue.global().async {
            self.protectRecursiveContents(atPath: toUrl.path)
        }

        #if TESTABLE_BUILD
        guard FileManager.default.fileExists(atPath: toUrl.path) else {
            throw OWSAssertionError("Destination file not created.")
        }
        #endif
    }

    class func recursiveFilesInDirectory(_ dirPath: String) throws -> [String] {
        owsAssertDebug(!dirPath.isEmpty)

        do {
            return try FileManager.default.subpathsOfDirectory(atPath: dirPath)
                .map { (dirPath as NSString).appendingPathComponent($0) }
                .filter {
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                    return !isDirectory.boolValue
                }

        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }
}

// MARK: - Temporary Files

@objc
public extension OWSFileSystem {

    class func temporaryFileUrl(
        fileExtension: String? = nil,
        isAvailableWhileDeviceLocked: Bool = false
    ) -> URL {
        return URL(fileURLWithPath: temporaryFilePath(
            fileName: nil,
            fileExtension: fileExtension,
            isAvailableWhileDeviceLocked: isAvailableWhileDeviceLocked
        ))
    }

    class func temporaryFileUrl(
        fileName: String,
        fileExtension: String? = nil,
        isAvailableWhileDeviceLocked: Bool = false
    ) -> URL {
        return URL(fileURLWithPath: temporaryFilePath(
            fileName: fileName,
            fileExtension: fileExtension,
            isAvailableWhileDeviceLocked: isAvailableWhileDeviceLocked
        ))
    }

    class func temporaryFilePath(
        fileName: String? = nil,
        fileExtension: String? = nil
    ) -> String {
        temporaryFilePath(
            fileName: fileName,
            fileExtension: fileExtension,
            isAvailableWhileDeviceLocked: false
        )
    }

    class func temporaryFilePath(
        fileName: String? = nil,
        fileExtension: String? = nil,
        isAvailableWhileDeviceLocked: Bool = false
    ) -> String {
        let tempDirPath = tempDirPath(availableWhileDeviceLocked: isAvailableWhileDeviceLocked)
        var fileName = fileName ?? UUID().uuidString
        if let fileExtension = fileExtension,
            !fileExtension.isEmpty {
            fileName = String(format: "\(fileName).\(fileExtension)")
        }
        let filePath = (tempDirPath as NSString).appendingPathComponent(fileName)
        return filePath
    }

    private class func tempDirPath(availableWhileDeviceLocked: Bool) -> String {
        return availableWhileDeviceLocked
            ? OWSTemporaryDirectoryAccessibleAfterFirstAuth()
            : OWSTemporaryDirectory()
    }
}

// MARK: -

public extension OWSFileSystem {
    @objc
    class func deleteFile(_ filePath: String, ignoreIfMissing: Bool = false) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: filePath)
            return true
        } catch POSIXError.ENOENT where ignoreIfMissing, CocoaError.fileNoSuchFile where ignoreIfMissing {
            // Ignore "No such file or directory" error.
            return true
        } catch CocoaError.fileWriteNoPermission {
            let attemptedUrl = URL(fileURLWithPath: filePath)
            let knownNoWritePermissionUrls = [
                OWSFileSystem.appSharedDataDirectoryURL().appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            ]
            owsAssertDebug(knownNoWritePermissionUrls.contains(attemptedUrl))
            return false
        } catch {
            owsFailDebug("\(error.shortDescription)")
            return false
        }
    }
}

// MARK: - Remaining space

public extension OWSFileSystem {
    /// Get the remaining free space for a path's volume in bytes.
    ///
    /// See [Apple's example][0]. It checks "important" storage (versus "opportunistic" storage).
    ///
    /// [0]: https://developer.apple.com/documentation/foundation/nsurlresourcekey/checking_volume_storage_capacity
    class func freeSpaceInBytes(forPath path: URL) throws -> UInt64 {
        let resourceValues = try path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let result = resourceValues.volumeAvailableCapacityForImportantUsage else {
            throw OWSGenericError("Could not determine remaining disk space")
        }
        return UInt64(result)
    }
}

// MARK: - Creating Partial files

public extension OWSFileSystem {
    class func createTempFileSlice(url: URL, start: Int) throws -> (URL, Int) {
        // Resuming, slice attachment data in memory.
        let dataSliceFileUrl = OWSFileSystem.temporaryFileUrl(isAvailableWhileDeviceLocked: true)

        // TODO: It'd be better if we could slice on disk.
        let entireFileData = try Data(contentsOf: url)
        let dataSlice = entireFileData.suffix(from: start)
        let dataSliceLength = dataSlice.count
        guard dataSliceLength + start == entireFileData.count else {
            throw OWSAssertionError("Could not slice the data.")
        }

        // Write the slice to a temporary file.
        try dataSlice.write(to: dataSliceFileUrl)

        return (dataSliceFileUrl, dataSliceLength)
    }
}
