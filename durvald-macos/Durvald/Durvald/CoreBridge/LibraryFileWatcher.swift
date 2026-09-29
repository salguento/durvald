import CoreServices
import Foundation

/// Thin FSEvents owner. Event interpretation, debounce and scans belong to the store.
final class LibraryFileWatcher: @unchecked Sendable {
    struct Event: @unchecked Sendable {
        let path: String
        let flags: FSEventStreamEventFlags

        var requiresReconnect: Bool {
            has(kFSEventStreamEventFlagRootChanged)
                || has(kFSEventStreamEventFlagMount)
                || has(kFSEventStreamEventFlagUnmount)
        }

        var requiresFullRescan: Bool {
            has(kFSEventStreamEventFlagMustScanSubDirs)
                || has(kFSEventStreamEventFlagUserDropped)
                || has(kFSEventStreamEventFlagKernelDropped)
                || has(kFSEventStreamEventFlagEventIdsWrapped)
        }

        var affectsLibraryContent: Bool {
            has(kFSEventStreamEventFlagItemCreated)
                || has(kFSEventStreamEventFlagItemRemoved)
                || has(kFSEventStreamEventFlagItemRenamed)
                || has(kFSEventStreamEventFlagItemModified)
                || has(kFSEventStreamEventFlagItemInodeMetaMod)
                || has(kFSEventStreamEventFlagItemFinderInfoMod)
                || has(kFSEventStreamEventFlagItemChangeOwner)
                || has(kFSEventStreamEventFlagItemXattrMod)
        }

        var isDirectory: Bool {
            has(kFSEventStreamEventFlagItemIsDir)
        }

        private func has(_ flag: Int) -> Bool {
            flags & FSEventStreamEventFlags(flag) != 0
        }
    }

    private var stream: FSEventStreamRef?
    private let onEvents: @Sendable ([Event]) -> Void

    init(paths: [String], onEvents: @escaping @Sendable ([Event]) -> Void) {
        self.onEvents = onEvents
        start(paths: paths)
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func start(paths: [String]) {
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<LibraryFileWatcher>
                .fromOpaque(info)
                .takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>
                .fromOpaque(rawPaths)
                .takeUnretainedValue()
            let eventPaths = cfPaths as? [String] ?? []
            let events = (0..<min(count, eventPaths.count)).map { index in
                Event(path: eventPaths[index], flags: flags[index])
            }
            watcher.onEvents(events)
        }

        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            createFlags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(
            stream,
            DispatchQueue(label: "com.durvald.library-fsevents", qos: .utility)
        )
        if !FSEventStreamStart(stream) {
            stop()
        }
    }
}
