// Logo animato "onda → testo" (stessa geometria di design/icon.svg, unità su 1024).
// Le righe di testo si "scrivono" una dopo l'altra in loop (più veloce in registrazione);
// le barre dell'onda respirano piano a riposo e ballano come un equalizzatore in registrazione.
import SwiftUI

struct LogoView: View {
    var recording = false
    var size: CGFloat = 36
    var paused = false

    private static let bars: [(x: CGFloat, h: CGFloat)] = [(238, 150), (310, 330), (382, 230), (454, 120)]
    private static let lines: [(y: CGFloat, l: CGFloat)] = [(377, 280), (455, 210), (533, 250), (611, 150)]
    private static let gradient = Gradient(colors: [Color(red: 1, green: 0.60, blue: 0.36), Color(red: 1, green: 0.31, blue: 0.43)])

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, sz in
                let k = sz.width / 620, ox = 200.0, w = 48.0
                func r(_ x: CGFloat, _ y: CGFloat, _ wd: CGFloat, _ h: CGFloat) -> Path {
                    Path(roundedRect: CGRect(x: (x - ox) * k, y: (y - ox) * k, width: wd * k, height: h * k), cornerRadius: w / 2 * k)
                }
                var p = Path()
                for (i, b) in Self.bars.enumerated() {
                    let d = Double(i)
                    let s = recording ? 0.55 + 0.5 * abs(sin(t * (4.6 + d * 0.9) + d * 1.7)) : 1 + 0.07 * sin(t * 2 + d * 0.8)
                    let h = max(w, b.h * s)
                    p.addPath(r(b.x - w / 2, 512 - h / 2, w, h))
                }
                let fill = GraphicsContext.Shading.linearGradient(Self.gradient, startPoint: CGPoint(x: 14 * k, y: 147 * k), endPoint: CGPoint(x: 606 * k, y: 477 * k))
                gc.fill(p, with: fill)
                // righe: ogni riga cresce da sinistra (1 passo), poi una pausa a testo completo e dissolvenza, poi si ricomincia
                let step = (t / (recording ? 0.55 : 0.85)).truncatingRemainder(dividingBy: 7) // 4 righe + 2 pausa + 1 dissolvenza
                var text = Path()
                for (i, l) in Self.lines.enumerated() {
                    let f = min(max(step - Double(i), 0), 1)
                    guard f > 0 else { continue }
                    let eased = 1 - pow(1 - f, 3)
                    text.addPath(r(526, l.y - w / 2, max(w, l.l * eased), w))
                }
                var g = gc
                g.opacity = step > 6 ? 7 - step : 1
                g.fill(text, with: fill)
            }
            .shadow(color: Color(red: 1, green: 0.42, blue: 0.4).opacity(recording ? 0.75 : 0.35), radius: size * 0.15)
        }
        .frame(width: size, height: size)
    }
}
