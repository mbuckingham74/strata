import Foundation

/// Single native trust anchor for M3 inference identity.
/// Do NOT derive these values from worker events or manifest.
/// Worker `ready` metadata is evidence, not trust.
enum TrustedInferenceIdentity {
    static let model = "roformer-model-bs-roformer-sw-by-jarredou"
    static let checkpointSHA256 = "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"
    static let backend = "mlx"
    static let device = "mps"
}
