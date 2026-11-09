import AppKit
import CoreGraphics
import Foundation

struct Display: Codable {
    let id: UInt32
    let uuid: String
    let name: String
    let builtin: Bool
    let active: Bool
    let online: Bool
    var brightness: Double?
    let ddcMaximum: Int?

    var key: String { builtin ? "builtin" : uuid }
    var floor: Double { builtin ? 1.0 / 16 : 0 }

    private static let curveGain = (0.67 - 0.01) / (1 - 0.67) * 0.5 / (0.5 - 0.01)

    private func remap(_ value: Double, gain: Double) -> Double {
        let normalized = (value - 0.01) / 0.99
        return 0.01 + 0.99 * gain * normalized / (1 + (gain - 1) * normalized)
    }

    func output(for value: Double) -> (hardware: Double, software: Double) {
        let value = min(1, max(0.01, value))
        let combined = builtin ? remap(value, gain: Self.curveGain) : value
        return (floor + (1 - floor) * max(0, (combined - 0.5) * 2), min(1, combined * 2))
    }

    func slider(hardware: Double, software: Double?) -> Double {
        let combined = software.map { 0.5 * $0 } ?? (0.5 + 0.5 * max(0, (hardware - floor) / (1 - floor)))
        return builtin ? remap(combined, gain: 1 / Self.curveGain) : combined
    }
}

final class DisplayController {
    private struct Job {
        let key: String
        let run: (@escaping () -> Void) -> Void
        let cancel: () -> Void
    }

    let defaults = UserDefaults.standard
    let sensor = LightSensor()
    private let dimming = Dimming()
    private let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/displayctl")
    private let worker = DispatchQueue(label: "io.nigelq.ping-display.hardware", qos: .userInitiated)
    private var jobs: [Job] = []
    private var activeJob: String?
    private var refreshCallbacks: [(Bool) -> Void] = []
    private var requested: [String: Double] = [:]
    private var revisions: [String: UUID] = [:]
    private var lowTargets: [String: Double] = [:]
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var topologyRefresh: DispatchWorkItem?
    private var stopped = false
    private(set) var displays: [Display] = []
    private(set) var builtinPending: Bool?
    private(set) var lastError: String?
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?

    var autoExternal: Bool {
        get { defaults.bool(forKey: "autoExternal") }
        set { defaults.set(newValue, forKey: "autoExternal") }
    }

    var sensorPath: String {
        get { defaults.string(forKey: "sensorPath") ?? "/dev/cu.usbmodem101" }
        set { defaults.set(newValue, forKey: "sensorPath") }
    }

    var presented: [Display] {
        displays.map { display in
            var row = display
            row.brightness = currentBrightness(display)
            return row
        }
    }

    func start() {
        lowTargets = defaults.dictionary(forKey: "lowTargets") as? [String: Double] ?? [:]
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleTopologyRefresh() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleTopologyRefresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
        sensor.applyBrightness = { [weak self] value, completion in
            guard let self else { completion(false); return }
            let external = self.displays.filter { !$0.builtin && $0.active && $0.online }
            guard external.count == 1 else { completion(false); return }
            self.setBrightness(external[0], value: value, completion: completion)
        }
        if defaults.bool(forKey: "sensorEnabled") { sensor.start(path: sensorPath) }
        refresh { [weak self] ok in if ok { self?.restorePolicy() } }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        topologyRefresh?.cancel()
        sensor.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        dimming.restore(displays)
    }

    func currentBrightness(_ display: Display) -> Double? {
        if let target = requested[display.key] { return target }
        guard display.active, let hardware = display.brightness else { return nil }
        return display.slider(hardware: hardware, software: dimming.factor(for: display))
    }

    func refresh(_ completion: ((Bool) -> Void)? = nil) {
        if let completion { refreshCallbacks.append(completion) }
        guard activeJob != "list", !jobs.contains(where: { $0.key == "list" }) else { return }
        enqueue(Job(key: "list", run: { [self] done in
            native(["list"]) { result in
                let rows = try? JSONDecoder().decode([Display].self, from: result.get())
                if let rows { self.displays = rows }
                let callbacks = self.refreshCallbacks
                self.refreshCallbacks.removeAll()
                self.onChange?()
                for callback in callbacks { callback(rows != nil) }
                done()
            }
        }, cancel: {}))
    }

