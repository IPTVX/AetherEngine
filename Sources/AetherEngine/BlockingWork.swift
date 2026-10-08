import Foundation

/// Where engine work that blocks its thread runs: a demuxer open, a packet read, a FIFO write
/// under backpressure, a `close()` that joins a pump, a `waitForFinish`.
///
/// `Task.detached` is no background thread. It runs on the Swift cooperative pool, which has one
/// thread per core and never grows, so every blocked job takes a core's worth of async work out
/// of the whole process, the host app's included. On a 3-core CI runner the test suite parked
/// all three for half a minute at a time (a 120 s time limit fired at 151 s, because the
/// watchdog is a task on the same pool), and an Apple TV has few more cores than that.
///
/// A task created here prefers `BlockingExecutor`, which runs its jobs on GCD's global queues.
/// Those add a thread when one blocks in the kernel, which is the whole difference. The task is
/// otherwise an ordinary one: it awaits, hops to the main actor and back, and is cancelled like
/// any other.
///
/// On iOS/tvOS 16–17 and macOS 14, executor preferences are unavailable. The fallback
/// retains the earlier detached-task execution and cancellation semantics; blocking work
/// can still occupy the cooperative pool on those systems.
enum BlockingWork {
    /// Starts independent work, retaining detached-task semantics below the executor API floor.
    @discardableResult
    static func detached<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        if #available(iOS 18, tvOS 18, macOS 15, visionOS 2, *) {
            return Task.detached(executorPreference: BlockingExecutor.shared, priority: priority, operation: operation)
        }
        return Task.detached(priority: priority, operation: operation)
    }

    /// Starts independent work, retaining detached-task semantics below the executor API floor.
    @discardableResult
    static func detached<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, any Error> {
        if #available(iOS 18, tvOS 18, macOS 15, visionOS 2, *) {
            return Task.detached(executorPreference: BlockingExecutor.shared, priority: priority, operation: operation)
        }
        return Task.detached(priority: priority, operation: operation)
    }
}

/// Runs each job on the GCD global queue that matches its priority. Stateless and shared, so a
/// task's preference never outlives what it points at.
@available(iOS 18, tvOS 18, macOS 15, visionOS 2, *)
final class BlockingExecutor: TaskExecutor {
    /// Process-wide executor retained for every preferred task.
    static let shared = BlockingExecutor()

    /// Schedules a Swift job on the dispatch queue matching its priority.
    func enqueue(_ job: consuming ExecutorJob) {
        let qos = Self.qos(for: job.priority)
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        DispatchQueue.global(qos: qos).async {
            job.runSynchronously(on: executor)
        }
    }

    /// Maps Swift job priority to the corresponding dispatch scheduling class.
    static func qos(for priority: JobPriority) -> DispatchQoS.QoSClass {
        switch TaskPriority(rawValue: priority.rawValue) {
        case .high: return .userInitiated
        case .medium: return .default
        case .low: return .utility
        case .background: return .background
        default: return priority.rawValue > TaskPriority.high.rawValue ? .userInteractive : .default
        }
    }
}
