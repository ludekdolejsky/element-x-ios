//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@MainActor
class AuthenticationFlowCoordinatorUITests: XCTestCase {
    func testNitroLiveLogin() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NITRO_LIVE_MATRIX_LOGIN"] == "1" else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_LOGIN=1 to run against the live Nitro homeserver.")
        }
        guard let password = environment["NITRO_LIVE_MATRIX_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_PASSWORD to the dedicated test account password.")
        }
        let server = environment["NITRO_LIVE_MATRIX_SERVER"] ?? "mn.nitrovery.com"
        let username = environment["NITRO_LIVE_MATRIX_USERNAME"] ?? "elementx_ios_test"
        
        let app = XCUIApplication()
        app.launch()
        
        let signInButton = app.buttons[A11yIdentifiers.authenticationStartScreen.signIn]
        XCTAssertTrue(signInButton.waitForExistence(timeout: 10))
        signInButton.tap()
        
        let serverField = app.textFields[A11yIdentifiers.changeServerScreen.server]
        if !serverField.waitForExistence(timeout: 2) {
            let changeServerButton = app.buttons[A11yIdentifiers.serverConfirmationScreen.changeServer]
            XCTAssertTrue(changeServerButton.waitForExistence(timeout: 10))
            changeServerButton.tap()
        }
        XCTAssertTrue(serverField.waitForExistence(timeout: 10))
        serverField.clearAndTypeText(server, app: app)
        
        let serverContinueButton = app.buttons[A11yIdentifiers.changeServerScreen.continue]
        XCTAssertTrue(serverContinueButton.wait(for: \.isHittable, toEqual: true, timeout: 20))
        serverContinueButton.tap()
        
        let loginContinueButton = app.buttons[A11yIdentifiers.loginScreen.continue]
        XCTAssertTrue(loginContinueButton.waitForExistence(timeout: 20))
        let usernameField = app.textFields[A11yIdentifiers.loginScreen.emailUsername]
        let passwordField = app.secureTextFields[A11yIdentifiers.loginScreen.password]
        XCTAssertTrue(usernameField.wait(for: \.isHittable, toEqual: true, timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        usernameField.clearAndTypeText(username, app: app)
        passwordField.clearAndTypeText(password, app: app)
        loginContinueButton.tap()
        
        XCTAssertTrue(loginContinueButton.wait(for: \.exists, toEqual: false, timeout: 30))
        XCTAssertFalse(app.alerts.element.exists)
    }
    
    func testNitroFinishLiveOnboarding() throws {
        guard ProcessInfo.processInfo.environment["NITRO_LIVE_MATRIX_ONBOARDING"] == "1" else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_ONBOARDING=1 to finish onboarding for the dedicated live test account.")
        }
        
        let app = XCUIApplication()
        app.launch()
        dismissLiveStartupPrompts(in: app)
        
        XCTAssertTrue(app.buttons[A11yIdentifiers.homeScreen.userAvatar].wait(for: \.isHittable, toEqual: true, timeout: 20))
    }
    
    func testNitroLiveTasksBoard() throws {
        guard ProcessInfo.processInfo.environment["NITRO_LIVE_MATRIX_TASKS"] == "1" else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_TASKS=1 to inspect the live Nitro task board.")
        }
        
        let app = XCUIApplication()
        app.launch()
        dismissLiveStartupPrompts(in: app)
        unlockLiveAppIfNeeded(in: app)
        
        let tasksTab = app.buttons["Tasks"]
        XCTAssertTrue(tasksTab.wait(for: \.isHittable, toEqual: true, timeout: 20))
        tasksTab.tap()
        
        let statusPicker = app.segmentedControls.firstMatch
        if !statusPicker.waitForExistence(timeout: 2) {
            XCTAssertTrue(app.staticTexts["No active tasks"].waitForExistence(timeout: 30))
            
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Nitro Tasks - Empty"
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }
        for status in ["To do", "In progress", "Done"] {
            let button = statusPicker.buttons[status]
            XCTAssertTrue(button.exists)
            button.tap()
            
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Nitro Tasks - \(status)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
    
    func testNitroLiveTasksLifecycle() throws {
        guard ProcessInfo.processInfo.environment["NITRO_LIVE_MATRIX_TASKS_LIFECYCLE"] == "1" else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_TASKS_LIFECYCLE=1 to exercise live Nitro task status changes.")
        }
        
        let app = XCUIApplication()
        let title = "iOS live task \(UUID().uuidString.prefix(8))"
        app.launch()
        unlockLiveAppIfNeeded(in: app)
        openLiveTasks(in: app)
        
        let newTaskButton = app.navigationBars["Tasks"].buttons["New task"]
        XCTAssertTrue(newTaskButton.wait(for: \.isHittable, toEqual: true, timeout: 20))
        newTaskButton.tap()
        
        let createNavigationBar = app.navigationBars["New task"]
        XCTAssertTrue(createNavigationBar.waitForExistence(timeout: 20))
        let titleField = app.textFields["Task title"]
        XCTAssertTrue(titleField.wait(for: \.isHittable, toEqual: true, timeout: 20))
        Thread.sleep(forTimeInterval: 1)
        titleField.clearAndTypeText(title, app: app, verifyingValue: false)
        
        let createButton = createNavigationBar.buttons["New task"]
        XCTAssertTrue(createButton.wait(for: \.isEnabled, toEqual: true, timeout: 30))
        createButton.tap()
        
        XCTAssertTrue(createNavigationBar.wait(for: \.exists, toEqual: false, timeout: 45))
        
        var statusPicker = app.segmentedControls.firstMatch
        XCTAssertTrue(statusPicker.waitForExistence(timeout: 45))
        let todoButton = statusPicker.buttons["To do"]
        todoButton.tap()
        
        var taskButton = liveTaskButton(title: title, in: app)
        XCTAssertTrue(taskButton.waitForExistence(timeout: 30))
        attachLiveScreenshot(named: "Nitro Tasks lifecycle - To do", app: app)
        
        let roomFilterButton = app.navigationBars["Tasks"].buttons["Filter by room"]
        XCTAssertTrue(roomFilterButton.wait(for: \.isHittable, toEqual: true, timeout: 10))
        roomFilterButton.tap()
        let taskRoomFilter = app.buttons["Nitro task push test"]
        XCTAssertTrue(taskRoomFilter.wait(for: \.isHittable, toEqual: true, timeout: 10))
        taskRoomFilter.tap()
        XCTAssertTrue(taskButton.waitForExistence(timeout: 10))
        attachLiveScreenshot(named: "Nitro Tasks lifecycle - Room filter active", app: app)
        roomFilterButton.tap()
        let allRoomsFilter = app.buttons["All rooms"]
        XCTAssertTrue(allRoomsFilter.wait(for: \.isHittable, toEqual: true, timeout: 10))
        allRoomsFilter.tap()
        
        taskButton.press(forDuration: 1)
        let openInRoomButton = app.buttons["Open in room"]
        XCTAssertTrue(openInRoomButton.wait(for: \.isHittable, toEqual: true, timeout: 10))
        openInRoomButton.tap()
        XCTAssertTrue(app.buttons[A11yIdentifiers.roomScreen.name].waitForExistence(timeout: 20))
        let backButton = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton'")).firstMatch
        XCTAssertTrue(backButton.wait(for: \.isHittable, toEqual: true, timeout: 10))
        backButton.tap()
        openLiveTasks(in: app)
        statusPicker = app.segmentedControls.firstMatch
        XCTAssertTrue(statusPicker.waitForExistence(timeout: 45))
        statusPicker.buttons["To do"].tap()
        taskButton = liveTaskButton(title: title, in: app)
        XCTAssertTrue(taskButton.waitForExistence(timeout: 30))
        
        taskButton.swipeRight()
        let startButton = app.buttons["Start"]
        XCTAssertTrue(startButton.wait(for: \.isHittable, toEqual: true, timeout: 10))
        startButton.tap()
        XCTAssertTrue(taskButton.wait(for: \.exists, toEqual: false, timeout: 30))
        
        statusPicker.buttons["In progress"].tap()
        taskButton = liveTaskButton(title: title, in: app)
        XCTAssertTrue(taskButton.waitForExistence(timeout: 30))
        attachLiveScreenshot(named: "Nitro Tasks lifecycle - In progress", app: app)
        
        app.terminate()
        app.launch()
        unlockLiveAppIfNeeded(in: app)
        openLiveTasks(in: app)
        statusPicker = app.segmentedControls.firstMatch
        XCTAssertTrue(statusPicker.waitForExistence(timeout: 45))
        statusPicker.buttons["In progress"].tap()
        taskButton = liveTaskButton(title: title, in: app)
        XCTAssertTrue(taskButton.waitForExistence(timeout: 30))
        attachLiveScreenshot(named: "Nitro Tasks lifecycle - In progress after reload", app: app)
        
        taskButton.swipeRight()
        let doneButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex
        let doneAction = doneButtons.first { $0.frame.minY > statusPicker.frame.maxY }
        XCTAssertNotNil(doneAction)
        doneAction?.tap()
        XCTAssertTrue(taskButton.wait(for: \.exists, toEqual: false, timeout: 30))
        
        statusPicker.buttons["Done"].tap()
        taskButton = liveTaskButton(title: title, in: app)
        XCTAssertTrue(taskButton.waitForExistence(timeout: 30))
        attachLiveScreenshot(named: "Nitro Tasks lifecycle - Done", app: app)
        
        app.terminate()
        app.launch()
        unlockLiveAppIfNeeded(in: app)
        openLiveTasks(in: app)
        statusPicker = app.segmentedControls.firstMatch
        XCTAssertTrue(statusPicker.waitForExistence(timeout: 45))
        statusPicker.buttons["Done"].tap()
        taskButton = liveTaskButton(title: title, in: app)
        XCTAssertTrue(taskButton.waitForExistence(timeout: 30))
        attachLiveScreenshot(named: "Nitro Tasks lifecycle - Done after reload", app: app)
        
        taskButton.swipeLeft()
        let archiveButton = app.buttons["Archive"]
        XCTAssertTrue(archiveButton.wait(for: \.isHittable, toEqual: true, timeout: 10))
        archiveButton.tap()
        XCTAssertTrue(taskButton.wait(for: \.exists, toEqual: false, timeout: 30))
    }
    
    func testNitroLiveTasksRoomFilter() throws {
        guard ProcessInfo.processInfo.environment["NITRO_LIVE_MATRIX_TASKS_LIFECYCLE"] == "1" else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_TASKS_LIFECYCLE=1 to exercise the live Nitro task room filter.")
        }
        
        let app = XCUIApplication()
        app.launch()
        unlockLiveAppIfNeeded(in: app)
        openLiveTasks(in: app)
        
        let roomFilterButton = app.navigationBars["Tasks"].buttons["Filter by room"]
        XCTAssertTrue(roomFilterButton.wait(for: \.isHittable, toEqual: true, timeout: 20))
        roomFilterButton.tap()
        let taskRoomFilter = app.buttons["Nitro task push test"]
        XCTAssertTrue(taskRoomFilter.wait(for: \.isHittable, toEqual: true, timeout: 10))
        taskRoomFilter.tap()
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 10))
        attachLiveScreenshot(named: "Nitro Tasks - Room filter active", app: app)
        
        roomFilterButton.tap()
        let allRoomsFilter = app.buttons["All rooms"]
        XCTAssertTrue(allRoomsFilter.wait(for: \.isHittable, toEqual: true, timeout: 10))
        allRoomsFilter.tap()
    }
    
    func testNitroLiveCustomEmojiRoomFlow() throws {
        guard ProcessInfo.processInfo.environment["NITRO_LIVE_MATRIX_EMOJI"] == "1" else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_EMOJI=1 to run against the dedicated live emoji room.")
        }
        
        let app = XCUIApplication()
        app.launch()
        openLiveRoom(named: "Nitro Emoji Live E2E", in: app)
        openCustomEmojiPicker(in: app)
        
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 2) {
            sheet.swipeUp()
        }
        
        let globalPack = app.staticTexts["01 Global test pack"]
        let roomPack = app.staticTexts["02 Room test pack"]
        let spacePack = app.staticTexts["03 Space test pack"]
        XCTAssertTrue(globalPack.waitForExistence(timeout: 20))
        XCTAssertTrue(roomPack.waitForExistence(timeout: 20))
        XCTAssertTrue(spacePack.waitForExistence(timeout: 20))
        XCTAssertLessThan(roomPack.frame.minY, spacePack.frame.minY)
        XCTAssertLessThan(spacePack.frame.minY, globalPack.frame.minY)
        
        let globalWinner = customEmojiButton(labelContaining: "Global winner", in: app)
        XCTAssertTrue(globalWinner.waitForExistence(timeout: 10))
        XCTAssertFalse(customEmojiButton(labelContaining: "Room duplicate", in: app).exists)
        XCTAssertFalse(customEmojiButton(labelContaining: "Space duplicate", in: app).exists)
        
        let initialEmojiCount = customEmojiMessages(in: app).count
        let globalOnly = customEmojiButton(labelContaining: "Global only", in: app)
        XCTAssertTrue(globalOnly.waitForExistence(timeout: 10))
        globalOnly.tap()
        XCTAssertTrue(waitForCustomEmojiMessages(count: initialEmojiCount + 1, in: app))
        
        let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(":shared")
        
        let sharedSuggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", ":shared:", "Global winner")).firstMatch
        XCTAssertTrue(sharedSuggestion.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Room duplicate")).firstMatch.exists)
        sharedSuggestion.tap()
        XCTAssertEqual(composer.value as? String, ":shared:")
        app.buttons[A11yIdentifiers.roomScreen.sendButton].tap()
        XCTAssertTrue(waitForCustomEmojiMessages(count: initialEmojiCount + 2, in: app))
        
        composer.tap()
        composer.typeText("literal *stars* :room-only:")
        app.buttons[A11yIdentifiers.roomScreen.sendButton].tap()
        XCTAssertTrue(waitForCustomEmojiMessages(count: initialEmojiCount + 3, in: app))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "[img")).firstMatch.exists)
    }
    
    func testNitroLiveEncryptedCustomEmojiWarning() throws {
        guard ProcessInfo.processInfo.environment["NITRO_LIVE_MATRIX_ENCRYPTED_EMOJI"] == "1" else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_ENCRYPTED_EMOJI=1 to run against the dedicated encrypted emoji room.")
        }
        
        let app = XCUIApplication()
        app.launch()
        openLiveRoom(named: "Nitro Emoji Encrypted E2E", in: app)
        
        let initialEmojiCount = customEmojiMessages(in: app).count
        openCustomEmojiPicker(in: app)
        let encryptedEmoji = customEmojiButton(labelContaining: "Encrypted only", in: app)
        XCTAssertTrue(encryptedEmoji.waitForExistence(timeout: 20))
        encryptedEmoji.tap()
        
        XCTAssertTrue(app.staticTexts["Custom emoji media isn’t encrypted"].waitForExistence(timeout: 10))
        app.buttons[A11yIdentifiers.alertInfo.primaryButton].firstMatch.tap()
        XCTAssertEqual(customEmojiMessages(in: app).count, initialEmojiCount)
        
        openCustomEmojiPicker(in: app)
        XCTAssertTrue(encryptedEmoji.waitForExistence(timeout: 20))
        encryptedEmoji.tap()
        XCTAssertTrue(app.staticTexts["Custom emoji media isn’t encrypted"].waitForExistence(timeout: 10))
        app.buttons[A11yIdentifiers.alertInfo.secondaryButton].firstMatch.tap()
        XCTAssertTrue(waitForCustomEmojiMessages(count: initialEmojiCount + 1, in: app))
        
        openCustomEmojiPicker(in: app)
        XCTAssertTrue(encryptedEmoji.waitForExistence(timeout: 20))
        encryptedEmoji.tap()
        XCTAssertFalse(app.staticTexts["Custom emoji media isn’t encrypted"].waitForExistence(timeout: 2))
        XCTAssertTrue(waitForCustomEmojiMessages(count: initialEmojiCount + 2, in: app))
    }
    
    func testNitroLiveCustomEmojiRoomIsolation() throws {
        guard ProcessInfo.processInfo.environment["NITRO_LIVE_MATRIX_EMOJI_ISOLATION"] == "1" else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_EMOJI_ISOLATION=1 to verify live room-scoped emoji cache isolation.")
        }
        
        let app = XCUIApplication()
        app.launch()
        openLiveRoom(named: "Nitro Emoji Live E2E", in: app)
        openCustomEmojiPicker(in: app)
        XCTAssertTrue(customEmojiButton(labelContaining: "Room only", in: app).waitForExistence(timeout: 20))
        app.buttons["Cancel"].tap()
        
        openLiveRoom(named: "Nitro Emoji Room Isolation", in: app)
        openCustomEmojiPicker(in: app)
        XCTAssertTrue(customEmojiButton(labelContaining: "Global only", in: app).waitForExistence(timeout: 20))
        XCTAssertFalse(customEmojiButton(labelContaining: "Room only", in: app).waitForExistence(timeout: 2))
        XCTAssertFalse(customEmojiButton(labelContaining: "Space only", in: app).waitForExistence(timeout: 2))
    }
    
    func testNitroLiveCustomEmojiRoomListPreview() throws {
        try requireLiveEmojiRelationsEnvironment()
        
        let app = XCUIApplication()
        app.launch()
        unlockLiveAppIfNeeded(in: app)
        dismissLiveStartupPrompts(in: app)
        let roomName = "Nitro Emoji Relations E2E"
        openLiveRoom(named: roomName, in: app)
        
        let marker = "nitro-preview-\(UUID().uuidString.prefix(8))"
        sendMessage("\(marker) :room-only:", in: app)
        XCTAssertTrue(timelineMessage(containing: marker, in: app).waitForExistence(timeout: 20))
        
        let backButton = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton'")).firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 10))
        backButton.tap()
        
        let roomButton = app.buttons[A11yIdentifiers.homeScreen.roomName(roomName)]
        XCTAssertTrue(roomButton.waitForExistence(timeout: 20))
        XCTAssertTrue(roomButton.label.contains(marker))
        XCTAssertTrue(roomButton.label.contains(":room-only:"))
        XCTAssertFalse(roomButton.label.contains("[img:"))
    }
    
    func testNitroLiveCustomEmojiEditFlow() throws {
        try requireLiveEmojiRelationsEnvironment()
        
        let app = XCUIApplication()
        app.launch()
        openLiveRoom(named: "Nitro Emoji Relations E2E", in: app)
        
        let marker = "nitro-edit-\(UUID().uuidString.prefix(8))"
        sendMessage("\(marker) :room-only:", in: app)
        
        let message = timelineMessage(containing: marker, in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        openTimelineItemMenu(for: message, marker: marker, in: app)
        
        let editButton = app.buttons[A11yIdentifiers.roomScreen.timelineItemActionMenuAction.edit]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10))
        editButton.tap()
        
        let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue((composer.value as? String)?.contains(":room-only:") == true)
        composer.tap()
        composer.typeText(" edited")
        app.buttons[A11yIdentifiers.roomScreen.sendButton].tap()
        
        let editedMessage = app.textViews.matching(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", marker, "edited")).firstMatch
        XCTAssertTrue(editedMessage.waitForExistence(timeout: 20))
        XCTAssertTrue((editedMessage.value as? String)?.contains("\u{FFFC}") == true)
    }
    
    func testNitroLiveCustomEmojiReplyAndThreadFlow() throws {
        try requireLiveEmojiRelationsEnvironment()
        
        let app = XCUIApplication()
        app.launch()
        openLiveRoom(named: "Nitro Emoji Relations E2E", in: app)
        
        let marker = "nitro-rel-\(UUID().uuidString.prefix(8))"
        sendMessage("\(marker) :room-only:", in: app)
        let target = timelineMessage(containing: marker, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        
        openTimelineItemMenu(for: target, marker: marker, in: app)
        let replyButton = app.buttons["Reply"].firstMatch
        XCTAssertTrue(replyButton.waitForExistence(timeout: 10))
        replyButton.tap()
        
        let replyMarker = "reply-\(marker)"
        sendMessage("\(replyMarker) :global-only:", in: app)
        let reply = timelineMessage(containing: replyMarker, in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
        XCTAssertTrue((reply.value as? String)?.contains("\u{FFFC}") == true)
        
        let threadTargetMarker = "thread-root-\(marker)"
        sendMessage("\(threadTargetMarker) :room-only:", in: app)
        let threadTarget = timelineMessage(containing: threadTargetMarker, in: app)
        XCTAssertTrue(threadTarget.waitForExistence(timeout: 20))
        
        openTimelineItemMenu(for: threadTarget, marker: threadTargetMarker, in: app)
        let threadButton = app.buttons["Reply in thread"].firstMatch
        XCTAssertTrue(threadButton.waitForExistence(timeout: 10))
        threadButton.tap()
        
        let threadMarker = "thread-\(marker)"
        sendMessage("\(threadMarker) :space-only:", in: app)
        let threadReply = timelineMessage(containing: threadMarker, in: app)
        XCTAssertTrue(threadReply.waitForExistence(timeout: 20))
        XCTAssertTrue((threadReply.value as? String)?.contains("\u{FFFC}") == true)
    }
    
    func testNitroLiveCustomEmojiReactionFlow() throws {
        try requireLiveEmojiRelationsEnvironment()
        
        let app = XCUIApplication()
        app.launch()
        openLiveRoom(named: "Nitro Emoji Relations E2E", in: app)
        
        let marker = "nitro-react-\(UUID().uuidString.prefix(8))"
        sendMessage("\(marker) :room-only:", in: app)
        let target = timelineMessage(containing: marker, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        
        openTimelineItemMenu(for: target, marker: marker, in: app)
        let reactButton = app.buttons["React"].firstMatch
        XCTAssertTrue(reactButton.waitForExistence(timeout: 10))
        reactButton.tap()
        
        let globalOnly = customEmojiButton(labelContaining: "Global only", in: app)
        XCTAssertTrue(globalOnly.waitForExistence(timeout: 20))
        globalOnly.tap()
        
        let renderedReaction = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "You reacted with Custom emoji"))
            .firstMatch
        XCTAssertTrue(renderedReaction.waitForExistence(timeout: 20))
    }
    
    private func dismissLiveStartupPrompts(in app: XCUIApplication) {
        let analyticsNotNow = app.buttons[A11yIdentifiers.analyticsPromptScreen.notNow]
        if analyticsNotNow.waitForExistence(timeout: 10) {
            analyticsNotNow.tap()
            XCTAssertTrue(analyticsNotNow.wait(for: \.exists, toEqual: false, timeout: 10))
        }
        
        let notificationNotNow = app.buttons["Not now"]
        if notificationNotNow.waitForExistence(timeout: 10) {
            notificationNotNow.tap()
            XCTAssertTrue(notificationNotNow.wait(for: \.exists, toEqual: false, timeout: 10))
        }
        
        let identityConfirmationSkip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip")).firstMatch
        if identityConfirmationSkip.waitForExistence(timeout: 10) {
            identityConfirmationSkip.tap()
            XCTAssertTrue(identityConfirmationSkip.wait(for: \.exists, toEqual: false, timeout: 10))
        }
    }
    
    private func openLiveRoom(named name: String, in app: XCUIApplication) {
        let homeAvatar = app.buttons[A11yIdentifiers.homeScreen.userAvatar]
        var navigationAttempts = 0
        while !homeAvatar.exists, navigationAttempts < 3 {
            let backButton = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton'")).firstMatch
            guard backButton.waitForExistence(timeout: 3) else { break }
            backButton.tap()
            navigationAttempts += 1
        }
        XCTAssertTrue(homeAvatar.waitForExistence(timeout: 20))
        
        let roomButton = app.buttons[A11yIdentifiers.homeScreen.roomName(name)]
        if !roomButton.waitForExistence(timeout: 5) {
            let searchField = app.searchFields.firstMatch
            XCTAssertTrue(searchField.waitForExistence(timeout: 5))
            searchField.tap()
            searchField.typeText(name)
        }
        XCTAssertTrue(roomButton.waitForExistence(timeout: 20))
        roomButton.tap()
        XCTAssertTrue(app.buttons[A11yIdentifiers.roomScreen.name].waitForExistence(timeout: 20))
    }
    
    private func openLiveTasks(in app: XCUIApplication) {
        let tasksNavigationBar = app.navigationBars["Tasks"]
        if !tasksNavigationBar.exists {
            let tasksTab = app.buttons["Tasks"]
            var navigationAttempts = 0
            while !tasksTab.isHittable, navigationAttempts < 3 {
                let backButton = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton'")).firstMatch
                guard backButton.waitForExistence(timeout: 3) else { break }
                backButton.tap()
                navigationAttempts += 1
            }
            XCTAssertTrue(tasksTab.wait(for: \.isHittable, toEqual: true, timeout: 20))
            tasksTab.tap()
        }
        XCTAssertTrue(tasksNavigationBar.waitForExistence(timeout: 20))
    }
    
    private func liveTaskButton(title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }
    
    private func attachLiveScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    
    private func unlockLiveAppIfNeeded(in app: XCUIApplication) {
        guard app.staticTexts["Enter your PIN"].waitForExistence(timeout: 2) else { return }
        guard let pin = ProcessInfo.processInfo.environment["NITRO_LIVE_MATRIX_PIN"],
              pin.count == 4,
              pin.allSatisfy(\.isNumber) else {
            XCTFail("Set NITRO_LIVE_MATRIX_PIN to unlock the persisted live test profile.")
            return
        }
        
        for digit in pin {
            guard let value = digit.wholeNumberValue else { continue }
            app.buttons[A11yIdentifiers.appLockScreen.numpad(value)].tap()
        }
        XCTAssertTrue(app.staticTexts["Enter your PIN"].wait(for: \.exists, toEqual: false, timeout: 10))
    }
    
    private func openCustomEmojiPicker(in app: XCUIApplication) {
        let composeOptions = app.buttons[A11yIdentifiers.roomScreen.composerToolbar.openComposeOptions]
        XCTAssertTrue(composeOptions.waitForExistence(timeout: 10))
        composeOptions.tap()
        
        let customEmoji = app.buttons["Custom emoji"]
        XCTAssertTrue(customEmoji.waitForExistence(timeout: 10))
        customEmoji.tap()
    }
    
    private func requireLiveEmojiRelationsEnvironment() throws {
        guard ProcessInfo.processInfo.environment["NITRO_LIVE_MATRIX_EMOJI_RELATIONS"] == "1" else {
            throw XCTSkip("Set NITRO_LIVE_MATRIX_EMOJI_RELATIONS=1 to exercise live custom emoji relations.")
        }
    }
    
    private func sendMessage(_ text: String, in app: XCUIApplication) {
        let composer = app.textViews[A11yIdentifiers.roomScreen.messageComposer]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(text)
        app.buttons[A11yIdentifiers.roomScreen.sendButton].tap()
    }
    
    private func timelineMessage(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }
    
    private func openTimelineItemMenu(for message: XCUIElement, marker: String, in app: XCUIApplication) {
        XCTAssertTrue(message.exists)
        let senders = app.staticTexts.matching(NSPredicate(format: "label == %@", "elementx_ios_test"))
        XCTAssertTrue(senders.firstMatch.waitForExistence(timeout: 10))
        
        let menu = app.descendants(matching: .any)[A11yIdentifiers.roomScreen.timelineItemActionMenu]
        let expectedPreview = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        for index in 0..<senders.count {
            let candidate = senders.element(boundBy: index)
            guard candidate.isHittable, !candidate.frame.isEmpty else { continue }
            candidate.press(forDuration: 5)
            guard menu.waitForExistence(timeout: 10) else { continue }
            if expectedPreview.waitForExistence(timeout: 2) {
                return
            }
            
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 2))
            sheet.swipeDown()
            XCTAssertTrue(menu.wait(for: \.exists, toEqual: false, timeout: 5))
        }
        
        XCTFail("Could not open the timeline menu for message marker \(marker).")
    }
    
    private func customEmojiButton(labelContaining label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
    }
    
    private func customEmojiMessages(in app: XCUIApplication) -> XCUIElementQuery {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "\u{FFFC}"))
    }
    
    private func waitForCustomEmojiMessages(count: Int, in app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= %d", count),
                                                    object: customEmojiMessages(in: app))
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
    
    func testLoginWithPassword() async throws {
        // Given the authentication flow.
        let app = Application.launch(.authenticationFlow)
        
        // Check the bug report flow works.
        try await verifyReportBugButton(app)
        
        // Splash Screen: Tap get started button
        app.buttons[A11yIdentifiers.authenticationStartScreen.signIn].tap()
        
        // Server Selection: Clear the default, enter a server address and submit.
        // The \n triggers confirm directly, navigating to the login screen.
        app.textFields[A11yIdentifiers.changeServerScreen.server].clearAndTypeText("example.com\n", app: app)
        
        // Login Screen: Wait for continue button to appear
        let continueButton = app.buttons[A11yIdentifiers.loginScreen.continue]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2.0))
        
        // Login Screen: Enter valid credentials
        app.textFields[A11yIdentifiers.loginScreen.emailUsername].clearAndTypeText("alice\n", app: app)
        app.secureTextFields[A11yIdentifiers.loginScreen.password].clearAndTypeText("12345678", app: app)
        
        try await app.assertScreenshot()
        
        // Login Screen: Tap next
        app.buttons[A11yIdentifiers.loginScreen.continue].tap()
    }
    
    func testLoginWithIncorrectPassword() {
        // Given the authentication flow.
        let app = Application.launch(.authenticationFlow)
        
        // Splash Screen: Tap get started button
        app.buttons[A11yIdentifiers.authenticationStartScreen.signIn].tap()
        
        // Server Selection: Clear the default, enter a server address and submit.
        // The \n triggers confirm directly, navigating to the login screen.
        app.textFields[A11yIdentifiers.changeServerScreen.server].clearAndTypeText("example.com\n", app: app)
        
        // Login Screen: Wait for continue button to appear
        let continueButton = app.buttons[A11yIdentifiers.loginScreen.continue]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2.0))
        
        // Login Screen: Enter invalid credentials
        app.textFields[A11yIdentifiers.loginScreen.emailUsername].clearAndTypeText("alice", app: app)
        app.secureTextFields[A11yIdentifiers.loginScreen.password].clearAndTypeText("87654321", app: app)
        
        // Login Screen: Tap continue
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()
        
        // Then login should fail.
        XCTAssertTrue(app.alerts.element.waitForExistence(timeout: 2.0), "An error alert should be shown when attempting login with invalid credentials.")
    }
    
    func testLoginWithUnsupportedUserID() async throws {
        // Given the authentication flow.
        let app = Application.launch(.authenticationFlow)
        
        // Splash Screen: Tap get started button
        app.buttons[A11yIdentifiers.authenticationStartScreen.signIn].tap()
        
        // Server Selection: Clear the default, enter a server address and submit.
        // The \n triggers confirm directly, navigating to the login screen.
        app.textFields[A11yIdentifiers.changeServerScreen.server].clearAndTypeText("example.com\n", app: app)
        
        // Login Screen: Wait for continue button to appear
        let continueButton = app.buttons[A11yIdentifiers.loginScreen.continue]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2.0))
        
        // When entering a username on a homeserver with an unsupported flow.
        app.textFields[A11yIdentifiers.loginScreen.emailUsername].clearAndTypeText("@test:server.net\n", app: app)
        
        // Then the screen should not allow login to continue.
        try await app.assertScreenshot()
    }
    
    // periphery:ignore - might be useful to have
    /// Disabled for now as the looping isn't 100% fool-proof and we have OAuth on the integration tests
    /// so this mock version doesn't really add anything to the tests as a whole.
    func disabled_testSelectingOAuthServer() {
        // Allow this test to run for longer to help with the loop whilst waiting to resolve the
        // webcredentials for the Web Authentication Session (see below).
        executionTimeAllowance = 300
        
        // Given the authentication flow.
        let app = Application.launch(.authenticationFlow)
        
        // Splash Screen: Tap get started button
        app.buttons[A11yIdentifiers.authenticationStartScreen.signIn].tap()
        
        // Server Selection: Clear the default, enter OAuth server and continue.
        app.textFields[A11yIdentifiers.changeServerScreen.server].clearAndTypeText("company.com\n", app: app)
        
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let wasAlertText = springboard.staticTexts["“ElementX” Wants to Use “company.com” to Sign In"]
        
        // On a fresh simulator the webcredentials association is sometimes slow to be resolved.
        // This results in an error alert being shown instead of the Web Authentication Session alert.
        // Keep looping on the Continue button for ~5 minutes until the Authentication Session is happy.
        var remainingAttempts = 30
        while !wasAlertText.exists {
            // Server Selection: Tap continue button
            app.buttons[A11yIdentifiers.changeServerScreen.continue].tap()
            
            if wasAlertText.waitForExistence(timeout: 10) {
                break
            }
            
            remainingAttempts -= 1
            if remainingAttempts <= 0 {
                XCTFail("Failed to present the web authentication session.")
            }
            
            if app.alerts.count > 0 {
                app.alerts.firstMatch.buttons["OK"].tap()
            }
        }
        
        XCTAssertTrue(wasAlertText.exists, "The web authentication prompt should be shown after selecting a homeserver with OAuth.")
    }
    
    func testProvisionedLoginWithPassword() async throws {
        // Given a provisioned authentication flow.
        let app = Application.launch(.provisionedAuthenticationFlow)
        
        // Then the start screen should be configured appropriately.
        try await app.assertScreenshot()
        
        // Check the bug report flow works.
        try await verifyReportBugButton(app)
        
        // Splash Screen: Tap get started button
        app.buttons[A11yIdentifiers.authenticationStartScreen.signIn].tap()
        
        // No server selection should be shown here
        
        // Login Screen: Wait for continue button to appear
        let continueButton = app.buttons[A11yIdentifiers.loginScreen.continue]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2.0))
        
        // Login Screen: Enter valid credentials
        app.textFields[A11yIdentifiers.loginScreen.emailUsername].clearAndTypeText("alice\n", app: app)
        app.secureTextFields[A11yIdentifiers.loginScreen.password].clearAndTypeText("12345678", app: app)
        
        // Login Screen: Tap next
        app.buttons[A11yIdentifiers.loginScreen.continue].tap()
    }
    
    func testSingleProviderLoginWithPassword() async throws {
        // Given the authentication flow with a single supported server.
        let app = Application.launch(.singleProviderAuthenticationFlow)
        
        // Then the start screen should be configured appropriately.
        try await app.assertScreenshot()
        
        // Check the bug report flow works.
        try await verifyReportBugButton(app)
        
        // Splash Screen: Tap get started button
        app.buttons[A11yIdentifiers.authenticationStartScreen.signIn].tap()
        
        // No server selection should be shown here
        
        // Login Screen: Wait for continue button to appear
        let continueButton = app.buttons[A11yIdentifiers.loginScreen.continue]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2.0))
        
        // Login Screen: Enter valid credentials
        app.textFields[A11yIdentifiers.loginScreen.emailUsername].clearAndTypeText("alice\n", app: app)
        app.secureTextFields[A11yIdentifiers.loginScreen.password].clearAndTypeText("12345678", app: app)
        
        // Login Screen: Tap next
        app.buttons[A11yIdentifiers.loginScreen.continue].tap()
    }
    
    func testMultipleProvidersLoginWithPassword() async throws {
        // Given the authentication flow with only 2 allowed servers.
        let app = Application.launch(.multipleProvidersAuthenticationFlow)
        
        // Then the start screen should be configured appropriately.
        try await app.assertScreenshot()
        
        // Splash Screen: Tap get started button
        app.buttons[A11yIdentifiers.authenticationStartScreen.signIn].tap()
        
        // Server Selection: Tap the second server in the picker and confirm.
        // Use descendants(matching: .any) since ListRow used outside a List produces an ambiguous
        // accessibility element type, making element-type-specific queries unreliable.
        app.descendants(matching: .any).matching(identifier: "example.com").firstMatch.tap()
        app.buttons[A11yIdentifiers.changeServerScreen.continue].tap()
        
        // Login Screen: Wait for continue button to appear
        let continueButton = app.buttons[A11yIdentifiers.loginScreen.continue]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2.0))
        
        // Login Screen: Enter valid credentials
        app.textFields[A11yIdentifiers.loginScreen.emailUsername].clearAndTypeText("alice\n", app: app)
        app.secureTextFields[A11yIdentifiers.loginScreen.password].clearAndTypeText("12345678", app: app)
        
        // Login Screen: Tap next
        app.buttons[A11yIdentifiers.loginScreen.continue].tap()
    }
    
    func verifyReportBugButton(_ app: XCUIApplication) async throws {
        // Splash Screen: Tap the version 7 times to report a problem
        app.staticTexts[A11yIdentifiers.authenticationStartScreen.appVersion].tap(withNumberOfTaps: 7, numberOfTouches: 1)
        
        // Bug report: Make sure it exists then cancel.
        XCTAssert(app.textFields[A11yIdentifiers.bugReportScreen.report].exists)
        app.buttons[A11yIdentifiers.bugReportScreen.cancel].tap()
    }
}
