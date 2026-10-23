import Backstage
import Foundation

/// Reports in the form MetricKit delivers them, so the Performance tab has something to show in
/// the simulator, which never gets real ones.
enum SampleIOSReports {
    static func add() {
        IOSReportStore.shared.add(.diagnostics, json: diagnostics)
        IOSReportStore.shared.add(.metrics, json: metrics)
    }

    private static let diagnostics = Data(#"""
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

    private static let metrics = Data(#"""
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
