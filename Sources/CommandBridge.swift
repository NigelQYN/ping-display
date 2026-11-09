import CoreFoundation
import Darwin
import Foundation

struct CommandRequest: Codable {
    var brightness: Double?
    var selector: String?
    var identity: String?
    var requestID: String?
    var status: Bool?
}

struct CommandReply: Codable {
    var done = true
    var ok = true
    var requestID: String?
    var error: String?
    var displays: [Display]?
}

final class CommandBridge {
    private static var name: CFString { "io.nigelq.ping-display.command.\(getuid())" as CFString }
    private var local: CFMessagePort?
    private var source: CFRunLoopSource?
    private var requests: [String: (reply: CommandReply, created: Date)] = [:]
    private let controller: DisplayController

    init(controller: DisplayController) { self.controller = controller }

    func start() {
        var context = CFMessagePortContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CFMessagePortCreateLocal(nil, Self.name, { _, _, data, info in
            guard let data, CFDataGetLength(data) <= 4096, let info else { return nil }
            let bridge = Unmanaged<CommandBridge>.fromOpaque(info).takeUnretainedValue()
            let reply = bridge.receive(data as Data)
            guard let encoded = try? JSONEncoder().encode(reply) else { return nil }
            return Unmanaged.passRetained(encoded as CFData)
        }, &context, nil), let runLoopSource = CFMessagePortCreateRunLoopSource(nil, port, 0) else { return }
        local = port
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let local { CFMessagePortInvalidate(local) }
    }

    private func receive(_ data: Data) -> CommandReply {
        requests = requests.filter { Date().timeIntervalSince($0.value.created) < 60 }
        guard let request = try? JSONDecoder().decode(CommandRequest.self, from: data) else {
            return CommandReply(ok: false, error: "无效命令")
        }
        if request.status == true { return CommandReply(displays: controller.presented) }
        if let id = request.requestID {
            return requests[id]?.reply ?? CommandReply(ok: false, error: "请求已过期")
        }
        guard let value = request.brightness, value.isFinite, (0...1).contains(value) else {
            return CommandReply(ok: false, error: "亮度必须在 0% 到 100% 之间")
        }
        let matching = controller.displays.filter { display in
            guard display.active, !display.uuid.isEmpty else { return false }
            guard let selector = request.selector, let identity = request.identity else { return !display.builtin }
            switch selector {
            case "uuid": return display.uuid.caseInsensitiveCompare(identity) == .orderedSame
            case "id": return String(display.id) == identity
            case "name": return display.name.caseInsensitiveCompare(identity) == .orderedSame
            default: return false
            }
        }
        guard matching.count == 1 else {
            return CommandReply(ok: false, error: "必须恰好选中一个活动显示器")
        }
        let id = UUID().uuidString
        requests[id] = (CommandReply(done: false, requestID: id), Date())
        controller.setBrightness(matching[0], value: value) { [weak self] ok in
            guard let self else { return }
            self.requests[id] = (CommandReply(ok: ok, error: ok ? nil : "亮度请求未完成"), Date())
        }
        return requests[id]!.reply
    }

    static func run(_ args: [String]) throws {
        var request = CommandRequest()
        if args == ["status"] {
            request.status = true
        } else {
            guard args.count >= 3, Array(args.prefix(2)) == ["cli", "set"] else {
                throw DisplayError("用法：displayctl cli set -brightness=N% [-UUID=UUID|-displayID=ID|-name=NAME]")
            }
            for arg in args.dropFirst(2) {
                let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[1].isEmpty else { throw DisplayError("无效参数：\(arg)") }
                let value = String(parts[1])
                switch parts[0] {
                case "-brightness":
                    let percent = value.hasSuffix("%")
                    let numeric = percent ? String(value.dropLast()) : value
                    guard request.brightness == nil,
                          let number = Double(numeric.trimmingCharacters(in: .whitespacesAndNewlines)),
                          number.isFinite, (0...(percent ? 100 : 1)).contains(number) else {
                        throw DisplayError("亮度必须在 0 到 1 或 0% 到 100% 之间")
                    }
                    request.brightness = percent ? number / 100 : number
                case "-UUID", "-displayID", "-name":
                    guard request.selector == nil else { throw DisplayError("只能指定一个显示器选择条件") }
                    if parts[0] == "-displayID", !value.utf8.allSatisfy({ (48...57).contains($0) }) {
                        throw DisplayError("显示器 ID 必须是十进制数字")
                    }
                    request.selector = parts[0] == "-UUID" ? "uuid" : parts[0] == "-displayID" ? "id" : "name"
                    request.identity = value
                default: throw DisplayError("不支持的参数：\(arg)")
                }
            }
            guard request.brightness != nil else { throw DisplayError("请指定亮度") }
        }
        guard let remote = CFMessagePortCreateRemote(nil, name) else { throw DisplayError("请先打开屏.app") }
        func send(_ request: CommandRequest) throws -> CommandReply {
            let data = try JSONEncoder().encode(request)
            var response: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(remote, 1, data as CFData, 2, 2,
                                                  CFRunLoopMode.defaultMode.rawValue, &response)
            guard status == kCFMessagePortSuccess, let response else { throw DisplayError("应用没有响应") }
            return try JSONDecoder().decode(CommandReply.self, from: response.takeRetainedValue() as Data)
        }
        var reply = try send(request)
        if !reply.done, let id = reply.requestID {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            repeat {
                Thread.sleep(forTimeInterval: 0.05)
                reply = try send(CommandRequest(requestID: id))
            } while !reply.done && ProcessInfo.processInfo.systemUptime < deadline
        }
        guard reply.done, reply.ok else { throw DisplayError(reply.error ?? "亮度请求超时") }
        print(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
    }
}
