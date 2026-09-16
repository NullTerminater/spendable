import Foundation
import Testing
@testable import Spendable

@Suite("Waiting for the network without polling")
@MainActor
struct NetworkReadinessTests {
    @Test("an unsatisfied path times out and a later wait remains independent")
    func offlineTimeout() async {
        // Keep real NWPathMonitor events out of this deterministic offline case.
        let network = NetworkReadiness(startMonitoring: false)
        #expect(await network.waitUntilOnline(timeout: .milliseconds(10)) == false)
        #expect(await network.waitUntilOnline(timeout: .milliseconds(10)) == false)
    }

    @Test("cancelling a suspended wait resumes it without waiting for its deadline")
    func cancelledWait() async {
        let network = NetworkReadiness(startMonitoring: false)
        let wait = Task { await network.waitUntilOnline(timeout: .seconds(60)) }
        await Task.yield()
        wait.cancel()
        #expect(await wait.value == false)
        #expect(await network.waitUntilOnline(timeout: .milliseconds(10)) == false)
    }
}
