import Foundation

struct AutoEQBassBoost: Codable, Hashable, Sendable {
    var fc: Double
    var q: Double
    var gain: Double
}

struct AutoEQCurve: Codable, Hashable, Sendable {
    var frequency: [Double]
    var raw: [Double]

    var isValid: Bool {
        frequency.count == raw.count && frequency.count >= 2
            && frequency.allSatisfy { $0.isFinite && $0 > 0 }
            && raw.allSatisfy { $0.isFinite }
            && zip(frequency, frequency.dropFirst()).allSatisfy { $0 < $1 }
    }

    func value(at f: Double) -> Double {
        if f <= frequency[0] { return raw[0] }
        if f >= frequency.last! { return raw.last! }
        var lo = 0
        var hi = frequency.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequency[mid] <= f { lo = mid } else { hi = mid }
        }
        let t = log(f / frequency[lo]) / log(frequency[hi] / frequency[lo])
        return raw[lo] + t * (raw[hi] - raw[lo])
    }

    static func csv(_ data: Data) throws -> Self {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutoEQError.malformedData
        }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let header = lines.first else { throw AutoEQError.malformedData }
        let columns = header.trimmingCharacters(in: .whitespacesAndNewlines).components(
            separatedBy: ",")
        guard let fi = columns.firstIndex(of: "frequency"), let ri = columns.firstIndex(of: "raw")
        else {
            throw AutoEQError.malformedData
        }
        var f: [Double] = []
        var r: [Double] = []
        for line in lines.dropFirst() {
            let cells = line.components(separatedBy: ",")
            guard cells.count > max(fi, ri), let x = Double(cells[fi]), let y = Double(cells[ri])
            else {
                throw AutoEQError.malformedData
            }
            f.append(x)
            r.append(y)
        }
        let curve = Self(frequency: f, raw: r)
        guard curve.isValid else { throw AutoEQError.malformedData }
        return curve
    }
}

/// Bounded coordinate descent using the same RBJ response as the audio engine.
/// This is an approximation, not a port of AutoEq's SciPy optimizer.
enum AutoEQLocalSolver {
    static let version = 1
    static let filterCount = 10
    static let frequencies = (0..<240).map { 20 * pow(1000, Double($0) / 239) }

    static func response(_ filter: AutoEQEqualizedFilter, at f: Double) -> Double {
        let kind: EQFilter.Kind =
            filter.type == "LOW_SHELF"
            ? .lowShelf
            : filter.type == "HIGH_SHELF" ? .highShelf : .bell
        return Biquad(
            kind: kind, frequency: filter.fc, gain: filter.gain, q: filter.q,
            sampleRate: 44_100
        ).magnitudeDB(at: f, sampleRate: 44_100)
    }

    static func compute(
        measurement: AutoEQCurve, target: AutoEQTarget
    ) throws -> AutoEQEqualizedProfile {
        guard measurement.isValid, let curve = target.fr, curve.isValid else {
            throw AutoEQError.malformedData
        }
        let offset = curve.value(at: 1000) - measurement.value(at: 1000)
        let desired = frequencies.map { f -> Double in
            var delta = curve.value(at: f) - measurement.value(at: f) - offset
            if let bass = target.bassBoost {
                delta += response(
                    .init(type: "LOW_SHELF", fc: bass.fc, q: bass.q, gain: bass.gain), at: f)
            }
            // Avoid attempting to invert narrow high-frequency measurement nulls.
            if f > 6000 { delta *= max(0, 1 - log(f / 6000) / log(20000 / 6000)) }
            return min(6, max(-12, delta))
        }
        var filters = [
            AutoEQEqualizedFilter(type: "LOW_SHELF", fc: 105, q: 0.7, gain: 0),
            AutoEQEqualizedFilter(type: "HIGH_SHELF", fc: 8000, q: 0.7, gain: 0),
        ]
        filters += (0..<8).map {
            .init(type: "PEAKING", fc: 40 * pow(250, Double($0) / 7), q: 1, gain: 0)
        }
        var responses = filters.map { filter in frequencies.map { response(filter, at: $0) } }
        var sum = [Double](repeating: 0, count: frequencies.count)
        for step in [2.0, 1, 0.5, 0.25, 0.125] {
            for _ in 0..<4 {
                for i in filters.indices {
                    try Task.checkCancellation()
                    let residual = zip(sum, responses[i]).map(-)
                    func loss(_ values: [Double]) -> Double {
                        zip(zip(residual, values), desired).reduce(0) {
                            $0 + pow($1.0.0 + $1.0.1 - $1.1, 2)
                        }
                    }
                    var best = loss(responses[i])
                    var chosen = filters[i]
                    var chosenResponse = responses[i]
                    for parameter in 0..<3 {
                        // Shelves stay monotonic so summed positive gains bound the response.
                        if parameter == 2 && filters[i].type != "PEAKING" { continue }
                        for direction in [-1.0, 1.0] {
                            var candidate = filters[i]
                            switch parameter {
                            case 0:
                                candidate.gain = min(6, max(-12, candidate.gain + direction * step))
                            case 1:
                                candidate.fc = min(
                                    10000, max(20, candidate.fc * pow(2, direction * step / 4)))
                            default:
                                candidate.q = min(
                                    4, max(0.3, candidate.q * pow(2, direction * step / 4)))
                            }
                            let positiveGain = filters.enumerated().reduce(0.0) {
                                $0 + max(0, $1.offset == i ? candidate.gain : $1.element.gain)
                            }
                            guard positiveGain <= 11.75 else { continue }
                            let values = frequencies.map { response(candidate, at: $0) }
                            let score = loss(values)
                            if score < best {
                                best = score
                                chosen = candidate
                                chosenResponse = values
                            }
                        }
                    }
                    filters[i] = chosen
                    responses[i] = chosenResponse
                    sum = zip(residual, chosenResponse).map(+)
                }
            }
        }
        // Sum of positive individual gains is a conservative bound at every frequency,
        // including peaks between grid samples and at other playback sample rates.
        // Match the importer's serialized precision before calculating headroom.
        for i in filters.indices {
            filters[i].gain = floor(filters[i].gain * 10) / 10
            filters[i].fc = filters[i].fc.rounded()
            filters[i].q = (filters[i].q * 100).rounded() / 100
        }
        let preamp = -filters.reduce(0) { $0 + max(0, $1.gain) } - 0.2
        return .init(filters: filters, preamp: preamp)
    }
}
