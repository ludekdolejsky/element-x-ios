//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct InfoPlistReader {
    private enum Keys {
        static let appGroupIdentifier = "appGroupIdentifier"
        static let baseBundleIdentifier = "baseBundleIdentifier"
        static let keychainAccessGroupIdentifier = "keychainAccessGroupIdentifier"
        static let bundleShortVersion = "CFBundleShortVersionString"
        static let bundleDisplayName = "CFBundleDisplayName"
        static let productionAppName = "productionAppName"
        static let isNightlyBuild = "isNightlyBuild"
        static let isNitroBuild = "isNitroBuild"
        static let notificationFilteringEnabled = "notificationFilteringEnabled"
        static let nitroPushGatewayBaseURL = "nitroPushGatewayBaseURL"
        static let nitroCatchUpBaseURL = "nitroCatchUpBaseURL"
        static let nitroReminderBaseURL = "nitroReminderBaseURL"
        static let nitroTranscriptionBaseURL = "nitroTranscriptionBaseURL"
        static let utExportedTypeDeclarationsKey = "UTExportedTypeDeclarations"
        static let utTypeIdentifierKey = "UTTypeIdentifier"
        static let utDescriptionKey = "UTTypeDescription"
        
        static let bundleURLTypes = "CFBundleURLTypes"
        static let bundleURLName = "CFBundleURLName"
        static let bundleURLSchemes = "CFBundleURLSchemes"
        
        static let classicAppGroupIdentifier = "classicAppGroupIdentifier"
        static let classicAppKeychainServiceIdentifier = "classicAppKeychainServiceIdentifier"
        static let classicAppKeychainAccessGroupIdentifier = "classicAppKeychainAccessGroupIdentifier"
        static let classicAppDeepLinkURL = "classicAppDeepLinkURL"
    }
    
    private enum Values {
        static let mentionPills = "Mention Pills"
    }
    
    /// Info.plist reader on the bundle object that contains the current executable.
    static let main = InfoPlistReader(bundle: .main)
    
    /// Info.plist reader on the bundle object that contains the main app executable.
    static let app = InfoPlistReader(bundle: .app)
    
    private let bundle: Bundle
    
    /// Initializer
    /// - Parameter bundle: bundle to read values from
    init(bundle: Bundle) {
        self.bundle = bundle
    }
    
    /// App group identifier set in Info.plist of the target
    var appGroupIdentifier: String {
        infoPlistValue(forKey: Keys.appGroupIdentifier)
    }
    
    /// Base bundle identifier set in Info.plist of the target
    var baseBundleIdentifier: String {
        infoPlistValue(forKey: Keys.baseBundleIdentifier)
    }
    
    /// Keychain access group identifier set in Info.plist of the target
    var keychainAccessGroupIdentifier: String {
        infoPlistValue(forKey: Keys.keychainAccessGroupIdentifier)
    }
    
    /// Bundle executable of the target
    var bundleExecutable: String {
        infoPlistValue(forKey: kCFBundleExecutableKey as String)
    }
    
    /// Bundle identifier of the target
    var bundleIdentifier: String {
        infoPlistValue(forKey: kCFBundleIdentifierKey as String)
    }
    
    /// Bundle short version string of the target
    var bundleShortVersionString: String {
        infoPlistValue(forKey: Keys.bundleShortVersion)
    }
    
    /// Bundle version of the target
    var bundleVersion: String {
        infoPlistValue(forKey: kCFBundleVersionKey as String)
    }
    
    /// Bundle display name of the target
    var bundleDisplayName: String {
        infoPlistValue(forKey: Keys.bundleDisplayName)
    }
    
    /// The name of the non-X app when it becomes production ready.
    var productionAppName: String {
        infoPlistValue(forKey: Keys.productionAppName)
    }
    
    // periphery:ignore - only used in release builds
    /// Whether or not the build is from the Nightly stream.
    var isNightlyBuild: Bool {
        infoPlistValue(forKey: Keys.isNightlyBuild)
    }
    
    /// Whether or not the build uses the Nitro app variant.
    var isNitroBuild: Bool {
        optionalBoolInfoPlistValue(forKey: Keys.isNitroBuild) ?? false
    }
    
    /// Whether the target is provisioned with Apple's notification filtering entitlement.
    var notificationFilteringEnabled: Bool {
        optionalBoolInfoPlistValue(forKey: Keys.notificationFilteringEnabled) ?? true
    }
    
    var nitroPushGatewayBaseURL: URL? {
        urlInfoPlistValue(forKey: Keys.nitroPushGatewayBaseURL)
    }
    
    var nitroCatchUpBaseURL: URL? {
        urlInfoPlistValue(forKey: Keys.nitroCatchUpBaseURL)
    }
    
    var nitroReminderBaseURL: URL? {
        urlInfoPlistValue(forKey: Keys.nitroReminderBaseURL)
    }
    
    var nitroTranscriptionBaseURL: URL? {
        urlInfoPlistValue(forKey: Keys.nitroTranscriptionBaseURL)
    }
    
    // MARK: - Custom App Scheme
    
    var appScheme: String {
        customSchemeForName("Application")
    }
    
    // MARK: - Mention Pills
    
    /// Mention Pills UTType
    var pillsUTType: String {
        let exportedTypes: [[String: Any]] = infoPlistValue(forKey: Keys.utExportedTypeDeclarationsKey)
        guard let mentionPills = exportedTypes.first(where: { $0[Keys.utDescriptionKey] as? String == Values.mentionPills }),
              let utType = mentionPills[Keys.utTypeIdentifierKey] as? String else {
            fatalError("Add properly \(Values.mentionPills) exported type into your target's Info.plist")
        }
        
        // The pills type is formed from the baseBundleIdentifier, however weirdly, if a fork sets that with a value
        // that includes one or more uppercase characters, pill rendering breaks. If we lowercase the type identifier
        // the bug is fixed, even though the value used in the fork's Info.plist no longer matches the value returned.
        // Maybe in the future the fork should set their own PILLS_UT_TYPE_IDENTIFIER, but for now this works 🤷‍♂️🤷‍♂️🤷‍♂️
        return utType.lowercased()
    }
    
    // MARK: - Sign in with Classic app
    
    var classicAppGroupIdentifier: String? {
        nonEmptyStringInfoPlistValue(forKey: Keys.classicAppGroupIdentifier)
    }
    
    var classicAppKeychainServiceIdentifier: String? {
        nonEmptyStringInfoPlistValue(forKey: Keys.classicAppKeychainServiceIdentifier)
    }
    
    var classicAppKeychainAccessGroupIdentifier: String? {
        nonEmptyStringInfoPlistValue(forKey: Keys.classicAppKeychainAccessGroupIdentifier)
    }
    
    var classicAppDeepLinkURL: URL? {
        urlInfoPlistValue(forKey: Keys.classicAppDeepLinkURL)
    }
    
    // MARK: - Private
    
    @_disfavoredOverload // Make sure optional types default to the optional version below.
    private func infoPlistValue<T>(forKey key: String) -> T {
        guard let result = bundle.object(forInfoDictionaryKey: key) as? T else {
            fatalError("Add \(key) into your target's Info.plist")
        }
        return result
    }
    
    private func infoPlistValue<T>(forKey key: String) -> T? {
        bundle.object(forInfoDictionaryKey: key) as? T
    }
    
    private func infoPlistValue(forKey key: String) -> Bool {
        // Build setting values are stored as strings ("YES"/"NO")…
        (infoPlistValue(forKey: key) as NSString).boolValue
    }
    
    private func optionalBoolInfoPlistValue(forKey key: String) -> Bool? {
        (bundle.object(forInfoDictionaryKey: key) as? NSString)?.boolValue
    }
    
    private func nonEmptyStringInfoPlistValue(forKey key: String) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
    
    private func urlInfoPlistValue(forKey key: String) -> URL? {
        nonEmptyStringInfoPlistValue(forKey: key).flatMap { URL(string: $0) }
    }
    
    private func customSchemeForName(_ name: String) -> String {
        let urlTypes: [[String: Any]] = infoPlistValue(forKey: Keys.bundleURLTypes)
        
        guard let urlType = urlTypes.first(where: { $0[Keys.bundleURLName] as? String == name }),
              let urlSchemes = urlType[Keys.bundleURLSchemes] as? [String],
              let scheme = urlSchemes.first else {
            fatalError("Invalid custom application scheme configuration")
        }
        
        return scheme
    }
}
