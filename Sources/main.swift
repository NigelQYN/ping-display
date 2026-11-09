import AppKit
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--command" {
    do {
        try CommandBridge.run(Array(arguments.dropFirst()))
        exit(0)
    } catch {
        let reply = CommandReply(ok: false, error: error.localizedDescription)
        if let data = try? JSONEncoder().encode(reply) { print(String(decoding: data, as: UTF8.self)) }
        exit(1)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = MenuApp()
application.delegate = delegate
application.run()
