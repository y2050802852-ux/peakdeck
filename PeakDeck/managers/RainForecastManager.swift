//
//  RainForecastManager.swift
//  PeakDeck
//

import AppKit
import Combine
import Defaults
import Foundation

extension Notification.Name {
    /// Posted on the main thread when a rain announcement should be shown.
    /// The sound is played by the manager; the AppDelegate decides whether
    /// the visual banner below the notch can be shown.
    static let rainForecastTriggered = Notification.Name("rainForecastTriggered")
}

/// A contiguous stretch of forecast precipitation.
struct RainEvent: Equatable {
    var start: Date
    var end: Date
    /// True when the event reaches the last forecast slot, so the real end
    /// time is unknown (QWeather only looks 2 hours ahead).
    var endTruncated: Bool
    /// Peak precipitation over the event, in the provider's per-slot unit.
    var peakIntensity: Double
    /// Ensemble probability of the starting hour, 0-100. Only available in
    /// the Open-Meteo fallback (radar nowcast has no probability).
    var probability: Int?

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Scheduled rain announcements below the notch, capped at two banners per
/// rain event:
///  - heads-up: the first check (top-of-hour summary within 2 h, or a
///    quarter-hour scan when the event is within 45 min) where the event
///    falls into the active window — start time, duration and chance
///  - onset: once the forecast slots actually turn wet — "it started, and
///    should ease around X"
///
/// Data source: QWeather's minute-level radar nowcast for China (needs the
/// user's dedicated API host + key in Settings) with Open-Meteo 15-minutely
/// as the no-credential fallback. Both providers normalize into RainEvent.
/// Checks run every 15 minutes at :00/:15/:30/:45; silent while the screen
/// is locked, and overdue fires after wake are skipped like the hourly chime.
@MainActor
final class RainForecastManager: ObservableObject {
    static let shared = RainForecastManager()

    /// Heads-up window for the top-of-hour summary.
    static let summaryWindow: TimeInterval = 2 * 3600
    /// Heads-up lead for quarter-hour scans (events first seen mid-window).
    static let imminentLead: TimeInterval = 45 * 60
    private static let refreshInterval: TimeInterval = 15 * 60

    private struct EventState {
        var headsUpShown = false
        var onsetShown = false
    }

    /// Announcement state per event, keyed by the event start date.
    private var eventStates: [Date: EventState] = [:]
    private var lastEvents: [RainEvent] = []
    private var cachedLocation: WeatherLocation?

