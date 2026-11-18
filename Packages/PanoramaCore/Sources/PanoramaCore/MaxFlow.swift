import Foundation

/// Boykov–Kolmogorov max-flow / min-cut ("An Experimental Comparison of Min-Cut/Max-Flow
/// Algorithms for Energy Minimization in Vision", PAMI 2004). This is the standard solver
/// for the sparse, grid-like graphs that graph-cut seam finding produces.
///
/// Usage mirrors the reference implementation: add nodes, set terminal weights with
/// `addTerminalWeights`, add n-links with `addEdge`, call `maxflow()`, then query
/// `isSink(_:)` for the minimum cut.
public final class MaxFlowGraph {
    private static let terminal: Int32 = -2
    private static let orphan: Int32 = -3
    private static let none: Int32 = -1

    // Nodes
    private var firstArc: [Int32] = []
    private var parent: [Int32] = []      // arc index to parent, or terminal/orphan/none
    private var nextActive: [Int32] = []  // -1 = not in the active list
    private var timestamp: [Int32] = []
    private var dist: [Int32] = []
    private var sinkTree: [Bool] = []
    private var trCap: [Double] = []

    // Arcs (stored in pairs: arc ^ 1 is the sister)
    private var head: [Int32] = []
    private var nextArc: [Int32] = []
    private var rCap: [Double] = []

    public private(set) var flow: Double = 0
    private var time: Int32 = 0

    // Active queue (FIFO linked through nextActive) and orphan list.
    private var queueFirst: Int32 = -1
    private var queueLast: Int32 = -1
    private var orphans: [Int32] = []
    private var orphanRead = 0

    public init(nodeCapacity: Int = 0, edgeCapacity: Int = 0) {
        firstArc.reserveCapacity(nodeCapacity)
        head.reserveCapacity(edgeCapacity * 2)
        nextArc.reserveCapacity(edgeCapacity * 2)
        rCap.reserveCapacity(edgeCapacity * 2)
    }

    public var nodeCount: Int { firstArc.count }

    @discardableResult
    public func addNodes(_ n: Int) -> Int {
        let first = firstArc.count
        firstArc.append(contentsOf: repeatElement(-1, count: n))
        parent.append(contentsOf: repeatElement(Self.none, count: n))
        nextActive.append(contentsOf: repeatElement(-1, count: n))
        timestamp.append(contentsOf: repeatElement(0, count: n))
        dist.append(contentsOf: repeatElement(0, count: n))
        sinkTree.append(contentsOf: repeatElement(false, count: n))
        trCap.append(contentsOf: repeatElement(0, count: n))
        return first
    }

    /// Cost `capSource` is paid if the node ends on the sink side, `capSink` if on the source side.
    public func addTerminalWeights(_ i: Int, source capSource: Double, sink capSink: Double) {
        var cs = capSource, ct = capSink
        let delta = trCap[i]
        if delta > 0 { cs += delta } else { ct -= delta }
        flow += min(cs, ct)
        trCap[i] = cs - ct
    }

    /// Unary energy: e0 if the node is on the source side (label 0), e1 on the sink side (label 1).
    public func addUnary(_ i: Int, e0: Double, e1: Double) {
        if e1 >= e0 {
            addTerminalWeights(i, source: e1 - e0, sink: 0)
        } else {
            addTerminalWeights(i, source: 0, sink: e0 - e1)
        }
    }

    /// Directed capacities: `cap` from i to j, `revCap` from j to i.
    public func addEdge(_ i: Int, _ j: Int, cap: Double, revCap: Double) {
        let a = Int32(head.count)
        head.append(Int32(j)); nextArc.append(firstArc[i]); rCap.append(cap)
        firstArc[i] = a
        head.append(Int32(i)); nextArc.append(firstArc[j]); rCap.append(revCap)
        firstArc[j] = a + 1
    }

    /// Pairwise energy E(xi, xj) with values A=E(0,0), B=E(0,1), C=E(1,0), D=E(1,1).
    /// Non-submodular terms are truncated (A lowered) so the graph stays valid.
    public func addPairwise(_ i: Int, _ j: Int, A: Double, B: Double, C: Double, D: Double) {
        var A = A
        if A + D > B + C { A = B + C - D }
        addUnary(i, e0: 0, e1: C - A)
        addUnary(j, e0: 0, e1: D - C)
        let w = B + C - A - D
        if w > 0 { addEdge(i, j, cap: w, revCap: 0) }
    }

    /// True if node `i` is on the sink side of the minimum cut (label 1).
    public func isSink(_ i: Int) -> Bool {
        parent[i] != Self.none && sinkTree[i]
    }

