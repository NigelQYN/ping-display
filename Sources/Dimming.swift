import ColorSync
import CoreGraphics
import Foundation

struct DisplayError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

final class Dimming {
    private struct Curve {
        let original: [Float]
        var applied: [Float]
        var factor: Double
        var uncertain = false
    }

    private var curves: [String: Curve] = [:]

    func factor(for display: Display) -> Double? {
        guard let curve = curves[display.uuid], !curve.uncertain,
              let actual = try? read(display.id), equal(actual, curve.applied) else { return nil }
        return curve.factor
    }

    func set(_ factor: Double, for display: Display) throws {
        guard !display.uuid.isEmpty, CGDisplayIsActive(display.id) != 0,
              CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue()
                  .mapUUID == display.uuid.uppercased() else {
            throw DisplayError("显示器已断开或已重新配置")
        }
        if factor == 1 && curves[display.uuid] == nil { return }
        let current = try read(display.id)
        var curve = curves[display.uuid] ?? Curve(original: current, applied: current, factor: 1)
        guard equal(current, curve.original) || (!curve.uncertain && equal(current, curve.applied)) else {
            throw DisplayError("色彩表已被系统或其他程序更改，请先取消软调暗")
        }
        let wanted = factor == 1 ? curve.original : curve.original.map { $0 * Float(factor) }
        do {
            curve.applied = try write(wanted, to: display.id)
            curve.factor = factor
            curve.uncertain = false
            curves[display.uuid] = factor == 1 ? nil : curve
        } catch {
            if (try? write(current, to: display.id)) == nil {
                curve.uncertain = true
                curves[display.uuid] = curve
            }
            throw error
        }
    }

    @discardableResult
    func restore(_ displays: [Display], forceUncertain: Bool = false) -> Bool {
        var success = true
        for display in displays where display.active {
            guard let curve = curves[display.uuid] else { continue }
            do {
                if curve.uncertain && forceUncertain {
                    guard CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue()
                        .mapUUID == display.uuid.uppercased() else {
                        throw DisplayError("显示器已重新配置")
                    }
                    _ = try write(curve.original, to: display.id)
                    curves.removeValue(forKey: display.uuid)
                } else {
                    try set(1, for: display)
                }
            } catch {
                success = false
                if forceUncertain && !curve.uncertain { curves.removeValue(forKey: display.uuid) }
            }
        }
        return success
    }

    private func read(_ id: CGDirectDisplayID) throws -> [Float] {
        let capacity = Int(CGDisplayGammaTableCapacity(id))
        guard (1...65_536).contains(capacity) else { throw DisplayError("显示器不支持色彩表") }
        var values = [Float](repeating: 0, count: capacity * 3)
        var count: UInt32 = 0
        let error = values.withUnsafeMutableBufferPointer { buffer in
            let red = buffer.baseAddress!
            return CGGetDisplayTransferByTable(id, UInt32(capacity), red, red + capacity,
                                               red + 2 * capacity, &count)
        }
        guard error == .success, count > 0, count <= capacity else {
            throw DisplayError("无法读取显示器色彩表")
        }
        let length = Int(count)
        if length != capacity {
            values = Array(values[0..<length]) + values[capacity..<(capacity + length)]
                + values[(2 * capacity)..<(2 * capacity + length)]
        }
        guard values.allSatisfy({ $0.isFinite }) else { throw DisplayError("显示器色彩表无效") }
        return values
    }

    private func write(_ values: [Float], to id: CGDirectDisplayID) throws -> [Float] {
        let count = values.count / 3
        let error = values.withUnsafeBufferPointer { buffer in
            let red = buffer.baseAddress!
            return CGSetDisplayTransferByTable(id, UInt32(count), red, red + count, red + 2 * count)
        }
        guard error == .success else { throw DisplayError("无法写入显示器色彩表") }
        let actual = try read(id)
        guard equal(actual, values) else { throw DisplayError("无法确认软调暗已生效") }
        return actual
    }

    private func equal(_ first: [Float], _ second: [Float]) -> Bool {
        first.count == second.count && zip(first, second).allSatisfy { abs($0 - $1) <= 1.0 / 2048 }
    }
}

private extension CFUUID {
    var mapUUID: String { (CFUUIDCreateString(nil, self) as String).uppercased() }
}
