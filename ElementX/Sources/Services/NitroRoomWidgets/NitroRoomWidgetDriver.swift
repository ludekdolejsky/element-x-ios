//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

enum NitroRoomWidgetDriverError: Error {
    case invalidRoom
    case invalidURL
    case setupFailed
}

protocol NitroRoomWidgetDriverProtocol: AnyObject {
    var messagePublisher: AnyPublisher<String, Never> { get }
    
    func start(widget: NitroRoomWidget, colorScheme: ColorScheme) async -> Result<URL, NitroRoomWidgetDriverError>
    func send(_ message: String) async
    func stop()
}

final class NitroRoomWidgetDriver: WidgetCapabilitiesProvider, NitroRoomWidgetDriverProtocol {
    private let room: RoomProtocol
    private let messageSubject = PassthroughSubject<String, Never>()
    private var widgetDriver: WidgetDriverAndHandle?
    
    @CancellableTask private var receiveTask: Task<Void, Never>?
    @CancellableTask private var runTask: Task<Void, Never>?
    
    var messagePublisher: AnyPublisher<String, Never> {
        messageSubject.eraseToAnyPublisher()
    }
    
    init(room: RoomProtocol) {
        self.room = room
    }
    
    func start(widget: NitroRoomWidget, colorScheme: ColorScheme) async -> Result<URL, NitroRoomWidgetDriverError> {
        stop()
        
        guard let room = room as? Room else { return .failure(.invalidRoom) }
        
        let settings = WidgetSettings(widgetId: widget.id,
                                      initAfterContentLoad: widget.waitForIframeLoad,
                                      rawUrl: widget.url.absoluteString)
        let urlString: String
        let languageTag = NitroRoomWidgetLocale.languageTag(for: .current)
        do {
            urlString = try await generateWebviewUrl(widgetSettings: settings,
                                                     room: room,
                                                     props: .init(clientId: InfoPlistReader.main.bundleIdentifier,
                                                                  languageTag: languageTag,
                                                                  theme: colorScheme == .dark ? "dark" : "light"))
        } catch {
            MXLog.error("Failed generating Nitro room widget URL: \(error)")
            return .failure(.invalidURL)
        }
        guard !Task.isCancelled else { return .failure(.setupFailed) }
        
        guard let url = URL(string: urlString) else { return .failure(.invalidURL) }
        
        let driver: WidgetDriverAndHandle
        do {
            driver = try makeWidgetDriver(settings: settings)
        } catch {
            MXLog.error("Failed creating Nitro room widget driver: \(error)")
            return .failure(.setupFailed)
        }
        guard !Task.isCancelled else { return .failure(.setupFailed) }
        
        widgetDriver = driver
        receiveTask = Task { [weak self, driver] in
            while !Task.isCancelled, let message = await driver.handle.recv() {
                guard !Task.isCancelled else { return }
                self?.messageSubject.send(message)
            }
        }
        runTask = Task { [weak self, driver] in
            guard let self else { return }
            await driver.driver.run(room: room, capabilitiesProvider: self)
        }
        
        return .success(url)
    }
    
    func send(_ message: String) async {
        guard let widgetDriver else { return }
        _ = await widgetDriver.handle.send(msg: message)
    }
    
    func stop() {
        receiveTask = nil
        runTask = nil
        widgetDriver = nil
    }
    
    nonisolated func acquireCapabilities(capabilities: WidgetCapabilities) -> WidgetCapabilities {
        .init(read: [],
              send: [],
              requiresClient: false,
              updateDelayedEvent: false,
              sendDelayedEvent: false,
              downloadFiles: false,
              rtcTransports: false)
    }
}

enum NitroRoomWidgetLocale {
    static func languageTag(for locale: Locale) -> String {
        locale.identifier(.bcp47)
    }
}
