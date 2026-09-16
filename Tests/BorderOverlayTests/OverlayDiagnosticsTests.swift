import AppKit
import Diagnostics
import Foundation
import Testing
@testable import BorderOverlay

@MainActor
struct OverlayDiagnosticsTests {
    @Test("pulse changes are logged once and rendering is aggregated")
    func pulseAndRenderTelemetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-diagnostics-\(UUID().uuidString)")
        let recorder = DiagnosticRecorder(directory: directory)
        defer { recorder.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let geometry = PhysicalBorderGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notch: NotchGeometry(rect: CGRect(x: 663.5, y: 950, width: 185, height: 32)),
            leftX: 661, rightX: 851, topY: 982, bottomY: 948, cornerRadius: 8)
        let view = OverlayView(frame: CGRect(x: 0, y: 900, width: 700, height: 82), drawing: .physical(geometry),
            lineWidth: 2, glow: false, pulse: false, padding: 0, strokeRange: .init(start: 0, end: 1),
            color: .red, strips: BorderStripStyle(), reduceMotion: false, globalOrigin: .zero, diagnostics: recorder)
        for _ in 0..<5 {
            view.updateAppearance(lineWidth: 2, glow: true, pulse: true, padding: 0,
                strokeRange: .init(start: 0, end: 1), color: .red, strips: BorderStripStyle(),
                reduceMotion: false, content: NotchHoverContent(), isEnabled: true)
        }
        view.setExpanded(true, animated: true)
        view.setSpaceTransitionHidden(true, animated: true)
        let border = try #require(view.layer?.sublayers?.first { $0.name == "border" })
        #expect(border.animation(forKey: "borderPulseOpacity") != nil)
        view.updateAppearance(lineWidth: 2, glow: true, pulse: true, padding: 0,
            strokeRange: .init(start: 0, end: 1), color: .red, strips: BorderStripStyle(),
            reduceMotion: true, content: NotchHoverContent(), isEnabled: true)
        #expect(border.animation(forKey: "borderPulseOpacity") == nil)
        recorder.shutdown()
        let events = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.flatMap { url in
                try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                }
            }
        let context = events.filter { $0["event"] as? String == "context" }.compactMap { $0["fields"] as? [String: Any] }
        #expect(context.compactMap { $0["pulse.animationActive"] as? Bool } == [false, true, false])
        let counters = events.filter { $0["event"] as? String == "counters" }.compactMap { $0["fields"] as? [String: Any] }
        #expect(counters.count == 1)
        #expect((counters.first?["render.count"] as? Int ?? 0) >= 8)
        #expect((counters.first?["render.durationNanoseconds"] as? Int ?? 0) > 0)
    }
}
