import Foundation

/// Small file-system reads shared by the scanner, the hasher and the holding store.
enum FileFacts {
    /// What the scanner asks for each entry, fetched in one batch by the enumerator.
    static let scanKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isReadableKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey,
        .ubiquitousItemDownloadingStatusKey,
    ]

    /// What `lstat` says about a path. `lstat` rather than `stat`, so a symlink is seen as a
    /// symlink and never followed.
    struct Status {
        let identity: FileIdentity
        let isRegularFile: Bool
        /// The content isn't on the device (an evicted iCloud or file-provider file). Reading it
        /// would download it.
        let isDataless: Bool
    }

    /// `SF_DATALESS` from sys/stat.h, spelled out so it doesn't depend on the header exporting it.
    private static let datalessFlag: UInt32 = 0x4000_0000

    static func status(of url: URL) -> Status? {
        guard case .present(let status) = presence(of: url) else { return nil }
        return status
    }

    /// Whether something is at a path, keeping "isn't there" apart from "couldn't tell".
    enum Presence {
        case present(Status)
        /// The system said so: no such file, or a part of the path isn't a folder.
        case missing
        /// Any other failure, such as permission denied, an I/O error on a drive or a share that
        /// timed out. The file may well be there, so nothing may be dropped or deleted on this.
        case unknown
    }

    static func presence(of url: URL) -> Presence {
        var info = stat()
        let failure: Int32? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            return lstat(path, &info) == 0 ? nil : errno
        }
        switch failure {
        case nil:
            return .present(Status(
                identity: FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino)),
                isRegularFile: (info.st_mode & S_IFMT) == S_IFREG,
                isDataless: (info.st_flags & datalessFlag) != 0
            ))
        case ENOENT, ENOTDIR:
            return .missing
        default:
            return .unknown
        }
    }

    /// True only when the system said nothing is at the path (even a broken symlink counts
    /// as something), so a failure to look never passes for "gone".
    static func isMissing(_ url: URL) -> Bool {
        if case .missing = presence(of: url) { return true }
        return false
    }

    /// True when the folder can actually be opened right now. A folder whose security scope
    /// isn't open can look empty instead of failing, and "empty" must never be taken to mean
    /// "the user deleted everything".
    static func canList(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let folder = opendir(path) else { return false }
            closedir(folder)
            return true
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path(of: url), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Why the file can't be read right now, or nil when its content is on the device and
    /// reading it can't start a download. Checked again just before hashing, because iOS can
    /// evict a file after the scan.
    static func reasonNotToRead(_ url: URL) -> FileSkipReason? {
        guard let status = status(of: url), status.isRegularFile else { return .unreadable }
        if status.isDataless { return .iCloudOnly }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let downloading = values?.ubiquitousItemDownloadingStatus, downloading != .current { return .iCloudOnly }
        return nil
    }

    /// Runs `body` with this thread barred from fetching anything that isn't on the device:
    /// the content of an evicted file, or the listing of a folder never opened here.
    ///
    /// Checks made beforehand can go stale (iOS can evict a file between the check and the
    /// read), so with this rule such a read fails, and the file is left out, instead of quietly
    /// starting a download. The rule belongs to the thread, so `body` must not suspend.
    static func withoutDownloads<T>(_ body: () throws -> T) rethrows -> T {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            let restore = previous >= 0 ? previous : IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT
            _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, restore)
        }
        return try body()
    }

    /// The part of `allocated` that only this file uses, which is what deleting it gives back.
    ///
    /// APFS clones (what the Files app's Duplicate, and most apps' "save a copy", make) share
    /// their blocks until one is edited, so deleting one gives back next to nothing. Asking for
    /// the private size costs the file system work, so it's asked only for a file APFS has
    /// flagged as maybe sharing. A file that may share, on a volume that can't say how much,
    /// counts as giving back nothing: an honest zero beats a promise the disk won't keep.
    static func unsharedBytes(of url: URL, allocated: Int64) -> Int64 {
        guard let flags = extendedAttribute(UInt32(ATTR_CMNEXT_EXT_FLAGS), of: url),
              flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 else { return allocated }
        guard let unshared = extendedAttribute(UInt32(ATTR_CMNEXT_PRIVATESIZE), of: url) else { return 0 }
        return min(Int64(clamping: unshared), allocated)
    }

    /// One 64-bit `ATTR_CMNEXT_*` value from `getattrlist`, or nil when the volume doesn't
    /// return it. Symlinks aren't followed.
    private static func extendedAttribute(_ attribute: UInt32, of url: URL) -> UInt64? {
        // Layout: total length (4 bytes), the set of attributes returned (5 × 4 bytes), then
        // the value. With FSOPT_PACK_INVAL_ATTRS the value's slot is there even when it isn't.
        let returnedOffset = 4
        let valueOffset = 4 + MemoryLayout<attribute_set_t>.size
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(attribute)
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS)
        var buffer = [UInt8](repeating: 0, count: valueOffset + 8)
        let ok = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, options) == 0 }
        }
        guard ok else { return nil }
        return buffer.withUnsafeBytes { raw in
            let returned = raw.loadUnaligned(fromByteOffset: returnedOffset, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(attribute) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: valueOffset, as: UInt64.self)
        }
    }

    /// Length and modification date read fresh from disk, to tell whether a file changed since
    /// it was scanned.
    static func lengthAndDate(of url: URL) -> (length: Int64, modified: Date)? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let length = values.fileSize else { return nil }
        return (Int64(length), values.contentModificationDate ?? .distantPast)
    }

    /// The name the Files app shows, such as "On My iPhone" for a folder whose name on disk is
    /// something else. Falls back to the name on disk when the folder can't be asked.
    static func displayName(of url: URL) -> String {
        let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
        return name ?? url.lastPathComponent
    }

    /// The plain POSIX path, without a trailing slash.
    static func path(of url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path(percentEncoded: false)
    }

    /// The real path with every symlink resolved, such as /private/var for /var. Paths built
    /// from it compare equal however the folder was reached.
    static func canonical(_ url: URL) -> URL {
        let resolved: String? = url.withUnsafeFileSystemRepresentation { path in
            guard let path, let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        }
        guard let resolved else { return url.standardized }
        return URL(fileURLWithPath: resolved, isDirectory: isDirectory(URL(fileURLWithPath: resolved)))
    }

    /// The canonical folder plus the file's own name. The name itself isn't resolved, so a
    /// symlink stays a symlink instead of turning into its target.
    static func canonicalFile(_ url: URL) -> URL {
        canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent, isDirectory: false)
    }

    /// The path components of `url` below `root`, or nil when it isn't inside. Both must
    /// already be canonical. (`standardizedFileURL` would drop "/private" only from paths that
    /// exist, so a vanished file would seem to be outside its folder.)
    static func components(of url: URL, under root: URL) -> [String]? {
        let rootParts = root.standardized.pathComponents
        let parts = url.standardized.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
        return Array(parts.dropFirst(rootParts.count))
    }

    /// `relative` under `root`, refusing anything that could climb out of it.
    static func url(_ relative: String, under root: URL) -> URL? {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }
}
