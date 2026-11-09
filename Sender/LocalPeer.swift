import Darwin
import Foundation

/// Who is at the other end of a connection made on this Mac, to a port only this Mac can reach.
///
/// Tandem's camera switcher serves pictures to its own camera extension on such a port. macOS
/// runs camera extensions as a user of their own, so nothing run by the person using this Mac is
/// ever the extension; and unlike that user's processes, this user's can be looked into, to see
/// which of them holds a connection. So one of them at the other end is some other app, after
/// the camera without having been allowed it, and is turned away.
///
/// What this can't tell apart from the extension: processes of other users (root's, or someone
/// else logged in to this Mac), which can't be looked into.
enum LocalPeer {
    /// The process of this user holding the TCP connection from `port` on this Mac to `serverPort`
    /// on this Mac, if one does. Takes a few milliseconds: it looks through every process.
    static func process(connectedFrom port: UInt16, to serverPort: UInt16) -> pid_t? {
        var pids = [pid_t](repeating: 0, count: 16384)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return nil }
        for pid in pids.prefix(count) where pid > 0 && holds(pid, from: port, to: serverPort) { return pid }
        return nil
    }

    static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "process \(pid)"
    }

    private static func holds(_ pid: pid_t, from port: UInt16, to serverPort: UInt16) -> Bool {
        // Fails, with nothing listed, for processes of other users.
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard used > 0 else { return false }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let length = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            // Ports are kept in network byte order, in the low half of an Int32.
            let tcp = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_lport))
            let remote = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_fport))
            if local == port && remote == serverPort { return true }
        }
        return false
    }
}
