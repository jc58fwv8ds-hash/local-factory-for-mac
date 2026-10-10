import Darwin

/// Only traverses descendants of a directly owned live process. Freeze parents
/// before discovering children, and revalidate parent/start identity before signals.
enum OwnedProcessTree {
    @discardableResult static func terminate(root: pid_t) -> Bool {
        guard root > 1, let anchor = identity(root), anchor.pbi_ppid == getpid() else { return false }
        var frozen: [proc_bsdinfo] = []
        var complete = true
        func freeze(_ expected: proc_bsdinfo) {
            guard frozen.count < 256 else { complete = false; return }
            guard let current = identity(Int32(expected.pbi_pid)), same(current, expected) else { return }
            let pid = Int32(current.pbi_pid)
            guard kill(pid, SIGSTOP) == 0 else { complete = false; return }
            frozen.append(current)
            var children = [pid_t](repeating: 0, count: 256)
            let count = children.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
            if count < 0 || count >= children.count { complete = false }
            guard count > 0 else { return }
            for child in children.prefix(min(Int(count), children.count)) where child > 1 {
                if let info = identity(child), info.pbi_ppid == current.pbi_pid { freeze(info) }
            }
        }
        freeze(anchor)
        // Descendants whose parent already exited are reparented to launchd and are
        // unreachable through parent links. SwiftPM starts some descendants (e.g. the
        // test runner) as leaders of new groups. While a group's leader is in our tree,
        // alive and stopped, its PGID cannot be reused, so that group's members are ours.
        var swept = Set<UInt32>()
        for _ in 0..<4 {
            let groups = Set(frozen.filter { $0.pbi_pgid == $0.pbi_pid }.map(\.pbi_pgid)).subtracting(swept)
            guard !groups.isEmpty else { break }
            for group in groups {
                swept.insert(group)
                var members = [pid_t](repeating: 0, count: 256)
                let bytes = members.withUnsafeMutableBytes {
                    proc_listpids(UInt32(PROC_PGRP_ONLY), group, $0.baseAddress, Int32($0.count))
                }
                let count = Int(bytes) / MemoryLayout<pid_t>.size
                if bytes < 0 || count >= members.count { complete = false }
                for pid in members.prefix(max(0, min(count, members.count))) where pid > 1 && !frozen.contains(where: { Int32($0.pbi_pid) == pid }) {
                    if let info = identity(pid), info.pbi_pgid == group, info.pbi_uid == anchor.pbi_uid { freeze(info) }
                }
            }
        }
        for expected in frozen.reversed() {
            if let current = identity(Int32(expected.pbi_pid)), same(current, expected) {
                _ = kill(Int32(current.pbi_pid), SIGKILL)
            }
        }
        for _ in 0..<100 {
            let live = frozen.contains { expected in
                guard let value = identity(Int32(expected.pbi_pid)) else { return false }
                return value.pbi_status != 5 && value.pbi_start_tvsec == expected.pbi_start_tvsec && value.pbi_start_tvusec == expected.pbi_start_tvusec
            }
            if !live { return complete }
            usleep(10_000)
        }
        return false
    }
    private static func identity(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
    private static func same(_ a: proc_bsdinfo, _ b: proc_bsdinfo) -> Bool {
        a.pbi_pid == b.pbi_pid && a.pbi_ppid == b.pbi_ppid && a.pbi_uid == b.pbi_uid &&
        a.pbi_start_tvsec == b.pbi_start_tvsec && a.pbi_start_tvusec == b.pbi_start_tvusec
    }
}
