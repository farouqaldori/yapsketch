import AppKit
import Darwin

/// A lock held during capture lets the bar query the state. macOS releases it if the app crashes.
final class RecordingState {
    private static let lockFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/com.yapsketch.app/recording.lock")
    private static let changed = Notification.Name("com.yapsketch.recordingStateChanged")
    private var descriptor: Int32 = -1

    static var isRecording: Bool {
        let fd = open(lockFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        return fcntl(fd, F_GETLK, &lock) == 0 && lock.l_type == Int16(F_WRLCK)
    }

    func publish(_ recording: Bool) {
        if recording {
            do {
                try FileManager.default.createDirectory(at: Self.lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fd = open(Self.lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard fd >= 0 else {
                    Log.info("couldn't open recording state lock: errno \(errno)")
                    return
                }
                var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
                guard fcntl(fd, F_SETLK, &lock) == 0 else {
                    let error = errno
                    close(fd)
                    Log.info("couldn't acquire recording state lock: errno \(error)")
                    return
                }
                descriptor = fd
            } catch {
                Log.info("couldn't create recording state directory: \(error.localizedDescription)")
                return
            }
        } else {
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.changed, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}
