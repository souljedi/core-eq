import Foundation
import Testing

extension AutoEQIntegrationTests {
    struct LocalSolver {
        @Test func fitsSyntheticTargetWithinOneDecibel() throws {
            let frequencies = AutoEQLocalSolver.frequencies
            let measurement = AutoEQCurve(
                frequency: frequencies, raw: frequencies.map { _ in 0 })
            let target = AutoEQCurve(
                frequency: frequencies,
                raw: frequencies.map { frequency in
                    let bass = 3.0 / (1 + pow(frequency / 160, 2))
                    let presence = 2.0 * exp(-pow(log(frequency / 2_800), 2) / 0.18)
                    return bass + presence
                })
            let result = try AutoEQLocalSolver.compute(
                measurement: measurement,
                target: .init(label: "Synthetic", compatible: [], recommended: [], fr: target))
            let errors = frequencies.filter { $0 <= 6000 }.map { frequency in
                result.filters.reduce(0) {
                    $0 + AutoEQLocalSolver.response($1, at: frequency)
                } - target.value(at: frequency)
            }
            let rms = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count))
            #expect(rms < 1.0, "Synthetic response RMS: \(rms) dB")
            #expect(result.filters.count == AutoEQLocalSolver.filterCount)
            #expect(result.filters.allSatisfy { (-12...6).contains($0.gain) })
            #expect((-12...0).contains(result.preamp))
        }

        @Test func invalidInputsAndCancellation() async throws {
            #expect(throws: AutoEQError.malformedData) {
                try AutoEQCurve.csv(Data("frequency,raw\n20,nan\n30,0".utf8))
            }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                let curve = AutoEQCurve(frequency: [20, 20_000], raw: [0, 0])
                return try AutoEQLocalSolver.compute(
                    measurement: curve,
                    target: .init(label: "Flat", compatible: [], recommended: [], fr: curve))
            }
            do {
                _ = try await task.value
                Issue.record("Expected cancellation")
            } catch is CancellationError {}
        }
    }
}
