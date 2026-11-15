// baseline-guard:allow new source file, no prior baseline
// How one command's devices are run: different devices concurrently (capped
// by `ControlConfig.parallelDevices`), each inside its own per-device budget
// and all inside one global budget; writes to the same device strictly in
// order (DeviceWriteGate, shared by every command). A device whose write had
// an unknown outcome is read back and, for idempotent commands only, written
// again (WriteRetryPolicy). Every outcome carries its own message and the
// number of writes actually sent.
import Foundation

/// FIFO per-device serialization of async work on the main actor. A caller
/// cancelled while waiting never starts its work; the gate is released when
/// the work (or its cancellation) finishes.
@MainActor
final class DeviceWriteGate {
    private var tails: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]

    /// Runs `operation` after every earlier operation for `id` finished.
    /// nil when the caller was cancelled before the operation started.
    func run<T: Sendable>(_ id: String, _ operation: @escaping @MainActor () async -> T) async -> T? {
        let previous = tails[id]
        let work = Task { @MainActor () -> T? in
            await previous?.value
            if Task.isCancelled { return nil }
            return await operation()
        }
        let token = UUID()
        tails[id] = Task { @MainActor in _ = await work.value }
        tokens[id] = token
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if tokens[id] == token {
            tails[id] = nil
            tokens[id] = nil
        }
        return result
    }

    /// Test seam: ids with work queued or running.
    var busyIDs: Set<String> { Set(tails.keys) }
}

/// Writes actually handed to a transport for one device in one command.
@MainActor
final class WriteCounter {
    var sent = 0
}

struct DeviceRunResult: Sendable {
    let status: OutcomeStatus
    let attempts: Int
}

extension DeviceController {
    // allow-hardcode: spoken UI copy.
    static let notAttemptedText = "was not attempted (the command ran out of time)"

    static func noReplyWithin(_ seconds: TimeInterval, attempts: Int) -> String {
        let shown = seconds < 1 ? String(format: "%.1f", seconds) : "\(Int(seconds.rounded()))"
        return attempts == 0
            ? "was not sent: the device was still busy after \(shown)s"
            : "gave no reply within \(shown)s; it may still apply the change"
    }

    /// Runs every allowed target (concurrently across devices, capped) and
    /// returns one outcome per decision, in target order.
    func runTargets(_ decisions: [(Device, PolicyDecision)], command: DeviceCommand) async -> [DeviceOutcome] {
        var outcomes = [DeviceOutcome?](repeating: nil, count: decisions.count)
        var jobs: [(index: Int, device: Device, plan: CapabilityMap.WritePlan)] = []
        for (index, (device, decision)) in decisions.enumerated() {
            switch decision {
            case .denied(let status):
                AppLog.control.notice("MyHome: verify pre id=\(device.id, privacy: .public) name=\(device.name, privacy: .public) refused=\(status.reason, privacy: .public)")
                outcomes[index] = DeviceOutcome(device: summary(for: device), status: status, attempts: 0)
            case .allowed(let plan):
                jobs.append((index, device, plan))
            }
        }
        let globalDeadline = Date().addingTimeInterval(config.globalBudget)
        let cap = max(config.parallelDevices, 1)
        await withTaskGroup(of: (Int, DeviceRunResult).self) { group in
            var pending = jobs.makeIterator()
            var running = 0
            while running < cap, let job = pending.next() {
                group.addTask { @MainActor in (job.index, await self.runOne(job.plan, on: job.device, command: command, until: globalDeadline)) }
                running += 1
            }
            while let (index, result) = await group.next() {
                outcomes[index] = DeviceOutcome(device: summary(for: decisions[index].0), status: result.status, attempts: result.attempts)
                if let job = pending.next() {
                    group.addTask { @MainActor in (job.index, await self.runOne(job.plan, on: job.device, command: command, until: globalDeadline)) }
                }
            }
        }
        return outcomes.enumerated().map { index, outcome in
            outcome ?? DeviceOutcome(device: summary(for: decisions[index].0), status: .denied(Self.notAttemptedText), attempts: 0)
        }
    }

