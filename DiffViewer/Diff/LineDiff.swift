import Foundation

/// Line-level diff using Myers' O(ND) algorithm in its linear-space
/// (middle snake) form. Iterative, so it is safe on small thread stacks.
enum LineDiff {
    enum Op: Equatable, Sendable {
        case equal(old: Int, new: Int)
        case delete(old: Int)
        case insert(new: Int)
    }

    static func diff<T: Hashable>(_ a: [T], _ b: [T]) -> [Op] {
        // Intern to integers so comparisons are cheap.
        var ids: [T: Int] = [:]
        func intern(_ value: T) -> Int {
            if let id = ids[value] { return id }
            let id = ids.count
            ids[value] = id
            return id
        }
        let ia = a.map(intern)
        let ib = b.map(intern)
        var solver = Solver(a: ia, b: ib)
        return solver.solve()
    }

    private struct Solver {
        let a: [Int]
        let b: [Int]
        var vf: [Int]
        var vb: [Int]
        let offset: Int

        init(a: [Int], b: [Int]) {
            self.a = a
            self.b = b
            let max = a.count + b.count + 2
            offset = max
            vf = Array(repeating: 0, count: 2 * max + 2)
            vb = Array(repeating: 0, count: 2 * max + 2)
        }

        private enum Work {
            case solve(a0: Int, a1: Int, b0: Int, b1: Int)
            case emit([Op])
        }

        mutating func solve() -> [Op] {
            var ops: [Op] = []
            ops.reserveCapacity(a.count + b.count)
            var stack: [Work] = [.solve(a0: 0, a1: a.count, b0: 0, b1: b.count)]
            while let work = stack.popLast() {
                switch work {
                case let .emit(chunk):
                    ops.append(contentsOf: chunk)
                case .solve(var a0, var a1, var b0, var b1):
                    // Common prefix is emitted now; common suffix after everything else.
                    while a0 < a1, b0 < b1, a[a0] == b[b0] {
                        ops.append(.equal(old: a0, new: b0))
                        a0 += 1; b0 += 1
                    }
                    var suffix: [Op] = []
                    while a0 < a1, b0 < b1, a[a1 - 1] == b[b1 - 1] {
                        a1 -= 1; b1 -= 1
                        suffix.append(.equal(old: a1, new: b1))
                    }
                    suffix.reverse()
                    if !suffix.isEmpty { stack.append(.emit(suffix)) }

                    if a0 == a1 {
                        ops.append(contentsOf: (b0..<b1).map { Op.insert(new: $0) })
                        continue
                    }
                    if b0 == b1 {
                        ops.append(contentsOf: (a0..<a1).map { Op.delete(old: $0) })
                        continue
                    }
                    let snake = middleSnake(a0: a0, a1: a1, b0: b0, b1: b1)
                    stack.append(.solve(a0: a0 + snake.u, a1: a1, b0: b0 + snake.v, b1: b1))
                    if snake.u > snake.x {
                        stack.append(
                            .emit(
                                (0..<(snake.u - snake.x)).map { .equal(old: a0 + snake.x + $0, new: b0 + snake.y + $0) }
                            ))
                    }
                    stack.append(.solve(a0: a0, a1: a0 + snake.x, b0: b0, b1: b0 + snake.y))
                }
            }
            return ops
        }

        /// Returns a middle snake (x,y)→(u,v) in coordinates relative to (a0, b0).
        private mutating func middleSnake(a0: Int, a1: Int, b0: Int, b1: Int) -> (x: Int, y: Int, u: Int, v: Int) {
            let n = a1 - a0
            let m = b1 - b0
            let delta = n - m
            let odd = delta & 1 != 0
            vf[offset + 1] = 0
            vb[offset + 1] = 0
            let dMax = (n + m + 1) / 2
            for d in 0...dMax {
                var k = -d
                while k <= d {
                    var x: Int
                    if k == -d || (k != d && vf[offset + k - 1] < vf[offset + k + 1]) {
                        x = vf[offset + k + 1]
                    } else {
                        x = vf[offset + k - 1] + 1
                    }
                    var y = x - k
                    let sx = x
                    let sy = y
                    while x < n, y < m, a[a0 + x] == b[b0 + y] { x += 1; y += 1 }
                    vf[offset + k] = x
                    if odd, (k - delta) >= -(d - 1), (k - delta) <= (d - 1),
                        vf[offset + k] + vb[offset + delta - k] >= n
                    {
                        return (sx, sy, x, y)
                    }
                    k += 2
                }
                k = -d
                while k <= d {
                    var x: Int
                    if k == -d || (k != d && vb[offset + k - 1] < vb[offset + k + 1]) {
                        x = vb[offset + k + 1]
                    } else {
                        x = vb[offset + k - 1] + 1
                    }
                    var y = x - k
                    let sx = x
                    let sy = y
                    while x < n, y < m, a[a1 - 1 - x] == b[b1 - 1 - y] { x += 1; y += 1 }
                    vb[offset + k] = x
                    if !odd, (k - delta) >= -d, (k - delta) <= d,
                        vb[offset + k] + vf[offset + delta - k] >= n
                    {
                        return (n - x, m - y, n - sx, m - sy)
                    }
                    k += 2
                }
            }
            // Unreachable for non-empty inputs; treat as full replacement.
            return (0, 0, 0, 0)
        }
    }
}
