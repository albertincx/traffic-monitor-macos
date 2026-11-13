import Cocoa
import Combine
import Darwin
import Foundation

final class TrafficMonitor: ObservableObject {
    static let shared = TrafficMonitor()

    @Published var currentInRate: Double = 0
    @Published var currentOutRate: Double = 0
    @Published var lastUpdated: Date = Date()
    @Published var revision: Int = 0

    @Published var menuTopProcesses: [ProcessTrafficSummary] = []
    @Published var menuTotalIn: Int64 = 0
    @Published var menuTotalOut: Int64 = 0

    var excludeLocal: Bool = true
    var menuPeriod: TimeRange = .day24h
    let sessionStartTimestamp: Int64 = Int64(Date().timeIntervalSince1970)

    private let pollQueue = DispatchQueue(label: "com.user.trafficmonitor.poll", qos: .utility)
    private let dnsQueue = DispatchQueue(label: "com.user.trafficmonitor.dns", qos: .utility)
    private let stateLock = NSLock()

    private var hasBaseline = false
    private var lastPollDate: Date?
    private var prevProcTotals: [String: (bytesIn: Int64, bytesOut: Int64)] = [:]
    private var prevSocketTotals: [String: (bytesIn: Int64, bytesOut: Int64)] = [:]

    private var dnsCache: [String: String] = [:]
    private var dnsPending: Set<String> = []
    private var procInfoCache: [Int: (name: String, icon: NSImage?)] = [:]

    // Session-only in-memory tracking
    private var sessionProcTotals: [String: (bytesIn: Int64, bytesOut: Int64, lastSeen: Int64, dests: Set<String>)] = [:]
    private var sessionDestTotals: [String: (ip: String, port: Int, proto: String, proc: String, bytesIn: Int64, bytesOut: Int64, firstSeen: Int64, lastSeen: Int64)] = [:]
    private var sessionTimeline: [Int64: (bytesIn: Int64, bytesOut: Int64)] = [:]

    var onMenuDataUpdated: (() -> Void)?

    private init() {
        dnsCache = TrafficDatabase.shared.loadDnsCache()
    }

    func pollOnce() {
        pollQueue.async { [weak self] in
            self?.runNettopPoll()
        }
    }

    func resetAllData() {
        stateLock.lock()
        sessionProcTotals.removeAll()
        sessionDestTotals.removeAll()
        sessionTimeline.removeAll()
        stateLock.unlock()

        TrafficDatabase.shared.clearAllData()
        DispatchQueue.main.async {
            self.menuTopProcesses = []
            self.menuTotalIn = 0
            self.menuTotalOut = 0
            self.revision += 1
            self.onMenuDataUpdated?()
        }
    }

    func iconForProcess(_ name: String) -> NSImage? {
        stateLock.lock()
        defer { stateLock.unlock() }
        for (_, info) in procInfoCache {
            if info.name == name, let icon = info.icon {
                return icon
            }
        }
        return nil
    }

    // MARK: - Query API for UI

    func fetchProcesses(range: TimeRange) -> [ProcessTrafficSummary] {
        if range == .session {
            stateLock.lock()
            let list = sessionProcTotals.map { (name, v) in
                ProcessTrafficSummary(
                    processName: name,
                    bytesIn: v.bytesIn,
                    bytesOut: v.bytesOut,
                    lastSeen: v.lastSeen,
                    destinationCount: v.dests.count
                )
            }
            stateLock.unlock()
            return list.sorted { $0.totalBytes > $1.totalBytes }
        } else {
            let since = range.sinceTimestamp ?? 0
            let sinceBucket = (since / 3600) * 3600
            return TrafficDatabase.shared.fetchProcessSummaries(sinceBucket: sinceBucket)
        }
    }

    func fetchDestinations(range: TimeRange, processName: String?) -> [DestinationTrafficSummary] {
        stateLock.lock()
        let dnsSnapshot = dnsCache
        stateLock.unlock()

        if range == .session {
            stateLock.lock()
            var grouped: [String: (ip: String, port: Int, proto: String, bytesIn: Int64, bytesOut: Int64, firstSeen: Int64, lastSeen: Int64, procs: Set<String>)] = [:]
            for (_, entry) in sessionDestTotals {
                if let targetProc = processName, entry.proc != targetProc { continue }
                let key = "\(entry.ip):\(entry.port):\(entry.proto)"
                if var existing = grouped[key] {
                    existing.bytesIn += entry.bytesIn
                    existing.bytesOut += entry.bytesOut
                    existing.firstSeen = min(existing.firstSeen, entry.firstSeen)
                    existing.lastSeen = max(existing.lastSeen, entry.lastSeen)
                    existing.procs.insert(entry.proc)
                    grouped[key] = existing
                } else {
                    grouped[key] = (entry.ip, entry.port, entry.proto, entry.bytesIn, entry.bytesOut, entry.firstSeen, entry.lastSeen, [entry.proc])
                }
            }
            stateLock.unlock()

            return grouped.values.map { v in
                DestinationTrafficSummary(
                    remoteIP: v.ip,
                    remotePort: v.port,
                    proto: v.proto,
                    hostname: dnsSnapshot[v.ip],
                    bytesIn: v.bytesIn,
                    bytesOut: v.bytesOut,
                    firstSeen: v.firstSeen,
                    lastSeen: v.lastSeen,
                    processNames: v.procs.sorted().joined(separator: ", ")
                )
            }.sorted { $0.totalBytes > $1.totalBytes }
        } else {
            let since = range.sinceTimestamp ?? 0
            let sinceBucket = (since / 3600) * 3600
            return TrafficDatabase.shared.fetchDestinations(sinceBucket: sinceBucket, processName: processName, dnsMap: dnsSnapshot)
        }
    }

