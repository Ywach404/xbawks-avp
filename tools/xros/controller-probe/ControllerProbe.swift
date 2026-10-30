// A probe, not the app. One question: does visionOS hand a PSVR2 Sense
// controller's buttons and sticks to a windowed app, or only to an app with
// an open immersive space? The window logs every element change the
// GameController framework delivers; fifteen seconds in it opens an empty
// mixed immersive space beside the window and keeps logging, with the
// immersive state on every line.
import SwiftUI
import GameController
import RealityKit

final class Log {
    static let shared = Log()
    private let handle: FileHandle
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try! FileHandle(forWritingTo: url)
    }
    func line(_ s: String) {
        let t = String(format: "%8.2f",
                       Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000))
        handle.write("\(t) \(s)\n".data(using: .utf8)!)
    }
}

@Observable final class Pad {
    var text = "waiting for controllers"
    var immersive = "closed"
    init() {
        Log.shared.line("probe start, \(GCController.controllers().count) controllers")
        for c in GCController.controllers() { attach(c) }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
            if let c = n.object as? GCController { self.attach(c) }
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main) { n in
            let c = n.object as? GCController
            Log.shared.line("disconnected \(c?.vendorName ?? "?")")
        }
    }
    func attach(_ c: GCController) {
        let p = c.physicalInputProfile
        Log.shared.line("connected '\(c.vendorName ?? "?")' category \(c.productCategory) "
                        + "extended \(c.extendedGamepad != nil) elements "
                        + p.elements.keys.sorted().joined(separator: ", "))
        p.valueDidChangeHandler = { _, element in
            var v: Float = 0
            if let b = element as? GCControllerButtonInput { v = b.value }
            else if let a = element as? GCControllerAxisInput { v = a.value }
            let name = element.aliases.first ?? "?"
            Log.shared.line("element '\(name)' -> \(v) [immersive \(self.immersive)]")
            DispatchQueue.main.async { self.text = "\(name) -> \(v)" }
        }
    }
}

@main struct ControllerProbeApp: App {
    @State private var pad = Pad()
    var body: some SwiftUI.Scene {
        WindowGroup { ContentView(pad: pad) }
        ImmersiveSpace(id: "pad") { RealityView { _ in } }
    }
}

struct ContentView: View {
    let pad: Pad
    @Environment(\.openImmersiveSpace) private var openImmersive
    @Environment(\.dismissImmersiveSpace) private var dismissImmersive
    var body: some View {
        VStack(spacing: 24) {
            Text("Controller probe").font(.title)
            Text("immersive space: \(pad.immersive)")
            Text(pad.text).font(.system(.body, design: .monospaced))
            Button("Open immersive space") {
                Task {
                    let r = await openImmersive(id: "pad")
                    pad.immersive = "open (\(String(describing: r)))"
                    Log.shared.line("immersive open by button: \(String(describing: r))")
                }
            }
            Button("Close immersive space") {
                Task {
                    await dismissImmersive()
                    pad.immersive = "closed"
                    Log.shared.line("immersive closed by button")
                }
            }
        }
        .padding(40)
        .task {
            Log.shared.line("window up; window-only phase for 15 s, press things now")
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            let r = await openImmersive(id: "pad")
            pad.immersive = "open (\(String(describing: r)))"
            Log.shared.line("immersive auto-open: \(String(describing: r)); press things again")
        }
    }
}
