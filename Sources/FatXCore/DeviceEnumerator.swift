import Foundation
import Darwin

/// A physical disk attached to the machine, as reported by `diskutil`.
public struct StorageDevice: Identifiable, Hashable, Sendable {
    public let id: String                 // "disk4"
    public let size: Int64
    public let isRemovable: Bool
    public let isInternal: Bool
    public let model: String
    public let busProtocol: String
    public let mountedVolumes: [String]

    public var rawPath: String { "/dev/r\(id)" }
    public var blockPath: String { "/dev/\(id)" }

    public var displayName: String {
        if !model.isEmpty { return model }
        return id
    }

    public var subtitle: String {
        var bits: [String] = []
        if !busProtocol.isEmpty { bits.append(busProtocol) }
        bits.append(FatXVolume.friendlySize(size))
        if !mountedVolumes.isEmpty { bits.append("已挂载：" + mountedVolumes.joined(separator: ", ")) }
        return bits.joined(separator: " · ")
    }
}

public enum DeviceEnumerator {

    /// Lists physical disks. Xbox 360 drives show up as ordinary external disks
    /// that macOS refuses to mount, which is exactly what we want to list.
    public static func listPhysicalDisks(includeInternal: Bool = false) -> [StorageDevice] {
        let args = includeInternal
            ? ["list", "-plist", "physical"]
            : ["list", "-plist", "external", "physical"]
        guard let plist = runDiskutil(args),
              let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let allDisks = root["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        var devices: [StorageDevice] = []
        for disk in allDisks {
            guard let identifier = disk["DeviceIdentifier"] as? String,
                  let size = disk["Size"] as? Int64 else { continue }

            let info = diskInfo(identifier)
            let mounted = (disk["Partitions"] as? [[String: Any]] ?? [])
                .compactMap { $0["MountPoint"] as? String }

            devices.append(StorageDevice(
                id: identifier,
                size: size,
                isRemovable: info["RemovableMedia"] as? Bool ?? false,
                isInternal: info["Internal"] as? Bool ?? false,
                model: (info["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "",
                busProtocol: info["BusProtocol"] as? String ?? "",
                mountedVolumes: mounted
            ))
        }
        return devices.sorted { $0.id < $1.id }
    }

    private static func diskInfo(_ identifier: String) -> [String: Any] {
        guard let plist = runDiskutil(["info", "-plist", identifier]),
              let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private static func runDiskutil(_ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    /// True if the current process can open the raw device node for reading.
    public static func canReadRawDevice(_ device: StorageDevice) -> Bool {
        let fd = open(device.rawPath, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    /// True if the current process can open the raw device node for writing.
    /// Reading and writing are separate permissions on `/dev/rdisk*`, so a
    /// volume can be browsable but not writable.
    public static func canWriteRawDevice(_ device: StorageDevice) -> Bool {
        let fd = open(device.rawPath, O_RDWR)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    /// What came back from an administrator-authorised `chmod`, including the
    /// permission bits afterwards. A bare `Bool` made failures indistinguishable
    /// from "the user cancelled" and from "the bits went back to 640".
    public struct PrivilegeOutcome: Sendable {
        public let granted: Bool
        public let detail: String
        public init(granted: Bool, detail: String) {
            self.granted = granted
            self.detail = detail
        }
    }

    /// Unlocks *write* access to the device node. This changes nothing except
    /// the permission bits on `/dev/rdisk*`; the FATX structures on the disk
    /// are only touched by an explicit upload, which always asks first.
    ///
    /// The two device nodes are chmodded separately: `/dev/disk8` is missing on
    /// some USB bridges, and a single failing `chmod a b` would abort the whole
    /// command — which is exactly how a correct password could still leave the
    /// volume read-only.
    public static func requestWriteAccessDetailed(for device: StorageDevice) -> PrivilegeOutcome {
        let shell = """
        chmod 666 \(device.rawPath) 2>&1; chmod 666 \(device.blockPath) 2>&1; ls -ld \(device.rawPath) \(device.blockPath) 2>&1
        """
        let outcome = runPrivileged(shell: shell,
                                    prompt: "BoxingBuffalo 需要管理员密码来放开 \(device.id) 设备节点的写权限")
        let failure = writeAccessErrno(device)
        let writable = failure == 0
        BoxingBuffaloLog.log("write-access \(device.id): sudo=\(outcome.granted) openRDWR=\(writable ? "ok" : "errno \(failure)") — \(outcome.detail)")
        var detail = outcome.detail + " · 写句柄=\(writable ? "成功" : "errno \(failure) \(String(cString: strerror(failure)))")"
        if !writable && failure == EPERM {
            detail += " · 需要给 BoxingBuffalo.app 授予「完全磁盘访问权限」"
        }
        return PrivilegeOutcome(granted: writable, detail: detail)
    }

    /// 0 if the node can be opened read-write, otherwise the errno from `open`.
    public static func writeAccessErrno(_ device: StorageDevice) -> Int32 {
        let fd = open(device.rawPath, O_RDWR)
        if fd >= 0 {
            close(fd)
            return 0
        }
        return errno
    }

    /// Kept for callers that only care about the boolean.
    @discardableResult
    public static func requestWriteAccess(for device: StorageDevice) -> Bool {
        requestWriteAccessDetailed(for: device).granted
    }

    /// Grants this user read access to the device node by running a single
    /// `chmod`. Nothing on the disk itself is touched — this only relaxes
    /// the permissions of the `/dev/rdisk*` character device.
    ///
    /// Requires the user to approve an administrator prompt (standard macOS
    /// password dialog). Returns true on success.
    @discardableResult
    public static func requestReadAccess(for device: StorageDevice) -> Bool {
        let shell = """
        chmod 644 \(device.rawPath) 2>&1; chmod 644 \(device.blockPath) 2>&1; ls -ld \(device.rawPath) \(device.blockPath) 2>&1
        """
        let outcome = runPrivileged(shell: shell,
                                    prompt: "BoxingBuffalo 需要只读权限来打开 \(device.id)。不会向磁盘写入任何内容。")
        let readable = canReadRawDevice(device)
        BoxingBuffaloLog.log("read-access \(device.id): sudo=\(outcome.granted) canOpenRDONLY=\(readable) — \(outcome.detail)")
        return readable
    }

    /// Runs a shell snippet as root.
    ///
    /// `osascript ... with administrator privileges` is NOT usable here: since
    /// macOS Catalina that elevated shell is refused by the kernel when it
    /// tries to chmod a `/dev/rdisk*` node ("Operation not permitted"), even
    /// though it really is root. `sudo -A` with a graphical askpass is the
    /// route that actually works (the same fix Etcher landed for this bug).
    private static func runPrivileged(shell: String, prompt: String) -> PrivilegeOutcome {
        do {
            let askpass = try prepareAskpass(prompt: prompt)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            // `id -u` goes first so the log proves the command ran as root.
            process.arguments = ["-A", "/bin/sh", "-c", "id -u; " + shell]
            var env = ProcessInfo.processInfo.environment
            env["SUDO_ASKPASS"] = askpass
            process.environment = env
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = process.terminationStatus
            let isRoot = stdout.hasPrefix("0\n") || stdout == "0"
            var detail = "sudo 退出码 \(code) · root=\(isRoot ? "是" : "否") · \(stdout)"
            if !stderr.isEmpty { detail += " · \(stderr)" }
            BoxingBuffaloLog.log("sudo -A: \(detail)")
            return PrivilegeOutcome(granted: code == 0 && isRoot, detail: detail)
        } catch {
            BoxingBuffaloLog.log("sudo -A 无法启动：\(error)，退回 osascript 提权")
            return runViaOsascript(shell: shell, prompt: prompt)
        }
    }

    /// A tiny `SUDO_ASKPASS` helper: shows one native password dialog and
    /// prints the password on stdout for sudo to consume.
    private static func prepareAskpass(prompt: String) throws -> String {
        // Only ASCII single quotes are used as the delimiter, so the prompt
        // itself must not contain one.
        let cleanPrompt = prompt
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        let path = "/tmp/boxingbuffalo-askpass-\(getuid()).sh"
        let body = """
        #!/bin/sh
        exec /usr/bin/osascript -e 'text returned of (display dialog "\(cleanPrompt)" with title "BoxingBuffalo 管理员授权" default answer "" with hidden answer buttons {"取消", "允许"} default button 2)'
        """
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    /// Last-resort fallback for systems where `sudo` is unavailable. It cannot
    /// chmod raw disk nodes on Catalina and later, but it still lets a read-only
    /// mount succeed on older macOS.
    private static func runViaOsascript(shell: String, prompt: String) -> PrivilegeOutcome {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let stdout = String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var detail = "osascript 退出码 \(process.terminationStatus) · \(stdout)"
            if !stderr.isEmpty { detail += " · \(stderr)" }
            return PrivilegeOutcome(granted: process.terminationStatus == 0, detail: detail)
        } catch {
            return PrivilegeOutcome(granted: false, detail: "提权命令无法启动：\(error.localizedDescription)")
        }
    }
}