    func fetchTimeline(range: TimeRange, processName: String?) -> [TimelineBucket] {
        if range == .session {
            if let proc = processName {
                // Fall back to DB for per-process session timeline since sessionStartTimestamp
                let sinceBucket = (sessionStartTimestamp / 3600) * 3600
                return TrafficDatabase.shared.fetchTimeline(sinceBucket: sinceBucket, bucketSeconds: 3600, processName: proc)
            }
            stateLock.lock()
            let buckets = sessionTimeline.map { TimelineBucket(timestamp: $0.key, bytesIn: $0.value.bytesIn, bytesOut: $0.value.bytesOut) }
                .sorted { $0.timestamp < $1.timestamp }
            stateLock.unlock()
            return buckets
        } else {
            let since = range.sinceTimestamp ?? 0
            let sinceBucket = (since / 3600) * 3600
            return TrafficDatabase.shared.fetchTimeline(sinceBucket: sinceBucket, bucketSeconds: range.bucketSeconds, processName: processName)
        }
    }

    // MARK: - nettop Polling & Parsing

    private func runNettopPoll() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-L", "1", "-J", "bytes_in,bytes_out"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
        processNettopOutput(output)
    }

    private struct ParsedSocket {
        let key: String
        let proto: String
        let remoteIP: String
        let remotePort: Int
        let bytesIn: Int64
        let bytesOut: Int64
    }

    private struct ParsedProcess {
        let pidKey: String
        let pid: Int
        let name: String
        let bytesIn: Int64
        let bytesOut: Int64
        var sockets: [ParsedSocket] = []
    }

    private func processNettopOutput(_ output: String) {
        let now = Date()
        let nowTs = Int64(now.timeIntervalSince1970)
        let bucketTs = (nowTs / 3600) * 3600

        var parsedProcs: [ParsedProcess] = []
        var currentProc: ParsedProcess?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix(",") { continue } // header

            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }

            let col0 = String(parts[0])
            let bIn = Int64(parts[1]) ?? 0
            let bOut = Int64(parts[2]) ?? 0

            // Socket lines start with protocol + space (e.g., "tcp4 ", "udp6 ", "quic6 ")
            if col0.hasPrefix("tcp") || col0.hasPrefix("udp") || col0.hasPrefix("quic") {
                guard var proc = currentProc else { continue }
                if let parsedSock = parseSocketColumn(col0, pid: proc.pid, bytesIn: bIn, bytesOut: bOut) {
                    proc.sockets.append(parsedSock)
                    currentProc = proc
                }
            } else {
                // Process header line: "<name>.<pid>"
                if let existing = currentProc {
                    parsedProcs.append(existing)
                }
                if let dotIdx = col0.lastIndex(of: "."),
                   let pid = Int(col0[col0.index(after: dotIdx)...]) {
                    let rawName = String(col0[..<dotIdx])
                    let fullName = resolveProcessName(pid: pid, fallback: rawName)
                    currentProc = ParsedProcess(
                        pidKey: "\(pid)|\(rawName)",
                        pid: pid,
                        name: fullName,
                        bytesIn: bIn,
                        bytesOut: bOut
                    )
                } else {
                    currentProc = nil
                }
            }
        }
        if let existing = currentProc {
            parsedProcs.append(existing)
        }

        var nextProcTotals: [String: (bytesIn: Int64, bytesOut: Int64)] = [:]
        var nextSocketTotals: [String: (bytesIn: Int64, bytesOut: Int64)] = [:]

        var dbRecords: [TrafficSampleRecord] = []
        var totalDeltaIn: Int64 = 0
        var totalDeltaOut: Int64 = 0
        var ipsToResolve: Set<String> = []

        for proc in parsedProcs {
            nextProcTotals[proc.pidKey] = (proc.bytesIn, proc.bytesOut)

            var sockSumIn: Int64 = 0
            var sockSumOut: Int64 = 0

            for sock in proc.sockets {
                nextSocketTotals[sock.key] = (sock.bytesIn, sock.bytesOut)

                if hasBaseline {
                    let prevSock = prevSocketTotals[sock.key]
                    let dIn = deltaValue(current: sock.bytesIn, previous: prevSock?.bytesIn)
                    let dOut = deltaValue(current: sock.bytesOut, previous: prevSock?.bytesOut)

                    if dIn > 0 || dOut > 0 {
                        if excludeLocal && isLocalOrSpecialIP(sock.remoteIP) {
                            continue
                        }
                        sockSumIn += dIn
                        sockSumOut += dOut
                        dbRecords.append(TrafficSampleRecord(
                            bucketTs: bucketTs,
                            processName: proc.name,
                            remoteIP: sock.remoteIP,
                            remotePort: sock.remotePort,
                            proto: sock.proto,
                            bytesIn: dIn,
                            bytesOut: dOut,
                            timestamp: nowTs
                        ))
                        ipsToResolve.insert(sock.remoteIP)
                    }
                }
            }

            if hasBaseline && !excludeLocal {
                let prevProc = prevProcTotals[proc.pidKey]
                let pIn = deltaValue(current: proc.bytesIn, previous: prevProc?.bytesIn)
                let pOut = deltaValue(current: proc.bytesOut, previous: prevProc?.bytesOut)
                let remIn = max(0, pIn - sockSumIn)
                let remOut = max(0, pOut - sockSumOut)
                if remIn > 0 || remOut > 0 {
                    sockSumIn += remIn
                    sockSumOut += remOut
                    dbRecords.append(TrafficSampleRecord(
                        bucketTs: bucketTs,
                        processName: proc.name,
                        remoteIP: "0.0.0.0",
                        remotePort: 0,
                        proto: "other",
                        bytesIn: remIn,
                        bytesOut: remOut,
                        timestamp: nowTs
                    ))
                }
            }

            totalDeltaIn += sockSumIn
            totalDeltaOut += sockSumOut
        }

        let elapsed = lastPollDate.map { max(0.5, now.timeIntervalSince($0)) } ?? 3.0
        lastPollDate = now
        prevProcTotals = nextProcTotals
        prevSocketTotals = nextSocketTotals

        if !hasBaseline {
            hasBaseline = true
            DispatchQueue.main.async {
                self.refreshMenuSummary()
            }
            return
        }

        if !dbRecords.isEmpty {
            TrafficDatabase.shared.recordSamples(dbRecords)

            stateLock.lock()
            for r in dbRecords {
                // Update session process totals
                var p = sessionProcTotals[r.processName] ?? (0, 0, r.timestamp, Set<String>())
                p.bytesIn += r.bytesIn
                p.bytesOut += r.bytesOut
                p.lastSeen = max(p.lastSeen, r.timestamp)
                p.dests.insert("\(r.remoteIP):\(r.remotePort)")
                sessionProcTotals[r.processName] = p

                // Update session destination totals
                let dKey = "\(r.processName)|\(r.remoteIP):\(r.remotePort):\(r.proto)"
                if var d = sessionDestTotals[dKey] {
                    d.bytesIn += r.bytesIn
                    d.bytesOut += r.bytesOut
                    d.lastSeen = max(d.lastSeen, r.timestamp)
                    sessionDestTotals[dKey] = d
                } else {
                    sessionDestTotals[dKey] = (r.remoteIP, r.remotePort, r.proto, r.processName, r.bytesIn, r.bytesOut, r.timestamp, r.timestamp)
                }

                // Update session timeline
                var tb = sessionTimeline[r.bucketTs] ?? (0, 0)
                tb.bytesIn += r.bytesIn
                tb.bytesOut += r.bytesOut
                sessionTimeline[r.bucketTs] = tb
            }
            stateLock.unlock()
        }

        if !ipsToResolve.isEmpty {
            enqueueDNSResolution(ipsToResolve)
        }

        let inRate = Double(totalDeltaIn) / elapsed
        let outRate = Double(totalDeltaOut) / elapsed

        DispatchQueue.main.async {
            self.currentInRate = inRate
            self.currentOutRate = outRate
            self.lastUpdated = now
            self.refreshMenuSummary()
            self.revision += 1
        }
    }

    func refreshMenuSummary() {
        let procs = fetchProcesses(range: menuPeriod)
        let totalIn = procs.reduce(0) { $0 + $1.bytesIn }
        let totalOut = procs.reduce(0) { $0 + $1.bytesOut }
        self.menuTopProcesses = Array(procs.prefix(5))
        self.menuTotalIn = totalIn
        self.menuTotalOut = totalOut
        self.onMenuDataUpdated?()
    }

    private func deltaValue(current: Int64, previous: Int64?) -> Int64 {
        guard let prev = previous else {
            return max(0, current)
        }
        if current >= prev {
            return current - prev
        }
        return max(0, current)
    }

    private func parseSocketColumn(_ col: String, pid: Int, bytesIn: Int64, bytesOut: Int64) -> ParsedSocket? {
        guard let spaceIdx = col.firstIndex(of: " ") else { return nil }
        let proto = String(col[..<spaceIdx])
        let endpoints = String(col[col.index(after: spaceIdx)...])
        guard let arrowRange = endpoints.range(of: "<->") else { return nil }

        let remotePart = String(endpoints[arrowRange.upperBound...])
        if remotePart == "*:*" || remotePart == "*.*" { return nil }

        guard let (ip, port) = splitIPAndPort(remotePart) else { return nil }
        if ip.isEmpty || ip == "*" { return nil }

        let key = "\(pid)|\(proto)|\(endpoints)"
        return ParsedSocket(key: key, proto: proto, remoteIP: ip, remotePort: port, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    private func splitIPAndPort(_ addr: String) -> (String, Int)? {
        let colonCount = addr.filter { $0 == ":" }.count
        if colonCount == 1 {
            // IPv4: "17.57.145.134:5223"
            let parts = addr.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let ip = String(parts[0])
            let port = Int(parts[1]) ?? 0
            return (ip, port)
        } else if colonCount > 1 {
            // IPv6: "2001:4860:4841:400::.443"
            guard let dotIdx = addr.lastIndex(of: ".") else { return (addr, 0) }
            let ip = String(addr[..<dotIdx])
            let portStr = String(addr[addr.index(after: dotIdx)...])
            let port = Int(portStr) ?? 0
            return (ip, port)
        } else {
            return nil
        }
    }

    private func isLocalOrSpecialIP(_ ip: String) -> Bool {
        let lower = ip.lowercased()
        if lower == "::1" || lower == "::" || lower == "0.0.0.0" { return true }
        if lower.hasPrefix("fe80:") || lower.hasPrefix("ff") || lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            return true
        }
        if lower.hasPrefix("127.") || lower.hasPrefix("169.254.") || lower.hasPrefix("10.") || lower.hasPrefix("192.168.") || lower.hasPrefix("255.") {
            return true
        }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        if let firstDot = lower.firstIndex(of: "."), let firstOctet = Int(lower[..<firstDot]) {
            if (224...239).contains(firstOctet) { return true }
        }
        return false
    }

    private func resolveProcessName(pid: Int, fallback: String) -> String {
        stateLock.lock()
        if let cached = procInfoCache[pid] {
            stateLock.unlock()
            return cached.name
        }
        stateLock.unlock()

        var resolvedName = fallback
        var resolvedIcon: NSImage?

        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            if let loc = app.localizedName, !loc.isEmpty {
                resolvedName = loc
            }
            resolvedIcon = app.icon
        } else {
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN) * 4)
            defer { buffer.deallocate() }
            let len = proc_pidpath(pid_t(pid), buffer, UInt32(MAXPATHLEN * 4))
            if len > 0 {
                let path = String(cString: buffer)
                let base = URL(fileURLWithPath: path).lastPathComponent
                if !base.isEmpty {
                    resolvedName = base
                }
            }
        }

        stateLock.lock()
        procInfoCache[pid] = (resolvedName, resolvedIcon)
        if procInfoCache.count > 2000 {
            procInfoCache.removeAll()
        }
        stateLock.unlock()
        return resolvedName
    }

    // MARK: - Reverse DNS Resolution

    private func enqueueDNSResolution(_ ips: Set<String>) {
        var toLookup: [String] = []
        stateLock.lock()
        for ip in ips {
            if ip == "0.0.0.0" { continue }
            if dnsCache[ip] == nil && !dnsPending.contains(ip) {
                dnsPending.insert(ip)
                toLookup.append(ip)
            }
        }
        stateLock.unlock()

        for ip in toLookup {
            dnsQueue.async { [weak self] in
                let host = Self.reverseDNS(ip: ip)
                guard let self = self else { return }
                self.stateLock.lock()
                self.dnsPending.remove(ip)
                self.dnsCache[ip] = host ?? ip
                self.stateLock.unlock()
                if let resolved = host, resolved != ip {
                    TrafficDatabase.shared.saveHostname(resolved, forIP: ip)
                }
            }
        }
    }

    private static func reverseDNS(ip: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let info = res else {
            return nil
        }
        defer { freeaddrinfo(info) }

        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            info.pointee.ai_addr,
            info.pointee.ai_addrlen,
            &hostBuf,
            socklen_t(hostBuf.count),
            nil,
            0,
            NI_NAMEREQD
        )
        if status == 0 {
            let name = String(cString: hostBuf)
            return name.isEmpty ? nil : name
        }
        return nil
    }
}
