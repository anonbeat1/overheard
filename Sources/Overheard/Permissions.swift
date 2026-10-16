// Permessi di macOS: stato e richiesta uno per uno (nell'introduzione), invece che tutti all'avvio.
import AVFoundation
import AppKit
import EventKit
import UserNotifications

enum Permission: CaseIterable {
    case microphone, systemAudio, notifications, calendar

    enum State { case granted, denied, unknown }

    var title: String {
        switch self {
        case .microphone: String(localized: "Microfono")
        case .systemAudio: String(localized: "Audio di sistema")
        case .notifications: String(localized: "Notifiche")
        case .calendar: String(localized: "Calendario")
        }
    }

    var icon: String {
        switch self {
        case .microphone: "mic.fill"
        case .systemAudio: "speaker.wave.2.fill"
        case .notifications: "bell.fill"
        case .calendar: "calendar"
        }
    }

    func state() async -> State {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .unknown
            default: return .denied
            }
        case .systemAudio:
            return AudioCaptureTCC.preflight()
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional: return .granted
            case .notDetermined: return .unknown
            default: return .denied
            }
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .notDetermined: return .unknown
            default: return .denied
            }
        }
    }

    /// Mostra la richiesta di macOS (solo la prima volta: dopo un rifiuto si cambia dalle Impostazioni di Sistema)
    func request() async {
        switch self {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .systemAudio: await AudioCaptureTCC.request()
        case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .calendar:
            if await MeetingCalendar.requestAccess() { UserDefaults.standard.set(true, forKey: "calendar.enabled") }
        }
    }

    func openSettings() {
        let pane = switch self {
        case .microphone: "com.apple.preference.security?Privacy_Microphone"
        case .systemAudio: "com.apple.preference.security?Privacy_AudioCapture"
        case .notifications: "com.apple.Notifications-Settings.extension"
        case .calendar: "com.apple.preference.security?Privacy_Calendars"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
    }
}

/// "Registrazione audio di sistema" (process tap) non ha un'API pubblica per stato e richiesta:
/// si usa TCC come fa AudioCap. Se il framework cambia, si ripiega su "sconosciuto" e macOS chiede alla prima registrazione.
enum AudioCaptureTCC {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func preflight() -> Permission.State {
        guard let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request() async {
        guard let sym = dlsym(tcc, "TCCAccessRequest") else { return }
        let fn = unsafeBitCast(sym, to: Request.self)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in fn(service, nil) { _ in c.resume() } }
    }
}
