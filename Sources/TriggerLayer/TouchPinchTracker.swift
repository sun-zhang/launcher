import Foundation

/// 四指捏合识别的纯逻辑核心（MultitouchGestureSource 的可单测部分）。
///
/// 输入是每触点帧的（指 ID + 归一化坐标），输出是与系统 magnification 语义
/// 一致的每帧增量序列，直接喂 `GestureEngine`：
///
/// - **方向**：指距（中位数两两距离）d 的逐帧变化 `(d_now − d_prev) / d_0`——
///   收拢为负、张开为正。2026-10-05 真机标定（macOS 26.6，
///   spike/logs/mt-human.log）：四指捏合簇累计 −0.48…−0.81、张开 +0.37…+2.01；
/// - **指集稳定门控**：落指/抬指帧（指 ID 集合变化）的指距跳变**不算手势位移**
///   ——静默重锚基线（真机实证：四指快速放置即产生 −0.4 量级的假位移，
///   会直接误触）；只有同一组手指在触期间的连续收拢/张开才产生增量；
/// - **指数门控**：稳定在触指数须 ≥ minFingers（默认 4）才输出——3 指捏合
///   同样给出强负值（−0.36/−0.64 实测），不门控必误触；
/// - **中位数指距**：拇指/掌沿常被报为第 5 触点（真机峰值指数恒为 5），
///   平均值会被 4 个“掌-指”近平稳距离稀释（实测 5 指捏合仅 −0.25）；
///   中位数由指-指距离主导，对 1 个静止外点鲁棒；
/// - 抬手（<2 指）即闭簇；`d0` 下限防两指落点过近时增量爆炸。
///
/// 隐私（NFR-PRIV P-2）：只算指距，绝不落盘触点坐标——生产日志只输出
/// 指数与增量统计。
public final class TouchPinchTracker {

    /// 一个触点（归一化坐标 0…1；id 为驱动侧指 ID，仅用于集合比对）。
    public struct TouchSample {
        public var id: Int32
        public var x: Float
        public var y: Float
        public init(id: Int32, x: Float, y: Float) {
            self.id = id; self.x = x; self.y = y
        }
    }

    /// 稳定在触指数须达到的值才输出增量（SRS：四指；双指/三指捏合不触发）。
    public var minFingers: Int
    /// d0 下限：两指落点过近时防增量爆炸（真机簇 d0 实测 0.20…1.00）。
    public var anchorDistanceFloor: Float = 0.05

    /// 横扫主判据——按指速度的平移/收拢分解：各指速度的共同分量占比。
    /// 只拦「近乎纯平移」的刚体横扫（占比 ≈0.9+，快慢与方向无关）；
    /// 门限必须收紧在 0.85——真机实证「边收拢边向触控板中心带拖手」的
    /// 正常捏合占比可达 0.65~0.75（四指同向位移+径向收拢的合成），
    /// 宽门限会把真捏合整簇误杀（面板到一半弹回）。慢速大收拢斜扫
    /// 由累计位移门兜底。
    public var swipeCommonRatio: Float = 0.85
    /// 速度噪声底（归一化/帧）：低于此速度的帧不参与平移/收拢分解。
    public var swipeVelocityNoiseFloor: Float = 0.0025
    /// 连续这么多帧近乎纯平移才判横扫（防单帧抖动误杀真捏合）。
    public var swipeConsecutiveFrames: Int = 3
    /// 横扫累计判据（兜底）：质心平移超过此值（真机横扫 ≥0.3；捏合 <0.1）。
    public var swipeCentroidTravel: Float = 0.2

