import Darwin
import Foundation

/// Thin wrappers over libproc and sysctl. Everything here is a direct kernel query:
/// no subprocesses, no `lsof`, no `ps`. That is what keeps a scan in the low milliseconds.
public enum LibProc {
    public struct ShortInfo: Sendable {
        public let pid: pid_t
        public let ppid: pid_t
        public let pgid: pid_t
        public let uid: uid_t
        public let comm: String
    }

    public struct Arguments: Sendable {
        public let executable: String
        public let argv: [String]
        public let environment: [String]
    }

    public struct Usage: Sendable {
        /// User plus system CPU time, in nanoseconds.
        public let cpuNanos: UInt64
        /// Physical footprint, the number Activity Monitor shows as "Memory".
        public let footprint: UInt64
    }

    // MARK: Process lists

    /// PIDs owned by the current user. Other users' processes cannot be inspected or signalled anyway.
    public static func userPids() -> [pid_t] {
        let uid = getuid()
        var capacity = 1024
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBytes { buf in
                proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), buf.baseAddress, Int32(buf.count))
            }
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / MemoryLayout<pid_t>.stride
            if count < capacity {
                return pids.prefix(count).filter { $0 > 0 }
            }
            capacity *= 2
        }
    }

    public static func shortInfo(_ pid: pid_t) -> ShortInfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        let comm = withUnsafeBytes(of: &info.pbsi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return ShortInfo(pid: pid, ppid: pid_t(info.pbsi_ppid), pgid: pid_t(info.pbsi_pgid), uid: info.pbsi_uid, comm: comm)
    }

    /// Process start time as a wall clock date.
    public static func startDate(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    // MARK: Sockets

    /// TCP sockets in LISTEN state held by `pid`.
    public static func listeningSockets(_ pid: pid_t) -> [PortBinding] {
        SocketLister().listeningSockets(pid)
    }

    /// Lists listening sockets with one reusable fd buffer, so a full scan does not allocate per process.
    public final class SocketLister {
        private var capacity = 2048
        private var buffer: UnsafeMutablePointer<proc_fdinfo>
        private var socketInfo = socket_fdinfo()

        public init() {
            buffer = .allocate(capacity: capacity)
        }

        deinit { buffer.deallocate() }

        public func listeningSockets(_ pid: pid_t) -> [PortBinding] {
            let stride = MemoryLayout<proc_fdinfo>.stride
            var got: Int32
            while true {
                got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, Int32(capacity * stride))
                guard got > 0 else { return [] }
                if Int(got) < capacity * stride { break }
                buffer.deallocate()
                capacity *= 2
                buffer = .allocate(capacity: capacity)
            }

            var result: [PortBinding] = []
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            for i in 0..<(Int(got) / stride) where buffer[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                guard proc_pidfdinfo(pid, buffer[i].proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, infoSize) == infoSize,
                      socketInfo.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
                let tcp = socketInfo.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                let ini = tcp.tcpsi_ini
                let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
                let isV6 = ini.insi_vflag & UInt8(INI_IPV6) != 0
                let address = isV6 ? LibProc.ipv6String(ini.insi_laddr.ina_6) : LibProc.ipv4String(ini.insi_laddr.ina_46.i46a_addr4)
                result.append(PortBinding(port: port, address: address, isIPv6: isV6))
            }
            return result
        }
    }

    static func ipv4String(_ addr: in_addr) -> String {
        var addr = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
        return string(from: buf)
    }

    static func ipv6String(_ addr: in6_addr) -> String {
        var addr = addr
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
        return string(from: buf)
    }

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Paths and arguments

    public static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return string(from: buf)
    }

    public static func currentDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    /// argv and environment via KERN_PROCARGS2. Only works for processes we own.
    public static func arguments(_ pid: pid_t) -> Arguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Layout: argc (int32), exec path, NUL padding, argc strings, env strings, then an empty string.
    static func parseProcArgs(_ bytes: [UInt8]) -> Arguments? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = 4

        func readString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }

        guard let executable = readString() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var argv: [String] = []
        for _ in 0..<max(argc, 0) {
            guard let arg = readString() else { break }
            argv.append(arg)
        }
        var environment: [String] = []
        while let entry = readString(), !entry.isEmpty {
            environment.append(entry)
        }
        return Arguments(executable: executable, argv: argv, environment: environment)
    }

    // MARK: Usage

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func usage(_ pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        guard ok else { return nil }
        // On Apple silicon these counters are in mach time units, not nanoseconds.
        let ticks = info.ri_user_time + info.ri_system_time
        let nanos = ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        return Usage(cpuNanos: nanos, footprint: info.ri_phys_footprint)
    }
}
