import SwiftUI

enum WiFiQuality {
    case good, fair, weak, poor

    var label: String {
        switch self {
        case .good: String(localized: "Хороший")
        case .fair: String(localized: "Допустимый")
        case .weak: String(localized: "Слабый")
        case .poor: String(localized: "Очень слабый")
        }
    }

    var color: Color {
        // Darker foregrounds keep the yellow and green readouts legible in light appearance.
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch self {
            case .good:
                return isDark ? .systemGreen : NSColor(srgbRed: 0.10, green: 0.48, blue: 0.20, alpha: 1)
            case .fair:
                return isDark ? .systemYellow : NSColor(srgbRed: 0.55, green: 0.39, blue: 0, alpha: 1)
            case .weak:
                return isDark ? .systemOrange : NSColor(srgbRed: 0.72, green: 0.32, blue: 0.02, alpha: 1)
            case .poor:
                return isDark ? .systemRed : NSColor(srgbRed: 0.78, green: 0.12, blue: 0.10, alpha: 1)
            }
        })
    }
}

enum WiFiQualityMetric {
    case rssi, snr, noise

    static let noiseReferenceSignalDBm: Double = -67

    var unit: String { self == .snr ? String(localized: "дБ") : String(localized: "дБм") }

    // Cisco, "Troubleshooting a Traditional Cisco Wireless Network", SNR section.
    // These application-oriented recommendations are not IEEE color requirements.
    var thresholds: [(minimum: Double, quality: WiFiQuality)] {
        switch self {
        case .rssi: [(-67, .good), (-70, .fair), (-80, .weak)]
        case .snr: [(25, .good), (20, .fair)]
        case .noise: Self.snr.thresholds.map { (Self.noiseReferenceSignalDBm - $0.minimum, $0.quality) }
        }
    }

    func quality(for value: Double?) -> WiFiQuality? {
        guard let value, value.isFinite else { return nil }
        return thresholds.first { self == .noise ? value <= $0.minimum : value >= $0.minimum }?.quality ?? .poor
    }

    func label(for quality: WiFiQuality) -> String {
        if self == .noise {
            return switch quality {
            case .good: String(localized: "Низкий")
            case .fair: String(localized: "Повышенный")
            case .weak, .poor: String(localized: "Высокий")
            }
        }
        return self == .snr && quality == .poor ? String(localized: "Низкий") : quality.label
    }

    func gradient(in bounds: ClosedRange<Double>) -> LinearGradient {
        let span = bounds.upperBound - bounds.lowerBound
        var previous = quality(for: bounds.lowerBound) ?? .poor
        var stops = [Gradient.Stop(color: previous.color, location: 0)]
        for threshold in thresholds.sorted(by: { $0.minimum < $1.minimum })
            where threshold.minimum > bounds.lowerBound && threshold.minimum < bounds.upperBound {
            let position = (threshold.minimum - bounds.lowerBound) / span
            let next = quality(for: threshold.minimum.nextUp) ?? .poor
            // Paired stops change color at the threshold, without inventing intermediate levels.
            stops.append(.init(color: previous.color, location: position))
            stops.append(.init(color: next.color, location: position))
            previous = next
        }
        stops.append(.init(color: previous.color, location: 1))
        return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }
}
