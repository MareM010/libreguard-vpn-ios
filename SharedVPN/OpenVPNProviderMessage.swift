import Foundation

enum OpenVPNProviderMessageType: String, Codable, Equatable {
    case status
    case diagnostics
}

struct OpenVPNProviderRequest: Codable, Equatable {
    let type: OpenVPNProviderMessageType
}

struct OpenVPNProviderResponse: Codable, Equatable {
    let type: OpenVPNProviderMessageType
    let success: Bool
    let diagnostics: OpenVPNRuntimeDiagnostics
    let error: String?
}

enum OpenVPNProviderMessageError: LocalizedError {
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "The OpenVPN provider message is invalid."
        }
    }
}

enum OpenVPNProviderMessageCodec {
    static func decodeRequest(from data: Data) throws -> OpenVPNProviderRequest {
        try decoder.decode(OpenVPNProviderRequest.self, from: data)
    }

    static func decodeResponse(from data: Data) throws -> OpenVPNProviderResponse {
        try decoder.decode(OpenVPNProviderResponse.self, from: data)
    }

    static func encodeResponse(
        type: OpenVPNProviderMessageType,
        diagnostics: OpenVPNRuntimeDiagnostics,
        error: String? = nil
    ) throws -> Data {
        let response = OpenVPNProviderResponse(
            type: type,
            success: error == nil,
            diagnostics: diagnostics,
            error: error
        )
        return try encoder.encode(response)
    }

    static func encodeInvalidMessageResponse(
        diagnostics: OpenVPNRuntimeDiagnostics
    ) throws -> Data {
        try encodeResponse(
            type: .diagnostics,
            diagnostics: diagnostics,
            error: OpenVPNProviderMessageError.invalidMessage.localizedDescription
        )
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
