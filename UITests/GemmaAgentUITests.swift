import XCTest

final class GemmaAgentUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // DEBUG-only scripted model keeps UI tests fast and deterministic;
        // clean conversation so tests don't inherit persisted chats
        app.launchArguments += ["-scripted_model", "YES", "-reset_conversation", "YES", "-reset_connectors", "YES", "-reset_privacy", "YES", "-reset_workflows", "YES"]
        app.launch()
        return app
    }

    // MARK: - Launch

    func testLaunchShowsChatScreenAndModelLoads() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["GemmaAgent"].waitForExistence(timeout: 10))

        // Mock model loads after ~0.5s and posts a system message
        let loaded = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Model loaded'")
        ).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 10))
    }

    // MARK: - Settings

    func testSettingsOpensAndDismisses() {
        let app = launchApp()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Gemini API Key"].exists)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["GemmaAgent"].waitForExistence(timeout: 5))
    }

    private func openSettingsRow(_ app: XCUIApplication, _ identifier: String) {
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let row = app.buttons[identifier]
        var tries = 0
        while !row.exists && tries < 8 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "row \(identifier) not found")
        row.tap()
    }

    func testWorkflowsScreenOpens() {
        let app = launchApp()
        openSettingsRow(app, "workflowsRow")
        XCTAssertTrue(app.navigationBars["Workflows"].waitForExistence(timeout: 5))
    }

    func testWorkflowsCreateAndRun() {
        let app = launchApp()
        openSettingsRow(app, "workflowsRow")
        XCTAssertTrue(app.navigationBars["Workflows"].waitForExistence(timeout: 5))

        // Create a workflow.
        app.buttons["addWorkflowButton"].tap()
        let nameField = app.textFields["workflowNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Say hello")

        // A vertical-axis TextField may surface as a textView or textField.
        let promptField = app.textViews["workflowPromptField"].exists
            ? app.textViews["workflowPromptField"]
            : app.textFields["workflowPromptField"]
        XCTAssertTrue(promptField.waitForExistence(timeout: 5))
        promptField.tap()
        promptField.typeText("say hello to the world")

        app.buttons["saveWorkflowButton"].tap()

        // The new workflow appears with a Run button; run it.
        let runButton = app.buttons.matching(identifier: "runWorkflowButton").firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 5))
        runButton.tap()

        // Back to the chat: pop Workflows → Settings, then dismiss the sheet.
        app.navigationBars["Workflows"].buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        let reply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Scripted test response'")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "workflow run should produce a reply")
    }

    func testModelManagerOpensFromSettings() {
        let app = launchApp()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        let row = app.buttons["modelRow"]
        var tries = 0
        while !row.exists && tries < 8 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 5))
        // The recommended "Automatic" brain is always listed.
        XCTAssertTrue(app.staticTexts["Automatic"].waitForExistence(timeout: 5))
    }

    func testPrivacyLedgerScreenOpensFromSettings() {
        let app = launchApp()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // The Privacy row lives in a lower section; SwiftUI's Form realizes rows
        // lazily, so scroll it into view before tapping.
        let row = app.buttons["privacyRow"]
        var tries = 0
        while !row.exists && tries < 8 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // Fresh launch (-reset_privacy) → ledger is empty; the screen still appears.
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 5))
    }

    // MARK: - Full agent loop (mock mode)

    func testCalculatorAgentFlow() {
        let app = launchApp()

        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("calculate 12 * 8 + 5")

        app.buttons["sendButton"].tap()

        // Tool call card appears
        let toolCall = app.staticTexts["Tool Call"]
        XCTAssertTrue(toolCall.waitForExistence(timeout: 15), "tool call bubble should appear")

        // Tool result card appears
        let toolResult = app.staticTexts["Tool Result"]
        XCTAssertTrue(toolResult.waitForExistence(timeout: 15), "tool result bubble should appear")

        // Final assistant answer references the computed value (101)
        let answer = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '101'")
        ).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "final answer should contain the result")
    }

    // MARK: - Real model smoke test (opt-in: slow, needs the bundled model)
    // Run with: TEST_RUNNER_REAL_MODEL_TEST=1 xcodebuild ... test

    func testRealModelAnswersQuestion() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["REAL_MODEL_TEST"] == "1",
            "Set REAL_MODEL_TEST=1 to run the real-model smoke test"
        )
        let app = XCUIApplication() // no mock launch argument — real model
        app.launchArguments += ["-reset_conversation", "YES"] // clean slate
        app.launch()

        let loaded = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Model loaded'")
        ).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 240), "model should load")

        let field = app.textFields["messageField"]
        field.tap()
        field.typeText("What is the capital of France? Answer in one word.")
        app.buttons["sendButton"].tap()

        // The user message doesn't contain "Paris", so a match means the model answered
        // Generous budget: the simulator runs the engine CPU-only, and the
        // agent prompt prefill alone takes minutes there (fast on devices)
        let answer = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Paris'")
        ).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 600), "real model should answer with Paris")
    }

    // MARK: - Session verification drivers
    // Drive the real UI for the features built this session and capture
    // screenshots as attachments (run with -resultBundlePath, then export).

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Verifies the hierarchical Planner→sub-agents→Critic pipeline end-to-end
    /// in the running app (scripted model drives the sentinels deterministically).
    /// Opt-in: a GUI verification driver, run explicitly (not in the default suite,
    /// where heavy drivers flake under load). Run with TEST_RUNNER_VERIFY_DRIVERS=1.
    func testVerifyAgenticPipeline() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VERIFY_DRIVERS"] == "1",
                          "set TEST_RUNNER_VERIFY_DRIVERS=1 to run the GUI verification drivers")
        let app = launchApp()
        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("calculate 5 plus 5 and then calculate 6 plus 6 and then add them together")
        app.buttons["sendButton"].tap()

        // The pipeline's synthesis step produces this final answer.
        let answer = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'combined final answer'")
        ).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 40), "pipeline should synthesize a final answer")
        snapshot(app, "01-pipeline-final-answer")

        // Reveal the reasoning trace; confirm the Plan step is recorded.
        // (The glass-box timeline shows a "Plan" node title.)
        // Ensure the trace is visible — `show_reasoning` persists across launches,
        // so only tap the toggle when the trace isn't already on screen.
        if !app.staticTexts["Agent Reasoning Trace"].waitForExistence(timeout: 1),
           app.buttons["traceToggle"].exists {
            app.buttons["traceToggle"].tap()
        }
        // The timeline node text is merged into the row's button label, so search
        // all element types, not just staticTexts.
        let plan = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Plan'")
        ).firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 10), "trace should show the plan")
        snapshot(app, "02-pipeline-trace")
    }

    /// Verifies the Settings → Connectors UI renders and is interactive. Opt-in
    /// GUI driver (see testVerifyAgenticPipeline). Run with TEST_RUNNER_VERIFY_DRIVERS=1.
    func testVerifyConnectorsUI() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VERIFY_DRIVERS"] == "1",
                          "set TEST_RUNNER_VERIFY_DRIVERS=1 to run the GUI verification drivers")
        let app = launchApp()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        let row = app.buttons["connectorsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Connectors row should exist in Settings")
        row.tap()
        XCTAssertTrue(app.navigationBars["Connectors"].waitForExistence(timeout: 5))
        snapshot(app, "03-connectors-screen")

        // Turn on app launching (gated capability).
        let toggle = app.switches["appLaunchToggle"]
        if toggle.waitForExistence(timeout: 5) { toggle.tap() }
        snapshot(app, "04-connectors-applaunch-on")

        // Open the Add MCP Server sheet.
        let addMCP = app.buttons["addMCPServer"]
        if addMCP.waitForExistence(timeout: 5) {
            addMCP.tap()
            XCTAssertTrue(app.navigationBars["Add MCP Server"].waitForExistence(timeout: 5))
            snapshot(app, "05-add-mcp-server")
        }
    }

    /// Captures the surfaces built across the roadmap steps: the per-turn privacy
    /// chip (Step 1), the Model Manager (Step 2), the Privacy Ledger (Step 1), and
    /// Workflows (Step 3). Run with TEST_RUNNER_VERIFY_DRIVERS=1.
    func testVerifyReachAndModelScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VERIFY_DRIVERS"] == "1",
                          "set TEST_RUNNER_VERIFY_DRIVERS=1 to run the GUI verification drivers")
        let app = launchApp()

        // A fully on-device turn → the privacy chip reads "0 bytes left this device".
        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap(); field.typeText("say hello")
        app.buttons["sendButton"].tap()
        let reply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Scripted test response'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 25), "scripted reply should appear")
        _ = app.buttons["privacyChip"].waitForExistence(timeout: 5)
        snapshot(app, "11-privacy-chip")

        // Bidirectional scroll — rows live in different sections, so search
        // down then up to locate one regardless of the current scroll position.
        func scrollTo(_ id: String) -> XCUIElement {
            let el = app.buttons[id]
            var t = 0
            while !el.exists && t < 6 { app.swipeUp(); t += 1 }
            t = 0
            while !el.exists && t < 8 { app.swipeDown(); t += 1 }
            return el
        }

        // Visit top-to-bottom: Model → Workflows → Privacy.
        // Step 2 — Model Manager (any model, incl. Apple's on-device).
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        scrollTo("modelRow").tap()
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 5))
        snapshot(app, "12-model-manager")
        app.navigationBars["Model"].buttons.element(boundBy: 0).tap()

        // Step 3 — Workflows: create one, capture the editor and the list.
        scrollTo("workflowsRow").tap()
        XCTAssertTrue(app.navigationBars["Workflows"].waitForExistence(timeout: 5))
        app.buttons["addWorkflowButton"].tap()
        let nameField = app.textFields["workflowNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap(); nameField.typeText("Morning briefing")
        let promptField = app.textViews["workflowPromptField"].exists
            ? app.textViews["workflowPromptField"] : app.textFields["workflowPromptField"]
        promptField.tap(); promptField.typeText("summarize my unread mail and today's calendar")
        snapshot(app, "14-workflow-editor")
        app.buttons["saveWorkflowButton"].tap()
        snapshot(app, "15-workflows-list")

        // Step 1 — Privacy Ledger (lower in Settings).
        app.navigationBars["Workflows"].buttons.element(boundBy: 0).tap()
        scrollTo("privacyRow").tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(timeout: 5))
        snapshot(app, "13-privacy-ledger")
    }

    /// Verifies the catalog (real no-auth connect), deferred OAuth (no launch
    /// sheet; "Sign in required"), and live registry browse. Hits real public
    /// endpoints (DeepWiki + the MCP registry), so it's opt-in to keep the
    /// default suite deterministic. Run with TEST_RUNNER_LIVE_CONNECTOR_TEST=1.
    func testVerifyConnectorCatalogAndRegistry() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LIVE_CONNECTOR_TEST"] == "1",
            "set TEST_RUNNER_LIVE_CONNECTOR_TEST=1 to run the live catalog/registry test"
        )
        let app = launchApp()
        // App reaches chat with no OAuth sheet blocking it (deferred connect).
        XCTAssertTrue(app.navigationBars["GemmaAgent"].waitForExistence(timeout: 10))

        app.buttons["settingsButton"].tap()
        app.buttons["connectorsRow"].tap()
        XCTAssertTrue(app.navigationBars["Connectors"].waitForExistence(timeout: 5))

        // Catalog
        app.buttons["addFromCatalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 5))
        snapshot(app, "08-catalog")
        tapCatalog(app, "DeepWiki")   // no-auth → will connect for real
        tapCatalog(app, "Linear")     // OAuth → deferred
        app.navigationBars["Catalog"].buttons.element(boundBy: 0).tap()

        // DeepWiki connects (real MCP, no auth); Linear stays deferred.
        let connected = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'tool'")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 25), "no-auth catalog server should connect")
        let needsSignIn = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Sign in required'")).firstMatch
        XCTAssertTrue(needsSignIn.waitForExistence(timeout: 10), "OAuth server should defer to Sign in")
        snapshot(app, "09-catalog-added")

        // Registry browse loads live entries.
        app.buttons["browseRegistry"].tap()
        XCTAssertTrue(app.navigationBars["Registry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 25), "registry should return entries")
        snapshot(app, "10-registry")
    }

    private func tapCatalog(_ app: XCUIApplication, _ name: String) {
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(name) catalog row should exist")
        button.tap()
    }

    /// Connects the running app to a REAL MCP server (HTTPS) and exercises a
    /// genuine initialize → tools/list → tools/call round-trip.
    /// Run with: TEST_RUNNER_MCP_TEST_URL=https://<host>/mcp xcodebuild ... test
    func testVerifyRealMCP() throws {
        let endpoint = ProcessInfo.processInfo.environment["MCP_TEST_URL"] ?? ""
        try XCTSkipUnless(!endpoint.isEmpty, "set TEST_RUNNER_MCP_TEST_URL to the MCP server URL")

        let app = launchApp()

        // Settings → Connectors → Add MCP Server
        app.buttons["settingsButton"].tap()
        app.buttons["connectorsRow"].tap()
        XCTAssertTrue(app.navigationBars["Connectors"].waitForExistence(timeout: 5))
        app.buttons["addMCPServer"].tap()

        let name = app.textFields["mcpNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Verify")
        let url = app.textFields["mcpEndpointField"]
        url.tap(); url.typeText(endpoint)
        app.buttons["Add"].tap()

        // Real initialize + tools/list round-trip → status shows discovered tools.
        let connected = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'tool'")
        ).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 25), "server should connect and report tools")
        snapshot(app, "06-mcp-connected")

        // Back to chat.
        app.navigationBars["Connectors"].buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()

        // Trigger a genuine tools/call via the agent. The arithmetic routes the
        // request to the on-device agent loop (tools available); "mcp" makes the
        // scripted model pick the discovered MCP tool — the call itself is real.
        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("calculate 2 + 2 using mcp")
        app.buttons["sendButton"].tap()

        let pong = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'pong from the real MCP server'")
        ).firstMatch
        let appeared = pong.waitForExistence(timeout: 30)
        snapshot(app, "07-mcp-tool-result")
        XCTAssertTrue(appeared, "real MCP tools/call result should appear in chat")
    }

    func testClearConversationEmptiesChat() {
        let app = launchApp()

        let field = app.textFields["messageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("hello")
        app.buttons["sendButton"].tap()

        // Wait for the scripted local answer
        let reply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Scripted test response'")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))

        app.buttons["clearButton"].tap()

        // Empty state returns
        XCTAssertTrue(app.staticTexts["GemmaAgent"].waitForExistence(timeout: 5))
        XCTAssertFalse(reply.exists)
    }
}