    private struct Burst {
        var ids: Set<Int32>           // 当前在触指集合（稳定期比对）
        var d0: Float                 // 基线指距（增量分母）
        var dPrev: Float              // 上一帧指距
        var cx0: Float = 0            // 质心基线（横扫累计判据）
        var cy0: Float = 0
        var prevPos: [Int32: (x: Float, y: Float)] = [:]   // 上一帧各指位置（速度分解）
        var transStreak = 0           // 连续「平移主导」帧计数
        var frames = 0
        var maxFingers = 0
        var cumMag: Double = 0        // (d − d0) / d0，诊断用
        var isSwipe = false           // 平移主导/质心大幅平移 → 整簇抑制（粘滞到闭簇）
    }
    private var burst: Burst?
    /// 横扫确认沿检测（回调只发一次/簇）。
    private var isSwipeLatched = false
    /// 最近一次闭簇摘要（"4指 26帧 等效放大率=-0.484"），取后即清——
    /// 供源侧结算日志区分「确有簇结束」与重复信号。
    public private(set) var lastBurstSummary: String?

    // 横扫判据参数已上移至实例属性（设置界面实时下发）
    /// 横扫确认（false→true 沿）回调——源侧立即清引擎累计并撤预览，
    /// 把慢速斜扫经累计门兜底时的泄漏闪现压到最短。
    public var onSwipeConfirmed: (() -> Void)?

    public init(minFingers: Int = 4) {
        self.minFingers = max(2, minFingers)
    }

    /// 每触点帧调用（任意线程语义由调用方保证；本类非线程安全）。
    /// 返回应喂引擎的增量序列：空 = 本帧不计入。
    public func onFrame(_ points: [TouchSample]) -> [Double] {
        guard points.count >= 2 else {
            closeBurst()
            return []
        }
        let d = Self.medianPairwiseDistance(points)
        let ids = Set(points.map(\.id))
        let n = Float(points.count)
        let cx = points.map(\.x).reduce(0, +) / n
        let cy = points.map(\.y).reduce(0, +) / n

        guard var b = burst else {
            // 簇首帧：只锚定基线，不产生增量
            var nb = Burst(ids: ids, d0: max(d, anchorDistanceFloor), dPrev: d,
                           cx0: cx, cy0: cy, maxFingers: points.count)
            for p in points { nb.prevPos[p.id] = (p.x, p.y) }
            burst = nb
            return []
        }
        b.frames += 1
        b.maxFingers = max(b.maxFingers, points.count)

        // 驱动偶发给两个触点发同一 fingerID（真机实证四指捏合切换期 Duplicate
        // key '0' 崩溃）——重复 ID 视为指集不稳定，走静默重锚（顺带避免速度错乱）
        let idsUnstable = points.count != ids.count

        if idsUnstable || ids != b.ids {
            // 落指/抬指：指距跳变是接触变化不是手势位移——静默重锚，零输出。
            // d0/质心/速度基线一并重锚：捏合量以当前指形为基准（真机弱捏合余量验证）。
            b.ids = ids
            b.d0 = max(d, anchorDistanceFloor)
            b.dPrev = d
            b.cx0 = cx
            b.cy0 = cy
            b.prevPos.removeAll()
            for p in points { b.prevPos[p.id] = (p.x, p.y) }
            b.transStreak = 0
            b.cumMag = 0
            burst = b
            return []
        }

        // 横扫主判据：按指速度分解共同分量占比（同向平移 vs 对向收拢）
        var sumVX: Float = 0
        var sumVY: Float = 0
        var sumSpeed: Float = 0
        for p in points {
            if let prev = b.prevPos[p.id] {
                let vx = p.x - prev.x
                let vy = p.y - prev.y
                sumVX += vx
                sumVY += vy
                sumSpeed += (vx * vx + vy * vy).squareRoot()
            }
            b.prevPos[p.id] = (p.x, p.y)
        }
        let nF = Float(points.count)
        let meanSpeed = sumSpeed / nF
        if meanSpeed > swipeVelocityNoiseFloor {
            let common = ((sumVX / nF) * (sumVX / nF) + (sumVY / nF) * (sumVY / nF)).squareRoot()
            if common / meanSpeed > swipeCommonRatio {
                b.transStreak += 1
            } else {
                b.transStreak = 0
            }
            if b.transStreak >= swipeConsecutiveFrames {
                b.isSwipe = true
            }
        } else {
            b.transStreak = 0
        }
        // 累计位移兜底（速度分解门漏判的慢速大收拢斜扫在此拦截）
        if !b.isSwipe {
            let travel = ((cx - b.cx0) * (cx - b.cx0) + (cy - b.cy0) * (cy - b.cy0)).squareRoot()
            if travel > swipeCentroidTravel {
                b.isSwipe = true
            }
        }
        if b.isSwipe {
            let wasSwipe = isSwipeLatched
            burst = b
            if !wasSwipe {
                isSwipeLatched = true
                onSwipeConfirmed?()
            }
            return []
        }
        isSwipeLatched = false

        // 同一组手指稳定在触且达指数门控：输出等效 magnification 增量
        let delta = Double((d - b.dPrev) / b.d0)
        b.cumMag = Double((d - b.d0) / b.d0)
        b.dPrev = d
        burst = b
        guard points.count >= minFingers, delta != 0 else { return [] }   // 静置帧零输出
        return [delta]
    }

