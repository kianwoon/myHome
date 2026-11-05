// Bounds an await: the result of `operation`, or nil when `seconds` pass (or the
// calling task is cancelled) first. Unlike a task group this returns at the
// deadline even if the operation never reaches a cancellation point — a hung
// model or bridge call cannot hold the caller (and the UI spinner) hostage.
import Foundation

private final class DeadlineBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if finished { task.cancel() } else { tasks.append(task) }
    }

    func finish(_ value: T?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let pending = continuation
        continuation = nil
        let running = tasks
        tasks = []
        lock.unlock()
        running.forEach { $0.cancel() }
        pending?.resume(returning: value)
    }
}

public enum Deadline {
    public static func run<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let box = DeadlineBox<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                box.install(continuation)
                box.add(Task { box.finish(await operation()) })
                box.add(Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                    box.finish(nil)
                })
            }
        } onCancel: {
            box.finish(nil)
        }
    }
}
