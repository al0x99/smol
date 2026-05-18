import Foundation
import Testing
@testable import smol

// MARK: - ProcessAnalyzer.findSuspiciousProcesses
//
// The instance method that drives the menu-bar suspicious-process count
// is a thin wrapper around this pure static, so testing the static
// covers the actual logic without having to hit the kernel via
// proc_listallpids. The reference values below (cpuThreshold = 30%,
// minRunning = 10 min, cpuTimeThreshold = 5 min) match the "Balanced"
// AlertSettings preset that the app ships with by default.
//
// Detection rule: process must (a) not be on the system-process skip
// list, (b) have run at least `minRunningMinutes`, (c) have used more
// CPU time than `cpuTimeThresholdMinutes`, AND (d) average above
// `cpuThresholdPercent` since start.

@MainActor
struct ProcessAnalyzerSuspiciousTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func proc(
        pid: Int32 = 1,
        name: String = "test",
        cpuTimeSeconds: Double = 0,
        memoryBytes: UInt64 = 0,
        startedAgo: TimeInterval = 0
    ) -> ProcessBasicInfo {
        ProcessBasicInfo(
            pid: pid,
            name: name,
            cpuTimeSeconds: cpuTimeSeconds,
            memoryBytes: memoryBytes,
            startTime: now.addingTimeInterval(-startedAgo)
        )
    }

    private func run(_ processes: [ProcessBasicInfo],
                     systemProcesses: Set<String> = []) -> [smol.ProcessInfo] {
        ProcessAnalyzer.findSuspiciousProcesses(
            in: processes,
            cpuThresholdPercent: 30,
            minRunningMinutes: 10,
            cpuTimeThresholdMinutes: 5,
            now: now,
            skipping: systemProcesses
        )
    }

    @Test func systemProcessesAreSkipped() {
        let p = proc(name: "kernel_task",
                     cpuTimeSeconds: 60 * 60,   // 60 min of CPU
                     startedAgo: 60 * 60)       // 60 min running ⇒ 100% avg
        let result = run([p], systemProcesses: ["kernel_task"])
        #expect(result.isEmpty, "system process must be filtered even if it would otherwise look suspicious")
    }

    @Test func recentlyStartedIsSkipped() {
        // 9 minutes ago — below the 10-minute floor. CPU% would be huge
        // (used 8 min of CPU in 9 min wall time) but we don't trust
        // short-window samples.
        let p = proc(name: "burst", cpuTimeSeconds: 60 * 8, startedAgo: 60 * 9)
        #expect(run([p]).isEmpty)
    }

    @Test func belowCPUTimeFloorIsSkipped() {
        // 4 min of CPU is below the 5-min cpuTimeThreshold even though
        // the average is well above 30% — the rule requires BOTH.
        let p = proc(name: "spike", cpuTimeSeconds: 60 * 4, startedAgo: 60 * 60)
        #expect(run([p]).isEmpty)
    }

    @Test func belowCPUPercentFloorIsSkipped() {
        // Process has been running for 24 hours, used 6 min of CPU.
        // cpuTimeMinutes (6) > 5, but average 6/1440 = 0.4% ≪ 30%.
        let p = proc(name: "lightweight", cpuTimeSeconds: 60 * 6, startedAgo: 60 * 60 * 24)
        #expect(run([p]).isEmpty)
    }

    @Test func runawayProcessIsCaught() {
        // The Logitech case: lots of CPU time, high average.
        // 30 min of CPU in 60 min running = 50% avg, above all floors.
        let p = proc(name: "logioptionsplus",
                     cpuTimeSeconds: 60 * 30,
                     startedAgo: 60 * 60)
        let result = run([p])
        #expect(result.count == 1)
        #expect(result.first?.name == "logioptionsplus")
        #expect(result.first.map { abs($0.cpuPercent - 50) < 0.0001 } ?? false)
    }

    @Test func resultsSortedByCPUDescending() {
        let p1 = proc(pid: 1, name: "a", cpuTimeSeconds: 60 * 10, startedAgo: 60 * 60)   // 10/60 = 16.67% (skipped)
        let p2 = proc(pid: 2, name: "b", cpuTimeSeconds: 60 * 30, startedAgo: 60 * 60)   // 50%
        let p3 = proc(pid: 3, name: "c", cpuTimeSeconds: 60 * 45, startedAgo: 60 * 60)   // 75%
        let p4 = proc(pid: 4, name: "d", cpuTimeSeconds: 60 * 20, startedAgo: 60 * 60)   // 33.33%
        let result = run([p1, p2, p3, p4])
        #expect(result.map(\.name) == ["c", "b", "d"])
    }

    @Test func boundaryAtExactlyMinRunningMinutesIsSkipped() {
        // Rule is `<`, so exactly 10 minutes running is allowed through
        // and we then check the CPU floors.
        let p = proc(name: "exact",
                     cpuTimeSeconds: 60 * 10,    // 10 min CPU > 5 min floor
                     startedAgo: 60 * 10)         // 100% avg
        let result = run([p])
        #expect(result.count == 1, "exactly 10 minutes is not 'too recently started'")
    }
}

