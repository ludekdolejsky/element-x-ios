//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing
import UIKit
import UniformTypeIdentifiers
import WysiwygComposer

@MainActor
final class ComposerToolbarViewModelTests {
    private var wysiwygViewModel: WysiwygComposerViewModel!
    private var viewModel: ComposerToolbarViewModel!
    private var completionSuggestionServiceMock: CompletionSuggestionServiceMock!
    private var draftServiceMock: ComposerDraftServiceMock!
    private var appSettings: AppSettings!
    
    init() {
        setUpViewModel()
    }
    
    @Test
    func composerFocus() {
        viewModel.process(timelineAction: .setMode(mode: .edit(originalEventOrTransactionID: .eventID("mock"), type: .default)))
        #expect(viewModel.state.bindings.composerFocused)
        viewModel.process(timelineAction: .removeFocus)
        #expect(!viewModel.state.bindings.composerFocused)
    }
    
    @Test
    func composerMode() {
        let mode: ComposerMode = .edit(originalEventOrTransactionID: .eventID("mock"), type: .default)
        viewModel.process(timelineAction: .setMode(mode: mode))
        #expect(viewModel.state.composerMode == mode)
        viewModel.process(timelineAction: .clear)
        #expect(viewModel.state.composerMode == .default)
    }
    
    @Test
    func composerModeIsPublished() async throws {
        let mode: ComposerMode = .edit(originalEventOrTransactionID: .eventID("mock"), type: .default)
        let deferred = deferFulfillment(viewModel.context.$viewState.map(\.composerMode).removeDuplicates().dropFirst()) { $0 == mode }
        viewModel.process(timelineAction: .setMode(mode: mode))
        try await deferred.fulfill()
    }
    
    @Test
    func handleKeyCommand() {
        #expect(viewModel.context.viewState.keyCommands.count == 1)
    }
    
    @Test
    func composerFocusAfterEnablingRTE() {
        viewModel.process(viewAction: .enableTextFormatting)
        #expect(viewModel.state.bindings.composerFocused)
    }
    
    @Test
    func formattingToolbarIsCollapsedByDefault() {
        #expect(!viewModel.state.bindings.composerFormattingEnabled)
    }
    
    @Test
    func enablingFormattingPreservesComposerAndSelection() {
        viewModel.process(viewAction: .composerAppeared)
        wysiwygViewModel.setMarkdownContent("Keep this text")
        let selection = NSRange(location: 5, length: 4)
        wysiwygViewModel.textView.selectedRange = selection
        
        viewModel.process(viewAction: .enableTextFormatting)
        
        #expect(wysiwygViewModel.content.markdown == "Keep this text")
        #expect(wysiwygViewModel.textView.selectedRange == selection)
    }
    
    @Test
    func rteEnabledAfterSendingMessage() {
        viewModel.process(viewAction: .enableTextFormatting)
        #expect(viewModel.state.bindings.composerFocused)
        viewModel.state.composerEmpty = false
        viewModel.process(viewAction: .sendMessage)
        #expect(viewModel.state.bindings.composerFormattingEnabled)
    }
    
    @Test
    func alertIsShownAfterLinkAction() {
        #expect(viewModel.state.bindings.alertInfo == nil)
        viewModel.process(viewAction: .enableTextFormatting)
        viewModel.process(viewAction: .composerAction(action: .link))
        #expect(viewModel.state.bindings.alertInfo != nil)
    }
    
    @Test
    func suggestions() {
        let suggestions: [SuggestionItem] = [.init(suggestionType: .user(.init(id: "@user_mention_1:matrix.org", displayName: "User 1", avatarURL: nil)), range: .init(), rawSuggestionText: ""),
                                             .init(suggestionType: .user(.init(id: "@user_mention_2:matrix.org", displayName: "User 2", avatarURL: nil)), range: .init(), rawSuggestionText: "")]
        let mockCompletionSuggestionService = CompletionSuggestionServiceMock(configuration: .init(suggestions: suggestions))
        
        let appSettings = AppSettings.volatile()
        
        viewModel = ComposerToolbarViewModel(roomProxy: JoinedRoomProxyMock(.init()),
                                             wysiwygViewModel: wysiwygViewModel,
                                             completionSuggestionService: mockCompletionSuggestionService,
                                             mediaProvider: MediaProviderMock(.init()),
                                             mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                             appSettings: appSettings,
                                             analyticsService: AnalyticsServiceMock(.init()),
                                             composerDraftService: draftServiceMock)
        
        #expect(viewModel.state.suggestions == suggestions)
    }
    