    // MARK: - Algorithm

    @inline(__always) private func setActive(_ i: Int32) {
        if nextActive[Int(i)] != -1 { return }
        if queueLast >= 0 { nextActive[Int(queueLast)] = i } else { queueFirst = i }
        queueLast = i
        nextActive[Int(i)] = i // self-loop marks the tail
    }

    private func popActive() -> Int32 {
        while queueFirst >= 0 {
            let i = queueFirst
            let nxt = nextActive[Int(i)]
            if nxt == i { queueFirst = -1; queueLast = -1 } else { queueFirst = nxt }
            nextActive[Int(i)] = -1
            if parent[Int(i)] != Self.none { return i }
        }
        return -1
    }

    @inline(__always) private func setOrphan(_ i: Int32) {
        parent[Int(i)] = Self.orphan
        orphans.append(i)
    }

    public func maxflow() -> Double {
        let n = firstArc.count
        for i in 0..<n {
            nextActive[i] = -1
            timestamp[i] = 0
            if trCap[i] > 0 {
                sinkTree[i] = false; parent[i] = Self.terminal; setActive(Int32(i)); dist[i] = 1
            } else if trCap[i] < 0 {
                sinkTree[i] = true; parent[i] = Self.terminal; setActive(Int32(i)); dist[i] = 1
            } else {
                parent[i] = Self.none
            }
        }
        time = 0
        var current: Int32 = -1

        while true {
            var i = current
            if i >= 0 && parent[Int(i)] == Self.none { i = -1 }
            if i < 0 {
                i = popActive()
                if i < 0 { break }
            }
            let ii = Int(i)
            // Grow
            var found: Int32 = -1
            if !sinkTree[ii] {
                var a = firstArc[ii]
                while a >= 0 {
                    let ai = Int(a)
                    if rCap[ai] > 0 {
                        let j = Int(head[ai])
                        if parent[j] == Self.none {
                            sinkTree[j] = false; parent[j] = a ^ 1
                            timestamp[j] = timestamp[ii]; dist[j] = dist[ii] + 1
                            setActive(Int32(j))
                        } else if sinkTree[j] {
                            found = a; break
                        } else if timestamp[j] <= timestamp[ii] && dist[j] > dist[ii] {
                            parent[j] = a ^ 1; timestamp[j] = timestamp[ii]; dist[j] = dist[ii] + 1
                        }
                    }
                    a = nextArc[ai]
                }
            } else {
                var a = firstArc[ii]
                while a >= 0 {
                    let ai = Int(a)
                    if rCap[ai ^ 1] > 0 {
                        let j = Int(head[ai])
                        if parent[j] == Self.none {
                            sinkTree[j] = true; parent[j] = a ^ 1
                            timestamp[j] = timestamp[ii]; dist[j] = dist[ii] + 1
                            setActive(Int32(j))
                        } else if !sinkTree[j] {
                            found = a ^ 1; break
                        } else if timestamp[j] <= timestamp[ii] && dist[j] > dist[ii] {
                            parent[j] = a ^ 1; timestamp[j] = timestamp[ii]; dist[j] = dist[ii] + 1
                        }
                    }
                    a = nextArc[ai]
                }
            }
            time += 1

            if found >= 0 {
                current = i
                augment(found)
                // Adopt orphans
                while orphanRead < orphans.count {
                    let o = orphans[orphanRead]
                    orphanRead += 1
                    if sinkTree[Int(o)] { processSinkOrphan(Int(o)) } else { processSourceOrphan(Int(o)) }
                }
                orphans.removeAll(keepingCapacity: true)
                orphanRead = 0
            } else {
                current = -1
            }
        }
        return flow
    }

