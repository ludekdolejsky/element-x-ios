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
    func restart() -> Result<Void, NitroRoomWidgetDriverError>
    func send(_ message: String) async
    func stop()
}

final class NitroRoomWidgetDriver: WidgetCapabilitiesProvider, NitroRoomWidgetDriverProtocol {
    private let room: RoomProtocol
    private let messageSubject = PassthroughSubject<String, Never>()
    private var sdkRoom: Room?
    private var settings: WidgetSettings?
    private var widgetDriver: WidgetDriverAndHandle?
    private var driverGenerationID: UUID?
    
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
        
        guard let sdkRoom = room as? Room else { return .failure(.invalidRoom) }
        
        let settings = Self.settings(for: widget)
        let urlString: String
        let languageTag = NitroRoomWidgetLocale.languageTag(for: .current)
        do {
            urlString = try await generateWebviewUrl(widgetSettings: settings,
                                                     room: sdkRoom,
                                                     props: .init(clientId: InfoPlistReader.main.bundleIdentifier,
                                                                  languageTag: languageTag,
                                                                  theme: colorScheme == .dark ? "dark" : "light"))
        } catch {
            MXLog.error("Failed generating Nitro room widget URL: \(error)")
            return .failure(.invalidURL)
        }
        guard !Task.isCancelled else { return .failure(.setupFailed) }
        
        guard let url = URL(string: urlString) else { return .failure(.invalidURL) }
        
        self.sdkRoom = sdkRoom
        self.settings = settings
        guard startDriver(settings: settings, room: sdkRoom) else {
            self.sdkRoom = nil
            self.settings = nil
            return .failure(.setupFailed)
        }

        return .success(url)
    }

    func restart() -> Result<Void, NitroRoomWidgetDriverError> {
        guard let settings, let sdkRoom else { return .failure(.setupFailed) }
        stopDriver()
        return startDriver(settings: settings, room: sdkRoom) ? .success(()) : .failure(.setupFailed)
    }

    func send(_ message: String) async {
        guard let widgetDriver else { return }
        _ = await widgetDriver.handle.send(msg: message)
    }

    func stop() {
        sdkRoom = nil
        settings = nil
        stopDriver()
    }

    private func startDriver(settings: WidgetSettings, room: Room) -> Bool {
        let driver: WidgetDriverAndHandle
        do {
            driver = try makeWidgetDriver(settings: settings)
        } catch {
            MXLog.error("Failed creating Nitro room widget driver: \(error)")
            return false
        }

        let generationID = UUID()
        driverGenerationID = generationID
        widgetDriver = driver
        receiveTask = Task { [weak self, driver, generationID] in
            while !Task.isCancelled, let message = await driver.handle.recv() {
                guard !Task.isCancelled, self?.driverGenerationID == generationID else { return }
                self?.messageSubject.send(message)
            }
        }
        runTask = Task { [weak self, driver] in
            guard let self else { return }
            await driver.driver.run(room: room, capabilitiesProvider: self)
        }
        return true
    }

    private func stopDriver() {
        driverGenerationID = nil
        widgetDriver?.driver.stop()
        receiveTask = nil
        runTask = nil
        widgetDriver = nil
    }
    
    static func settings(for widget: NitroRoomWidget) -> WidgetSettings {
        WidgetSettings(widgetId: widget.id,
                       initAfterContentLoad: !widget.waitForIframeLoad,
                       rawUrl: widget.url.absoluteString)
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