    @Test
    func suggestionTrigger() async throws {
        let deferred = deferFulfillment(wysiwygViewModel.$attributedContent) { $0.plainText == "Say :meats" }
        wysiwygViewModel.setMarkdownContent("@user-test")
        wysiwygViewModel.setMarkdownContent("#room-alias-test")
        wysiwygViewModel.setMarkdownContent("Say :meats")
        try await deferred.fulfill()
        
        // The first one is nil because when initialised the view model is empty
        #expect(completionSuggestionServiceMock.setSuggestionTriggerReceivedInvocations == [nil,
                                                                                            .init(type: .user, text: "user-test", range: .init(location: 0, length: 10)),
                                                                                            .init(type: .room, text: "room-alias-test",
                                                                                                  range: .init(location: 0, length: 16)),
                                                                                            .init(type: .emoji, text: "meats", range: .init(location: 4, length: 6))])
    }
    
    @Test
    func selectedUserSuggestion() {
        let suggestion = SuggestionItem(suggestionType: .user(.init(id: "@test:matrix.org", displayName: "Test", avatarURL: nil)), range: .init(), rawSuggestionText: "")
        viewModel.context.send(viewAction: .selectedSuggestion(suggestion))
        
        // The display name can be used for HTML injection in the rich text editor and it's useless anyway as the clients don't use it when resolving display names
        #expect(wysiwygViewModel.content.html == "<a href=\"https://matrix.to/#/@test:matrix.org\">@test:matrix.org</a> ")
    }
    
    @Test
    func selectedRoomSuggestion() {
        let suggestion = SuggestionItem(suggestionType: .room(.init(id: "!room:matrix.org",
                                                                    canonicalAlias: "#room-alias:matrix.org",
                                                                    name: "Room",
                                                                    avatar: .room(id: "!room:matrix.org",
                                                                                  name: "Room",
                                                                                  avatarURL: nil))),
                                        range: .init(), rawSuggestionText: "")
        viewModel.context.send(viewAction: .selectedSuggestion(suggestion))
        
        // The display name can be used for HTML injection in the rich text editor and it's useless anyway as the clients don't use it when resolving display names
        
        #expect(wysiwygViewModel.content.html == "<a href=\"https://matrix.to/#/%23room-alias:matrix.org\">#room-alias:matrix.org</a> ")
    }
    
    @Test
    func allUsersSuggestion() throws {
        let suggestion = SuggestionItem(suggestionType: .allUsers(.room(id: "", name: nil, avatarURL: nil)), range: .init(), rawSuggestionText: "")
        viewModel.context.send(viewAction: .selectedSuggestion(suggestion))
        
        var string = "@room"
        try string.unicodeScalars.append(#require(UnicodeScalar(String.nbsp)))
        #expect(wysiwygViewModel.content.html == string)
    }
    
    @Test
    func userMentionPillInRTE() async {
        viewModel.context.send(viewAction: .composerAppeared)
        await Task.yield()
        let userID = "@test:matrix.org"
        let suggestion = SuggestionItem(suggestionType: .user(.init(id: userID, displayName: "Test", avatarURL: nil)), range: .init(), rawSuggestionText: "")
        viewModel.context.send(viewAction: .selectedSuggestion(suggestion))
        
        let attachment = wysiwygViewModel.textView.attributedText.attribute(.attachment, at: 0, effectiveRange: nil) as? PillTextAttachment
        #expect(attachment?.pillData?.type == .user(userID: userID))
    }
    
    @Test
    func roomMentionPillInRTE() async {
        viewModel.context.send(viewAction: .composerAppeared)
        await Task.yield()
        let roomAlias = "#test:matrix.org"
        let suggestion = SuggestionItem(suggestionType: .room(.init(id: "room-id", canonicalAlias: roomAlias, name: "Room", avatar: .room(id: "room-id", name: "Room", avatarURL: nil))), range: .init(), rawSuggestionText: "")
        viewModel.context.send(viewAction: .selectedSuggestion(suggestion))
        
        let attachment = wysiwygViewModel.textView.attributedText.attribute(.attachment, at: 0, effectiveRange: nil) as? PillTextAttachment
        #expect(attachment?.pillData?.type == .roomAlias(roomAlias))
    }
    
    @Test
    func allUsersMentionPillInRTE() async {
        viewModel.context.send(viewAction: .composerAppeared)
        await Task.yield()
        let suggestion = SuggestionItem(suggestionType: .allUsers(.room(id: "", name: nil, avatarURL: nil)), range: .init(), rawSuggestionText: "")
        viewModel.context.send(viewAction: .selectedSuggestion(suggestion))
        
        let attachment = wysiwygViewModel.textView.attributedText.attribute(.attachment, at: 0, effectiveRange: nil) as? PillTextAttachment
        #expect(attachment?.pillData?.type == .allUsers)
    }
    
    @Test
    func intentionalMentions() async throws {
        wysiwygViewModel.setHtmlContent("""
        <p>Hello @room \
        and especially hello to <a href=\"https://matrix.to/#/@test:matrix.org\">Test</a></p>
        """)
        
        let deferred = deferFulfillment(viewModel.actions) { action in
            switch action {
            case let .sendMessage(_, _, _, intentionalMentions):
                return intentionalMentions == IntentionalMentions(userIDs: ["@test:matrix.org"], atRoom: true)
            default:
                return false
            }
        }
        viewModel.context.send(viewAction: .sendMessage)
        
        try await deferred.fulfill()
    }
    
    @Test
    func sendCustomEmoji() async throws {
        let customEmoji = try CustomEmoji(shortcode: "party\"",
                                          body: "A&B \"<>\"",
                                          imageURL: #require(URL(string: "mxc://example.org/party")))
        let emoji = EmojiPickerEmojiViewData(id: "party",
                                             value: ":party:",
                                             label: "Party",
                                             customEmoji: customEmoji)
        let expectedHTML = #"<img data-mx-emoticon src="mxc://example.org/party" alt="A&amp;B &quot;&lt;&gt;&quot;" title="party&quot;" height="32" />"#
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(plain, html, mode, intentionalMentions) = action else {
                return false
            }
            return plain == ":party\":" &&
                html == expectedHTML &&
                mode == .default &&
                intentionalMentions == .empty
        }
        
        viewModel.sendEmoji(emoji)
        
        try await deferred.fulfill()
    }
    
    @Test
    func selectedCustomEmojiSuggestionUsesShortcodeWithCollapsedToolbar() throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let emojiItem = EmojiItem(label: "Meatspin",
                                  unicode: ":meatspin:",
                                  keywords: [],
                                  shortcodes: ["meatspin"],
                                  customEmoji: customEmoji)
        let suggestion = SuggestionItem(suggestionType: .emoji(emojiItem),
                                        range: .init(location: 0, length: 6),
                                        rawSuggestionText: "meats")
        wysiwygViewModel.setMarkdownContent(":meats")
        
        viewModel.context.send(viewAction: .selectedSuggestion(suggestion))
        
        #expect(wysiwygViewModel.content.markdown == ":meatspin:")
        #expect(wysiwygViewModel.textView.selectedRange == .init(location: 10, length: 0))
    }
    
    @Test
    func selectedCustomEmojiSuggestionUsesShortcodeInRichComposer() throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let emojiItem = EmojiItem(label: "Meatspin",
                                  unicode: ":meatspin:",
                                  keywords: [],
                                  shortcodes: ["meatspin"],
                                  customEmoji: customEmoji)
        let suggestion = SuggestionItem(suggestionType: .emoji(emojiItem),
                                        range: .init(location: 4, length: 4),
                                        rawSuggestionText: "mea")
        wysiwygViewModel.setMarkdownContent("Say :mea")
        wysiwygViewModel.setMarkdownContent("Say :meats")
        
        viewModel.context.send(viewAction: .selectedSuggestion(suggestion))
        
        #expect(wysiwygViewModel.content.markdown == "Say :meatspin:")
        #expect(wysiwygViewModel.textView.selectedRange == .init(location: 14, length: 0))
    }
    
    @Test
    func selectedSystemEmojiSuggestionUsesUnicodeWithCollapsedToolbar() {
        let emojiItem = EmojiItem(label: "Grinning face",
                                  unicode: "😀",
                                  keywords: ["smile"],
                                  shortcodes: ["grinning"])
        let suggestion = SuggestionItem(suggestionType: .emoji(emojiItem),
                                        range: .init(location: 4, length: 4),
                                        rawSuggestionText: "gri")
        wysiwygViewModel.setMarkdownContent("Say :gri now")
        
        viewModel.context.send(viewAction: .selectedSuggestion(suggestion))
        
        #expect(wysiwygViewModel.content.markdown == "Say 😀 now")
        #expect(wysiwygViewModel.textView.selectedRange == .init(location: 6, length: 0))
    }
    
    @Test
    func customEmojiFormatterOnlyTransformsEligibleTextNodes() throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let source = #"<p>:meatspin: <code>:meatspin:</code> <a href=":meatspin:">:meatspin:</a> :unknown:</p>"#
        let image = #"<img data-mx-emoticon src="mxc://example.org/meatspin" alt="Meatspin" title="meatspin" height="32" />"#
        
        let result = CustomEmojiMessageContent.renderingCustomEmojis(in: source, customEmojis: [customEmoji])
        
        #expect(result == "<p>\(image) <code>:meatspin:</code> <a href=\":meatspin:\">:meatspin:</a> :unknown:</p>")
    }
    
    @Test
    func customEmojiFormatterUsesFirstDuplicateShortcode() throws {
        let currentEmoji = try CustomEmoji(shortcode: "shared",
                                           body: "Current",
                                           imageURL: #require(URL(string: "mxc://example.org/current")))
        let globalEmoji = try CustomEmoji(shortcode: "shared",
                                          body: "Global",
                                          imageURL: #require(URL(string: "mxc://example.org/global")))
        
        let result = CustomEmojiMessageContent.renderingCustomEmojis(in: ":shared:",
                                                                     customEmojis: [currentEmoji, globalEmoji])
        
        #expect(result?.contains(#"src="mxc://example.org/current""#) == true)
        #expect(result?.contains("mxc://example.org/global") == false)
    }
    
    @Test
    func customEmojiFormatterRestoresShortcodeForEditing() {
        let source = #"<strong>Hello</strong> <img data-mx-emoticon src="mxc://example.org/meatspin" alt="Meatspin" title="meatspin" height="32" />"#
        
        #expect(CustomEmojiMessageContent.restoringShortcodes(in: source) == "<strong>Hello</strong> :meatspin:")
    }
    
    @Test
    func customEmojiFormatterRestoresExactMetadataForRoundTrip() throws {
        let source = #"<img data-mx-emoticon src="mxc://original.example/asset" alt="Original body" title="shared" height="32" />"#
        
        let restoration = CustomEmojiMessageContent.restoringCustomEmojis(in: source)
        let emoji = try #require(restoration.customEmojis.first)
        
        #expect(restoration.html == ":shared:")
        #expect(emoji.shortcode == "shared")
        #expect(emoji.body == "Original body")
        #expect(emoji.imageURL.absoluteString == "mxc://original.example/asset")
    }
    
    @Test
    func customEmojiFormatterRestoresSanitizedEmojiUsingPlainFallback() throws {
        let source = #"Look <img src="mxc://original.example/asset" alt="Original body" title="shared" height="32" /> now"#
        
        let restoration = CustomEmojiMessageContent.restoringCustomEmojis(in: source, fallbackBody: "Look :shared: now")
        let emoji = try #require(restoration.customEmojis.first)
        
        #expect(restoration.html == "Look :shared: now")
        #expect(emoji.shortcode == "shared")
        #expect(emoji.body == "Original body")
        #expect(emoji.imageURL.absoluteString == "mxc://original.example/asset")
    }
    
    @Test
    func customEmojiFormatterRequiresExactEmoticonAttribute() {
        let source = #"<img src="mxc://example.org/plain" alt="contains data-mx-emoticon text" title="plain" />"#
        
        #expect(CustomEmojiMessageContent.restoringShortcodes(in: source) == source)
    }
    
    @Test
    func sendCustomEmojiShortcodePreservesPlainFallback() async throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let emojiItem = EmojiItem(label: "Meatspin",
                                  unicode: ":meatspin:",
                                  keywords: [],
                                  shortcodes: ["meatspin"],
                                  customEmoji: customEmoji)
        setUpViewModel(emojiProvider: ComposerTestEmojiProvider(categories: [.init(id: "custom", emojis: [emojiItem])]))
        wysiwygViewModel.setMarkdownContent("Hello :meatspin:")
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(plain, html, _, _) = action else { return false }
            return plain == "Hello :meatspin:"
                && html?.contains("data-mx-emoticon") == true
                && html?.contains("title=\"meatspin\"") == true
        }
        
        viewModel.context.send(viewAction: .sendMessage)
        
        try await deferred.fulfill()
    }
    
    @Test
    func sendCustomEmojiWithCollapsedToolbarPreservesLiteralText() async throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let emojiItem = EmojiItem(label: "Meatspin",
                                  unicode: ":meatspin:",
                                  keywords: [],
                                  shortcodes: ["meatspin"],
                                  customEmoji: customEmoji)
        setUpViewModel(emojiProvider: ComposerTestEmojiProvider(categories: [.init(id: "custom", emojis: [emojiItem])]))
        let source = "**literal** <tag> :meatspin:\n_next_"
        wysiwygViewModel.setHtmlContent("**literal** &lt;tag&gt; :meatspin:<br />_next_")
        let image = #"<img data-mx-emoticon src="mxc://example.org/meatspin" alt="Meatspin" title="meatspin" height="32" />"#
        let expectedHTML = "**literal** &lt;tag&gt; \(image)<br />_next_"
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(plain, html, _, _) = action else { return false }
            return plain == source && html == expectedHTML
        }
        
        viewModel.context.send(viewAction: .sendMessage)
        
        try await deferred.fulfill()
    }
    
    @Test
    func sendCustomEmojiShortcodeFromRichComposerPreservesFallbackAndFormatting() async throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let emojiItem = EmojiItem(label: "Meatspin",
                                  unicode: ":meatspin:",
                                  keywords: [],
                                  shortcodes: ["meatspin"],
                                  customEmoji: customEmoji)
        setUpViewModel(emojiProvider: ComposerTestEmojiProvider(categories: [.init(id: "custom", emojis: [emojiItem])]))
        wysiwygViewModel.setMarkdownContent("**Hello** :meatspin:")
        let expectedPlain = wysiwygViewModel.content.markdown
        #expect(expectedPlain.contains(":meatspin:"))
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(plain, html, _, _) = action else { return false }
            return plain == expectedPlain
                && html?.contains("<strong>Hello</strong>") == true
                && html?.contains("data-mx-emoticon") == true
                && html?.contains("title=\"meatspin\"") == true
        }
        
        viewModel.context.send(viewAction: .sendMessage)
        
        try await deferred.fulfill()
    }
    
    @Test
    func loadsEmojiProviderBeforeSendingShortcodeWithColdCache() async throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let emojiItem = EmojiItem(label: "Meatspin",
                                  unicode: ":meatspin:",
                                  keywords: [],
                                  shortcodes: ["meatspin"],
                                  customEmoji: customEmoji)
        let emojiProvider = ComposerTestEmojiProvider(categories: [.init(id: "custom", emojis: [emojiItem])],
                                                      cacheLoaded: false)
        setUpViewModel(emojiProvider: emojiProvider)
        wysiwygViewModel.setMarkdownContent("Hello :meatspin:")
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(plain, html, _, _) = action else { return false }
            return plain == "Hello :meatspin:"
                && html?.contains("data-mx-emoticon") == true
                && html?.contains("title=\"meatspin\"") == true
        }
        
        viewModel.context.send(viewAction: .sendMessage)
        
        try await deferred.fulfill()
        #expect(emojiProvider.categoryRequests == 1)
    }
    
    @Test(arguments: [true, false])
    func editingCustomEmojiPreservesOriginalMXCOverProviderDuplicate(formattingEnabled: Bool) async throws {
        let providerEmoji = try CustomEmoji(shortcode: "shared",
                                            body: "Provider",
                                            imageURL: #require(URL(string: "mxc://provider.example/asset")))
        let providerItem = EmojiItem(label: "Provider",
                                     unicode: ":shared:",
                                     keywords: [],
                                     shortcodes: ["shared"],
                                     customEmoji: providerEmoji)
        setUpViewModel(emojiProvider: ComposerTestEmojiProvider(categories: [.init(id: "custom", emojis: [providerItem])]))
        viewModel.context.composerFormattingEnabled = formattingEnabled
        let sourceHTML = #"Hello <img data-mx-emoticon src="mxc://original.example/asset" alt="Original" title="shared" height="32" />"#
        viewModel.process(timelineAction: .setText(plainText: "Hello :shared:", htmlText: sourceHTML))
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(_, html, _, _) = action else { return false }
            return html?.contains("mxc://original.example/asset") == true
                && html?.contains("mxc://provider.example/asset") == false
        }
        
        viewModel.process(viewAction: .sendMessage)
        
        try await deferred.fulfill()
    }
    
    @Test
    func editingSanitizedCustomEmojiRestoresTextAndPreservesOriginalMXC() async throws {
        let sourceHTML = #"Hello <img src="mxc://original.example/asset" alt="Original" title="shared" height="32" />"#
        viewModel.process(timelineAction: .setText(plainText: "Hello :shared:", htmlText: sourceHTML))
        
        #expect(wysiwygViewModel.content.markdown == "Hello :shared:")
        #expect(!wysiwygViewModel.isContentEmpty)
        
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(plain, html, _, _) = action else { return false }
            return plain == "Hello :shared:"
                && html?.contains("mxc://original.example/asset") == true
                && html?.contains("data-mx-emoticon") == true
        }
        viewModel.process(viewAction: .sendMessage)
        try await deferred.fulfill()
    }
    
    @Test
    func customEmojiDraftPreservesOriginalMXCAndCollapsedToolbar() async throws {
        let sourceHTML = #"Hello <img data-mx-emoticon src="mxc://original.example/asset" alt="Original" title="shared" height="32" />"#
        viewModel.context.composerFormattingEnabled = false
        viewModel.process(timelineAction: .setText(plainText: "Hello :shared:", htmlText: sourceHTML))
        
        var capturedDraft: ComposerDraftProxy?
        await waitForConfirmation("Save custom emoji draft") { confirmation in
            draftServiceMock.saveDraftClosure = { draft in
                capturedDraft = draft
                confirmation()
                return .success(())
            }
            viewModel.saveDraft()
        }
        let draft = try #require(capturedDraft)
        let draftHTML = try #require(draft.htmlText)
        #expect(draftHTML.contains("mxc://original.example/asset"))
        
        setUpViewModel { .success(draft) }
        await viewModel.loadDraft()
        #expect(!viewModel.context.composerFormattingEnabled)
        #expect(viewModel.context.plainComposerText.string == "Hello :shared:")
        
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(_, html, _, _) = action else { return false }
            return html?.contains("mxc://original.example/asset") == true
        }
        viewModel.process(viewAction: .sendMessage)
        try await deferred.fulfill()
    }
    
    @Test
    func encryptedRoomRequiresCustomEmojiMediaAcknowledgement() async throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let emojiItem = EmojiItem(label: "Meatspin",
                                  unicode: ":meatspin:",
                                  keywords: [],
                                  shortcodes: ["meatspin"],
                                  customEmoji: customEmoji)
        setUpViewModel(emojiProvider: ComposerTestEmojiProvider(categories: [.init(id: "custom", emojis: [emojiItem])]),
                       isEncrypted: true)
        viewModel.context.composerFormattingEnabled = false
        wysiwygViewModel.setMarkdownContent(":meatspin:")
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case .sendMessage = action else { return false }
            return true
        }
        let alertDeferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.alertInfo != nil }
        
        viewModel.process(viewAction: .sendMessage)
        try await alertDeferred.fulfill()
        #expect(viewModel.context.alertInfo != nil)
        #expect(!appSettings.hasAcknowledgedCustomEmojiMediaWarning)
        viewModel.context.alertInfo?.secondaryButton?.action?()
        
        try await deferred.fulfill()
        #expect(appSettings.hasAcknowledgedCustomEmojiMediaWarning)
        #expect(viewModel.context.alertInfo == nil)
    }
    
    // MARK: - Draft
    
    @Test
    func saveDraftPlainText() async throws {
        wysiwygViewModel.setMarkdownContent("Hello world!")
        
        var capturedDraft: ComposerDraftProxy?
        await waitForConfirmation("Save draft") { confirmation in
            draftServiceMock.saveDraftClosure = { draft in
                capturedDraft = draft
                confirmation()
                return .success(())
            }
            viewModel.saveDraft()
        }
        
        let draft = try #require(capturedDraft)
        #expect(draft.plainText == "Hello world!")
        #expect(draft.htmlText == "Hello world!")
        #expect(draft.draftType == .newMessage)
        #expect(draftServiceMock.saveDraftCallsCount == 1)
        #expect(!draftServiceMock.clearDraftCalled)
        #expect(!draftServiceMock.loadDraftCalled)
    }
    
    @Test
    func saveDraftFormattedText() async throws {
        viewModel.context.composerFormattingEnabled = true
        wysiwygViewModel.setHtmlContent("<strong>Hello</strong> world!")
        
        var capturedDraft: ComposerDraftProxy?
        await waitForConfirmation("Save draft") { confirmation in
            draftServiceMock.saveDraftClosure = { draft in
                capturedDraft = draft
                confirmation()
                return .success(())
            }
            viewModel.saveDraft()
        }
        
        let draft = try #require(capturedDraft)
        #expect(draft.plainText == "__Hello__ world!")
        #expect(draft.htmlText == "<strong>Hello</strong> world!")
        #expect(draft.draftType == .newMessage)
        #expect(draftServiceMock.saveDraftCallsCount == 1)
        #expect(!draftServiceMock.clearDraftCalled)
        #expect(!draftServiceMock.loadDraftCalled)
    }
    
    @Test
    func saveDraftEdit() async throws {
        viewModel.process(timelineAction: .setMode(mode: .edit(originalEventOrTransactionID: .eventID("testID"), type: .default)))
        wysiwygViewModel.setMarkdownContent("Hello world!")
        
        var capturedDraft: ComposerDraftProxy?
        await waitForConfirmation("Save draft") { confirmation in
            draftServiceMock.saveDraftClosure = { draft in
                capturedDraft = draft
                confirmation()
                return .success(())
            }
            viewModel.saveDraft()
        }
        
        let draft = try #require(capturedDraft)
        #expect(draft.plainText == "Hello world!")
        #expect(draft.htmlText == "Hello world!")
        #expect(draft.draftType == .edit(eventID: "testID"))
        #expect(draftServiceMock.saveDraftCallsCount == 1)
        #expect(!draftServiceMock.clearDraftCalled)
        #expect(!draftServiceMock.loadDraftCalled)
    }
    
    @Test
    func saveDraftReply() async throws {
        viewModel.process(timelineAction: .setMode(mode: .reply(eventID: "testID",
                                                                replyDetails: .loaded(sender: .init(id: ""),
                                                                                      eventID: "testID",
                                                                                      eventContent: .message(.text(.init(body: "reply text")))),
                                                                isThread: false)))
        wysiwygViewModel.setMarkdownContent("Hello world!")
        
        var capturedDraft: ComposerDraftProxy?
        await waitForConfirmation("Save draft") { confirmation in
            draftServiceMock.saveDraftClosure = { draft in
                capturedDraft = draft
                confirmation()
                return .success(())
            }
            viewModel.saveDraft()
        }
        
        let draft = try #require(capturedDraft)
        #expect(draft.plainText == "Hello world!")
        #expect(draft.htmlText == "Hello world!")
        #expect(draft.draftType == .reply(eventID: "testID"))
        #expect(draftServiceMock.saveDraftCallsCount == 1)
        #expect(!draftServiceMock.clearDraftCalled)
        #expect(!draftServiceMock.loadDraftCalled)
    }
    
    @Test
    func saveDraftWhenEmptyReply() async throws {
        viewModel.context.composerFormattingEnabled = false
        viewModel.process(timelineAction: .setMode(mode: .reply(eventID: "testID",
                                                                replyDetails: .loaded(sender: .init(id: ""),
                                                                                      eventID: "testID",
                                                                                      eventContent: .message(.text(.init(body: "reply text")))),
                                                                isThread: false)))
        
        var capturedDraft: ComposerDraftProxy?
        await waitForConfirmation("Save draft") { confirmation in
            draftServiceMock.saveDraftClosure = { draft in
                capturedDraft = draft
                confirmation()
                return .success(())
            }
            viewModel.saveDraft()
        }
        
        let draft = try #require(capturedDraft)
        #expect(draft.plainText == "")
        #expect(draft.htmlText == nil)
        #expect(draft.draftType == .reply(eventID: "testID"))
        #expect(draftServiceMock.saveDraftCallsCount == 1)
        #expect(!draftServiceMock.clearDraftCalled)
        #expect(!draftServiceMock.loadDraftCalled)
    }
    
    @Test
    func clearDraftWhenEmptyNormalMessage() async {
        viewModel.context.composerFormattingEnabled = false
        
        await waitForConfirmation("Clear draft") { confirmation in
            draftServiceMock.clearDraftClosure = {
                confirmation()
                return .success(())
            }
            viewModel.saveDraft()
        }
        
        #expect(!draftServiceMock.saveDraftCalled)
        #expect(draftServiceMock.clearDraftCallsCount == 1)
        #expect(!draftServiceMock.loadDraftCalled)
    }
    
    @Test
    func clearDraftForNonTextMode() async {
        let waveformData: [Float] = Array(repeating: 1.0, count: 1000)
        wysiwygViewModel.setMarkdownContent("Hello world!")
        viewModel.process(timelineAction: .setMode(mode: .previewVoiceMessage(state: AudioPlayerState(id: .recorderPreview, title: "", duration: 10.0),
                                                                              waveform: .data(waveformData),
                                                                              isUploading: false)))
        
        await waitForConfirmation("Clear draft") { confirmation in
            draftServiceMock.clearDraftClosure = {
                confirmation()
                return .success(())
            }
            viewModel.saveDraft()
        }
        
        #expect(!draftServiceMock.saveDraftCalled)
        #expect(draftServiceMock.clearDraftCallsCount == 1)
        #expect(!draftServiceMock.loadDraftCalled)
    }
    
    @Test
    func nothingToRestore() async {
        viewModel.context.composerFormattingEnabled = false
        draftServiceMock.loadDraftClosure = {
            .success(nil)
        }
        
        await viewModel.loadDraft()
        #expect(!viewModel.context.composerFormattingEnabled)
        #expect(viewModel.state.composerEmpty)
        #expect(viewModel.state.composerMode == .default)
    }
    
    @Test
    func restoreNormalPlainTextMessage() async {
        viewModel.context.composerFormattingEnabled = false
        draftServiceMock.loadDraftClosure = {
            .success(.init(plainText: "Hello world!",
                           htmlText: nil,
                           draftType: .newMessage))
        }
        await viewModel.loadDraft()
        
        #expect(!viewModel.context.composerFormattingEnabled)
        #expect(viewModel.state.composerMode == .default)
        #expect(viewModel.context.plainComposerText == NSAttributedString(string: "Hello world!"))
    }
    
    @Test
    func restoreNormalFormattedTextMessage() async throws {
        viewModel.context.composerFormattingEnabled = false
        
        try await confirmation { confirmation in
            draftServiceMock.loadDraftClosure = {
                defer { confirmation() }
                return .success(.init(plainText: "__Hello__ world!",
                                      htmlText: "<strong>Hello</strong> world!",
                                      draftType: .newMessage))
            }
            
            let deferred = deferFulfillment(wysiwygViewModel.$isContentEmpty) { !$0 }
            await viewModel.loadDraft()
            try await deferred.fulfill()
        }
        
        #expect(!viewModel.context.composerFormattingEnabled)
        #expect(viewModel.state.composerMode == .default)
        #expect(wysiwygViewModel.content.html == "<strong>Hello</strong> world!")
        #expect(wysiwygViewModel.content.markdown == "__Hello__ world!")
    }
    
    @Test
    func restoreEdit() async {
        viewModel.context.composerFormattingEnabled = false
        draftServiceMock.loadDraftClosure = {
            .success(.init(plainText: "Hello world!",
                           htmlText: nil,
                           draftType: .edit(eventID: "testID")))
        }
        await viewModel.loadDraft()
        
        #expect(!viewModel.context.composerFormattingEnabled)
        #expect(viewModel.state.composerMode == .edit(originalEventOrTransactionID: .eventID("testID"), type: .default))
        #expect(viewModel.context.plainComposerText == NSAttributedString(string: "Hello world!"))
    }
    
    @Test
    func restoreReply() async throws {
        let testEventID = "testID"
        let text = "Hello world!"
        let loadedReply = TimelineItemReplyDetails.loaded(sender: .init(id: "userID",
                                                                        displayName: "Username"),
                                                          eventID: testEventID,
                                                          eventContent: .message(.text(.init(body: "Reply text"))))
        
        viewModel.context.composerFormattingEnabled = false
        draftServiceMock.loadDraftClosure = {
            .success(.init(plainText: text,
                           htmlText: nil,
                           draftType: .reply(eventID: testEventID)))
        }
        
        let deferredReplyLoaded = deferFulfillment(viewModel.context.$viewState) {
            $0.composerMode == .reply(eventID: testEventID, replyDetails: loadedReply, isThread: true)
        }
        draftServiceMock.getReplyEventIDClosure = { eventID in
            #expect(eventID == testEventID)
            try? await Task.sleep(for: .seconds(1))
            return .success(.init(details: loadedReply,
                                  isThreaded: true))
        }
        await viewModel.loadDraft()
        
        #expect(!viewModel.context.composerFormattingEnabled)
        // Testing the loading state first
        #expect(viewModel.state.composerMode == .reply(eventID: testEventID,
                                                       replyDetails: .loading(eventID: testEventID),
                                                       isThread: false))
        #expect(viewModel.context.plainComposerText == NSAttributedString(string: text))
        
        try await deferredReplyLoaded.fulfill()
        #expect(viewModel.state.composerMode == .reply(eventID: testEventID,
                                                       replyDetails: loadedReply,
                                                       isThread: true))
    }
    
    @Test
    func restoreReplyAndCancelReplyMode() async throws {
        let testEventID = "testID"
        let text = "Hello world!"
        let loadedReply = TimelineItemReplyDetails.loaded(sender: .init(id: "userID", displayName: "Username"),
                                                          eventID: testEventID,
                                                          eventContent: .message(.text(.init(body: "Reply text"))))
        
        viewModel.context.composerFormattingEnabled = false
        draftServiceMock.loadDraftClosure = {
            .success(.init(plainText: text,
                           htmlText: nil,
                           draftType: .reply(eventID: testEventID)))
        }
        
        let replyLoadedSubject = PassthroughSubject<Void, Never>()
        let deferredReplyLoaded = deferFulfillment(replyLoadedSubject) { _ in true }
        draftServiceMock.getReplyEventIDClosure = { eventID in
            defer { replyLoadedSubject.send(()) }
            #expect(eventID == testEventID)
            try? await Task.sleep(for: .seconds(1))
            return .success(.init(details: loadedReply,
                                  isThreaded: true))
        }
        await viewModel.loadDraft()
        
        #expect(!viewModel.context.composerFormattingEnabled)
        // Testing the loading state first
        #expect(viewModel.state.composerMode == .reply(eventID: testEventID,
                                                       replyDetails: .loading(eventID: testEventID),
                                                       isThread: false))
        #expect(viewModel.context.plainComposerText == NSAttributedString(string: text))
        
        // Now we change the state to cancel the reply mode update
        viewModel.process(viewAction: .cancelReply)
        try await deferredReplyLoaded.fulfill()
        #expect(viewModel.state.composerMode == .default)
    }
    
    @Test
    func saveVolatileDraftWhenEditing() {
        wysiwygViewModel.setMarkdownContent("Hello world!")
        viewModel.process(timelineAction: .setMode(mode: .edit(originalEventOrTransactionID: .eventID(UUID().uuidString), type: .default)))
        
        let draft = draftServiceMock.saveVolatileDraftReceivedDraft
        #expect(draft != nil)
        #expect(draft?.plainText == "Hello world!")
        #expect(draft?.htmlText == "Hello world!")
        #expect(draft?.draftType == .newMessage)
    }
    
    @Test
    func restoreVolatileDraftWhenCancellingEdit() async {
        await waitForConfirmation("Volatile draft loaded") { confirmation in
            draftServiceMock.loadVolatileDraftClosure = {
                defer { confirmation() }
                return .init(plainText: "Hello world",
                             htmlText: nil,
                             draftType: .newMessage)
            }
            DispatchQueue.main.async {
                self.viewModel.process(viewAction: .cancelEdit)
            }
        }
        #expect(viewModel.context.plainComposerText == NSAttributedString(string: "Hello world"))
    }
    
    @Test
    func restoreVolatileDraftWhenClearing() async {
        await waitForConfirmation("Volatile draft loaded and cleared", expectedCount: 2) { confirmation in
            draftServiceMock.loadVolatileDraftClosure = {
                defer { confirmation() }
                return .init(plainText: "Hello world",
                             htmlText: nil,
                             draftType: .newMessage)
            }
            draftServiceMock.clearVolatileDraftClosure = {
                confirmation()
            }
            DispatchQueue.main.async {
                self.viewModel.process(timelineAction: .clear)
            }
        }
        #expect(viewModel.context.plainComposerText == NSAttributedString(string: "Hello world"))
    }
    
    @Test
    func restoreVolatileDraftDoubleClear() async {
        await waitForConfirmation("Volatile draft loaded and cleared", expectedCount: 2) { confirmation in
            draftServiceMock.loadVolatileDraftClosure = {
                defer { confirmation() }
                return .init(plainText: "Hello world",
                             htmlText: nil,
                             draftType: .newMessage)
            }
            draftServiceMock.clearVolatileDraftClosure = {
                confirmation()
            }
            DispatchQueue.main.async {
                self.viewModel.process(timelineAction: .clear)
            }
        }
        #expect(viewModel.context.plainComposerText == NSAttributedString(string: "Hello world"))
    }
    
    @Test
    func restoreUserMentionInPlainText() async throws {
        viewModel.context.composerFormattingEnabled = false
        let text = "Hello [TestName](https://matrix.to/#/@test:matrix.org)!"
        viewModel.process(timelineAction: .setText(plainText: text, htmlText: nil))
        
        let deferred = deferFulfillment(viewModel.actions) { action in
            if case .sendMessage = action {
                true
            } else {
                false
            }
        }
        
        viewModel.process(viewAction: .sendMessage)
        guard case let .sendMessage(plainText, _, _, intentionalMentions) = try await deferred.fulfill() else { return }
        #expect(plainText == "Hello TestName!")
        #expect(intentionalMentions == IntentionalMentions(userIDs: ["@test:matrix.org"], atRoom: false))
    }
    
    @Test
    func restoreAllUsersMentionInPlainText() async throws {
        viewModel.context.composerFormattingEnabled = false
        let text = "Hello @room"
        viewModel.process(timelineAction: .setText(plainText: text, htmlText: nil))
        
        let deferred = deferFulfillment(viewModel.actions) { action in
            switch action {
            case let .sendMessage(plainText, _, _, intentionalMentions):
                return plainText == "Hello @room" &&
                    intentionalMentions == IntentionalMentions(userIDs: [], atRoom: true)
            default:
                return false
            }
        }
        
        viewModel.process(viewAction: .sendMessage)
        try await deferred.fulfill()
    }
    
    @Test
    func restoreMixedMentionsInPlainText() async throws {
        viewModel.context.composerFormattingEnabled = false
        let text = "Hello [User1](https://matrix.to/#/@user1:matrix.org), [User2](https://matrix.to/#/@user2:matrix.org) and @room"
        viewModel.process(timelineAction: .setText(plainText: text, htmlText: nil))
        
        let deferred = deferFulfillment(viewModel.actions) { action in
            if case .sendMessage = action {
                true
            } else {
                false
            }
        }
        
        viewModel.process(viewAction: .sendMessage)
        guard case let .sendMessage(plainText, _, _, intentionalMentions) = try await deferred.fulfill() else { return }
        #expect(plainText == "Hello User1, User2 and @room")
        #expect(intentionalMentions == IntentionalMentions(userIDs: ["@user1:matrix.org", "@user2:matrix.org"], atRoom: true))
    }
    
    @Test
    func restoreAmbiguousMention() async throws {
        viewModel.context.composerFormattingEnabled = false
        let text = "Hello [User1](https://matrix.to/#/@roomuser:matrix.org)"
        viewModel.process(timelineAction: .setText(plainText: text, htmlText: nil))
        
        let deferred = deferFulfillment(viewModel.actions) { action in
            if case .sendMessage = action {
                true
            } else {
                false
            }
        }
        
        viewModel.process(viewAction: .sendMessage)
        guard case let .sendMessage(plainText, _, _, intentionalMentions) = try await deferred.fulfill() else { return }
        #expect(plainText == "Hello User1")
        #expect(intentionalMentions == IntentionalMentions(userIDs: ["@roomuser:matrix.org"], atRoom: false))
    }
    
    @Test
    func restoreDoesntOverwriteInitialText() async {
        let sharedText = "Some shared text"
        var draftLoadCalled = false
        setUpViewModel(initialText: sharedText) {
            draftLoadCalled = true
            return .success(.init(plainText: "Hello world!",
                                  htmlText: nil,
                                  draftType: .newMessage))
        }
        viewModel.context.composerFormattingEnabled = false
        await viewModel.loadDraft()
        
        #expect(!draftLoadCalled)
        #expect(!viewModel.context.composerFormattingEnabled)
        #expect(viewModel.state.composerMode == .default)
        #expect(viewModel.context.plainComposerText == NSAttributedString(string: sharedText))
    }
    
    // MARK: - Identity Violation
    
    @Test
    func verificationViolationDisablesComposer() async throws {
        let mockCompletionSuggestionService = CompletionSuggestionServiceMock(configuration: .init())
        
        let roomProxyMock = JoinedRoomProxyMock(.init(name: "Test"))
        
        let roomMemberProxyMock = RoomMemberProxyMock(with: .init(userID: "@alice:localhost", membership: .join))
        roomProxyMock.getMemberUserIDClosure = { _ in
            .success(roomMemberProxyMock)
        }
        
        let mockSubject = CurrentValueSubject<[IdentityStatusChange], Never>([])
        roomProxyMock.identityStatusChangesPublisher = mockSubject.asCurrentValuePublisher()
        
        let appSettings = AppSettings.volatile()
        
        viewModel = ComposerToolbarViewModel(roomProxy: roomProxyMock,
                                             wysiwygViewModel: wysiwygViewModel,
                                             completionSuggestionService: mockCompletionSuggestionService,
                                             mediaProvider: MediaProviderMock(.init()),
                                             mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                             appSettings: appSettings,
                                             analyticsService: AnalyticsServiceMock(.init()),
                                             composerDraftService: draftServiceMock)
        
        var fulfillment = deferFulfillment(viewModel.context.$viewState, message: "Composer is disabled") { $0.canSend == false }
        mockSubject.send([IdentityStatusChange(userId: "@alice:localhost", changedTo: .verificationViolation)])
        try await fulfillment.fulfill()
        
        fulfillment = deferFulfillment(viewModel.context.$viewState, message: "Composer is enabled") { $0.canSend == true }
        mockSubject.send([IdentityStatusChange(userId: "@alice:localhost", changedTo: .pinned)])
        try await fulfillment.fulfill()
    }
    
    @Test
    func multipleViolation() async throws {
        let mockCompletionSuggestionService = CompletionSuggestionServiceMock(configuration: .init())
        
        let roomProxyMock = JoinedRoomProxyMock(.init(name: "Test"))
        
        let aliceRoomMemberProxyMock = RoomMemberProxyMock(with: .init(userID: "@alice:localhost", membership: .join))
        let bobRoomMemberProxyMock = RoomMemberProxyMock(with: .init(userID: "@bob:localhost", membership: .join))
        
        roomProxyMock.getMemberUserIDClosure = { userId in
            if userId == "@alice:localhost" {
                return .success(aliceRoomMemberProxyMock)
            } else if userId == "@bob:localhost" {
                return .success(bobRoomMemberProxyMock)
            } else {
                return .failure(.sdkError(ClientProxyMockError.generic))
            }
        }
        
        let mockSubject = CurrentValueSubject<[IdentityStatusChange], Never>([])
        
        roomProxyMock.identityStatusChangesPublisher = mockSubject.asCurrentValuePublisher()
        
        let appSettings = AppSettings.volatile()
        
        viewModel = ComposerToolbarViewModel(roomProxy: roomProxyMock,
                                             wysiwygViewModel: wysiwygViewModel,
                                             completionSuggestionService: mockCompletionSuggestionService,
                                             mediaProvider: MediaProviderMock(.init()),
                                             mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                             appSettings: appSettings,
                                             analyticsService: AnalyticsServiceMock(.init()),
                                             composerDraftService: draftServiceMock)
        
        var fulfillment = deferFulfillment(viewModel.context.$viewState, message: "Composer is disabled") { $0.canSend == false }
        mockSubject.send([
            IdentityStatusChange(userId: "@alice:localhost", changedTo: .verificationViolation),
            IdentityStatusChange(userId: "@bob:localhost", changedTo: .verificationViolation)
        ])
        try await fulfillment.fulfill()
        
        // There are 2 violations, ensure that resolving the first one is not enough.
        let failure = deferFailure(viewModel.context.$viewState, timeout: .seconds(1), message: "Composer should still be disabled") { $0.canSend == true }
        mockSubject.send([IdentityStatusChange(userId: "@alice:localhost", changedTo: .pinned)])
        try await failure.fulfill()
        
        fulfillment = deferFulfillment(viewModel.context.$viewState, message: "Composer is now enabled") { $0.canSend == true }
        mockSubject.send([IdentityStatusChange(userId: "@bob:localhost", changedTo: .pinned)])
        try await fulfillment.fulfill()
    }
    
    @Test
    func pinViolationDoesNotDisableComposer() async throws {
        let mockCompletionSuggestionService = CompletionSuggestionServiceMock(configuration: .init())
        
        let roomProxyMock = JoinedRoomProxyMock(.init(name: "Test"))
        let roomMemberProxyMock = RoomMemberProxyMock(with: .init(userID: "@alice:localhost", membership: .join))
        
        roomProxyMock.getMemberUserIDClosure = { _ in
            .success(roomMemberProxyMock)
        }
        
        roomProxyMock.identityStatusChangesPublisher = CurrentValueSubject([IdentityStatusChange(userId: "@alice:localhost", changedTo: .pinViolation)]).asCurrentValuePublisher()
        let appSettings = AppSettings.volatile()
        
        viewModel = ComposerToolbarViewModel(roomProxy: roomProxyMock,
                                             wysiwygViewModel: wysiwygViewModel,
                                             completionSuggestionService: mockCompletionSuggestionService,
                                             mediaProvider: MediaProviderMock(.init()),
                                             mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                             appSettings: appSettings,
                                             analyticsService: AnalyticsServiceMock(.init()),
                                             composerDraftService: draftServiceMock)
        
        let deferred = deferFulfillment(viewModel.context.$viewState, message: "Composer should be enabled") { $0.canSend == true }
        try await deferred.fulfill()
    }
}

