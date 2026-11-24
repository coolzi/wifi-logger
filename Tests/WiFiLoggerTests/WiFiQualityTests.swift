import Testing

@testable import WiFiLogger

@Test func rssiQualityUsesCiscoThresholdsIncludingTheirBoundaries() {
    let cases: [(Double, WiFiQuality)] = [
        (-30, .good), (-66, .good), (-67, .good), (-67.01, .fair),
        (-69, .fair), (-70, .fair), (-70.01, .weak), (-79, .weak),
        (-80, .weak), (-80.01, .poor), (-90, .poor), (-100, .poor),
    ]
    for (value, expected) in cases {
        #expect(WiFiQualityMetric.rssi.quality(for: value) == expected)
    }
}

@Test func snrQualityDistinguishesVoiceAndDataRecommendations() {
    let cases: [(Double, WiFiQuality)] = [
        (40, .good), (25, .good), (24.99, .fair), (20, .fair),
        (19.99, .poor), (0, .poor), (-5, .poor),
    ]
    for (value, expected) in cases {
        #expect(WiFiQualityMetric.snr.quality(for: value) == expected)
    }
}

@Test func unavailableQualityHasNoRating() {
    for metric in [WiFiQualityMetric.rssi, .snr, .noise] {
        for value: Double? in [nil, .nan, .infinity, -.infinity] {
            #expect(metric.quality(for: value) == nil)
        }
    }
    let unavailable = WiFiSample(time: .now, monotonicTime: 0, state: .disconnected,
                                 measurements: WiFiMeasurements(rssi: -60, noise: -95))
    #expect(WiFiQualityMetric.rssi.quality(for: unavailable.connectedMeasurements.signalDBm.map(Double.init)) == nil)
    #expect(WiFiQualityMetric.snr.quality(for: unavailable.connectedMeasurements.snrDB.map(Double.init)) == nil)
    #expect(WiFiQualityMetric.noise.quality(for: unavailable.connectedMeasurements.noiseDBm.map(Double.init)) == nil)
}

@Test func noiseQualityUsesTheInverseScaleAtTheReferenceSignal() {
    let cases: [(Double, WiFiQuality)] = [
        (-110, .good), (-95, .good), (-92, .good), (-91.99, .fair),
        (-90, .fair), (-87, .fair), (-86.99, .poor), (-80, .poor),
    ]
    for (noise, expected) in cases {
        #expect(WiFiQualityMetric.noise.quality(for: noise) == expected)
        #expect(WiFiQualityMetric.noise.quality(for: noise) == WiFiQualityMetric.snr.quality(for: -67 - noise))
    }
    #expect(WiFiQualityMetric.noise.label(for: .good) == "Низкий")
    #expect(WiFiQualityMetric.noise.label(for: .fair) == "Повышенный")
    #expect(WiFiQualityMetric.noise.label(for: .poor) == "Высокий")
    let missing = WiFiMeasurements(noise: 0)
    #expect(WiFiQualityMetric.noise.quality(for: missing.noiseDBm.map(Double.init)) == nil)
}
