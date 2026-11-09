import Darwin
import Foundation

final class LightSensor {
    private var timer: Timer?
    private var descriptor: Int32 = -1
    private var path = ""
    private var nextConnect: TimeInterval = 0
    private var line = Data()
    private var skippingLine = false
    private var busy = false
    private var generation = UUID()
    private var lastApplied: (value: Double, time: TimeInterval)?
    private(set) var status = "已关闭"
    var applyBrightness: ((Double, @escaping (Bool) -> Void) -> Void)?

    func start(path: String) {
        stop()
        self.path = path
        status = "等待连接"
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        disconnect()
        status = "已关闭"
        nextConnect = 0
    }

    private func disconnect() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        line.removeAll()
        skippingLine = false
        generation = UUID()
        busy = false
        lastApplied = nil
    }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        if descriptor < 0 {
            guard now >= nextConnect else { return }
            nextConnect = now + 3
            guard path.hasPrefix("/dev/cu.") else { return }
            let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return }
            var options = termios()
            guard tcgetattr(fd, &options) == 0 else { close(fd); return }
            cfmakeraw(&options)
            options.c_cflag |= tcflag_t(CLOCAL | CREAD)
            cfsetspeed(&options, speed_t(B115200))
            guard tcsetattr(fd, TCSANOW, &options) == 0 else { close(fd); return }
            descriptor = fd
            status = "已连接"
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            for byte in buffer.prefix(count) { receive(byte, now: now) }
        } else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            disconnect()
            status = "等待重连"
            nextConnect = now + 3
        }
    }

    private func receive(_ byte: UInt8, now: TimeInterval) {
        if byte == 10 {
            defer { line.removeAll(keepingCapacity: true); skippingLine = false }
            guard !skippingLine, !busy, let text = String(data: line, encoding: .utf8),
                  text.hasPrefix("LUX:"),
                  let lux = Double(text.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)),
                  lux.isFinite, lux >= 0 else { return }
            let target: Double
            switch lux {
            case ..<5: target = 0.10
            case ..<100: target = 0.40
            case ..<500: target = 0.70
            case ..<2000: target = 0.90
            default: target = 1
            }
            if let lastApplied, lastApplied.value == target, now - lastApplied.time < 30 { return }
            guard let applyBrightness else { return }
            busy = true
            let current = generation
            applyBrightness(target) { [weak self] success in
                guard let self, self.generation == current else { return }
                self.busy = false
                if success { self.lastApplied = (target, ProcessInfo.processInfo.systemUptime) }
            }
        } else if !skippingLine {
            if line.count < 4096 { line.append(byte) }
            else { line.removeAll(); skippingLine = true }
        }
    }
}
