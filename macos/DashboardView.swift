import Charts
import Cocoa
import SwiftUI

struct DashboardView: View {
    @ObservedObject var monitor = TrafficMonitor.shared

    @State private var selectedRange: TimeRange = .day24h
    @State private var searchText: String = ""
    @State private var sortOrder: ProcessSortOrder = .totalDesc
    @State private var selectedProcess: String? = nil

    @State private var processes: [ProcessTrafficSummary] = []
    @State private var destinations: [DestinationTrafficSummary] = []
    @State private var timeline: [TimelineBucket] = []

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            summaryCards
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            timelineSection
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Divider()
            HSplitView {
                processesPane
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 500)
                destinationsPane
                    .frame(minWidth: 440, idealWidth: 620)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .onAppear { reloadData() }
        .onChange(of: selectedRange) { _ in reloadData() }
        .onChange(of: selectedProcess) { _ in reloadDestinationsAndTimeline() }
        .onChange(of: monitor.revision) { _ in reloadData() }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedRange) {
                Text(L10n.t("period_session")).tag(TimeRange.session)
                Text(L10n.t("period_24h")).tag(TimeRange.day24h)
                Text(L10n.t("period_7d")).tag(TimeRange.week7d)
                Text(L10n.t("period_30d")).tag(TimeRange.month30d)
                Text(L10n.t("period_all")).tag(TimeRange.allTime)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(L10n.t("search_placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 190)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))

            Button(action: exportCSV) {
                Label(L10n.t("export_csv"), systemImage: "square.and.arrow.up")
            }

            Button(action: reloadData) {
                Image(systemName: "arrow.clockwise")
            }
            .help(L10n.t("refresh"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var filteredProcesses: [ProcessTrafficSummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = q.isEmpty ? processes : processes.filter { $0.processName.lowercased().contains(q) }
        switch sortOrder {
        case .totalDesc: return base.sorted { $0.totalBytes > $1.totalBytes }
        case .outDesc: return base.sorted { $0.bytesOut > $1.bytesOut }
        case .inDesc: return base.sorted { $0.bytesIn > $1.bytesIn }
        case .nameAsc: return base.sorted { $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending }
        }
    }

    private var filteredDestinations: [DestinationTrafficSummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return destinations }
        return destinations.filter {
            $0.remoteIP.lowercased().contains(q) ||
            ($0.hostname?.lowercased().contains(q) ?? false) ||
            $0.processNames.lowercased().contains(q) ||
            "\($0.remotePort)".contains(q)
        }
    }

    private var totalSent: Int64 { processes.reduce(0) { $0 + $1.bytesOut } }
    private var totalRecv: Int64 { processes.reduce(0) { $0 + $1.bytesIn } }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            StatCard(
                title: L10n.t("sent"),
                value: ByteFormatter.format(totalSent),
                icon: "arrow.up.circle.fill",
                color: .orange
            )
            StatCard(
                title: L10n.t("received"),
                value: ByteFormatter.format(totalRecv),
                icon: "arrow.down.circle.fill",
                color: .blue
            )
            StatCard(
                title: L10n.t("total"),
                value: ByteFormatter.format(totalSent + totalRecv),
                icon: "network",
                color: .purple
            )
            StatCard(
                title: L10n.t("speed"),
                value: "↓ \(ByteFormatter.formatRate(monitor.currentInRate))  ↑ \(ByteFormatter.formatRate(monitor.currentOutRate))",
                icon: "speedometer",
                color: .green
            )
            StatCard(
                title: L10n.t("active_procs"),
                value: "\(processes.count)",
                icon: "app.badge",
                color: .secondary
            )
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.t("timeline"))
                    .font(.headline)
                if let proc = selectedProcess {
                    Text("— \(proc)")
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                }
                Spacer()
                HStack(spacing: 12) {
                    Label(L10n.t("sent"), systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Label(L10n.t("received"), systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }

            if timeline.isEmpty {
                HStack {
                    Spacer()
                    Text(L10n.t("no_traffic"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(height: 120)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(8)
            } else {
                let maxVal = timeline.map { max($0.bytesIn, $0.bytesOut) }.max() ?? 1
                let useGB = maxVal >= 1024 * 1024 * 1024
                let divisor: Double = useGB ? (1024 * 1024 * 1024) : (1024 * 1024)
                let unitLabel = useGB ? "GB" : "MB"

                Chart {
                    ForEach(timeline) { bucket in
                        let date = Date(timeIntervalSince1970: TimeInterval(bucket.timestamp))
                        BarMark(
                            x: .value("Time", date),
                            y: .value(unitLabel, Double(bucket.bytesOut) / divisor)
                        )
                        .foregroundStyle(Color.orange.opacity(0.85))
                        .position(by: .value("Type", "Sent"))

                        BarMark(
                            x: .value("Time", date),
                            y: .value(unitLabel, Double(bucket.bytesIn) / divisor)
                        )
                        .foregroundStyle(Color.blue.opacity(0.85))
                        .position(by: .value("Type", "Recv"))
                    }
                }
                .chartYAxisLabel(unitLabel)
                .frame(height: 130)
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
        }
    }

    private var processesPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("processes"))
                    .font(.headline)
                Spacer()
                if selectedProcess != nil {
                    Button(L10n.t("all_processes")) {
                        selectedProcess = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Picker("", selection: $sortOrder) {
                    Text(L10n.t("sort_total")).tag(ProcessSortOrder.totalDesc)
                    Text(L10n.t("sort_sent")).tag(ProcessSortOrder.outDesc)
                    Text(L10n.t("sort_recv")).tag(ProcessSortOrder.inDesc)
                    Text(L10n.t("sort_name")).tag(ProcessSortOrder.nameAsc)
                }
                .frame(width: 115)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            let list = filteredProcesses
            let maxTotal = max(1, list.map(\.totalBytes).max() ?? 1)

            List(list, selection: $selectedProcess) { proc in
                ProcessRowView(proc: proc, maxTotal: maxTotal, isSelected: selectedProcess == proc.processName)
                    .tag(proc.processName)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedProcess == proc.processName {
                            selectedProcess = nil
                        } else {
                            selectedProcess = proc.processName
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    private var destinationsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("destinations"))
                    .font(.headline)
                if let proc = selectedProcess {
                    Text("(\(proc))")
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                } else {
                    Text("(\(L10n.t("all_processes")))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(filteredDestinations.count) \(L10n.t("active_dests").lowercased())")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            Table(filteredDestinations) {
                TableColumn(L10n.t("host_ip")) { dest in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dest.displayHost)
                            .font(.system(.body, weight: .medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if dest.hostname != nil && dest.hostname != dest.remoteIP {
                                Text(dest.remoteIP)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if selectedProcess == nil && !dest.processNames.isEmpty {
                                Text(dest.processNames)
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .width(min: 180, ideal: 240)

                TableColumn(L10n.t("proto_port")) { dest in
                    Text("\(dest.proto) :\(dest.remotePort)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .width(min: 80, ideal: 95, max: 115)

                TableColumn(L10n.t("sent")) { dest in
                    Text(ByteFormatter.format(dest.bytesOut))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.orange)
                }
                .width(min: 75, ideal: 85, max: 105)

                TableColumn(L10n.t("received")) { dest in
                    Text(ByteFormatter.format(dest.bytesIn))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                }
                .width(min: 75, ideal: 85, max: 105)

                TableColumn(L10n.t("total")) { dest in
                    Text(ByteFormatter.format(dest.totalBytes))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }
                .width(min: 75, ideal: 85, max: 105)

                TableColumn(L10n.t("when_last")) { dest in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ByteFormatter.formatDate(dest.lastSeen))
                            .font(.caption2)
                        Text("\(L10n.t("when_first")): \(ByteFormatter.formatDate(dest.firstSeen))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .width(min: 135, ideal: 155)
            }
        }
    }

    private func reloadData() {
        processes = monitor.fetchProcesses(range: selectedRange)
        reloadDestinationsAndTimeline()
    }

    private func reloadDestinationsAndTimeline() {
        destinations = monitor.fetchDestinations(range: selectedRange, processName: selectedProcess)
        timeline = monitor.fetchTimeline(range: selectedRange, processName: selectedProcess)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "traffic-\(selectedRange.rawValue).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var csv = "Process,RemoteHost,RemoteIP,Port,Protocol,SentBytes,ReceivedBytes,TotalBytes,FirstSeen,LastSeen\n"
        for d in filteredDestinations {
            let host = (d.hostname ?? "").replacingOccurrences(of: ",", with: " ")
            let procs = d.processNames.replacingOccurrences(of: ",", with: ";")
            csv += "\"\(procs)\",\"\(host)\",\(d.remoteIP),\(d.remotePort),\(d.proto),\(d.bytesOut),\(d.bytesIn),\(d.totalBytes),\(ByteFormatter.formatDate(d.firstSeen)),\(ByteFormatter.formatDate(d.lastSeen))\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18)))
    }
}

private struct ProcessRowView: View {
    let proc: ProcessTrafficSummary
    let maxTotal: Int64
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let icon = TrafficMonitor.shared.iconForProcess(proc.processName) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(proc.processName)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)
                    Text("\(proc.destinationCount) \(L10n.t("active_dests").lowercased())")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteFormatter.format(proc.totalBytes))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    HStack(spacing: 6) {
                        Text("↑ \(ByteFormatter.format(proc.bytesOut))")
                            .foregroundColor(.orange)
                        Text("↓ \(ByteFormatter.format(proc.bytesIn))")
                            .foregroundColor(.blue)
                    }
                    .font(.system(.caption2, design: .monospaced))
                }
            }

            GeometryReader { geo in
                let ratio = maxTotal > 0 ? CGFloat(proc.totalBytes) / CGFloat(maxTotal) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule().fill(isSelected ? Color.accentColor : Color.blue.opacity(0.65))
                        .frame(width: max(3, geo.size.width * ratio))
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 4)
    }
}