    /// 闭簇（抬手/超时）。
    public func closeBurst() {
        guard let b = burst else { return }
        burst = nil
        let tag = b.isSwipe ? "横扫抑制" : String(format: "等效放大率=%.3f", b.cumMag)
        lastBurstSummary = "\(b.maxFingers)指 \(b.frames)帧 \(tag)"
    }

    public var isTracking: Bool { burst != nil }

    /// 读取并清除闭簇摘要（nil = 自上次取走后无新闭簇）。
    public func takeLastBurstSummary() -> String? {
        defer { lastBurstSummary = nil }
        return lastBurstSummary
    }

    /// 两两距离的中位数（n 指 → C(n,2) 个 pair；n ≤ 6，代价可忽略）。
    /// 中位数对 1 个静止外点（拇指/掌沿被报为触点）鲁棒：其 pair 距离
    /// 大且平稳，落在分布两端不干扰中位——均值则被显著稀释（真机 5 指
    /// 捏合 −0.25 vs 4 指 −0.5）。
    static func medianPairwiseDistance(_ points: [TouchSample]) -> Float {
        guard points.count >= 2 else { return 0 }
        var dists: [Float] = []
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let dx = points[i].x - points[j].x
                let dy = points[i].y - points[j].y
                dists.append((dx * dx + dy * dy).squareRoot())
            }
        }
        dists.sort()
        let mid = dists.count / 2
        return dists.count % 2 == 1 ? dists[mid] : (dists[mid - 1] + dists[mid]) / 2
    }
}

/// 面板打开期间的四指张开关闭累计（FR-T3）。
///
/// 面板是非激活窗口（FR-P3 不抢焦点），系统 `.magnify` 事件投递给前台应用、
/// 面板自身的 `magnify(with:)` 收不到——关闭方向改由全局触点流驱动（与唤起
/// 同源，不依赖激活状态）。口径与面板公开 API 路径一致：累计 ≥ +0.30 触发、
/// 反向（捏合）即清零防漂移；两路并存幂等（closePanel 有可见性守卫）。
public struct PinchCloseAccumulator {

    public static let defaultThreshold: Double = 0.30

    /// 关闭阈值（设置界面实时下发）。
    public var threshold: Double
    public private(set) var accum: Double = 0
    /// 一簇一击：触发后锁定，reset()（抬手/面板关闭）才重新武装。
    private var fired = false

    public init(threshold: Double = PinchCloseAccumulator.defaultThreshold) {
        self.threshold = threshold
    }

    /// 喂入一帧张开增量。返回 true = 达到阈值应关闭（本簇不再重复触发）。
    public mutating func feed(_ delta: Double) -> Bool {
        guard !fired else { return false }
        if delta <= 0 {
            accum = 0   // 反向清零防漂移（与面板公开 API 口径一致）
            return false
        }
        accum += delta
        if accum >= threshold {
            accum = 0
            fired = true
            return true
        }
        return false
    }

    public mutating func reset() {
        accum = 0
        fired = false
    }
}
