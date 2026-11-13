import Foundation
import SQLite3

struct TrafficSampleRecord {
    let bucketTs: Int64
    let processName: String
    let remoteIP: String
    let remotePort: Int
    let proto: String
    let bytesIn: Int64
    let bytesOut: Int64
    let timestamp: Int64
}

final class TrafficDatabase {
    static let shared = TrafficDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.user.trafficmonitor.db", qos: .utility)

    var dbFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/traffic-monitor/traffic.db")
    }

    private init() {
        openDatabase()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func openDatabase() {
        let url = dbFileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if sqlite3_open(url.path, &db) != SQLITE_OK {
            return
        }

        sqlite3_busy_timeout(db, 3000)
        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")

        let createTrafficSQL = """
        CREATE TABLE IF NOT EXISTS traffic_hourly (
            bucket_ts INTEGER NOT NULL,
            process_name TEXT NOT NULL,
            remote_ip TEXT NOT NULL,
            remote_port INTEGER NOT NULL,
            proto TEXT NOT NULL,
            bytes_in INTEGER NOT NULL DEFAULT 0,
            bytes_out INTEGER NOT NULL DEFAULT 0,
            first_seen INTEGER NOT NULL,
            last_seen INTEGER NOT NULL,
            PRIMARY KEY (bucket_ts, process_name, remote_ip, remote_port, proto)
        );
        CREATE INDEX IF NOT EXISTS idx_traffic_bucket ON traffic_hourly(bucket_ts);
        CREATE INDEX IF NOT EXISTS idx_traffic_proc ON traffic_hourly(process_name, bucket_ts);
        """
        execute(createTrafficSQL)

        let createDnsSQL = """
        CREATE TABLE IF NOT EXISTS dns_cache (
            ip TEXT PRIMARY KEY,
            hostname TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """
        execute(createDnsSQL)
    }

    private func execute(_ sql: String) {
        guard let db = db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func recordSamples(_ records: [TrafficSampleRecord]) {
        guard !records.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            self.execute("BEGIN IMMEDIATE TRANSACTION;")
            let sql = """
            INSERT INTO traffic_hourly
                (bucket_ts, process_name, remote_ip, remote_port, proto, bytes_in, bytes_out, first_seen, last_seen)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bucket_ts, process_name, remote_ip, remote_port, proto) DO UPDATE SET
                bytes_in = bytes_in + excluded.bytes_in,
                bytes_out = bytes_out + excluded.bytes_out,
                first_seen = MIN(first_seen, excluded.first_seen),
                last_seen = MAX(last_seen, excluded.last_seen);
            """
            var stmt: OpaquePointer?
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for r in records {
                    sqlite3_reset(stmt)
                    sqlite3_bind_int64(stmt, 1, r.bucketTs)
                    sqlite3_bind_text(stmt, 2, r.processName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, r.remoteIP, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(stmt, 4, Int32(r.remotePort))
                    sqlite3_bind_text(stmt, 5, r.proto, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 6, r.bytesIn)
                    sqlite3_bind_int64(stmt, 7, r.bytesOut)
                    sqlite3_bind_int64(stmt, 8, r.timestamp)
                    sqlite3_bind_int64(stmt, 9, r.timestamp)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            self.execute("COMMIT;")
        }
    }

    func saveHostname(_ hostname: String, forIP ip: String) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = "INSERT OR REPLACE INTO dns_cache (ip, hostname, updated_at) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, ip, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, hostname, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    func loadDnsCache() -> [String: String] {
        var result: [String: String] = [:]
        queue.sync {
            guard let db = self.db else { return }
            let sql = "SELECT ip, hostname FROM dns_cache;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cIP = sqlite3_column_text(stmt, 0),
                       let cHost = sqlite3_column_text(stmt, 1) {
                        result[String(cString: cIP)] = String(cString: cHost)
                    }
                }
                sqlite3_finalize(stmt)
            }
        }
        return result
    }

    func fetchProcessSummaries(sinceBucket: Int64) -> [ProcessTrafficSummary] {
        var list: [ProcessTrafficSummary] = []
        queue.sync {
            guard let db = self.db else { return }
            let sql = """
            SELECT process_name,
                   SUM(bytes_in) as total_in,
                   SUM(bytes_out) as total_out,
                   MAX(last_seen) as last_active,
                   COUNT(DISTINCT remote_ip || ':' || remote_port) as dest_cnt
            FROM traffic_hourly
            WHERE bucket_ts >= ?
            GROUP BY process_name
            ORDER BY (total_in + total_out) DESC;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, sinceBucket)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cName = sqlite3_column_text(stmt, 0) else { continue }
                    let name = String(cString: cName)
                    let bIn = sqlite3_column_int64(stmt, 1)
                    let bOut = sqlite3_column_int64(stmt, 2)
                    let lastSeen = sqlite3_column_int64(stmt, 3)
                    let destCnt = Int(sqlite3_column_int(stmt, 4))
                    list.append(ProcessTrafficSummary(
                        processName: name,
                        bytesIn: bIn,
                        bytesOut: bOut,
                        lastSeen: lastSeen,
                        destinationCount: destCnt
                    ))
                }
                sqlite3_finalize(stmt)
            }
        }
        return list
    }

    func fetchDestinations(sinceBucket: Int64, processName: String?, dnsMap: [String: String]) -> [DestinationTrafficSummary] {
        var list: [DestinationTrafficSummary] = []
        queue.sync {
            guard let db = self.db else { return }
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let sql: String
            if processName != nil {
                sql = """
                SELECT t.remote_ip, t.remote_port, t.proto,
                       COALESCE(d.hostname, ''),
                       SUM(t.bytes_in) as total_in,
                       SUM(t.bytes_out) as total_out,
                       MIN(t.first_seen) as f_seen,
                       MAX(t.last_seen) as l_seen,
                       t.process_name
                FROM traffic_hourly t
                LEFT JOIN dns_cache d ON d.ip = t.remote_ip
                WHERE t.bucket_ts >= ? AND t.process_name = ?
                GROUP BY t.remote_ip, t.remote_port, t.proto
                ORDER BY (total_in + total_out) DESC
                LIMIT 500;
                """
            } else {
                sql = """
                SELECT t.remote_ip, t.remote_port, t.proto,
                       COALESCE(d.hostname, ''),
                       SUM(t.bytes_in) as total_in,
                       SUM(t.bytes_out) as total_out,
                       MIN(t.first_seen) as f_seen,
                       MAX(t.last_seen) as l_seen,
                       GROUP_CONCAT(DISTINCT t.process_name)
                FROM traffic_hourly t
                LEFT JOIN dns_cache d ON d.ip = t.remote_ip
                WHERE t.bucket_ts >= ?
                GROUP BY t.remote_ip, t.remote_port, t.proto
                ORDER BY (total_in + total_out) DESC
                LIMIT 500;
                """
            }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, sinceBucket)
                if let proc = processName {
                    sqlite3_bind_text(stmt, 2, proc, -1, SQLITE_TRANSIENT)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cIP = sqlite3_column_text(stmt, 0),
                          let cProto = sqlite3_column_text(stmt, 2) else { continue }
                    let ip = String(cString: cIP)
                    let port = Int(sqlite3_column_int(stmt, 1))
                    let proto = String(cString: cProto)
                    let dbHost = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                    let bIn = sqlite3_column_int64(stmt, 4)
                    let bOut = sqlite3_column_int64(stmt, 5)
                    let fSeen = sqlite3_column_int64(stmt, 6)
                    let lSeen = sqlite3_column_int64(stmt, 7)
                    let procs = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
                    let resolvedHost = !dbHost.isEmpty ? dbHost : dnsMap[ip]
                    list.append(DestinationTrafficSummary(
                        remoteIP: ip,
                        remotePort: port,
                        proto: proto,
                        hostname: resolvedHost,
                        bytesIn: bIn,
                        bytesOut: bOut,
                        firstSeen: fSeen,
                        lastSeen: lSeen,
                        processNames: procs
                    ))
                }
                sqlite3_finalize(stmt)
            }
        }
        return list
    }

    func fetchTimeline(sinceBucket: Int64, bucketSeconds: Int64, processName: String?) -> [TimelineBucket] {
        var list: [TimelineBucket] = []
        queue.sync {
            guard let db = self.db else { return }
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let sql: String
            if processName != nil {
                sql = """
                SELECT (bucket_ts / ?) * ? as grp_ts,
                       SUM(bytes_in),
                       SUM(bytes_out)
                FROM traffic_hourly
                WHERE bucket_ts >= ? AND process_name = ?
                GROUP BY grp_ts
                ORDER BY grp_ts ASC;
                """
            } else {
                sql = """
                SELECT (bucket_ts / ?) * ? as grp_ts,
                       SUM(bytes_in),
                       SUM(bytes_out)
                FROM traffic_hourly
                WHERE bucket_ts >= ?
                GROUP BY grp_ts
                ORDER BY grp_ts ASC;
                """
            }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, bucketSeconds)
                sqlite3_bind_int64(stmt, 2, bucketSeconds)
                sqlite3_bind_int64(stmt, 3, sinceBucket)
                if let proc = processName {
                    sqlite3_bind_text(stmt, 4, proc, -1, SQLITE_TRANSIENT)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let ts = sqlite3_column_int64(stmt, 0)
                    let bIn = sqlite3_column_int64(stmt, 1)
                    let bOut = sqlite3_column_int64(stmt, 2)
                    list.append(TimelineBucket(timestamp: ts, bytesIn: bIn, bytesOut: bOut))
                }
                sqlite3_finalize(stmt)
            }
        }
        return list
    }

    func clearAllData() {
        queue.sync {
            execute("DELETE FROM traffic_hourly;")
        }
    }
}