private extension ComposerToolbarViewModelTests {
    func setUpViewModel(initialText: String? = nil,
                        loadDraftClosure: (() async -> Result<ComposerDraftProxy?, ComposerDraftServiceError>)? = nil,
                        emojiProvider: EmojiProviderProtocol? = nil,
                        isEncrypted: Bool = false,
                        nitroTasksEnabled: Bool = false,
                        powerLevelsConfiguration: RoomPowerLevelsProxyMock.Configuration = .init()) {
        wysiwygViewModel = WysiwygComposerViewModel()
        completionSuggestionServiceMock = CompletionSuggestionServiceMock(configuration: .init())
        draftServiceMock = ComposerDraftServiceMock(.init())
        if let loadDraftClosure {
            draftServiceMock.loadDraftClosure = loadDraftClosure
        }
        
        appSettings = AppSettings.volatile()
        
        viewModel = ComposerToolbarViewModel(initialText: initialText,
                                             roomProxy: JoinedRoomProxyMock(.init(isEncrypted: isEncrypted,
                                                                                  powerLevelsConfiguration: powerLevelsConfiguration)),
                                             wysiwygViewModel: wysiwygViewModel,
                                             completionSuggestionService: completionSuggestionServiceMock,
                                             mediaProvider: MediaProviderMock(.init()),
                                             mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                             appSettings: appSettings,
                                             analyticsService: AnalyticsServiceMock(.init()),
                                             composerDraftService: draftServiceMock,
                                             emojiProvider: emojiProvider,
                                             nitroTasksEnabled: nitroTasksEnabled)
    }
}