    private var refreshTimer: Timer?
    private var isFetching = false
    private var isScreenLocked = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Stay silent while the screen is locked; announcements that fall in
        // the locked window are simply skipped and picked up at the next
        // quarter-hour if they are still relevant.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLocked = true
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLocked = false
            }
        }

        Defaults.publisher(.rainForecastEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                change.newValue ? self?.start() : self?.stop()
            }
            .store(in: &cancellables)

        // Follow the weather city setting; re-resolve when it changes.
        Defaults.publisher(.weatherManualLocationData)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.cachedLocation = nil
            }
            .store(in: &cancellables)

        // Re-arm after sleep/wake and fetch fresh data right away.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, Defaults[.rainForecastEnabled] else { return }
                self.scheduleNext()
                Task { await self.refresh() }
            }
        }

        if Defaults[.rainForecastEnabled] {
            start()
        }
    }

    func start() {
        Task { await refresh() }
        scheduleNext()
        fireDebugPresetIfNeeded()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Scheduling

    private func scheduleNext() {
        refreshTimer?.invalidate()
        let next = Self.nextQuarter(after: Date())
        let timer = Timer(fire: next, interval: 0, repeats: false, block: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAndEvaluate()
            }
        })
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private static func nextQuarter(after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: date)
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        components.minute = (minute / 15 + 1) * 15 // 60 rolls over via calendar normalization
        return calendar.date(from: components) ?? date.addingTimeInterval(15 * 60)
    }

    private func refreshAndEvaluate() {
        scheduleNext()
        Task { await refresh() }
    }

    private func refresh() async {
        guard Defaults[.rainForecastEnabled], !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        if let events = await fetchEvents() {
            lastEvents = events
        }
        // On fetch failure the previous forecast is kept: it is at most one
        // quarter-hour stale, still good enough for a heads-up.
        evaluate()
    }

    // MARK: - Evaluation

    private func evaluate() {
        guard !isScreenLocked, !lastEvents.isEmpty else { return }
        let now = Date()
        pruneStates(before: now.addingTimeInterval(-6 * 3600))
        let topOfHour = Calendar.current.component(.minute, from: now) == 0

        // Onset first: rain is falling right now.
        if let ongoing = lastEvents.first(where: { $0.start <= now && now < $0.end }),
           !state(for: ongoing).onsetShown {
            setState(ongoing) { $0.onsetShown = true }
            announce(onsetMessage(ongoing))
            return // one banner per check
        }

        // Heads-up for the first upcoming event inside the active window.
        let window: TimeInterval = topOfHour ? Self.summaryWindow : Self.imminentLead
        if let upcoming = lastEvents
            .filter({ $0.start > now && $0.start.timeIntervalSince(now) <= window })
            .first(where: { !state(for: $0).headsUpShown }) {
            setState(upcoming) { $0.headsUpShown = true }
            announce(headsUpMessage(upcoming))
        }
    }

    private func state(for event: RainEvent) -> EventState {
        eventStates[event.start] ?? EventState()
    }

    private func setState(_ event: RainEvent, _ mutate: (inout EventState) -> Void) {
        var current = eventStates[event.start] ?? EventState()
        mutate(&current)
        eventStates[event.start] = current
    }

    private func pruneStates(before cutoff: Date) {
        eventStates = eventStates.filter { $0.key > cutoff }
    }

    // MARK: - Messages

    private func announce(_ message: String) {
        SystemSound.play(Defaults[.rainForecastSoundName])
        NotificationCenter.default.post(
            name: .rainForecastTriggered, object: nil,
            userInfo: ["message": message]
        )
    }

    private func headsUpMessage(_ event: RainEvent) -> String {
        let start = Self.timeText(event.start)
        let duration = Self.durationText(event.duration)
        if let probability = event.probability {
            return L10n.string(
                "Rain expected around %@, lasting about %@ · %lld%% chance",
                start, duration, probability
            )
        }
        return L10n.string("Rain expected around %@, lasting about %@", start, duration)
    }

    private func onsetMessage(_ event: RainEvent) -> String {
        if event.endTruncated {
            return L10n.string("It's raining now — likely to stick around for the next two hours")
        }
        return L10n.string("It's raining now — expected to ease around %@", Self.timeText(event.end))
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = max(5, Int((interval / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, _): return L10n.string("%lld min", minutes)
        case (_, 0): return L10n.string("%lld hr", hours)
        default: return L10n.string("%lld hr %lld min", hours, minutes)
        }
    }

    // MARK: - Data source selection

    private func activeLocation() async -> WeatherLocation? {
        if let cached = cachedLocation { return cached }
        guard let location = await WeatherManager.resolveLocation() else {
            Logger.log("Rain forecast: no location available", category: .warning)
            return nil
        }
        cachedLocation = location
        return location
    }

    private var qweatherConfigured: Bool {
        !Defaults[.qweatherApiHost].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !Defaults[.qweatherApiKey].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func fetchEvents() async -> [RainEvent]? {
        guard let location = await activeLocation() else { return nil }
        if qweatherConfigured {
            return await fetchQWeather(location)
        }
        return await fetchOpenMeteo(location)
    }

    private func logFailure(_ source: String, detail: String) {
        Logger.log("Rain forecast: \(source) request failed — \(detail)", category: .warning)
    }

    // MARK: - QWeather (和风天气) minute-level radar nowcast

    private struct QWeatherMinutely: Decodable {
        let code: String
        let summary: String?
        let minutely: [Entry]?

        struct Entry: Decodable {
            let fxTime: String
            let precip: String
            let type: String?
        }
    }

    /// Newer QWeather error shape: {"error": {"status": 403, "type": "...", ...}}
    private struct QWeatherErrorBody: Decodable {
        let error: ErrorInfo?
        struct ErrorInfo: Decodable {
            let status: Int?
            let type: String?
        }
    }

    private func fetchQWeather(_ location: WeatherLocation) async -> [RainEvent]? {
        guard let request = Self.qweatherRequest(
            host: Defaults[.qweatherApiHost],
            key: Defaults[.qweatherApiKey],
            at: location
        ) else {
            logFailure("QWeather", detail: "invalid API host")
            return nil
        }

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let payload = try? JSONDecoder().decode(QWeatherMinutely.self, from: data) else {
            logFailure("QWeather", detail: "network/decode error")
            return nil
        }
        guard payload.code == "200", let entries = payload.minutely, entries.count >= 2 else {
            logFailure("QWeather", detail: "code=\(payload.code)")
            return nil
        }

        let times = entries.compactMap { Self.qweatherDate($0.fxTime) }
        guard times.count == entries.count, let lastTime = times.last else {
            logFailure("QWeather", detail: "unparseable fxTime")
            return nil
        }
        let dataEnd = lastTime.addingTimeInterval(5 * 60)
        let slots: [(Date, Double)] = entries.enumerated().compactMap { index, entry in
            (times[index], Double(entry.precip) ?? 0)
        }
        return Self.groupEvents(
            slots: slots, slotLength: 5 * 60, rainThreshold: 0.08,
            bridgeSlots: 3, dataEnd: dataEnd
        )
    }

    /// Builds the minute-level nowcast request; nil when the host is not a
    /// plausible domain. Shared by the fetch path and settings verification.
    private static func qweatherRequest(host: String, key: String, at location: WeatherLocation) -> URLRequest? {
        var cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        guard cleaned.contains("."), let base = URL(string: "https://\(cleaned)/v7/minutely/5m") else {
            return nil
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // QWeather wants "longitude,latitude" with at most 2 decimals.
            URLQueryItem(name: "location", value: String(format: "%.2f,%.2f", location.longitude, location.latitude)),
            URLQueryItem(name: "lang", value: "zh"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-QW-Api-Key")
        return request
    }

    /// Outcome of the settings-side connection test. QWeather reports errors
    /// both as HTTP status and as a body code; the body code wins when present.
    enum QWeatherVerifyResult: Equatable {
        /// 200 — credentials valid and the minute-level nowcast is unlocked
        /// (personal developer verification complete).
        case minuteNowcastOK
        /// 401 — the API Key is rejected.
        case invalidKey
        /// 403 — key accepted but the nowcast needs personal verification.
        case permissionDenied
        /// Host not reachable (typo, network) or response unparseable.
        case unreachable
        /// Not a plausible host string.
        case invalidHost
    }

    /// Tests the entered QWeather credentials with a real minute-level
    /// nowcast call, so the user learns exactly which layer is broken.
    /// Uses the resolved weather location; falls back to Beijing purely to
    /// have valid coordinates — the test is about credentials, not data.
    /// QWeather errors come either as a legacy `code` body or as the newer
    /// `{error: {status, type, ...}}` object; both are mapped here.
    static func verifyQWeather(host: String, key: String) async -> QWeatherVerifyResult {
        let location = await WeatherManager.resolveLocation()
            ?? WeatherLocation(latitude: 39.92, longitude: 116.41, name: "Beijing")
        guard let request = qweatherRequest(host: host, key: key, at: location) else {
            return .invalidHost
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .unreachable
        }

        if let payload = try? JSONDecoder().decode(QWeatherMinutely.self, from: data) {
            switch payload.code {
            case "200": return .minuteNowcastOK
            case "401": return .invalidKey
            case "403": return .permissionDenied
            default: break
            }
        }
        if let error = try? JSONDecoder().decode(QWeatherErrorBody.self, from: data),
           let info = error.error, let status = info.status {
            switch status {
            case 401: return .invalidKey
            case 403:
                // "invalid-host" means the domain itself is wrong, not a
                // permission problem with a correct host.
                return info.type?.contains("invalid-host") == true ? .invalidHost : .permissionDenied
            default: break
            }
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 401: return .invalidKey
            case 403: return .permissionDenied
            default: break
            }
        }
        return .unreachable
    }

    private static let qweatherDateFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mmXXX"].map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }
    }()

    private static func qweatherDate(_ string: String) -> Date? {
        qweatherDateFormatters.lazy.compactMap { $0.date(from: string) }.first
    }

    // MARK: - Open-Meteo fallback (15-minutely, interpolated from 1 h in China)

    private func fetchOpenMeteo(_ location: WeatherLocation) async -> [RainEvent]? {
        struct Response: Decodable {
            struct Minutely: Decodable {
                let time: [String]
                let precipitation: [Double]?
            }
            struct Hourly: Decodable {
                let time: [String]
                let precipitation_probability: [Int]?
            }
            let minutely_15: Minutely?
            let hourly: Hourly?
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]

        guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
              let payload = try? JSONDecoder().decode(Response.self, from: data),
              let minutely = payload.minutely_15 else {
            logFailure("Open-Meteo", detail: "network/decode error")
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let count = minutely.time.count
        let slots: [(Date, Double)] = minutely.time.enumerated().compactMap { index, text in
            guard let date = formatter.date(from: text) else { return nil }
            guard let values = minutely.precipitation, index < values.count else {
                return (date, 0)
            }
            return (date, values[index])
        }
        guard slots.count >= 2, count == slots.count else {
            logFailure("Open-Meteo", detail: "unparseable time series")
            return nil
        }

        var events = Self.groupEvents(
            slots: slots, slotLength: 15 * 60, rainThreshold: 0.1,
            bridgeSlots: 2, dataEnd: slots.last!.0.addingTimeInterval(15 * 60)
        )

        // Attach the ensemble probability of the hour containing the start.
        if let hourly = payload.hourly {
            let hourlyTimes = hourly.time.compactMap { formatter.date(from: $0) }
            let probabilities = hourly.precipitation_probability ?? []
            for index in events.indices {
                if let hourIndex = hourlyTimes.lastIndex(where: { $0 <= events[index].start }),
                   hourIndex < probabilities.count {
                    events[index].probability = probabilities[hourIndex]
                }
            }
        }
        return events
    }

    // MARK: - Event grouping

    /// Merges wet slots into contiguous events. Short dry gaps (up to
    /// `bridgeSlots - 1` dry slots) are bridged so radar artifacts or hourly
    /// interpolation do not split one shower into many announcements.
    private static func groupEvents(
        slots: [(time: Date, value: Double)],
        slotLength: TimeInterval,
        rainThreshold: Double,
        bridgeSlots: Int,
        dataEnd: Date
    ) -> [RainEvent] {
        var events: [RainEvent] = []
        var current: (start: Date, end: Date, peak: Double)?

        func flush() {
            guard let event = current else { return }
            events.append(RainEvent(
                start: event.start,
                end: event.end,
                endTruncated: event.end >= dataEnd,
                peakIntensity: event.peak,
                probability: nil
            ))
            current = nil
        }

        for slot in slots {
            if slot.value >= rainThreshold {
                if let event = current {
                    current = (event.start, slot.time.addingTimeInterval(slotLength), max(event.peak, slot.value))
                } else {
                    current = (slot.time, slot.time.addingTimeInterval(slotLength), slot.value)
                }
            } else if let event = current,
                      slot.time.timeIntervalSince(event.end) >= TimeInterval(bridgeSlots) * slotLength {
                flush()
            }
        }
        flush()
        return events
    }

    // MARK: - Debug

    /// Hidden hook for visual verification: any non-empty debug preset fires
    /// a canned heads-up banner shortly after the manager starts.
    private func fireDebugPresetIfNeeded() {
        guard !Defaults[.rainForecastDebugPreset].isEmpty else { return }
        Defaults[.rainForecastDebugPreset] = ""
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            let start = Date().addingTimeInterval(30 * 60)
            let fake = RainEvent(
                start: start, end: start.addingTimeInterval(75 * 60),
                endTruncated: false, peakIntensity: 0.3, probability: 65
            )
            self.announce(self.headsUpMessage(fake))
        }
    }
}
