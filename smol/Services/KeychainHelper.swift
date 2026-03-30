import Foundation
import Security

/// Keychain wrapper for storing API keys and secrets securely
enum KeychainHelper {

    private static let service = "com.whitepaper.smol"

    // MARK: - Keys

    static let apiKeyAccount = "ai_api_key"
    static let providerURLAccount = "ai_provider_url"
    static let modelIDAccount = "ai_model_id"

    // MARK: - CRUD

    /// Save a string value to the Keychain
    @discardableResult
    static func save(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Load a string value from the Keychain
    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from the Keychain
    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Convenience

    /// Check if an API key is stored
    static var hasAPIKey: Bool {
        load(account: apiKeyAccount) != nil
    }

    /// Get the stored API key
    static var apiKey: String? {
        load(account: apiKeyAccount)
    }

    /// Get the stored provider base URL (default: OpenRouter)
    static var providerBaseURL: String {
        load(account: providerURLAccount) ?? AIProvider.openRouter.baseURL
    }

    /// Get the stored model ID
    static var modelID: String {
        load(account: modelIDAccount) ?? "google/gemini-2.5-flash"
    }
}

// MARK: - AI Providers

/// Known OpenAI-compatible API providers
enum AIProvider: String, CaseIterable, Identifiable {
    case openRouter = "OpenRouter"
    case togetherAI = "Together AI"
    case groq = "Groq"
    case openAI = "OpenAI"
    case custom = "Custom"

    var id: String { rawValue }

    var baseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .togetherAI: return "https://api.together.xyz/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: return "google/gemini-2.5-flash"
        case .togetherAI: return "meta-llama/Llama-4-Maverick-17B-128E-Instruct-Turbo"
        case .groq: return "llama-4-scout-17b-16e-instruct"
        case .openAI: return "gpt-4o-mini"
        case .custom: return ""
        }
    }

    var icon: String {
        switch self {
        case .openRouter: return "network"
        case .togetherAI: return "person.3"
        case .groq: return "bolt"
        case .openAI: return "brain.head.profile"
        case .custom: return "slider.horizontal.3"
        }
    }
}
