/// # RecommendationEngine — Advisory Recommendations from Predictive + Compressor State
///
/// Consumes PredictiveEngine state (including cached ScanResult with partial flag),
/// CompressorTracker state, and AgentDetector to produce typed recommendations.
///
/// ## Recommendation Types
/// - `exhaustion_imminent`: Time-to-exhaustion prediction below threshold (daemon-only, trend-based)
/// - `compressor_degrading`: Compression ratio trend declining (daemon-only, trend-based)
/// - `compressor_low_ratio`: Single-sample compression ratio below 2.0 (all modes, snapshot)
/// - `high_growth_process`: Process at/near lifetime peak with large footprint
/// - `rosetta_detected`: Rosetta-translated process consuming significant memory
/// - `agent_memory_pressure`: Known AI agent with large memory footprint
/// - `swap_pressure`: Swap usage above threshold

import CacheoutShared
import Foundation

// MARK: - Types

/// The source/mode context for recommendation generation.
enum RecommendationSource: String, Sendable {
    /// One-shot CLI invocation — no trend data available.
    case cli
    /// Daemon with accumulated history.
    case daemon
}

/// Confidence level for a recommendation.
public enum RecommendationConfidence: String, Codable, Sendable {
    case high
    case low
}

/// Category of recommendation.
public enum RecommendationType: String, Codable, Sendable {
    case exhaustionImminent = "exhaustion_imminent"
    case compressorDegrading = "compressor_degrading"
    case compressorLowRatio = "compressor_low_ratio"
    case highGrowthProcess = "high_growth_process"
    case rosettaDetected = "rosetta_detected"
    case agentMemoryPressure = "agent_memory_pressure"
    case swapPressure = "swap_pressure"
}

/// A single typed recommendation with canonical snake_case JSON output.
public struct Recommendation: Codable, Sendable {
    let type: RecommendationType
    let message: String
    let process: String?
    let pid: Int32?
    let impactValue: Double
    let impactUnit: String
    let confidence: RecommendationConfidence
    let source: String

    enum CodingKeys: String, CodingKey {
        case type, message, process, pid
        case impactValue = "impact_value"
        case impactUnit = "impact_unit"
        case confidence, source
    }
}

/// Result of recommendation generation, including scan partiality metadata.
public struct RecommendationResult: Sendable {
    public let recommendations: [Recommendation]
    public let scanPartial: Bool
}

// MARK: - Engine

/// Generates recommendations from PredictiveEngine, CompressorTracker, and process data.
///
/// Thread-safe: all inputs are accessed via actor isolation or value types.
/// The engine itself is stateless — all state lives in its dependencies.
struct RecommendationEngine {

    // MARK: - Configuration

    /// Minimum physical footprint (bytes) for Rosetta recommendation.
    static let rosettaMinFootprint: UInt64 = 200 * 1024 * 1024  // 200 MB

    /// Minimum physical footprint (bytes) for agent memory pressure.
    static let agentMinFootprint: UInt64 = 1024 * 1024 * 1024  // 1 GB

    /// Swap usage percentage threshold for swap_pressure recommendation.
    static let swapPressureThreshold: Double = 50.0  // 50%

    /// Compression ratio threshold for compressor_low_ratio.
    static let lowRatioThreshold: Double = 2.0

    /// Maximum cache age (seconds) for high-confidence process recommendations in daemon mode.
    static let highConfidenceCacheMaxAge: TimeInterval = 30.0

    // MARK: - Generation

