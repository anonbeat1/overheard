// Riunioni ricorrenti (standup, weekly): stesso evento ricorrente del calendario, oppure per le riunioni
// registrate prima stesso titolo dal calendario e con invitati (il titolo scritto dall'AI non ha invitati).
import SwiftUI

enum MeetingSeries {
    /// Identificativo dell'evento ricorrente, scritto da MeetingCalendar.annotate nel file "series"
    static func id(_ dir: URL) -> String? {
        (try? String(contentsOf: dir.appendingPathComponent("series"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Stesso titolo e: stesso evento ricorrente se lo sanno entrambe, altrimenti invitati in tutte e due
    static func sameSeries(_ a: Meeting, _ b: Meeting) -> Bool {
        guard let t = a.title, let u = b.title, t.caseInsensitiveCompare(u) == .orderedSame else { return false }
        if let x = id(a.url), let y = id(b.url) { return x == y }
        return !MeetingCalendar.attendees(a.url).isEmpty && !MeetingCalendar.attendees(b.url).isEmpty
    }

    /// Le riunioni della serie di `m`, lei compresa, dalla più recente; vuoto se non ce ne sono almeno due
    static func members(of m: Meeting, in all: [Meeting]) -> [Meeting] {
        guard let title = m.title else { return [] }
        // prima il titolo (già in memoria), poi i file solo per quelle poche
        let out = all.filter { $0.id == m.id || ($0.title?.caseInsensitiveCompare(title) == .orderedSame && sameSeries(m, $0)) }
        return out.count >= 2 ? out.sorted { $0.id > $1.id } : []
    }

    /// Cose da fare non spuntate nei riassunti della serie
    static func openTasks(_ members: [Meeting]) -> [(meeting: Meeting, text: String)] {
        members.flatMap { m in
            SummaryLine.parse((try? String(contentsOf: m.url.appendingPathComponent("summary.md"), encoding: .utf8)) ?? "")
                .compactMap { l -> (Meeting, String)? in
                    guard case .todo(done: false) = l.kind else { return nil }
                    return (m, l.text)
                }
        }
    }
}

/// Pannello della serie: le riunioni (clic = apri), le cose da fare ancora aperte in tutte, e la domanda all'AI
struct SeriesView: View {
    let title: String
    let members: [Meeting]
    let current: String
    let onOpen: (String) -> Void
    let onAsk: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tasks = MeetingSeries.openTasks(members)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: "repeat").font(.title3.weight(.bold))
                Spacer()
                Button("Chiudi") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(members.count) riunioni").font(.headline).foregroundStyle(.orange)
                        ForEach(members) { m in
                            Button { onOpen(m.id) } label: {
                                HStack {
                                    Text(m.date?.formatted(date: .abbreviated, time: .shortened) ?? m.id)
                                    if m.id == current { Text("aperta ora").font(.caption).foregroundStyle(.white.opacity(0.5)) }
                                    Spacer()
                                    if !FileManager.default.fileExists(atPath: m.url.appendingPathComponent("summary.md").path) {
                                        Text("senza riassunto").font(.caption).foregroundStyle(.white.opacity(0.4))
                                    }
                                }
                                .padding(.vertical, 3).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(m.id == current)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cose da fare ancora aperte").font(.headline).foregroundStyle(.orange)
                        if tasks.isEmpty { Text("Nessuna: tutto spuntato.").foregroundStyle(.white.opacity(0.5)) }
                        ForEach(Array(tasks.enumerated()), id: \.offset) { _, t in
                            Button { onOpen(t.meeting.id) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "circle").foregroundStyle(.white.opacity(0.5))
                                    Text((try? AttributedString(markdown: t.text)) ?? AttributedString(t.text)).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Text(t.meeting.date?.formatted(.dateTime.day().month(.abbreviated)) ?? "").font(.caption).foregroundStyle(.white.opacity(0.5))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("Apri la riunione")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                onAsk(String(localized: "Confronta le riunioni della serie «\(title)» (cartelle: \(members.map(\.id).joined(separator: ", "))): cosa è cambiato da una all'altra, quali temi tornano e quali cose da fare restano aperte?"))
            } label: { Label("Cosa è cambiato?", systemImage: "sparkles").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).tint(.orange)
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .foregroundStyle(.white)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}