extension ComposerToolbarViewModelTests {
    @Test
    func enablesNitroTaskCreationWithRoomPermissions() {
        setUpViewModel(nitroTasksEnabled: true)
        
        #expect(viewModel.context.viewState.canCreateNitroTask)
    }
    
    @Test
    func disablesNitroTaskCreationWithoutRequiredPermissions() {
        setUpViewModel(nitroTasksEnabled: true,
                       powerLevelsConfiguration: .init(canUserPin: false))
        
        #expect(!viewModel.context.viewState.canCreateNitroTask)
        
        setUpViewModel(nitroTasksEnabled: true,
                       powerLevelsConfiguration: .init(canUserSendMessage: false))
        
        #expect(!viewModel.context.viewState.canCreateNitroTask)
    }
    
    @Test
    func pastesNitroHTMLAsFormattedContent() {
        viewModel.process(viewAction: .pasteRichText(.html("<strong>Hello</strong>", plainText: "Hello")))
        
        #expect(wysiwygViewModel.content.html == "<strong>Hello</strong>")
        #expect(wysiwygViewModel.content.markdown == "__Hello__")
    }
    
    @Test
    func pastesNitroCustomEmojiAndPreservesOriginalMedia() async throws {
        let html = #"Hello <img data-mx-emoticon src="mxc://example.org/meatspin" alt="Meatspin" title="meatspin" height="32" />"#
        viewModel.process(viewAction: .pasteRichText(.html(html, plainText: "Hello :meatspin:")))
        
        #expect(wysiwygViewModel.content.markdown == "Hello :meatspin:")
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(_, sentHTML, _, _) = action else { return false }
            return sentHTML == html
        }
        
