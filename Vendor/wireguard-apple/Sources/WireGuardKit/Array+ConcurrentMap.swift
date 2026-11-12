// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

extension Array {

    /// Returns an array containing the results of mapping the given closure over the sequence’s
    /// elements concurrently.
    ///
    /// - Parameters:
    ///   - queue: The queue for performing concurrent computations.
    ///            If the given queue is serial, the values are mapped in a serial fashion.
    ///            Pass `nil` to perform computations on the current queue.
    ///   - transform: the block to perform concurrent computations over the given element.
    /// - Returns: an array of concurrently computed values.
    // Swift 6 修正：transform 会被 concurrentPerform 的逃逸闭包捕获，需标 @escaping。
    func concurrentMap<U>(queue: DispatchQueue?, _ transform: @escaping (Element) -> U) -> [U] {
        var result = [U?](repeating: nil, count: self.count)
        let resultQueue = DispatchQueue(label: "ConcurrentMapQueue")

        // Swift 6 修正：直接写 `queue?.sync ?? { $0() }` 会让编译器在 DispatchQueue.sync
        // 的重载间无法定位（触发 "failed to produce diagnostic"）。显式标注函数类型即可。
        let execute: (@escaping () -> Void) -> Void = queue.map { q in { q.sync(execute: $0) } } ?? { $0() }

        execute {
            DispatchQueue.concurrentPerform(iterations: self.count) { index in
                let value = transform(self[index])
                resultQueue.sync {
                    result[index] = value
                }
            }
        }

        return result.map { $0! }
    }
}
