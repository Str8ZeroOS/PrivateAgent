import Foundation
import FlashMoEBridge
import ModelHub
import ModelPack

@MainActor
public enum EngineBootstrap {
    public enum Error: LocalizedError {
        case noDownloadedModels
        case modelNotFound(String)
        case loadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noDownloadedModels:
                return "No downloaded models were found. Download a model first."
            case .modelNotFound(let id):
                return "Selected model \(id) was not found on disk."
            case .loadFailed(let message):
                return message
            }
        }
    }

    public static func autoLoadSelectedModel(into engine: PrivateAgentEngine, selectedModelIdKey: String = "selectedModelId") async throws {
        let storage = ModelStorage()
        let models = (try? await storage.listModels()) ?? []

        guard !models.isEmpty else {
            throw Error.noDownloadedModels
        }

        let selectedId = UserDefaults.standard.string(forKey: selectedModelIdKey) ?? ""
        let modelDir: URL
        if !selectedId.isEmpty,
           let selected = models.first(where: { $0.lastPathComponent == selectedId }) {
            modelDir = selected
        } else if let first = models.first {
            modelDir = first
        } else {
            throw Error.noDownloadedModels
        }

        let manifest = try ModelManifest(modelDir: modelDir)
        do {
            try await engine.loadModel(from: manifest)
        } catch {
            throw Error.loadFailed(error.localizedDescription)
        }
    }
}
