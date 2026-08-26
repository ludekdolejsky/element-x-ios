import ArgumentParser
import Foundation
import Subprocess

struct UploadDSYMs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload-dsyms",
                                                    abstract: "Uploads dSYMs to Sentry using sentry-cli.",
                                                    discussion: "Requires SENTRY_AUTH_TOKEN or a file containing the token.")
    
    @Option(help: "The path to the dSYMs directory or file to upload.")
    var dsymPath: String
    
    @Option(help: "The Sentry organization slug.")
    var orgSlug = "element"
    
    @Option(help: "The Sentry project slug.")
    var projectSlug = "element-x-ios"
    
    @Option(help: "The Sentry server URL.")
    var url = "https://sentry.tools.element.io/"
    
    @Option(help: "A file containing the Sentry authentication token. Defaults to SENTRY_AUTH_TOKEN_FILE; SENTRY_AUTH_TOKEN takes precedence.")
    var authTokenFile: String?

    @Option(help: "The maximum number of upload attempts.")
    var maxRetries = 5
    
    func run() async throws {
        let authToken = try loadAuthToken()
        let arguments: Arguments = [
            "--url", url,
            "dif", "upload",
            "--org", orgSlug,
            "--project", projectSlug,
            "--log-level", "info",
            dsymPath,
        ]
        
        var lastError: Swift.Error?
        
        for attempt in 1 ... maxRetries {
            do {
                logger.info("\n📡 Uploading dSYMs to Sentry (attempt \(attempt)/\(maxRetries))…\n")
                try await CI.run(.name("sentry-cli"), arguments,
                                 environment: .inherit.updating(["SENTRY_AUTH_TOKEN": authToken]))
                logger.info("\n✅ Successfully uploaded dSYMs to Sentry.\n")
                return
            } catch {
                lastError = error
                logger.error("\n❌ Sentry upload attempt \(attempt) failed: \(error.localizedDescription)\n")
            }
        }
        
        if let lastError {
            CI.annotateError(title: "Failed to upload dSYMs to Sentry", "All \(maxRetries) attempts failed: \(lastError.localizedDescription)")
            throw lastError
        }
    }

    private func loadAuthToken() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let authToken = environment["SENTRY_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authToken.isEmpty
        {
            return authToken
        }

        guard let authTokenFile = authTokenFile ?? environment["SENTRY_AUTH_TOKEN_FILE"] else {
            throw ValidationError("Set SENTRY_AUTH_TOKEN or provide an authentication token file.")
        }

        let authToken = try String(contentsOfFile: authTokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authToken.isEmpty else {
            throw ValidationError("The Sentry authentication token file is empty.")
        }
        return authToken
    }
}
