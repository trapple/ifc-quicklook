// ifcql-bench: パース時間・三角形数・ピークメモリを計測する CLI。
// 性能回帰チェックに使う（QL 拡張を経由せずコアだけを測る）。
import Foundation

/// プロセスのピーク物理メモリ (MB)
func peakMemoryMB() -> Double {
    var info = rusage_info_current()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
        }
    }
    guard ok == 0 else { return -1 }
    return Double(info.ri_lifetime_max_phys_footprint) / 1024 / 1024
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: ifcql-bench <file.ifc>\n".data(using: .utf8)!)
    exit(2)
}
let path = CommandLine.arguments[1]

let start = ContinuousClock.now
let batcher = MeshBatcher()
let bridge = WebIFCBridge()
do {
    let info = try bridge.streamMeshes(fromFileAtPath: path, memoryCapMB: 0) { batcher.add($0) }
    let batches = batcher.drain()
    let seconds = Double((ContinuousClock.now - start) / .milliseconds(1)) / 1000
    print("schema=\(info.schemaVersion) elements=\(info.elementCount) " +
          "triangles=\(batcher.totalTriangles) colors=\(batches.count) " +
          "skipped=\(batcher.skippedElements) " +
          String(format: "parse_s=%.2f peak_mem_mb=%.0f", seconds, peakMemoryMB()))
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
