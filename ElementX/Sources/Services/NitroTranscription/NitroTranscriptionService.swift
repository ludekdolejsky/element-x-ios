//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct NitroTranscriptionService: NitroTranscriptionServiceProtocol {
    private struct Response: Decodable {
        let text: String
    }
    
    private let baseURL: URL
    private let urlSession: URLSession
    
    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }
    
    func transcribeAudio(at fileURL: URL,
                         filename: String,
                         contentType: String,
                         homeserverURL: URL,
                         openIDToken: NitroOpenIDToken) async -> Result<String, NitroTranscriptionError> {
        var request = URLRequest(url: baseURL.appending(path: "api/transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(homeserverURL.absoluteString, forHTTPHeaderField: "X-Homeserver-Url")
        request.setValue(encodedFilename(filename), forHTTPHeaderField: "X-Filename")
        request.setValue(openIDToken.accessToken, forHTTPHeaderField: "X-Openid-Access-Token")
        request.setValue(openIDToken.tokenType, forHTTPHeaderField: "X-Openid-Token-Type")
        request.setValue(openIDToken.matrixServerName, forHTTPHeaderField: "X-Openid-Matrix-Server-Name")
        
        do {
            let (data, response) = try await urlSession.upload(for: request, fromFile: fileURL)
            guard let response = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(response.statusCode) else {
                return .failure(.httpError(statusCode: response.statusCode))
            }
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                return .failure(.invalidResponse)
            }
            
            let transcript = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? .failure(.emptyTranscript) : .success(transcript)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.transport)
        }
    }
    
    private func encodedFilename(_ filename: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        return filename.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? filename
    }
}
