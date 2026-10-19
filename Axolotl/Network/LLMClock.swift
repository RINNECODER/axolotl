// Axolotl — internal clock for the assistant.
// LLMs have no sense of the current date; every request includes this line so
// "today", "this week", and date math work correctly.
import Foundation

enum LLMClock {
    /// One-line date/time context injected into the system prompt of every AI request.
    nonisolated static func contextLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let zone = timeZone.abbreviation(for: now) ?? timeZone.identifier
        return "Current date and time: \(formatter.string(from: now)) \(zone). Use this when answering time-sensitive questions; your training data may be outdated."
    }
}
