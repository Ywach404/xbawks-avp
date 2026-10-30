// JITProbe -- S0 for xemu-avp, in a window you can read with the headset on.
//
// The interesting run is not the first one. Launch under a debugger, detach,
// then press Run again: that is the attach trick, and whether the second run
// still executes is the thing the whole port is gated on.

import SwiftUI
import UIKit

@main
struct JITProbeApp: App {
	// The probe runs here, at process start, NOT when the view appears.
	//
	// Under a debugger a visionOS app can sit at the loading splash and never
	// present a window, so anything hung off a view's lifecycle never runs.
	// The one measurement this whole project is gated on cannot depend on the
	// compositor cooperating, and the journal on disk is the real output. The
	// window is a convenience for reading it.
	init() {
		ProbeModel.runAtLaunch()
	}

	var body: some Scene {
		WindowGroup {
			ProbeView()
		}
		.defaultSize(width: 760, height: 900)
	}
}

@MainActor
@Observable
final class ProbeModel {
	var report = ""
	var previous = ""
	var executed = 0
	var runCount = 0

	// Rewritten line by line from C. Executing a page the kernel objects to
	// can end the process outside anything a signal handler sees, so after a
	// hard crash this file is the only evidence of how far it got.
	private var journalURL: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("jitprobe-journal.txt")
	}

	func loadPrevious() {
		previous = (try? String(contentsOf: journalURL, encoding: .utf8)) ?? ""
	}

	// Journal path resolved without touching any @MainActor state, so it can
	// be called from the App's init before anything else exists.
	nonisolated static var journalPath: String {
		(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("jitprobe-journal.txt")).path
	}

	nonisolated static func runAtLaunch() {
		var buffer = [CChar](repeating: 0, count: 64 * 1024)
		_ = journalPath.withCString { jp_run_all($0, &buffer, buffer.count) }
	}

	func run() {
		runCount += 1
		var buffer = [CChar](repeating: 0, count: 64 * 1024)
		let n = journalURL.path.withCString { journal in
			jp_run_all(journal, &buffer, buffer.count)
		}
		executed = Int(n)
		report = String(cString: buffer)
	}

	var verdict: String {
		if executed > 0 {
			return jp_cs_debugged() == 1
				? "JIT works, but this process is debugger-flagged"
				: "JIT works with no debugger involved"
		}
		return "No path produced running code"
	}

	var verdictColour: Color { executed > 0 ? .green : .red }
}

struct ProbeView: View {
	@State private var model = ProbeModel()

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			header

			ScrollView {
				Text(model.report.isEmpty ? "not run yet" : model.report)
					.font(.system(.caption, design: .monospaced))
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxHeight: .infinity)

			if !model.previous.isEmpty {
				DisclosureGroup("Journal from the previous launch") {
					ScrollView {
						Text(model.previous)
							.font(.system(.caption2, design: .monospaced))
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(height: 160)
				}
			}

			controls
		}
		.padding(28)
		.task {
			model.loadPrevious()
			model.run()
		}
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("JIT probe")
				.font(.largeTitle.bold())
			Text(model.verdict)
				.font(.title3.weight(.semibold))
				.foregroundStyle(model.verdictColour)
			Text("\(model.executed) of 4 paths executed, run \(model.runCount)")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}

	private var controls: some View {
		HStack(spacing: 12) {
			Button("Run again") { model.run() }
				.buttonStyle(.borderedProminent)
			Button("Copy report") {
				UIPasteboard.general.string = model.report
			}
			Spacer()
			Text("Detach the debugger first, then Run again")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}
}