    private func augment(_ middle: Int32) {
        let m = Int(middle)
        var bottleneck = rCap[m]
        // Source tree
        var i = Int(head[m ^ 1])
        while true {
            let a = parent[i]
            if a == Self.terminal { break }
            bottleneck = min(bottleneck, rCap[Int(a) ^ 1])
            i = Int(head[Int(a)])
        }
        bottleneck = min(bottleneck, trCap[i])
        // Sink tree
        i = Int(head[m])
        while true {
            let a = parent[i]
            if a == Self.terminal { break }
            bottleneck = min(bottleneck, rCap[Int(a)])
            i = Int(head[Int(a)])
        }
        bottleneck = min(bottleneck, -trCap[i])

        rCap[m ^ 1] += bottleneck
        rCap[m] -= bottleneck
        i = Int(head[m ^ 1])
        while true {
            let a = parent[i]
            if a == Self.terminal { break }
            let ai = Int(a)
            rCap[ai] += bottleneck
            rCap[ai ^ 1] -= bottleneck
            if rCap[ai ^ 1] <= 0 { rCap[ai ^ 1] = 0; setOrphan(Int32(i)) }
            i = Int(head[ai])
        }
        trCap[i] -= bottleneck
        if trCap[i] <= 0 { trCap[i] = 0; setOrphan(Int32(i)) }

        i = Int(head[m])
        while true {
            let a = parent[i]
            if a == Self.terminal { break }
            let ai = Int(a)
            rCap[ai ^ 1] += bottleneck
            rCap[ai] -= bottleneck
            if rCap[ai] <= 0 { rCap[ai] = 0; setOrphan(Int32(i)) }
            i = Int(head[ai])
        }
        trCap[i] += bottleneck
        if trCap[i] >= 0 { trCap[i] = 0; setOrphan(Int32(i)) }

        flow += bottleneck
    }

    private func processSourceOrphan(_ i: Int) {
        var minArc: Int32 = -1
        var dMin = Int32.max
        var a0 = firstArc[i]
        while a0 >= 0 {
            let a0i = Int(a0)
            if rCap[a0i ^ 1] > 0 {
                var j = Int(head[a0i])
                if !sinkTree[j] && parent[j] != Self.none {
                    // Find the origin of j's tree path.
                    var d: Int32 = 0
                    while true {
                        if timestamp[j] == time { d += dist[j]; break }
                        let a = parent[j]
                        d += 1
                        if a == Self.terminal { timestamp[j] = time; dist[j] = 1; break }
                        if a == Self.orphan { d = Int32.max; break }
                        j = Int(head[Int(a)])
                    }
                    if d < Int32.max {
                        if d < dMin { minArc = a0; dMin = d }
                        // Mark the path for faster subsequent searches.
                        j = Int(head[a0i])
                        while timestamp[j] != time {
                            timestamp[j] = time
                            dist[j] = d
                            d -= 1
                            j = Int(head[Int(parent[j])])
                        }
                    }
                }
            }
            a0 = nextArc[a0i]
        }
        if minArc >= 0 {
            parent[i] = minArc
            timestamp[i] = time
            dist[i] = dMin + 1
        } else {
            parent[i] = Self.none
            var a = firstArc[i]
            while a >= 0 {
                let ai = Int(a)
                let j = Int(head[ai])
                let pa = parent[j]
                if !sinkTree[j] && pa != Self.none {
                    if rCap[ai ^ 1] > 0 { setActive(Int32(j)) }
                    if pa != Self.terminal && pa != Self.orphan && Int(head[Int(pa)]) == i { setOrphan(Int32(j)) }
                }
                a = nextArc[ai]
            }
        }
    }

    private func processSinkOrphan(_ i: Int) {
        var minArc: Int32 = -1
        var dMin = Int32.max
        var a0 = firstArc[i]
        while a0 >= 0 {
            let a0i = Int(a0)
            if rCap[a0i] > 0 {
                var j = Int(head[a0i])
                if sinkTree[j] && parent[j] != Self.none {
                    var d: Int32 = 0
                    while true {
                        if timestamp[j] == time { d += dist[j]; break }
                        let a = parent[j]
                        d += 1
                        if a == Self.terminal { timestamp[j] = time; dist[j] = 1; break }
                        if a == Self.orphan { d = Int32.max; break }
                        j = Int(head[Int(a)])
                    }
                    if d < Int32.max {
                        if d < dMin { minArc = a0; dMin = d }
                        j = Int(head[a0i])
                        while timestamp[j] != time {
                            timestamp[j] = time
                            dist[j] = d
                            d -= 1
                            j = Int(head[Int(parent[j])])
                        }
                    }
                }
            }
            a0 = nextArc[a0i]
        }
        if minArc >= 0 {
            parent[i] = minArc
            timestamp[i] = time
            dist[i] = dMin + 1
        } else {
            parent[i] = Self.none
            var a = firstArc[i]
            while a >= 0 {
                let ai = Int(a)
                let j = Int(head[ai])
                let pa = parent[j]
                if sinkTree[j] && pa != Self.none {
                    if rCap[ai] > 0 { setActive(Int32(j)) }
                    if pa != Self.terminal && pa != Self.orphan && Int(head[Int(pa)]) == i { setOrphan(Int32(j)) }
                }
                a = nextArc[ai]
            }
        }
    }
}
