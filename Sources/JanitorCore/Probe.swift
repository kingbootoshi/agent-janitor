import Foundation
import CProbe

public struct RawProc {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    public var uid: UInt32
    public var startSec: UInt64
    public var startUsec: UInt64
    public var status: UInt32
    public var ttyDev: Int32
    public var key: ProcessKey { ProcessKey(pid: pid, startSec: startSec, startUsec: startUsec) }
}

public struct RusageFact {
    public var footprint: UInt64
    public var resident: UInt64
    public var cpuNs: UInt64
    public var diskR: UInt64
    public var diskW: UInt64
    public var logicalWrites: UInt64
}

public enum Probe {
    public static func allPids() -> [Int32] {
        var buf = [Int32](repeating: 0, count: 8192)
        let bytes = buf.withUnsafeMutableBufferPointer { p in
            aj_list_pids(p.baseAddress, Int32(p.count * MemoryLayout<Int32>.size))
        }
        guard bytes > 0 else { return [] }
        let n = Int(bytes) / MemoryLayout<Int32>.size
        return Array(buf.prefix(n)).filter { $0 > 0 }
    }

    public static func bsdInfo(_ pid: Int32) -> RawProc? {
        var info = proc_bsdinfo()
        let r = aj_bsdinfo(pid, &info)
        guard r == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return RawProc(
            pid: pid,
            ppid: Int32(info.pbi_ppid),
            pgid: Int32(info.pbi_pgid),
            uid: info.pbi_uid,
            startSec: info.pbi_start_tvsec,
            startUsec: info.pbi_start_tvusec,
            status: info.pbi_status,
            ttyDev: Int32(bitPattern: info.e_tdev)
        )
    }

    public static func rusage(_ pid: Int32) -> RusageFact? {
        var ru = rusage_info_v4()
        guard aj_rusage(pid, &ru) == 0 else { return nil }
        return RusageFact(
            footprint: ru.ri_phys_footprint,
            resident: ru.ri_resident_size,
            cpuNs: ru.ri_user_time &+ ru.ri_system_time,
            diskR: ru.ri_diskio_bytesread,
            diskW: ru.ri_diskio_byteswritten,
            logicalWrites: ru.ri_logical_writes
        )
    }

    public static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let r = buf.withUnsafeMutableBufferPointer { p in
            aj_path(pid, p.baseAddress, UInt32(p.count))
        }
        guard r > 0 else { return "" }
        return String(cString: buf)
    }

    public static func cwd(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let r = aj_cwd(pid, &info)
        guard r == MemoryLayout<proc_vnodepathinfo>.size else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    public static func argv(_ pid: Int32) -> [String] {
        var len: size_t = 0
        var mibCheck = aj_args(pid, nil, &len)
        guard mibCheck == 0 || len > 0 else { return [] }
        len = max(len, 4096)
        var buf = [UInt8](repeating: 0, count: len)
        mibCheck = buf.withUnsafeMutableBytes { p in
            aj_args(pid, p.baseAddress?.assumingMemoryBound(to: CChar.self), &len)
        }
        guard mibCheck == 0, len > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var idx = MemoryLayout<Int32>.size
        while idx < len && buf[idx] != 0 { idx += 1 }
        while idx < len && buf[idx] == 0 { idx += 1 }
        var args: [String] = []
        var current: [UInt8] = []
        while idx < len && args.count < Int(argc) {
            if buf[idx] == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current = []
                while idx < len && buf[idx] == 0 { idx += 1 }
            } else {
                current.append(buf[idx])
                idx += 1
            }
        }
        return args
    }

    public static func sockets(_ pid: Int32) -> SocketFact {
        var fact = SocketFact(listeners: [], loopbackOnly: true, established: 0)
        let fdBytes = aj_fds(pid, nil, 0)
        guard fdBytes > 0 else { return fact }
        let count = Int(fdBytes) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let got = fds.withUnsafeMutableBufferPointer { p in
            aj_fds(pid, p.baseAddress, Int32(p.count * MemoryLayout<proc_fdinfo>.size))
        }
        guard got > 0 else { return fact }
        let n = Int(got) / MemoryLayout<proc_fdinfo>.size
        for i in 0..<n where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard aj_socket(pid, fds[i].proc_fd, &si) == MemoryLayout<socket_fdinfo>.size else { continue }
            guard si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            let state = tcp.tcpsi_state
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if state == TSI_S_LISTEN {
                fact.listeners.append(port)
                let vflag = tcp.tcpsi_ini.insi_vflag
                if (vflag & UInt8(INI_IPV4)) != 0 {
                    let addr = tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr
                    if addr != UInt32(bigEndian: 0x7f000001) && addr != 0 { fact.loopbackOnly = false }
                    if addr == 0 { fact.loopbackOnly = false }
                } else {
                    var l6 = tcp.tcpsi_ini.insi_laddr.ina_6
                    let isLoop = withUnsafeBytes(of: &l6) { raw -> Bool in
                        let b = raw.bindMemory(to: UInt8.self)
                        for i in 0..<15 where b[i] != 0 { return false }
                        return b[15] == 1
                    }
                    if !isLoop { fact.loopbackOnly = false }
                }
            } else if state == TSI_S_ESTABLISHED {
                fact.established += 1
            }
        }
        return fact
    }

    public static func pipePeerHandles(_ pid: Int32) -> [UInt64] {
        let fdBytes = aj_fds(pid, nil, 0)
        guard fdBytes > 0 else { return [] }
        let count = Int(fdBytes) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let got = fds.withUnsafeMutableBufferPointer { p in
            aj_fds(pid, p.baseAddress, Int32(p.count * MemoryLayout<proc_fdinfo>.size))
        }
        guard got > 0 else { return [] }
        let n = Int(got) / MemoryLayout<proc_fdinfo>.size
        var handles: [UInt64] = []
        for i in 0..<n where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_PIPE) {
            var pi = pipe_fdinfo()
            guard aj_pipe(pid, fds[i].proc_fd, &pi) == MemoryLayout<pipe_fdinfo>.size else { continue }
            if pi.pipeinfo.pipe_peerhandle != 0 { handles.append(pi.pipeinfo.pipe_peerhandle) }
            if pi.pipeinfo.pipe_handle != 0 { handles.append(pi.pipeinfo.pipe_handle) }
        }
        return handles
    }

    public static func swapUsedMB() -> Double {
        var swap = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &len, nil, 0) == 0 else { return 0 }
        return Double(swap.xsu_used) / 1_048_576.0
    }
}
