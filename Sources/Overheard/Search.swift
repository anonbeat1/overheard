// Ricerca rapida nei transcript (pannello della barra dei menu): niente indice, si leggono i file all'apertura.
import SwiftUI

struct SearchHit: Identifiable {
    let meeting: Meeting
    let line: TranscriptLine
    var id: String { "\(meeting.id)#\(line.id)" }
}

enum MeetingSearch {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    // ponytail: legge tutti i transcript a ogni apertura del pannello; ok fino a qualche migliaio di meeting
    static func load() -> [(Meeting, [TranscriptLine])] {
        Meeting.recent(.max).compactMap { m in
            (try? String(contentsOf: m.url.appendingPathComponent("transcript.md"), encoding: .utf8)).map { (m, TranscriptLine.parse($0)) }
        }
    }

    /// Interventi che contengono la frase cercata, dal meeting più recente
    static func search(_ query: String, in index: [(Meeting, [TranscriptLine])]) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return index.flatMap { m, lines in
            lines.filter { !$0.speaker.isEmpty && ($0.text.range(of: q, options: options) != nil || $0.speaker.range(of: q, options: options) != nil) }
                .map { SearchHit(meeting: m, line: $0) }
        }
    }

    /// Pezzo di testo attorno alla prima occorrenza, con le occorrenze evidenziate
    static func snippet(_ text: String, _ query: String, radius: Int = 48) -> AttributedString {
        var s = text
        if let r = text.range(of: query, options: options) {
            let start = text.index(r.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
            // parte dall'inizio di una parola
            let from = start == text.startIndex ? start : (text[start...].firstIndex(of: " ").map { text.index(after: $0) } ?? start)
            s = (from == text.startIndex ? "" : "…") + text[from...]
        }
        return highlighted(s, query)
    }
}

/// Testo con le occorrenze di `query` in grassetto arancione
func highlighted(_ text: String, _ query: String) -> AttributedString {
    var out = AttributedString(text)
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return out }
    var rest = text.startIndex..<text.endIndex
    while let r = text.range(of: q, options: MeetingSearch.options, range: rest) {
        if let ar = Range(r, in: out) {
            out[ar].foregroundColor = .orange
            out[ar].inlinePresentationIntent = .stronglyEmphasized // grassetto della dimensione del testo intorno
        }
        rest = r.upperBound..<text.endIndex
    }
    return out
}

/// Riga cliccabile con evidenziazione al passaggio del mouse (o selezionata da tastiera)
struct HoverRow<Label: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(selected || hover ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Campo di ricerca + risultati del pannello
struct QuickSearch: View {
    @Binding var query: String
    @State private var index: [(Meeting, [TranscriptLine])] = []
    @State private var selected = 0
    @FocusState private var focused: Bool
    private let maxShown = 5

    private var hits: [SearchHit] { MeetingSearch.search(query, in: index) }

    var body: some View {
        let hits = hits, q = query.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(focused ? .orange : .white.opacity(0.45))
                TextField("Cerca nei meeting", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { submit(hits) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, min(hits.count, maxShown) - 1); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) {
                        if query.isEmpty { PanelController.shared.hide() } else { query = "" }
                        return .handled
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4)) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(Color.white.opacity(focused ? 0.1 : 0.07), in: Capsule())
            .overlay(Capsule().stroke(Color.orange.opacity(focused ? 0.55 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: focused)

            if q.count >= 2 {
                Card {
                    HStack {
                        Text("Risultati").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        if !hits.isEmpty {
                            let n = Set(hits.map(\.meeting.id)).count
                            Text("\(hits.count) \(hits.count == 1 ? "frase" : "frasi") in \(n) meeting")
                                .font(.caption).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    if hits.isEmpty {
                        Text(index.isEmpty ? "Carico i transcript…" : "Nessun risultato per «\(q)»")
                            .font(.callout).foregroundStyle(.white.opacity(0.5)).padding(.vertical, 4)
                    }
                    VStack(spacing: 2) {
                        ForEach(Array(hits.prefix(maxShown).enumerated()), id: \.element.id) { i, hit in
                            HoverRow(selected: i == selected) { open(hit) } label: { row(hit, q) }
                        }
                    }
                    .padding(.horizontal, -8)
                    if hits.count > maxShown {
                        Button("Vedi tutti i \(hits.count) risultati") { openAll(hits) }
                            .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                    HoverRow(action: { askAI(q) }) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(.orange)
                            (Text("Chiedi all'AI: ").foregroundStyle(.white.opacity(0.6)) + Text("«\(q)»").fontWeight(.semibold))
                                .font(.callout).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .padding(.horizontal, -8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: q.count >= 2)
        .onChange(of: query) { _, _ in selected = 0 }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let idx = MeetingSearch.load()
                DispatchQueue.main.async { index = idx }
            }
        }
    }

    private func row(_ hit: SearchHit, _ q: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SourceIcon(source: hit.meeting.source).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hit.meeting.app).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(hit.meeting.when) · \(hit.line.time)").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                }
                (Text(hit.line.speaker + ": ").foregroundStyle(speakerColor(hit.line.speaker)).fontWeight(.medium)
                    + Text(MeetingSearch.snippet(hit.line.text, q)))
                    .font(.callout).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            }
        }
    }

    private func submit(_ hits: [SearchHit]) {
        if hits.indices.contains(selected) { open(hits[selected]) } else if !query.isEmpty { openAll(hits) }
    }

    private func open(_ hit: SearchHit) {
        PanelController.shared.hide()
        TranscriptWindow.show(hit.meeting, query: query, at: hit.line.seconds)
    }

    private func openAll(_ hits: [SearchHit]) {
        PanelController.shared.hide()
        TranscriptWindow.show(hits.first?.meeting, query: query)
    }

    private func askAI(_ q: String) {
        PanelController.shared.hide()
        TranscriptWindow.show(nil, ask: q)
    }
}