    /// Generate recommendations from all available data sources.
    ///
    /// - Parameters:
    ///   - mode: The source context (.cli or .daemon).
    ///   - predictiveEngine: The predictive engine for TTE and high-growth detection.
    ///   - compressorTracker: The compressor tracker for trend data (nil in CLI mode).
    ///   - systemStats: Current system stats for swap/compression snapshot data.
    /// - Returns: A `RecommendationResult` with recommendations and scan partiality.
    static func generateRecommendations(
        mode: RecommendationSource,
        predictiveEngine: PredictiveEngine,
        compressorTracker: CompressorTracker?,
        systemStats: SystemStatsDTO?
    ) async -> RecommendationResult {
        var recommendations: [Recommendation] = []
        let sourceStr = mode.rawValue

        // Get scan result (triggers immediate scan if cache is empty)
        let scanResult = await predictiveEngine.getOrRefreshScanResult()
        let scanPartial = scanResult.partial

        // Determine cache freshness for confidence
        let cacheAge: TimeInterval
        if let lastScanTime = await predictiveEngine.lastScanTime {
            cacheAge = Date().timeIntervalSince(lastScanTime)
        } else {
            cacheAge = .infinity
        }

        /// Compute confidence for process-based recommendations.
        func processConfidence() -> RecommendationConfidence {
            if scanPartial { return .low }
            if mode == .cli { return .low }
            if cacheAge > Self.highConfidenceCacheMaxAge { return .low }
            return .high
        }

        // --- Trend-based recommendations (daemon-only) ---

        if mode == .daemon {
            // exhaustion_imminent
            let sampleCount = await predictiveEngine.sampleCount
            if sampleCount >= PredictiveEngine.minSamplesForPrediction {
                if let tte = await predictiveEngine.predictTimeToExhaustion() {
                    recommendations.append(Recommendation(
                        type: .exhaustionImminent,
                        message: "Memory exhaustion predicted in \(Int(tte)) seconds based on current consumption rate",
                        process: nil,
                        pid: nil,
                        impactValue: tte,
                        impactUnit: "seconds",
                        confidence: .high,
                        source: sourceStr
                    ))
                }
            }

            // compressor_degrading (from CompressorTracker trend)
            if let tracker = compressorTracker {
                let trend = await tracker.compressionRatioTrend()
                if case .declining(let slope) = trend {
                    recommendations.append(Recommendation(
                        type: .compressorDegrading,
                        message: "Compression ratio declining (slope: \(String(format: "%.4f", slope))/sec) — workload becoming less compressible",
                        process: nil,
                        pid: nil,
                        impactValue: abs(slope),
                        impactUnit: "ratio_per_second",
                        confidence: .high,
                        source: sourceStr
                    ))
                }
            }
        }

        // --- Snapshot-based recommendations (all modes) ---

        // compressor_low_ratio
        if let stats = systemStats {
            if stats.compressionRatio > 0 && stats.compressionRatio < Self.lowRatioThreshold {
                let conf: RecommendationConfidence = mode == .daemon ? .high : .low
                recommendations.append(Recommendation(
                    type: .compressorLowRatio,
                    message: "Compression ratio is \(String(format: "%.2f", stats.compressionRatio))x (below \(Self.lowRatioThreshold)x) — compressed memory is inefficient",
                    process: nil,
                    pid: nil,
                    impactValue: stats.compressionRatio,
                    impactUnit: "ratio",
                    confidence: conf,
                    source: sourceStr
                ))
            }
        }

        // high_growth_process
        let highGrowth = await predictiveEngine.detectHighGrowthProcesses(from: scanResult.processes)
        for proc in highGrowth {
            let footprintGB = Double(proc.physFootprint) / (1024 * 1024 * 1024)
            recommendations.append(Recommendation(
                type: .highGrowthProcess,
                message: "\(proc.name) (PID \(proc.pid)) at \(String(format: "%.1f", footprintGB)) GB — near lifetime peak (leak indicator: \(String(format: "%.2f", proc.leakIndicator)))",
                process: proc.name,
                pid: proc.pid,
                impactValue: footprintGB,
                impactUnit: "GB",
                confidence: processConfidence(),
                source: sourceStr
            ))
        }

        // rosetta_detected
        let rosettaProcesses = scanResult.processes.filter {
            $0.isRosetta && $0.physFootprint >= Self.rosettaMinFootprint
        }
        for proc in rosettaProcesses {
            let footprintGB = Double(proc.physFootprint) / (1024 * 1024 * 1024)
            recommendations.append(Recommendation(
                type: .rosettaDetected,
                message: "\(proc.name) (PID \(proc.pid)) running under Rosetta at \(String(format: "%.1f", footprintGB)) GB — native build would use less memory",
                process: proc.name,
                pid: proc.pid,
                impactValue: footprintGB,
                impactUnit: "GB",
                confidence: processConfidence(),
                source: sourceStr
            ))
        }

        // agent_memory_pressure
        let agents = AgentDetector.agentProcesses(from: scanResult.processes)
        for agent in agents where agent.physFootprint >= Self.agentMinFootprint {
            let footprintGB = Double(agent.physFootprint) / (1024 * 1024 * 1024)
            recommendations.append(Recommendation(
                type: .agentMemoryPressure,
                message: "AI agent \(agent.name) (PID \(agent.pid)) using \(String(format: "%.1f", footprintGB)) GB — consider reducing model size or stopping when idle",
                process: agent.name,
                pid: agent.pid,
                impactValue: footprintGB,
                impactUnit: "GB",
                confidence: processConfidence(),
                source: sourceStr
            ))
        }

        // swap_pressure
        if let stats = systemStats, stats.swapTotalBytes > 0 {
            let swapPercent = Double(stats.swapUsedBytes) / Double(stats.swapTotalBytes) * 100.0
            if swapPercent >= Self.swapPressureThreshold {
                let conf: RecommendationConfidence = mode == .daemon ? .high : .low
                recommendations.append(Recommendation(
                    type: .swapPressure,
                    message: "Swap usage at \(String(format: "%.0f", swapPercent))% — system performance may be degraded",
                    process: nil,
                    pid: nil,
                    impactValue: swapPercent,
                    impactUnit: "percent",
                    confidence: conf,
                    source: sourceStr
                ))
            }
        }

        return RecommendationResult(recommendations: recommendations, scanPartial: scanPartial)
    }
}