// MARK: - ProcessAnalyzer.findKnownBloatware

@MainActor
struct ProcessAnalyzerBloatwareTests {

    private func proc(pid: Int32, name: String, memory: UInt64 = 0) -> ProcessBasicInfo {
        ProcessBasicInfo(pid: pid,
                         name: name,
                         cpuTimeSeconds: 0,
                         memoryBytes: memory,
                         startTime: Date())
    }

    private let adobe = KnownBloatware(
        name: "Adobe Creative Cloud",
        processes: ["AdobeIPCBroker", "CCLibrary", "CCXProcess"],
        reason: "many background processes",
        removalSafe: false
    )

    @Test func multipleMatchingPatternsCollapseToOneEntry() {
        // The original bug: with 3 patterns and 3 distinct processes
        // matching, the old code produced 3 BloatwareMatch entries each
        // listing one process. The fix collapses them into one entry
        // listing all three.
        let procs = [
            proc(pid: 100, name: "AdobeIPCBroker", memory: 100_000_000),
            proc(pid: 101, name: "CCLibrary",      memory:  50_000_000),
            proc(pid: 102, name: "CCXProcess",     memory:  25_000_000),
        ]
        let matches = ProcessAnalyzer.findKnownBloatware(in: procs, knownBloatware: [adobe])
        #expect(matches.count == 1, "one bloatware entry → one match, regardless of pattern count")
        #expect(matches.first?.runningProcesses.sorted() == ["AdobeIPCBroker", "CCLibrary", "CCXProcess"])
        #expect(matches.first?.totalMemoryBytes == 175_000_000)
    }

    @Test func caseInsensitiveMatching() {
        let procs = [proc(pid: 1, name: "adobeipcbroker")]
        let matches = ProcessAnalyzer.findKnownBloatware(in: procs, knownBloatware: [adobe])
        #expect(matches.count == 1)
        #expect(matches.first?.runningProcesses == ["adobeipcbroker"])
    }

    @Test func substringMatching() {
        // The patterns are matched as substrings (the existing convention),
        // so "AdobeIPCBrokerCLI" still counts.
        let procs = [proc(pid: 1, name: "AdobeIPCBrokerCLI")]
        let matches = ProcessAnalyzer.findKnownBloatware(in: procs, knownBloatware: [adobe])
        #expect(matches.count == 1)
    }

    @Test func noMatchesProducesEmpty() {
        let procs = [proc(pid: 1, name: "Safari"), proc(pid: 2, name: "Mail")]
        #expect(ProcessAnalyzer.findKnownBloatware(in: procs, knownBloatware: [adobe]).isEmpty)
    }

    @Test func sameProcessMatchedByTwoPatternsCountedOnce() {
        // Pathological bloatware definition where two patterns both
        // match the same process. The dedup-by-PID guarantee means it
        // doesn't get added twice to runningProcesses and its memory
        // isn't double-counted.
        let redundant = KnownBloatware(
            name: "Redundant",
            processes: ["Adobe", "AdobeIPC"],   // both match "AdobeIPCBroker"
            reason: "duplicate patterns",
            removalSafe: false
        )
        let procs = [proc(pid: 1, name: "AdobeIPCBroker", memory: 100_000_000)]
        let matches = ProcessAnalyzer.findKnownBloatware(in: procs, knownBloatware: [redundant])
        #expect(matches.count == 1)
        #expect(matches.first?.runningProcesses.count == 1)
        #expect(matches.first?.totalMemoryBytes == 100_000_000)
    }

    @Test func multipleBloatwareEntriesProduceMultipleMatches() {
        let logitech = KnownBloatware(
            name: "Logitech Options+",
            processes: ["logioptionsplus"],
            reason: "updater loop",
            removalSafe: true
        )
        let procs = [
            proc(pid: 1, name: "AdobeIPCBroker"),
            proc(pid: 2, name: "logioptionsplus"),
        ]
        let matches = ProcessAnalyzer.findKnownBloatware(in: procs, knownBloatware: [adobe, logitech])
        #expect(matches.count == 2)
        #expect(Set(matches.map(\.bloatware.name)) == ["Adobe Creative Cloud", "Logitech Options+"])
    }
}