    /// One device: gate → pre-check → write (+ retries) → verify, bounded by
    /// min(per-device budget, what is left of the global budget).
    private func runOne(_ plan: CapabilityMap.WritePlan, on device: Device, command: DeviceCommand, until globalDeadline: Date) async -> DeviceRunResult {
        let remaining = globalDeadline.timeIntervalSinceNow
        guard remaining > 0, !Task.isCancelled else {
            return DeviceRunResult(status: .denied(Self.notAttemptedText), attempts: 0)
        }
        let budget = min(config.perDeviceBudget, remaining)
        let deviceDeadline = Date().addingTimeInterval(budget)
        let counter = WriteCounter()
        let gate = writeGate
        let status = await Deadline.run(seconds: budget) { @MainActor [weak self] () -> OutcomeStatus? in
            guard let self else { return nil }
            return await gate.run(device.id) { @MainActor () -> OutcomeStatus? in
                guard !Task.isCancelled else { return nil }
                await self.precheck(device)
                guard !Task.isCancelled else { return nil }
                return await self.executeWithRetry(plan, on: device, command: command, counter: counter, until: deviceDeadline)
            } ?? nil
        } ?? nil
        guard let status else {
            let text = Self.noReplyWithin(budget, attempts: counter.sent)
            AppLog.control.notice("MyHome: verify post id=\(device.id, privacy: .public) name=\(device.name, privacy: .public) result=timeout attempts=\(counter.sent, privacy: .public) budget=\(budget, privacy: .public)")
            return DeviceRunResult(status: counter.sent == 0 ? .denied(text) : .uncertain(text), attempts: counter.sent)
        }
        return DeviceRunResult(status: status, attempts: counter.sent)
    }

    /// The first write, then — only while the outcome is unknown, the command
    /// is idempotent and enough of the device budget is left — back off, read
    /// the device, and write again only if it still does not show the value.
    /// A retry that runs out of budget keeps the previous attempt's status.
    func executeWithRetry(_ plan: CapabilityMap.WritePlan, on device: Device, command: DeviceCommand,
                          counter: WriteCounter, until deadline: Date) async -> OutcomeStatus {
        let firstStarted = Date()
        var attempt = await execute(plan, on: device, counter: counter)
        var retry = 0
        let policy = config.retry
        while attempt.ambiguous, !attempt.status.wasSent, !Task.isCancelled,
              policy.allowsRetry(command, attempts: counter.sent, remaining: deadline.timeIntervalSinceNow) {
            retry += 1
            let window = deadline.timeIntervalSinceNow - AppSettings.defaultControlReplyGrace
            AppLog.control.notice("MyHome: retry id=\(device.id, privacy: .public) name=\(device.name, privacy: .public) retry=\(retry, privacy: .public) after=\(attempt.status.label, privacy: .public) window=\(window, privacy: .public)")
            let number = retry
            let next = await Deadline.run(seconds: max(window, 0)) { @MainActor [weak self] () -> WriteAttempt? in
                guard let self else { return nil }
                return await self.retryOnce(plan, on: device, retry: number, since: firstStarted, counter: counter)
            } ?? nil
            guard let next else { break }
            attempt = next
        }
        return attempt.status
    }

    /// Backoff, re-read, and (unless the device already shows the value) one
    /// more write. nil when cancelled during the wait.
    private func retryOnce(_ plan: CapabilityMap.WritePlan, on device: Device, retry: Int, since started: Date,
                           counter: WriteCounter) async -> WriteAttempt? {
        let delay = config.retry.delay(beforeRetry: retry)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        guard !Task.isCancelled else { return nil }
        let expectation = CapabilityMap.expectation(for: plan)
        let store = self.store
        if let reading = await Deadline.run(seconds: config.verifyTimeout, { @MainActor in await store.readBack(device) }),
           case .match = compare(expectation, to: reading, since: started, device: device) {
            return .definite(finish(device, expectation: expectation, result: .confirmed, evidence: "read-back before retry via \(reading.via)"))
        }
        guard !Task.isCancelled else { return nil }
        return await execute(plan, on: device, counter: counter)
    }
}
