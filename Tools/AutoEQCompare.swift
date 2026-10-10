import Foundation

/// CLI adapter around the production solver and import path; no duplicated filter math.
@main
struct AutoEQCompare {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            throw NSError(
                domain: "AutoEQCompare: expected measurement.csv ParametricEQ.txt", code: 1)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let measurement = try AutoEQCurve.csv(data)
        // Published CSVs include the actual default target, including bass boost.
        // Reuse the curve decoder by selecting that column as raw.
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: .newlines)
        let header = lines[0].components(separatedBy: ",")
        func csvCurve(_ column: String) throws -> AutoEQCurve {
            guard let ci = header.firstIndex(of: column),
                let fi = header.firstIndex(of: "frequency")
            else {
                throw AutoEQError.malformedData
            }
            let selected =
                "frequency,raw\n"
                + (try lines.dropFirst().filter { !$0.isEmpty }.map {
                    let cells = $0.components(separatedBy: ",")
                    guard cells.count > max(fi, ci) else { throw AutoEQError.malformedData }
                    return cells[fi] + "," + cells[ci]
                }).joined(separator: "\n")
            return try AutoEQCurve.csv(Data(selected.utf8))
        }
        let target = try csvCurve("target")
        let upstreamResponse = try csvCurve("parametric_eq")
        let upstreamEqualization = try csvCurve("equalization")
        let started = Date()
        let computed = try AutoEQLocalSolver.compute(
            measurement: measurement,
            target: .init(
                label: "Published CSV target", compatible: [], recommended: [], fr: target))
        let solveSeconds = Date().timeIntervalSince(started)
        let local = try AutoEQProfileBuilder.makeProfile(model: "Benchmark", equalized: computed)
        let published = try AutoEQProfileBuilder.makeProfile(
            model: "Benchmark",
            parametricEQText: String(contentsOfFile: args[2], encoding: .utf8))
        func response(_ profile: EQProfile, _ f: Double) -> Double {
            profile.filters.reduce(0) {
                $0 + Biquad(filter: $1, sampleRate: 44_100).magnitudeDB(at: f, sampleRate: 44_100)
            }
        }
        let grid = (0..<1024).map { 20 * pow(1000, Double($0) / 1023) }
        let offset = response(local, 1000) - upstreamResponse.value(at: 1000)
        func rms(_ values: [Double]) -> Double {
            sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
        }
        let errors = grid.map { response(local, $0) - upstreamResponse.value(at: $0) }
        let lowGrid = grid.filter { $0 <= 6000 }
        let importedErrors = lowGrid.map { response(local, $0) - response(published, $0) }
        let importDistortion = lowGrid.map {
            response(published, $0) - upstreamResponse.value(at: $0)
        }
        let equalizationErrors = lowGrid.map {
            response(local, $0) - upstreamEqualization.value(at: $0)
        }
        let lowErrors = zip(grid, errors).filter { $0.0 <= 6000 }.map { $0.1 }
        let metrics: [String: Double] = [
            "rms_20_6000_db": rms(lowErrors),
            "imported_published_rms_20_6000_db": rms(importedErrors),
            "published_import_distortion_rms_20_6000_db": rms(importDistortion),
            "equalization_rms_20_6000_db": rms(equalizationErrors),
            "centered_rms_20_6000_db": rms(lowErrors.map { $0 - offset }),
            "rms_20_20000_db": rms(errors),
            "max_error_db": errors.map(abs).max()!,
            "local_preamp_db": local.preamp,
            "published_preamp_db": published.preamp,
            "combined_peak_db": try AutoEQLocalSolver.peakGain(computed.filters),
            "summed_positive_gain_db": computed.filters.reduce(0) { $0 + max(0, $1.gain) },
            "headroom_db": computed.preamp + (try AutoEQLocalSolver.peakGain(computed.filters)),
            "max_absolute_filter_gain_db": computed.filters.map { abs($0.gain) }.max()!,
            "solver_version": Double(AutoEQLocalSolver.version),
            "solve_seconds": solveSeconds,
        ]
        print(String(decoding: try JSONEncoder().encode(metrics), as: UTF8.self))
    }
}