    func setBrightness(_ display: Display, value: Double, dragging: Bool = false,
                       completion: ((Bool) -> Void)? = nil) {
        guard value.isFinite, display.active, !display.uuid.isEmpty else { completion?(false); return }
        let target = min(1, max(0.01, value))
        let key = "brightness:" + display.key
        let revision = UUID()
        revisions[display.key] = revision
        requested[display.key] = target
        let output = display.output(for: target)
        let preview = dragging && !display.builtin && output.hardware > display.floor
        let finish: (Display, Bool, Result<Data, Error>) -> Void = { [self] current, preview, result in
            guard revisions[display.key] == revision, !stopped else { completion?(false); return }
            do {
                _ = try result.get()
                try dimming.set(output.software, for: current)
                let low = output.software < 1 ? target : nil
                if lowTargets[display.key] != low {
                    lowTargets[display.key] = low
                    defaults.set(lowTargets, forKey: "lowTargets")
                }
                requested[display.key] = preview ? target : nil
                lastError = nil
                onChange?()
                completion?(true)
            } catch {
                requested[display.key] = nil
                if !preview { report(error.localizedDescription) }
                onChange?()
                completion?(false)
            }
        }
        let minimum = output.hardware == display.floor
        if minimum && activeJob != key && activeJob != "builtin",
           !jobs.contains(where: { $0.key == key || $0.key == "builtin" }),
           display.brightness == display.floor {
            finish(display, false, .success(Data()))
            return
        }
        enqueue(Job(key: key, run: { [self] done in
            guard let index = displays.firstIndex(where: { $0.key == display.key && $0.active && $0.uuid == display.uuid }) else {
                finish(display, false, .failure(DisplayError("显示器已断开"))); done(); return
            }
            let current = displays[index]
            if minimum && current.brightness == current.floor {
                finish(current, false, .success(Data()))
                done()
                return
            }
            let range = preview ? current.ddcMaximum : nil
            var args = ["brightness", "--uuid", current.uuid, "--value",
                        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), output.hardware)]
            if let range { args += ["--preview-max", String(range)] }
            native(args) { result in
                if self.displays.indices.contains(index), self.displays[index].uuid == current.uuid {
                    self.displays[index].brightness = range == nil && (try? result.get()) != nil
                        ? Double(args[4]) : nil
                }
                finish(current, range != nil, result)
                if range == nil && self.revisions[display.key] == revision { self.refresh() }
                done()
            }
        }, cancel: { completion?(false) }), coalesce: true)
    }

    func setBuiltin(_ enabled: Bool, manual: Bool = false) {
        guard builtinPending == nil else { return }
        if manual && enabled { autoExternal = false }
        builtinPending = enabled
        onChange?()
        enqueue(Job(key: "builtin", run: { [self] done in
            native(["builtin", enabled ? "on" : "off"]) { result in
                if case let .failure(error) = result { self.report(error.localizedDescription) }
                self.refresh { _ in
                    self.builtinPending = nil
                    self.onChange?()
                }
                done()
            }
        }, cancel: {}))
    }

    func applyAutoPolicy() {
        guard let built = displays.first(where: \.builtin) else { return }
        if autoExternal {
            let external = displays.contains { !$0.builtin && $0.active && $0.online && $0.ddcMaximum != nil }
            if built.active == external { setBuiltin(!external) }
        } else if !built.active {
            setBuiltin(true)
        }
    }

    func cancelDimming() {
        setSensorEnabled(false)
        revisions.removeAll()
        requested.removeAll()
        lowTargets.removeAll()
        defaults.removeObject(forKey: "lowTargets")
        let discarded = jobs.filter { $0.key.hasPrefix("brightness:") }
        jobs.removeAll { $0.key.hasPrefix("brightness:") }
        discarded.forEach { $0.cancel() }
        if !dimming.restore(displays, forceUncertain: true) { report("部分显示器的软调暗未能恢复") }
        refresh()
    }

    func setSensorEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "sensorEnabled")
        if enabled { sensor.start(path: sensorPath) } else { sensor.stop() }
    }

    func report(_ error: String) {
        lastError = error
        onError?(error)
    }

    private func restorePolicy() {
        for display in displays where display.active {
            if let value = lowTargets[display.key] { setBrightness(display, value: value) }
        }
        if autoExternal { applyAutoPolicy() }
    }

    private func scheduleTopologyRefresh() {
        topologyRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refresh { ok in if ok { self?.restorePolicy() } }
        }
        topologyRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func enqueue(_ job: Job, coalesce: Bool = false) {
        guard !stopped else { job.cancel(); return }
        if coalesce, let index = jobs.firstIndex(where: { $0.key == job.key }) {
            let old = jobs[index]
            jobs[index] = job
            old.cancel()
        } else {
            jobs.append(job)
        }
        pump()
    }

    private func pump() {
        guard !stopped, activeJob == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        activeJob = job.key
        job.run { [weak self] in self?.activeJob = nil; self?.pump() }
    }

    private func native(_ args: [String], completion: @escaping (Result<Data, Error>) -> Void) {
        let helper = helper
        worker.async {
            let result = Result { () -> Data in
                let task = Process()
                let output = Pipe()
                task.executableURL = helper
                task.arguments = args
                task.standardOutput = output
                task.standardError = output
                try task.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw DisplayError(detail.isEmpty ? "显示器操作失败" : detail)
                }
                return data
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
