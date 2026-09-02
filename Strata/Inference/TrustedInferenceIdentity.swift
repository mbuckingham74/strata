import Foundation

/// Single native trust anchor for M3 inference identity.
/// Do NOT derive these values from worker events or manifest.
/// Worker `ready` metadata is evidence, not trust.
enum TrustedInferenceIdentity {
    static let model = "roformer-model-bs-roformer-sw-by-jarredou"
    static let checkpointSHA256 = "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"
    static let backend = "mlx"
    static let device = "mps"

    // Canonical model files, mirroring InferenceWorker/src/demux_worker/constants.py.
    static let checkpointFilename = "BS-Rofo-SW-Fixed.ckpt"
    static let checkpointBytes: Int64 = 699_412_152
    static let configFilename = "BS-Rofo-SW-Fixed.yaml"
    static let configBytes: Int64 = 4613
    static let configSHA256 = "f9fada9f94e5ba2d2e4600196299459294bc5f532b314c209cc156ac63e4329b"

    /// Canonical cache root: ~/Library/Caches/Demux/Models (mirrors MODEL_CACHE_ROOT).
    static var modelsRootDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Demux", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Canonical model dir: <modelsRoot>/<model> (mirrors MODEL_CACHE_DIR).
    static func modelDirectory(modelsRoot: URL? = nil) -> URL {
        (modelsRoot ?? modelsRootDirectory).appendingPathComponent(model, isDirectory: true)
    }

    /// Canonical checkpoint path (mirrors CHECKPOINT_PATH).
    static func checkpointURL(modelsRoot: URL? = nil) -> URL {
        modelDirectory(modelsRoot: modelsRoot).appendingPathComponent(checkpointFilename)
    }

    /// Canonical config path (mirrors CONFIG_PATH).
    static func configURL(modelsRoot: URL? = nil) -> URL {
        modelDirectory(modelsRoot: modelsRoot).appendingPathComponent(configFilename)
    }
}
