import XCTest
@testable import CopyCat

final class TailscaleStatusCacheTests: XCTestCase {
    private func peer(_ name: String) -> TailscalePeer {
        TailscalePeer(hostname: name, online: true, os: nil)
    }

    // Thread-safe call counter for the concurrency test; a captured `var`
    // can't be mutated from concurrently-executing code under Swift 6.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testFirstCallFetches() {
        let cache = TailscaleStatusCache(ttl: 30)
        let result = cache.peers { [peer("a")] }
        XCTAssertEqual(result.map(\.hostname), ["a"])
    }

    func testServesCachedWithinTTL() {
        let cache = TailscaleStatusCache(ttl: 30)
        let t0 = Date()
        var calls = 0
        _ = cache.peers(now: t0) { calls += 1; return [self.peer("a")] }
        let second = cache.peers(now: t0.addingTimeInterval(29)) { calls += 1; return [self.peer("b")] }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(second.map(\.hostname), ["a"])
    }

    func testRefetchesPastTTL() {
        let cache = TailscaleStatusCache(ttl: 30)
        let t0 = Date()
        var calls = 0
        _ = cache.peers(now: t0) { calls += 1; return [self.peer("a")] }
        let second = cache.peers(now: t0.addingTimeInterval(31)) { calls += 1; return [self.peer("b")] }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(second.map(\.hostname), ["b"])
    }

    func testMaxAgeZeroForcesRefetch() {
        let cache = TailscaleStatusCache(ttl: 30)
        let t0 = Date()
        var calls = 0
        _ = cache.peers(now: t0) { calls += 1; return [self.peer("a")] }
        let second = cache.peers(maxAge: 0, now: t0) { calls += 1; return [self.peer("b")] }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(second.map(\.hostname), ["b"])
    }

    // Failure results must be cached like any other: refetching a wedged
    // daemon on every call is the stall the cache exists to prevent.
    func testEmptyResultIsCached() {
        let cache = TailscaleStatusCache(ttl: 30)
        let t0 = Date()
        var calls = 0
        _ = cache.peers(now: t0) { calls += 1; return [] }
        let second = cache.peers(now: t0.addingTimeInterval(5)) { calls += 1; return [self.peer("b")] }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(second, [])
    }

    // A burst of concurrent callers (one per rapid ⌘⌥V press) must ride a
    // single fetch: the first spawns it, the rest block and reuse. Each
    // caller's default `now` predates the fetch's completion, so the TTL
    // check passes for all of them once the result lands.
    func testBurstCallersShareOneFetch() {
        let cache = TailscaleStatusCache(ttl: 30)
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 5) { _ in
            _ = cache.peers {
                counter.increment()
                Thread.sleep(forTimeInterval: 0.1)
                return []
            }
        }
        XCTAssertEqual(counter.count, 1)
    }
}
