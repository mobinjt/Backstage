import Foundation
import Testing
@testable import BackstageCore

/// Samples in the form MetricKit's `jsonRepresentation()` writes.
enum SampleReports {
    static let diagnostics = Data(#"""
    {
      "timeStampBegin": "2026-10-22 00:00:00",
      "timeStampEnd": "2026-10-22 23:59:00",
      "crashDiagnostics": [{
        "version": "1.0.0",
        "diagnosticMetaData": {
          "appVersion": "1.0", "appBuildVersion": "1", "osVersion": "iPhone OS 27.0",
          "deviceType": "iPhone18,1", "exceptionType": 1, "exceptionCode": 0, "signal": 11,
          "virtualMemoryRegionInfo": "0 is not in any region."
        },
        "callStackTree": {
          "callStackPerThread": true,
          "callStacks": [
            {"threadAttributed": false, "callStackRootFrames": [{"binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 4096, "address": 7000, "sampleCount": 1}]},
            {"threadAttributed": true, "callStackRootFrames": [{
              "binaryName": "MyApp", "binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743",
              "offsetIntoBinaryTextSegment": 6688, "address": 4302348960, "sampleCount": 1,
              "subFrames": [{"binaryName": "UIKitCore", "offsetIntoBinaryTextSegment": 160, "address": 6000, "sampleCount": 1}]
            }]}
          ]
        }
      }],
      "hangDiagnostics": [{
        "diagnosticMetaData": {"appVersion": "1.0", "hangDuration": "3.5 sec"},
        "callStackTree": {"callStackPerThread": true, "callStacks": []}
      }]
    }
    """#.utf8)

    static let metrics = Data(#"""
    {
      "appVersion": "1.0",
      "timeStampBegin": "2026-10-21 00:00:00",
      "timeStampEnd": "2026-10-21 23:59:00",
      "applicationLaunchMetrics": {
        "histogrammedTimeToFirstDrawKey": {"histogramNumBuckets": 2, "histogramValue": {
          "0": {"bucketCount": 3, "bucketStart": "500 ms", "bucketEnd": "510 ms"},
          "1": {"bucketCount": 40, "bucketStart": "1000 ms", "bucketEnd": "1010 ms"}
        }}
      },
      "memoryMetrics": {"peakMemoryUsage": "180,000 kB"},
      "cpuMetrics": {"cumulativeCPUTime": "100 sec"},
      "applicationTimeMetrics": {"cumulativeForegroundTime": "700 sec", "cumulativeBackgroundTime": "40 sec"}
    }
    """#.utf8)
}

struct IOSReportTests {
    @Test func aCrashIsReadWithItsAttributedThread() throws {
        let report = IOSReport(kind: .diagnostics, json: SampleReports.diagnostics)
        let diagnostics = report.diagnostics
        #expect(diagnostics.map(\.kind) == [.crash, .hang])
        let crash = try #require(diagnostics.first)
        #expect(crash.summary == "SIGSEGV (signal 11)")
        #expect(crash.callStack.map(\.text) == ["MyApp + 0x1a20", "UIKitCore + 0xa0"], "The thread it's about, depth first")
        #expect(crash.callStack.map(\.depth) == [0, 1])
        #expect(crash.details.contains { $0.key == "deviceType" && $0.value == "iPhone18,1" })
        #expect(diagnostics.last?.summary == "Hung for 3.5 sec")
        #expect(report.dailySummary == nil)
    }

    @Test func aDailyReportGivesItsKeyNumbers() throws {
        let summary = try #require(IOSReport(kind: .metrics, json: SampleReports.metrics).dailySummary)
        #expect(summary.appVersion == "1.0")
        #expect(summary.values.first { $0.name == "Typical launch" }?.value == "1000–1010 ms", "The bucket most launches fall in")
        #expect(summary.values.first { $0.name == "Peak memory" }?.value == "180,000 kB")
        #expect(summary.values.first { $0.name == "On screen" }?.value == "700 sec")
        #expect(summary.begin != nil)
    }

    @Test func eachReportIsKeptOnceAndOldOnesGo() {
        let directory = URL.temporaryDirectory.appending(path: "backstage-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSReportStore(directory: directory)
        store.add(.diagnostics, json: SampleReports.diagnostics)
        store.add(.diagnostics, json: SampleReports.diagnostics)
        store.add(.metrics, json: SampleReports.metrics, received: .now.addingTimeInterval(-IOSReportStore.keptFor - 60))
        #expect(store.reports.map(\.kind) == [.diagnostics], "The same report delivered twice is kept once; the old one is gone")
        store.clear()
        #expect(store.reports.isEmpty)
    }
}