        viewModel.process(viewAction: .sendMessage)
        
        try await deferred.fulfill()
    }
    
    @Test
    func pastesNitroMarkdownAsFormattedContent() {
        viewModel.process(viewAction: .pasteRichText(.markdown("__Hello__")))
        
        #expect(wysiwygViewModel.content.html == "<strong>Hello</strong>")
        #expect(wysiwygViewModel.content.markdown == "__Hello__")
    }
    
    @Test
    func pastesNitroPlainTextWithoutInterpretingMarkdown() {
        viewModel.process(viewAction: .pasteRichText(.plainText("__Hello__")))
        
        #expect(wysiwygViewModel.content.html == "__Hello__")
    }
    
    @Test
    func resolvesRichPasteProviderInViewModel() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) { completion in
            completion(Data("<strong>Hello</strong>".utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(Data("Hello".utf8), nil)
            return nil
        }
        let pasted = deferFulfillment(wysiwygViewModel.$attributedContent) { content in
            content.text.string == "Hello"
        }
        
        viewModel.process(viewAction: .pasteRichTextProvider(provider))
        
        try await pasted.fulfill()
        #expect(wysiwygViewModel.content.markdown == "__Hello__")
    }
    
    @Test
    func resolvesNotesPlainTextProviderInViewModel() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "com.apple.webarchive", visibility: .all) { completion in
            completion(Data("webarchive".utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(Data("Hello from Notes".utf8), nil)
            return nil
        }
        let pasted = deferFulfillment(wysiwygViewModel.$attributedContent) { content in
            content.text.string == "Hello from Notes"
        }

        viewModel.process(viewAction: .pasteRichTextProvider(provider))

        try await pasted.fulfill()
        #expect(wysiwygViewModel.content.html == "Hello from Notes")
    }

    @Test
    func disablesComposerWhileResolvingCustomEmojis() async throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let emojiItem = EmojiItem(label: "Meatspin",
                                  unicode: ":meatspin:",
                                  keywords: [],
                                  shortcodes: ["meatspin"],
                                  customEmoji: customEmoji)
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let emojiProvider = ComposerTestEmojiProvider(categories: [.init(id: "custom", emojis: [emojiItem])],
                                                      cacheLoaded: false) {
            for await _ in stream {
                break
            }
            return [.init(id: "custom", emojis: [emojiItem])]
        }
        setUpViewModel(emojiProvider: emojiProvider)
        wysiwygViewModel.setMarkdownContent("Hello :meatspin:")
        let deferred = deferFulfillment(viewModel.actions) { action in
            guard case let .sendMessage(plain, html, _, _) = action else { return false }
            return plain == "Hello :meatspin:" && html?.contains("data-mx-emoticon") == true
        }
        
        viewModel.context.send(viewAction: .sendMessage)
        
        #expect(viewModel.context.viewState.isResolvingCustomEmojis)
        #expect(viewModel.context.viewState.sendButtonDisabled)
        continuation.yield()
        continuation.finish()
        try await deferred.fulfill()
        #expect(!viewModel.context.viewState.isResolvingCustomEmojis)
    }
}

private final class ComposerTestEmojiProvider: EmojiProviderProtocol {
    private let emojiCategories: [EmojiCategory]
    private let cacheLoaded: Bool
    private let categoriesClosure: (() async -> [EmojiCategory])?
    private(set) var categoryRequests = 0
    
    init(categories: [EmojiCategory],
         cacheLoaded: Bool = true,
         categoriesClosure: (() async -> [EmojiCategory])? = nil) {
        emojiCategories = categories
        self.cacheLoaded = cacheLoaded
        self.categoriesClosure = categoriesClosure
    }
    
    func categories(searchString: String?) async -> [EmojiCategory] {
        categoryRequests += 1
        if let categoriesClosure {
            return await categoriesClosure()
        }
        return emojiCategories
    }
    
    func cachedCustomEmojis() -> [CustomEmoji] {
        guard cacheLoaded else { return [] }
        return emojiCategories.flatMap(\.emojis).compactMap(\.customEmoji)
    }
    
    func frequentlyUsedSystemEmojis() -> [String] {
        []
    }
    
    func markEmojiAsFrequentlyUsed(_ emoji: String) { }
}
