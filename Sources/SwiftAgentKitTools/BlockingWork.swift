//
//  BlockingWork.swift
//  SwiftAgentKitTools
//
//  Blocking calls — waiting on a child process, a parser, a pipe — must not run
//  on Swift's cooperative pool. That pool has one thread per core (three on a CI
//  runner) and every Task.sleep timer needs a free one to wake: with the pool
//  parked on blocking calls, run_shell's 1 s timeout fired after 6.5 s and a
//  2.5 s grace window lasted until the command had finished.
//

#if os(macOS)
import Foundation

enum BlockingWork {
    /// Run `body` on a GCD thread and await its result, leaving the cooperative
    /// pool free. GCD grows its pool for blocked threads; Swift's does not.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: body())
            }
        }
    }
}
#endif
