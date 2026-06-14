#!/usr/bin/env python3
"""
Generates GemmaAgent.xcodeproj for the GemmaAgent iOS app.
Run from the IOSApp directory: python3 generate_xcodeproj.py
"""

import os
import uuid
import json

# ── Deterministic UUIDs so re-running produces the same file ──────────────────
_counter = [0]
def U():
    _counter[0] += 1
    return f"{_counter[0]:024X}"

# ── File list ──────────────────────────────────────────────────────────────────
SOURCE_ROOT = os.path.dirname(os.path.abspath(__file__))

SWIFT_FILES = [
    # (display_name, path_relative_to_SOURCE_ROOT)
    ("GeminiClient.swift",          "Sources/GemmaAgent/API/GeminiClient.swift"),
    ("GeminiModels.swift",          "Sources/GemmaAgent/API/GeminiModels.swift"),
    ("AgentMessage.swift",          "Sources/GemmaAgent/Agent/AgentMessage.swift"),
    ("AgentOrchestrator.swift",     "Sources/GemmaAgent/Agent/AgentOrchestrator.swift"),
    ("AgentState.swift",            "Sources/GemmaAgent/Agent/AgentState.swift"),
    ("ConversationWindow.swift",    "Sources/GemmaAgent/Agent/ConversationWindow.swift"),
    ("MemoryStore.swift",           "Sources/GemmaAgent/Agent/MemoryStore.swift"),
    ("MessageRouter.swift",         "Sources/GemmaAgent/Agent/MessageRouter.swift"),
    ("ModelClassifier.swift",       "Sources/GemmaAgent/Agent/ModelClassifier.swift"),
    ("TaskClassifier.swift",        "Sources/GemmaAgent/Agent/TaskClassifier.swift"),
    ("RoutingDecision.swift",       "Sources/GemmaAgent/Agent/RoutingDecision.swift"),
    ("PlanModels.swift",            "Sources/GemmaAgent/Agent/PlanModels.swift"),
    ("Planner.swift",               "Sources/GemmaAgent/Agent/Planner.swift"),
    ("Critic.swift",                "Sources/GemmaAgent/Agent/Critic.swift"),
    ("PlanGate.swift",              "Sources/GemmaAgent/Agent/PlanGate.swift"),
    ("PlanPipeline.swift",          "Sources/GemmaAgent/Agent/PlanPipeline.swift"),
    ("PrivacyLedger.swift",         "Sources/GemmaAgent/Agent/PrivacyLedger.swift"),
    ("AskGemmaIntent.swift",        "Sources/GemmaAgent/App/AskGemmaIntent.swift"),
    ("ContentView.swift",           "Sources/GemmaAgent/App/ContentView.swift"),
    ("GemmaAgentApp.swift",         "Sources/GemmaAgent/App/GemmaAgentApp.swift"),
    ("GemmaModel.swift",            "Sources/GemmaAgent/Models/GemmaModel.swift"),
    ("GemmaTokenizer.swift",        "Sources/GemmaAgent/Models/GemmaTokenizer.swift"),
    ("LiteRTGemmaModel.swift",      "Sources/GemmaAgent/Models/LiteRTGemmaModel.swift"),
    ("FoundationModelBackend.swift","Sources/GemmaAgent/Models/FoundationModelBackend.swift"),
    ("ModelCatalog.swift",          "Sources/GemmaAgent/Models/ModelCatalog.swift"),
    ("ModelManager.swift",          "Sources/GemmaAgent/Models/ModelManager.swift"),
    ("ModelConfig.swift",           "Sources/GemmaAgent/Models/ModelConfig.swift"),
    ("ScriptedModel.swift",         "Sources/GemmaAgent/Models/ScriptedModel.swift"),
    ("Tokenizer.swift",             "Sources/GemmaAgent/Models/Tokenizer.swift"),
    ("CalculatorTool.swift",        "Sources/GemmaAgent/Tools/BuiltinTools/CalculatorTool.swift"),
    ("EscalateToGeminiTool.swift",  "Sources/GemmaAgent/Tools/BuiltinTools/EscalateToGeminiTool.swift"),
    ("WebSearchTool.swift",         "Sources/GemmaAgent/Tools/BuiltinTools/WebSearchTool.swift"),
    ("DateTimeTool.swift",          "Sources/GemmaAgent/Tools/BuiltinTools/DateTimeTool.swift"),
    ("UnitConverterTool.swift",     "Sources/GemmaAgent/Tools/BuiltinTools/UnitConverterTool.swift"),
    ("ToolDateParsing.swift",       "Sources/GemmaAgent/Tools/BuiltinTools/ToolDateParsing.swift"),
    ("RemindersTool.swift",         "Sources/GemmaAgent/Tools/BuiltinTools/RemindersTool.swift"),
    ("CalendarTool.swift",          "Sources/GemmaAgent/Tools/BuiltinTools/CalendarTool.swift"),
    ("ContactsTool.swift",          "Sources/GemmaAgent/Tools/BuiltinTools/ContactsTool.swift"),
    ("Tool.swift",                  "Sources/GemmaAgent/Tools/Tool.swift"),
    ("ToolRegistry.swift",          "Sources/GemmaAgent/Tools/ToolRegistry.swift"),
    ("AgentTraceView.swift",        "Sources/GemmaAgent/UI/AgentTraceView.swift"),
    ("ChatView.swift",              "Sources/GemmaAgent/UI/ChatView.swift"),
    ("MemoryView.swift",            "Sources/GemmaAgent/UI/MemoryView.swift"),
    ("MessageBubble.swift",         "Sources/GemmaAgent/UI/MessageBubble.swift"),
    ("ModelManagerView.swift",      "Sources/GemmaAgent/UI/ModelManagerView.swift"),
    ("PrivacyView.swift",           "Sources/GemmaAgent/UI/PrivacyView.swift"),
    ("SettingsView.swift",          "Sources/GemmaAgent/UI/SettingsView.swift"),
    ("JSONSchema.swift",            "Sources/GemmaAgent/Utilities/JSONSchema.swift"),
    ("KeychainStore.swift",         "Sources/GemmaAgent/Utilities/KeychainStore.swift"),
    ("StreamParser.swift",          "Sources/GemmaAgent/Utilities/StreamParser.swift"),
    ("ConversationStore.swift",     "Sources/GemmaAgent/Utilities/ConversationStore.swift"),
    ("PIISanitizer.swift",          "Sources/GemmaAgent/Utilities/PIISanitizer.swift"),
    ("SessionContextTracker.swift", "Sources/GemmaAgent/Utilities/SessionContextTracker.swift"),
    ("SpeechRecognizer.swift",      "Sources/GemmaAgent/Utilities/SpeechRecognizer.swift"),
    ("StreamStopFilter.swift",      "Sources/GemmaAgent/Utilities/StreamStopFilter.swift"),
    ("ConnectorConfig.swift",       "Sources/GemmaAgent/Connectors/ConnectorConfig.swift"),
    ("ConnectorManager.swift",      "Sources/GemmaAgent/Connectors/ConnectorManager.swift"),
    ("MCPToolProxy.swift",          "Sources/GemmaAgent/Connectors/MCPToolProxy.swift"),
    ("MCPConnection.swift",         "Sources/GemmaAgent/Connectors/MCPConnection.swift"),
    ("RESTConnectorTool.swift",     "Sources/GemmaAgent/Connectors/RESTConnectorTool.swift"),
    ("AppLauncherTool.swift",       "Sources/GemmaAgent/Connectors/AppLauncherTool.swift"),
    ("MCPOAuth.swift",              "Sources/GemmaAgent/Connectors/MCPOAuth.swift"),
    ("MCPCatalog.swift",            "Sources/GemmaAgent/Connectors/MCPCatalog.swift"),
    ("MCPRegistryClient.swift",     "Sources/GemmaAgent/Connectors/MCPRegistryClient.swift"),
    ("UCPDiscovery.swift",          "Sources/GemmaAgent/Connectors/UCPDiscovery.swift"),
    ("ConnectorsView.swift",        "Sources/GemmaAgent/UI/ConnectorsView.swift"),
    ("WorkflowsView.swift",         "Sources/GemmaAgent/UI/WorkflowsView.swift"),
    ("AppGroupStore.swift",         "Sources/GemmaAgent/Workflows/AppGroupStore.swift"),
    ("Workflow.swift",              "Sources/GemmaAgent/Workflows/Workflow.swift"),
    ("WorkflowStore.swift",         "Sources/GemmaAgent/Workflows/WorkflowStore.swift"),
    ("InboxStore.swift",            "Sources/GemmaAgent/Workflows/InboxStore.swift"),
    ("WorkflowEntity.swift",        "Sources/GemmaAgent/Workflows/WorkflowEntity.swift"),
    ("RunWorkflowIntent.swift",     "Sources/GemmaAgent/Workflows/RunWorkflowIntent.swift"),
    ("WorkflowManager.swift",       "Sources/GemmaAgent/Workflows/WorkflowManager.swift"),
]

TEST_FILES = [
    ("CalculatorToolTests.swift",   "Tests/GemmaAgentTests/CalculatorToolTests.swift"),
    ("ResponseParserTests.swift",   "Tests/GemmaAgentTests/ResponseParserTests.swift"),
    ("GemmaTokenizerTests.swift",   "Tests/GemmaAgentTests/GemmaTokenizerTests.swift"),
    ("LiteRTEngineTests.swift",     "Tests/GemmaAgentTests/LiteRTEngineTests.swift"),
    ("StreamStopFilterTests.swift", "Tests/GemmaAgentTests/StreamStopFilterTests.swift"),
    ("AgentOrchestratorTests.swift","Tests/GemmaAgentTests/AgentOrchestratorTests.swift"),
    ("KeychainStoreTests.swift",    "Tests/GemmaAgentTests/KeychainStoreTests.swift"),
    ("MemoryStoreTests.swift",      "Tests/GemmaAgentTests/MemoryStoreTests.swift"),
    ("StreamParserTests.swift",     "Tests/GemmaAgentTests/StreamParserTests.swift"),
    ("GenerationConfigTests.swift", "Tests/GemmaAgentTests/GenerationConfigTests.swift"),
    ("MessageRouterTests.swift",    "Tests/GemmaAgentTests/MessageRouterTests.swift"),
    ("ClassifierEvalTests.swift",   "Tests/GemmaAgentTests/ClassifierEvalTests.swift"),
    ("ClassifierTests.swift",       "Tests/GemmaAgentTests/ClassifierTests.swift"),
    ("PIISanitizerTests.swift",     "Tests/GemmaAgentTests/PIISanitizerTests.swift"),
    ("ConversationWindowTests.swift","Tests/GemmaAgentTests/ConversationWindowTests.swift"),
    ("SessionContextTrackerTests.swift","Tests/GemmaAgentTests/SessionContextTrackerTests.swift"),
    ("ScriptedModelTests.swift",    "Tests/GemmaAgentTests/ScriptedModelTests.swift"),
    ("ChatTemplateTests.swift",     "Tests/GemmaAgentTests/ChatTemplateTests.swift"),
    ("JSONValueTests.swift",        "Tests/GemmaAgentTests/JSONValueTests.swift"),
    ("QueuedMockModel.swift",       "Tests/GemmaAgentTests/QueuedMockModel.swift"),
    ("PlanParserTests.swift",       "Tests/GemmaAgentTests/PlanParserTests.swift"),
    ("PlanGateTests.swift",         "Tests/GemmaAgentTests/PlanGateTests.swift"),
    ("PlannerTests.swift",          "Tests/GemmaAgentTests/PlannerTests.swift"),
    ("CriticTests.swift",           "Tests/GemmaAgentTests/CriticTests.swift"),
    ("PlanPipelineTests.swift",     "Tests/GemmaAgentTests/PlanPipelineTests.swift"),
    ("PrivacyLedgerTests.swift",    "Tests/GemmaAgentTests/PrivacyLedgerTests.swift"),
    ("ModelManagerTests.swift",     "Tests/GemmaAgentTests/ModelManagerTests.swift"),
    ("WorkflowTests.swift",         "Tests/GemmaAgentTests/WorkflowTests.swift"),
    ("DateTimeToolTests.swift",     "Tests/GemmaAgentTests/DateTimeToolTests.swift"),
    ("UnitConverterToolTests.swift","Tests/GemmaAgentTests/UnitConverterToolTests.swift"),
    ("ConnectorConfigTests.swift",  "Tests/GemmaAgentTests/ConnectorConfigTests.swift"),
    ("MCPToolProxyTests.swift",     "Tests/GemmaAgentTests/MCPToolProxyTests.swift"),
    ("RESTConnectorToolTests.swift","Tests/GemmaAgentTests/RESTConnectorToolTests.swift"),
    ("AppLauncherToolTests.swift",  "Tests/GemmaAgentTests/AppLauncherToolTests.swift"),
    ("ConnectorManagerTests.swift", "Tests/GemmaAgentTests/ConnectorManagerTests.swift"),
    ("ToolRegistryTests.swift",     "Tests/GemmaAgentTests/ToolRegistryTests.swift"),
    ("MCPAuthMigrationTests.swift", "Tests/GemmaAgentTests/MCPAuthMigrationTests.swift"),
    ("JSONKeychainBoxTests.swift",  "Tests/GemmaAgentTests/JSONKeychainBoxTests.swift"),
    ("MCPCatalogTests.swift",       "Tests/GemmaAgentTests/MCPCatalogTests.swift"),
    ("MCPRegistryClientTests.swift","Tests/GemmaAgentTests/MCPRegistryClientTests.swift"),
    ("UCPDiscoveryTests.swift",     "Tests/GemmaAgentTests/UCPDiscoveryTests.swift"),
]

UITEST_FILES = [
    ("GemmaAgentUITests.swift",     "UITests/GemmaAgentUITests.swift"),
]

# Optional model resources — included only when present on disk.
# gemma4b.mlpackage goes in the Sources phase (Xcode compiles it to .mlmodelc);
# tokenizer.json goes in the Resources phase.
MODEL_PACKAGE_PATH = "GemmaAgent/gemma4b.mlpackage"
TOKENIZER_PATH = "GemmaAgent/tokenizer.json"
LITERT_MODEL_PATH = "GemmaAgent/gemma4e4b.litertlm"

def has_model():
    return os.path.exists(os.path.join(SOURCE_ROOT, MODEL_PACKAGE_PATH))

def has_tokenizer():
    return os.path.exists(os.path.join(SOURCE_ROOT, TOKENIZER_PATH))

def has_litert_model():
    return os.path.exists(os.path.join(SOURCE_ROOT, LITERT_MODEL_PATH))

# Assign UUIDs
uids = {}

# Project-level
uids["PROJECT"]         = U()
uids["TARGET"]          = U()
uids["PRODUCT_APP"]     = U()
uids["TARGET_TESTS"]    = U()
uids["PRODUCT_TESTS"]   = U()
uids["TARGET_UITESTS"]  = U()
uids["PRODUCT_UITESTS"] = U()

# File references & build files
for name, _ in SWIFT_FILES + TEST_FILES + UITEST_FILES:
    uids[f"FR_{name}"]  = U()
    uids[f"BF_{name}"]  = U()

uids["FR_Assets"]       = U()
uids["BF_Assets"]       = U()  # goes in Resources phase
uids["FR_Privacy"]      = U()
uids["BF_Privacy"]      = U()  # PrivacyInfo.xcprivacy — Resources phase (always present)
uids["FR_Model"]        = U()
uids["BF_Model"]        = U()  # goes in Sources phase (coremlc compiles it)
uids["FR_Tokenizer"]    = U()
uids["BF_Tokenizer"]    = U()  # goes in Resources phase
uids["FR_LiteRT"]       = U()
uids["BF_LiteRT"]       = U()  # goes in Resources phase

# Groups
uids["GR_Root"]         = U()
uids["GR_Products"]     = U()
uids["GR_Sources"]      = U()
uids["GR_API"]          = U()
uids["GR_Agent"]        = U()
uids["GR_App"]          = U()
uids["GR_Models"]       = U()
uids["GR_Tools"]        = U()
uids["GR_BuiltinTools"] = U()
uids["GR_UI"]           = U()
uids["GR_Utilities"]    = U()
uids["GR_Connectors"]   = U()
uids["GR_Workflows"]    = U()
uids["GR_Resources"]    = U()

# Swift Package Manager: the official MCP SDK (app target only)
uids["PKG_MCP"]         = U()  # XCRemoteSwiftPackageReference
uids["PRODDEP_MCP"]     = U()  # XCSwiftPackageProductDependency (product "MCP")
uids["BF_MCP"]          = U()  # PBXBuildFile linking the product in app Frameworks

# AppIntents.framework — explicit link so the App Intents metadata processor
# runs and the "Ask Gemma" App Shortcut registers with Siri/Spotlight.
uids["FR_AppIntents"]   = U()
uids["BF_AppIntents"]   = U()

# Build phases
uids["PHASE_Sources"]    = U()
uids["PHASE_Resources"]  = U()
uids["PHASE_Frameworks"] = U()
uids["PHASE_TestsSources"]      = U()
uids["PHASE_TestsFrameworks"]   = U()
uids["PHASE_UITestsSources"]    = U()
uids["PHASE_UITestsFrameworks"] = U()

# Build configurations
uids["BC_ProjDebug"]    = U()
uids["BC_ProjRelease"]  = U()
uids["BC_TgtDebug"]     = U()
uids["BC_TgtRelease"]   = U()
uids["BC_TestsDebug"]     = U()
uids["BC_TestsRelease"]   = U()
uids["BC_UITestsDebug"]   = U()
uids["BC_UITestsRelease"] = U()

# Config lists
uids["CL_Project"]      = U()
uids["CL_Target"]       = U()
uids["CL_Tests"]        = U()
uids["CL_UITests"]      = U()

# Target dependencies (test targets depend on the app)
uids["PROXY_Tests"]     = U()
uids["DEP_Tests"]       = U()
uids["PROXY_UITests"]   = U()
uids["DEP_UITests"]     = U()

# Groups for tests
uids["GR_Tests"]        = U()
uids["GR_UITests"]      = U()

# ── App extensions (widget + share) ──────────────────────────────────────────
# The App Group all three targets share so the inbox + workflows are visible
# across processes.
APP_GROUP_ID = "group.com.gemmaagent.app"

# Files compiled into each extension target. Shared files reuse the app's
# FR_<name> file reference but get their OWN PBXBuildFile per target.
WIDGET_SHARED_FILES = ["Workflow.swift", "WorkflowStore.swift", "InboxStore.swift",
                       "AppGroupStore.swift", "WorkflowEntity.swift", "RunWorkflowIntent.swift"]
WIDGET_OWN_FILES = [("GemmaWidget.swift", "GemmaWidget/GemmaWidget.swift")]
SHARE_SHARED_FILES = ["InboxStore.swift", "AppGroupStore.swift"]
SHARE_OWN_FILES = [("ShareViewController.swift", "GemmaShare/ShareViewController.swift")]

# Own-file file references (extension-only sources)
for _n, _p in WIDGET_OWN_FILES + SHARE_OWN_FILES:
    uids[f"FR_{_n}"] = U()

# Widget target
uids["TARGET_W"]        = U()
uids["PRODUCT_W"]       = U()
uids["PHASE_W_Sources"]    = U()
uids["PHASE_W_Frameworks"] = U()
uids["PHASE_W_Resources"]  = U()
uids["CL_W"]            = U()
uids["BC_W_Debug"]      = U()
uids["BC_W_Release"]    = U()
uids["PROXY_W"]         = U()
uids["DEP_W"]           = U()
for _n in WIDGET_SHARED_FILES:
    uids[f"BF_W_{_n}"] = U()
for _n, _p in WIDGET_OWN_FILES:
    uids[f"BF_W_{_n}"] = U()

# Share target
uids["TARGET_S"]        = U()
uids["PRODUCT_S"]       = U()
uids["PHASE_S_Sources"]    = U()
uids["PHASE_S_Frameworks"] = U()
uids["PHASE_S_Resources"]  = U()
uids["CL_S"]            = U()
uids["BC_S_Debug"]      = U()
uids["BC_S_Release"]    = U()
uids["PROXY_S"]         = U()
uids["DEP_S"]           = U()
for _n in SHARE_SHARED_FILES:
    uids[f"BF_S_{_n}"] = U()
for _n, _p in SHARE_OWN_FILES:
    uids[f"BF_S_{_n}"] = U()

# Embed-App-Extensions copy phase on the app + its build files
uids["PHASE_EmbedExt"]  = U()
uids["BF_EmbedW"]       = U()
uids["BF_EmbedS"]       = U()

# Extension groups
uids["GR_Extensions"]   = U()
uids["GR_Widget"]       = U()
uids["GR_Share"]        = U()

# ── Helper ──────────────────────────────────────────────────────────────────
def lines(*args):
    return "\n".join(args)

def section(name, content):
    return f"\n/* Begin {name} section */\n{content}\n/* End {name} section */\n"

# ── Sections ──────────────────────────────────────────────────────────────────

def build_files_section():
    parts = []
    for name, path in SWIFT_FILES + TEST_FILES + UITEST_FILES:
        uid = uids[f"BF_{name}"]
        fr  = uids[f"FR_{name}"]
        parts.append(f"\t\t{uid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")
    # Assets in Resources
    # SwiftPM product link (productRef, NOT fileRef) — app Frameworks phase
    parts.append(f"\t\t{uids['BF_MCP']} /* MCP in Frameworks */ = {{isa = PBXBuildFile; productRef = {uids['PRODDEP_MCP']} /* MCP */; }};")
    parts.append(f"\t\t{uids['BF_AppIntents']} /* AppIntents.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {uids['FR_AppIntents']} /* AppIntents.framework */; }};")
    parts.append(f"\t\t{uids['BF_Assets']} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Assets']} /* Assets.xcassets */; }};")
    parts.append(f"\t\t{uids['BF_Privacy']} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Privacy']} /* PrivacyInfo.xcprivacy */; }};")
    if has_model():
        parts.append(f"\t\t{uids['BF_Model']} /* gemma4b.mlpackage in Sources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Model']} /* gemma4b.mlpackage */; }};")
    if has_tokenizer():
        parts.append(f"\t\t{uids['BF_Tokenizer']} /* tokenizer.json in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Tokenizer']} /* tokenizer.json */; }};")
    if has_litert_model():
        parts.append(f"\t\t{uids['BF_LiteRT']} /* gemma4e4b.litertlm in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_LiteRT']} /* gemma4e4b.litertlm */; }};")
    return section("PBXBuildFile", "\n".join(parts))

def file_references_section():
    parts = []
    for name, path in SWIFT_FILES + TEST_FILES + UITEST_FILES:
        uid = uids[f"FR_{name}"]
        parts.append(f"\t\t{uid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {name}; path = {path}; sourceTree = SOURCE_ROOT; }};")
    # Assets
    parts.append(f"\t\t{uids['FR_Assets']} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = Assets.xcassets; path = GemmaAgent/Assets.xcassets; sourceTree = SOURCE_ROOT; }};")
    parts.append(f"\t\t{uids['FR_Privacy']} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = PrivacyInfo.xcprivacy; path = GemmaAgent/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT; }};")
    if has_model():
        parts.append(f"\t\t{uids['FR_Model']} /* gemma4b.mlpackage */ = {{isa = PBXFileReference; lastKnownFileType = folder.mlpackage; name = gemma4b.mlpackage; path = {MODEL_PACKAGE_PATH}; sourceTree = SOURCE_ROOT; }};")
    if has_tokenizer():
        parts.append(f"\t\t{uids['FR_Tokenizer']} /* tokenizer.json */ = {{isa = PBXFileReference; lastKnownFileType = text.json; name = tokenizer.json; path = {TOKENIZER_PATH}; sourceTree = SOURCE_ROOT; }};")
    if has_litert_model():
        parts.append(f"\t\t{uids['FR_LiteRT']} /* gemma4e4b.litertlm */ = {{isa = PBXFileReference; lastKnownFileType = file; name = gemma4e4b.litertlm; path = {LITERT_MODEL_PATH}; sourceTree = SOURCE_ROOT; }};")
    # System frameworks
    parts.append(f"\t\t{uids['FR_AppIntents']} /* AppIntents.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = AppIntents.framework; path = System/Library/Frameworks/AppIntents.framework; sourceTree = SDKROOT; }};")
    # Products
    parts.append(f"\t\t{uids['PRODUCT_APP']} /* GemmaAgent.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = GemmaAgent.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    parts.append(f"\t\t{uids['PRODUCT_TESTS']} /* GemmaAgentTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = GemmaAgentTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};")
    parts.append(f"\t\t{uids['PRODUCT_UITESTS']} /* GemmaAgentUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = GemmaAgentUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};")
    return section("PBXFileReference", "\n".join(parts))

def container_item_proxy_section():
    def proxy(uid, remote_id, remote_name):
        return (
            f"\t\t{uid} /* PBXContainerItemProxy */ = {{\n"
            f"\t\t\tisa = PBXContainerItemProxy;\n"
            f"\t\t\tcontainerPortal = {uids['PROJECT']} /* Project object */;\n"
            f"\t\t\tproxyType = 1;\n"
            f"\t\t\tremoteGlobalIDString = {remote_id};\n"
            f"\t\t\tremoteInfo = {remote_name};\n"
            f"\t\t}};"
        )
    parts = [
        proxy(uids["PROXY_Tests"], uids["TARGET"], "GemmaAgent"),
        proxy(uids["PROXY_UITests"], uids["TARGET"], "GemmaAgent"),
    ]
    return section("PBXContainerItemProxy", "\n".join(parts))

def target_dependency_section():
    def dep(uid, proxy_uid):
        return (
            f"\t\t{uid} /* PBXTargetDependency */ = {{\n"
            f"\t\t\tisa = PBXTargetDependency;\n"
            f"\t\t\ttarget = {uids['TARGET']} /* GemmaAgent */;\n"
            f"\t\t\ttargetProxy = {proxy_uid} /* PBXContainerItemProxy */;\n"
            f"\t\t}};"
        )
    parts = [
        dep(uids["DEP_Tests"], uids["PROXY_Tests"]),
        dep(uids["DEP_UITests"], uids["PROXY_UITests"]),
    ]
    return section("PBXTargetDependency", "\n".join(parts))

def groups_section():
    def file_refs_for(folder):
        """Return FR UIDs for files in the given subfolder."""
        prefix = f"Sources/GemmaAgent/{folder}/"
        return [uids[f"FR_{n}"] for n, p in SWIFT_FILES if p.startswith(prefix)]

    def group(uid, name, children, path=None, source_tree="<group>"):
        children_str = "\n".join(f"\t\t\t\t{c}," for c in children)
        path_line = f"\t\t\tpath = {path};\n" if path else ""
        name_line = f"\t\t\tname = \"{name}\";\n"
        return (
            f"\t\t{uid} /* {name} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n{children_str}\n\t\t\t);\n"
            f"{name_line}"
            f"{path_line}"
            f"\t\t\tsourceTree = \"{source_tree}\";\n"
            f"\t\t}};"
        )

    parts = []

    # Root group
    root_children = [uids["GR_Sources"], uids["GR_Tests"], uids["GR_UITests"],
                     uids["GR_Extensions"], uids["GR_Resources"], uids["GR_Products"]]
    parts.append(group(uids["GR_Root"], "GemmaAgent", root_children))

    # Products
    parts.append(group(uids["GR_Products"], "Products",
                       [uids["PRODUCT_APP"], uids["PRODUCT_TESTS"], uids["PRODUCT_UITESTS"],
                        uids["PRODUCT_W"], uids["PRODUCT_S"]]))

    # Test groups
    parts.append(group(uids["GR_Tests"], "GemmaAgentTests", [uids[f"FR_{n}"] for n, _ in TEST_FILES]))
    parts.append(group(uids["GR_UITests"], "GemmaAgentUITests", [uids[f"FR_{n}"] for n, _ in UITEST_FILES]))

    # Resources
    resource_children = [uids["FR_Assets"], uids["FR_Privacy"]]
    if has_model():
        resource_children.append(uids["FR_Model"])
    if has_tokenizer():
        resource_children.append(uids["FR_Tokenizer"])
    if has_litert_model():
        resource_children.append(uids["FR_LiteRT"])
    parts.append(group(uids["GR_Resources"], "Resources", resource_children))

    # Sources/GemmaAgent top-level
    src_children = [
        uids["GR_App"], uids["GR_Agent"], uids["GR_Models"],
        uids["GR_Tools"], uids["GR_Connectors"], uids["GR_Workflows"],
        uids["GR_UI"], uids["GR_API"], uids["GR_Utilities"]
    ]
    parts.append(group(uids["GR_Sources"], "GemmaAgent", src_children))

    # Sub-groups
    parts.append(group(uids["GR_API"],        "API",          file_refs_for("API")))
    parts.append(group(uids["GR_Agent"],       "Agent",        file_refs_for("Agent")))
    parts.append(group(uids["GR_App"],         "App",          file_refs_for("App")))
    parts.append(group(uids["GR_Models"],      "Models",       file_refs_for("Models")))
    parts.append(group(uids["GR_Connectors"],  "Connectors",   file_refs_for("Connectors")))
    parts.append(group(uids["GR_Workflows"],   "Workflows",    file_refs_for("Workflows")))
    parts.append(group(uids["GR_Utilities"],   "Utilities",    file_refs_for("Utilities")))
    parts.append(group(uids["GR_UI"],          "UI",           file_refs_for("UI")))

    # Tools: Tool.swift + ToolRegistry.swift + BuiltinTools sub-group
    tool_direct = [uids[f"FR_{n}"] for n, p in SWIFT_FILES
                   if p.startswith("Sources/GemmaAgent/Tools/") and "/BuiltinTools/" not in p]
    builtin_refs = file_refs_for("Tools/BuiltinTools")
    parts.append(group(uids["GR_BuiltinTools"], "BuiltinTools", builtin_refs))
    parts.append(group(uids["GR_Tools"],         "Tools",        tool_direct + [uids["GR_BuiltinTools"]]))

    return section("PBXGroup", "\n".join(parts))

def native_target_section():
    app_target = (
        f"\t\t{uids['TARGET']} /* GemmaAgent */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {uids['CL_Target']} /* Build configuration list for PBXNativeTarget \"GemmaAgent\" */;\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{uids['PHASE_Sources']} /* Sources */,\n"
        f"\t\t\t\t{uids['PHASE_Resources']} /* Resources */,\n"
        f"\t\t\t\t{uids['PHASE_Frameworks']} /* Frameworks */,\n"
        f"\t\t\t\t{uids['PHASE_EmbedExt']} /* Embed App Extensions */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n"
        f"\t\t\t);\n"
        f"\t\t\tdependencies = (\n"
        f"\t\t\t\t{uids['DEP_W']} /* PBXTargetDependency */,\n"
        f"\t\t\t\t{uids['DEP_S']} /* PBXTargetDependency */,\n"
        f"\t\t\t);\n"
        f"\t\t\tname = GemmaAgent;\n"
        f"\t\t\tpackageProductDependencies = (\n"
        f"\t\t\t\t{uids['PRODDEP_MCP']} /* MCP */,\n"
        f"\t\t\t);\n"
        f"\t\t\tproductName = GemmaAgent;\n"
        f"\t\t\tproductReference = {uids['PRODUCT_APP']} /* GemmaAgent.app */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.application\";\n"
        f"\t\t}};"
    )
    tests_target = (
        f"\t\t{uids['TARGET_TESTS']} /* GemmaAgentTests */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {uids['CL_Tests']} /* Build configuration list for PBXNativeTarget \"GemmaAgentTests\" */;\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{uids['PHASE_TestsSources']} /* Sources */,\n"
        f"\t\t\t\t{uids['PHASE_TestsFrameworks']} /* Frameworks */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n"
        f"\t\t\t);\n"
        f"\t\t\tdependencies = (\n"
        f"\t\t\t\t{uids['DEP_Tests']} /* PBXTargetDependency */,\n"
        f"\t\t\t);\n"
        f"\t\t\tname = GemmaAgentTests;\n"
        f"\t\t\tproductName = GemmaAgentTests;\n"
        f"\t\t\tproductReference = {uids['PRODUCT_TESTS']} /* GemmaAgentTests.xctest */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";\n"
        f"\t\t}};"
    )
    uitests_target = (
        f"\t\t{uids['TARGET_UITESTS']} /* GemmaAgentUITests */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {uids['CL_UITests']} /* Build configuration list for PBXNativeTarget \"GemmaAgentUITests\" */;\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{uids['PHASE_UITestsSources']} /* Sources */,\n"
        f"\t\t\t\t{uids['PHASE_UITestsFrameworks']} /* Frameworks */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n"
        f"\t\t\t);\n"
        f"\t\t\tdependencies = (\n"
        f"\t\t\t\t{uids['DEP_UITests']} /* PBXTargetDependency */,\n"
        f"\t\t\t);\n"
        f"\t\t\tname = GemmaAgentUITests;\n"
        f"\t\t\tproductName = GemmaAgentUITests;\n"
        f"\t\t\tproductReference = {uids['PRODUCT_UITESTS']} /* GemmaAgentUITests.xctest */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.bundle.ui-testing\";\n"
        f"\t\t}};"
    )
    return section("PBXNativeTarget", app_target + "\n" + tests_target + "\n" + uitests_target)

def project_section():
    content = (
        f"\t\t{uids['PROJECT']} /* Project object */ = {{\n"
        f"\t\t\tisa = PBXProject;\n"
        f"\t\t\tattributes = {{\n"
        f"\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        f"\t\t\t\tLastSwiftUpdateCheck = 1500;\n"
        f"\t\t\t\tLastUpgradeCheck = 1500;\n"
        f"\t\t\t\tTargetAttributes = {{\n"
        f"\t\t\t\t\t{uids['TARGET']} = {{\n"
        f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        f"\t\t\t\t\t}};\n"
        f"\t\t\t\t\t{uids['TARGET_TESTS']} = {{\n"
        f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        f"\t\t\t\t\t\tTestTargetID = {uids['TARGET']};\n"
        f"\t\t\t\t\t}};\n"
        f"\t\t\t\t\t{uids['TARGET_UITESTS']} = {{\n"
        f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        f"\t\t\t\t\t\tTestTargetID = {uids['TARGET']};\n"
        f"\t\t\t\t\t}};\n"
        f"\t\t\t\t\t{uids['TARGET_W']} = {{\n"
        f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        f"\t\t\t\t\t}};\n"
        f"\t\t\t\t\t{uids['TARGET_S']} = {{\n"
        f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        f"\t\t\t\t\t}};\n"
        f"\t\t\t\t}};\n"
        f"\t\t\t}};\n"
        f"\t\t\tbuildConfigurationList = {uids['CL_Project']} /* Build configuration list for PBXProject \"GemmaAgent\" */;\n"
        f"\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
        f"\t\t\tdevelopmentRegion = en;\n"
        f"\t\t\thasScannedForEncodings = 0;\n"
        f"\t\t\tknownRegions = (\n"
        f"\t\t\t\ten,\n"
        f"\t\t\t\tBase,\n"
        f"\t\t\t);\n"
        f"\t\t\tmainGroup = {uids['GR_Root']};\n"
        f"\t\t\tpackageReferences = (\n"
        f"\t\t\t\t{uids['PKG_MCP']} /* XCRemoteSwiftPackageReference \"swift-sdk\" */,\n"
        f"\t\t\t);\n"
        f"\t\t\tproductRefGroup = {uids['GR_Products']} /* Products */;\n"
        f"\t\t\tprojectDirPath = \"\";\n"
        f"\t\t\tprojectRoot = \"\";\n"
        f"\t\t\ttargets = (\n"
        f"\t\t\t\t{uids['TARGET']} /* GemmaAgent */,\n"
        f"\t\t\t\t{uids['TARGET_TESTS']} /* GemmaAgentTests */,\n"
        f"\t\t\t\t{uids['TARGET_UITESTS']} /* GemmaAgentUITests */,\n"
        f"\t\t\t\t{uids['TARGET_W']} /* GemmaWidget */,\n"
        f"\t\t\t\t{uids['TARGET_S']} /* GemmaShare */,\n"
        f"\t\t\t);\n"
        f"\t\t}};"
    )
    return section("PBXProject", content)

def sources_build_phase():
    def phase(uid, file_list, extra_lines=None):
        lines_list = [
            f"\t\t\t\t{uids[f'BF_{n}']} /* {n} in Sources */,"
            for n, _ in file_list
        ] + (extra_lines or [])
        files = "\n".join(lines_list)
        return (
            f"\t\t{uid} /* Sources */ = {{\n"
            f"\t\t\tisa = PBXSourcesBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n{files}\n\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            f"\t\t}};"
        )
    # Core ML model files belong in the Sources phase — Xcode's coremlc
    # build rule compiles .mlpackage → .mlmodelc inside the app bundle
    app_extra = []
    if has_model():
        app_extra.append(f"\t\t\t\t{uids['BF_Model']} /* gemma4b.mlpackage in Sources */,")
    parts = [
        phase(uids["PHASE_Sources"], SWIFT_FILES, app_extra),
        phase(uids["PHASE_TestsSources"], TEST_FILES),
        phase(uids["PHASE_UITestsSources"], UITEST_FILES),
    ]
    return section("PBXSourcesBuildPhase", "\n".join(parts))

def resources_build_phase():
    lines_list = [
        f"\t\t\t\t{uids['BF_Assets']} /* Assets.xcassets in Resources */,",
        f"\t\t\t\t{uids['BF_Privacy']} /* PrivacyInfo.xcprivacy in Resources */,",
    ]
    if has_tokenizer():
        lines_list.append(f"\t\t\t\t{uids['BF_Tokenizer']} /* tokenizer.json in Resources */,")
    if has_litert_model():
        lines_list.append(f"\t\t\t\t{uids['BF_LiteRT']} /* gemma4e4b.litertlm in Resources */,")
    files = "\n".join(lines_list)
    content = (
        f"\t\t{uids['PHASE_Resources']} /* Resources */ = {{\n"
        f"\t\t\tisa = PBXResourcesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n{files}\n"
        f"\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};"
    )
    return section("PBXResourcesBuildPhase", content)

def frameworks_build_phase():
    def phase(uid, file_lines=None):
        files = "\n".join(file_lines or [])
        return (
            f"\t\t{uid} /* Frameworks */ = {{\n"
            f"\t\t\tisa = PBXFrameworksBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n{files}\n\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            f"\t\t}};"
        )
    # Only the app target links the MCP SwiftPM product; test targets stay empty.
    app_frameworks = [
        f"\t\t\t\t{uids['BF_MCP']} /* MCP in Frameworks */,",
        f"\t\t\t\t{uids['BF_AppIntents']} /* AppIntents.framework in Frameworks */,",
    ]
    parts = [
        phase(uids["PHASE_Frameworks"], app_frameworks),
        phase(uids["PHASE_TestsFrameworks"]),
        phase(uids["PHASE_UITestsFrameworks"]),
    ]
    return section("PBXFrameworksBuildPhase", "\n".join(parts))

def build_settings_common():
    """Settings shared between Debug and Release for the target."""
    return {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_ENTITLEMENTS": "GemmaAgent/GemmaAgent.entitlements",
        "COREML_CODEGEN_LANGUAGE": "None",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_NSMicrophoneUsageDescription": "GemmaAgent uses the microphone for voice input.",
        "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription": "GemmaAgent transcribes your voice on-device to chat with the local AI.",
        "INFOPLIST_KEY_NSRemindersFullAccessUsageDescription": "GemmaAgent creates and reads reminders when you ask it to.",
        "INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription": "GemmaAgent adds and reads calendar events when you ask it to.",
        "INFOPLIST_KEY_NSContactsUsageDescription": "GemmaAgent looks up contact details when you ask it to find someone.",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad":
            "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone":
            "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.gemmaagent.app",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }

def fmt_build_settings(d, indent="\t\t\t\t"):
    """Emit build settings, quoting values that need it for pbxproj."""
    lines = []
    # Characters that require quoting in pbxproj values
    def needs_quotes(v):
        if v == "":
            return True
        if any(c in v for c in (' ', ',', '$', '+', '(', ')')):
            return True
        return False

    for k, v in sorted(d.items()):
        # Strip outer quotes if the value was pre-quoted (e.g. '"gnu++20"')
        raw = v.strip('"') if v.startswith('"') and v.endswith('"') else v
        if needs_quotes(raw):
            lines.append(f'{indent}{k} = "{raw}";')
        else:
            lines.append(f'{indent}{k} = {raw};')
    return "\n".join(lines)

def build_configurations_section():
    common = build_settings_common()
    debug_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                   "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"}
    release_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_OPTIMIZATION_LEVEL": "-Owholemodule",
                     "COPY_PHASE_STRIP": "NO", "VALIDATE_PRODUCT": "YES"}

    proj_base = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "\"gnu++20\"",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
    }
    proj_debug = {**proj_base, "DEBUG_INFORMATION_FORMAT": "dwarf",
                  "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                  "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
                  "ENABLE_TESTABILITY": "YES",
                  "ONLY_ACTIVE_ARCH": "YES"}
    proj_release = {**proj_base, "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                    "SWIFT_OPTIMIZATION_LEVEL": "-Owholemodule",
                    "COPY_PHASE_STRIP": "NO"}

    def config_block(uid, name, settings):
        return (
            f"\t\t{uid} /* {name} */ = {{\n"
            f"\t\t\tisa = XCBuildConfiguration;\n"
            f"\t\t\tbuildSettings = {{\n"
            f"{fmt_build_settings(settings)}\n"
            f"\t\t\t}};\n"
            f"\t\t\tname = {name.split()[0]};\n"  # "Debug" from "Debug (project)"
            f"\t\t}};"
        )

    # Fix name extraction
    parts = []
    parts.append(
        f"\t\t{uids['BC_ProjDebug']} /* Debug */ = {{\n"
        f"\t\t\tisa = XCBuildConfiguration;\n"
        f"\t\t\tbuildSettings = {{\n"
        f"{fmt_build_settings(proj_debug)}\n"
        f"\t\t\t}};\n"
        f"\t\t\tname = Debug;\n"
        f"\t\t}};"
    )
    parts.append(
        f"\t\t{uids['BC_ProjRelease']} /* Release */ = {{\n"
        f"\t\t\tisa = XCBuildConfiguration;\n"
        f"\t\t\tbuildSettings = {{\n"
        f"{fmt_build_settings(proj_release)}\n"
        f"\t\t\t}};\n"
        f"\t\t\tname = Release;\n"
        f"\t\t}};"
    )

    tgt_debug = {**common, **debug_extra}
    tgt_release = {**common, **release_extra}

    parts.append(
        f"\t\t{uids['BC_TgtDebug']} /* Debug */ = {{\n"
        f"\t\t\tisa = XCBuildConfiguration;\n"
        f"\t\t\tbuildSettings = {{\n"
        f"{fmt_build_settings(tgt_debug)}\n"
        f"\t\t\t}};\n"
        f"\t\t\tname = Debug;\n"
        f"\t\t}};"
    )
    parts.append(
        f"\t\t{uids['BC_TgtRelease']} /* Release */ = {{\n"
        f"\t\t\tisa = XCBuildConfiguration;\n"
        f"\t\t\tbuildSettings = {{\n"
        f"{fmt_build_settings(tgt_release)}\n"
        f"\t\t\t}};\n"
        f"\t\t\tname = Release;\n"
        f"\t\t}};"
    )

    # ── Test target configs ──
    test_common = {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/GemmaAgent.app/GemmaAgent",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        "GENERATE_INFOPLIST_FILE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.gemmaagent.app.tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }
    uitest_common = {k: v for k, v in test_common.items()
                     if k not in ("BUNDLE_LOADER", "TEST_HOST")}
    uitest_common["TEST_TARGET_NAME"] = "GemmaAgent"
    uitest_common["PRODUCT_BUNDLE_IDENTIFIER"] = "com.gemmaagent.app.uitests"

    test_debug_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf",
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"}
    test_release_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                          "SWIFT_OPTIMIZATION_LEVEL": "-Owholemodule",
                          "COPY_PHASE_STRIP": "NO"}

    for uid_key, name, settings in [
        ("BC_TestsDebug",     "Debug",   {**test_common, **test_debug_extra}),
        ("BC_TestsRelease",   "Release", {**test_common, **test_release_extra}),
        ("BC_UITestsDebug",   "Debug",   {**uitest_common, **test_debug_extra}),
        ("BC_UITestsRelease", "Release", {**uitest_common, **test_release_extra}),
    ]:
        parts.append(
            f"\t\t{uids[uid_key]} /* {name} */ = {{\n"
            f"\t\t\tisa = XCBuildConfiguration;\n"
            f"\t\t\tbuildSettings = {{\n"
            f"{fmt_build_settings(settings)}\n"
            f"\t\t\t}};\n"
            f"\t\t\tname = {name};\n"
            f"\t\t}};"
        )
    return section("XCBuildConfiguration", "\n".join(parts))

def config_lists_section():
    proj_list = (
        f"\t\t{uids['CL_Project']} /* Build configuration list for PBXProject \"GemmaAgent\" */ = {{\n"
        f"\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{uids['BC_ProjDebug']} /* Debug */,\n"
        f"\t\t\t\t{uids['BC_ProjRelease']} /* Release */,\n"
        f"\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
        f"\t\t\tdefaultConfigurationName = Release;\n"
        f"\t\t}};"
    )
    tgt_list = (
        f"\t\t{uids['CL_Target']} /* Build configuration list for PBXNativeTarget \"GemmaAgent\" */ = {{\n"
        f"\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{uids['BC_TgtDebug']} /* Debug */,\n"
        f"\t\t\t\t{uids['BC_TgtRelease']} /* Release */,\n"
        f"\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
        f"\t\t\tdefaultConfigurationName = Release;\n"
        f"\t\t}};"
    )
    tests_list = (
        f"\t\t{uids['CL_Tests']} /* Build configuration list for PBXNativeTarget \"GemmaAgentTests\" */ = {{\n"
        f"\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{uids['BC_TestsDebug']} /* Debug */,\n"
        f"\t\t\t\t{uids['BC_TestsRelease']} /* Release */,\n"
        f"\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
        f"\t\t\tdefaultConfigurationName = Release;\n"
        f"\t\t}};"
    )
    uitests_list = (
        f"\t\t{uids['CL_UITests']} /* Build configuration list for PBXNativeTarget \"GemmaAgentUITests\" */ = {{\n"
        f"\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{uids['BC_UITestsDebug']} /* Debug */,\n"
        f"\t\t\t\t{uids['BC_UITestsRelease']} /* Release */,\n"
        f"\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
        f"\t\t\tdefaultConfigurationName = Release;\n"
        f"\t\t}};"
    )
    return section("XCConfigurationList", proj_list + "\n" + tgt_list + "\n" + tests_list + "\n" + uitests_list)

# ── Swift Package Manager (official MCP SDK) ─────────────────────────────────

def swift_package_reference_section():
    content = (
        f"\t\t{uids['PKG_MCP']} /* XCRemoteSwiftPackageReference \"swift-sdk\" */ = {{\n"
        f"\t\t\tisa = XCRemoteSwiftPackageReference;\n"
        f"\t\t\trepositoryURL = \"https://github.com/modelcontextprotocol/swift-sdk.git\";\n"
        f"\t\t\trequirement = {{\n"
        f"\t\t\t\tkind = upToNextMajorVersion;\n"
        f"\t\t\t\tminimumVersion = 0.11.0;\n"
        f"\t\t\t}};\n"
        f"\t\t}};"
    )
    return section("XCRemoteSwiftPackageReference", content)

def swift_package_product_section():
    content = (
        f"\t\t{uids['PRODDEP_MCP']} /* MCP */ = {{\n"
        f"\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tpackage = {uids['PKG_MCP']} /* XCRemoteSwiftPackageReference \"swift-sdk\" */;\n"
        f"\t\t\tproductName = MCP;\n"
        f"\t\t}};"
    )
    return section("XCSwiftPackageProductDependency", content)

# ── App extensions (widget + share) ──────────────────────────────────────────
#
# pbxproj's `objects` is a flat dictionary, so every extension object (build
# files, file refs, targets, phases, configs, proxies, deps, groups) is emitted
# here in one block regardless of isa. The app target gains an embed phase +
# dependencies via small edits to native_target_section()/project_section().

def extensions_section():
    p = []

    # --- PBXBuildFile (per-target source compiles reuse shared FR_<name>) ---
    for n in WIDGET_SHARED_FILES:
        p.append(f"\t\t{uids[f'BF_W_{n}']} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {uids[f'FR_{n}']} /* {n} */; }};")
    for n, _ in WIDGET_OWN_FILES:
        p.append(f"\t\t{uids[f'BF_W_{n}']} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {uids[f'FR_{n}']} /* {n} */; }};")
    for n in SHARE_SHARED_FILES:
        p.append(f"\t\t{uids[f'BF_S_{n}']} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {uids[f'FR_{n}']} /* {n} */; }};")
    for n, _ in SHARE_OWN_FILES:
        p.append(f"\t\t{uids[f'BF_S_{n}']} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {uids[f'FR_{n}']} /* {n} */; }};")
    p.append(f"\t\t{uids['BF_EmbedW']} /* GemmaWidget.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {uids['PRODUCT_W']} /* GemmaWidget.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")
    p.append(f"\t\t{uids['BF_EmbedS']} /* GemmaShare.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {uids['PRODUCT_S']} /* GemmaShare.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")

    # --- PBXFileReference (own sources + the .appex products) ---
    for n, path in WIDGET_OWN_FILES + SHARE_OWN_FILES:
        p.append(f"\t\t{uids[f'FR_{n}']} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {n}; path = {path}; sourceTree = SOURCE_ROOT; }};")
    p.append(f"\t\t{uids['PRODUCT_W']} /* GemmaWidget.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = GemmaWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; }};")
    p.append(f"\t\t{uids['PRODUCT_S']} /* GemmaShare.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = GemmaShare.appex; sourceTree = BUILT_PRODUCTS_DIR; }};")

    # --- Build phases ---
    def phase(uid, isa, label, file_uid_comments):
        files = "\n".join(f"\t\t\t\t{u} /* {c} */," for u, c in file_uid_comments)
        return (
            f"\t\t{uid} /* {label} */ = {{\n"
            f"\t\t\tisa = {isa};\n"
            f"\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n{files}\n\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            f"\t\t}};"
        )
    w_src = [(uids[f'BF_W_{n}'], f"{n} in Sources") for n in WIDGET_SHARED_FILES] \
          + [(uids[f'BF_W_{n}'], f"{n} in Sources") for n, _ in WIDGET_OWN_FILES]
    s_src = [(uids[f'BF_S_{n}'], f"{n} in Sources") for n in SHARE_SHARED_FILES] \
          + [(uids[f'BF_S_{n}'], f"{n} in Sources") for n, _ in SHARE_OWN_FILES]
    p.append(phase(uids["PHASE_W_Sources"], "PBXSourcesBuildPhase", "Sources", w_src))
    p.append(phase(uids["PHASE_W_Frameworks"], "PBXFrameworksBuildPhase", "Frameworks", []))
    p.append(phase(uids["PHASE_W_Resources"], "PBXResourcesBuildPhase", "Resources", []))
    p.append(phase(uids["PHASE_S_Sources"], "PBXSourcesBuildPhase", "Sources", s_src))
    p.append(phase(uids["PHASE_S_Frameworks"], "PBXFrameworksBuildPhase", "Frameworks", []))
    p.append(phase(uids["PHASE_S_Resources"], "PBXResourcesBuildPhase", "Resources", []))

    # --- Embed App Extensions copy phase (added to the app target's phases) ---
    p.append(
        f"\t\t{uids['PHASE_EmbedExt']} /* Embed App Extensions */ = {{\n"
        f"\t\t\tisa = PBXCopyFilesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tdstPath = \"\";\n"
        f"\t\t\tdstSubfolderSpec = 13;\n"
        f"\t\t\tfiles = (\n"
        f"\t\t\t\t{uids['BF_EmbedW']} /* GemmaWidget.appex in Embed App Extensions */,\n"
        f"\t\t\t\t{uids['BF_EmbedS']} /* GemmaShare.appex in Embed App Extensions */,\n"
        f"\t\t\t);\n"
        f"\t\t\tname = \"Embed App Extensions\";\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};"
    )

    # --- Native targets ---
    def ext_target(uid, name, cl, src, fw, res, product):
        return (
            f"\t\t{uid} /* {name} */ = {{\n"
            f"\t\t\tisa = PBXNativeTarget;\n"
            f"\t\t\tbuildConfigurationList = {cl} /* Build configuration list for PBXNativeTarget \"{name}\" */;\n"
            f"\t\t\tbuildPhases = (\n"
            f"\t\t\t\t{src} /* Sources */,\n"
            f"\t\t\t\t{fw} /* Frameworks */,\n"
            f"\t\t\t\t{res} /* Resources */,\n"
            f"\t\t\t);\n"
            f"\t\t\tbuildRules = (\n\t\t\t);\n"
            f"\t\t\tdependencies = (\n\t\t\t);\n"
            f"\t\t\tname = {name};\n"
            f"\t\t\tproductName = {name};\n"
            f"\t\t\tproductReference = {product} /* {name}.appex */;\n"
            f"\t\t\tproductType = \"com.apple.product-type.app-extension\";\n"
            f"\t\t}};"
        )
    p.append(ext_target(uids["TARGET_W"], "GemmaWidget", uids["CL_W"],
                        uids["PHASE_W_Sources"], uids["PHASE_W_Frameworks"], uids["PHASE_W_Resources"], uids["PRODUCT_W"]))
    p.append(ext_target(uids["TARGET_S"], "GemmaShare", uids["CL_S"],
                        uids["PHASE_S_Sources"], uids["PHASE_S_Frameworks"], uids["PHASE_S_Resources"], uids["PRODUCT_S"]))

    # --- Container proxies + target dependencies (app depends on both) ---
    def proxy(uid, target_uid, name):
        return (
            f"\t\t{uid} /* PBXContainerItemProxy */ = {{\n"
            f"\t\t\tisa = PBXContainerItemProxy;\n"
            f"\t\t\tcontainerPortal = {uids['PROJECT']} /* Project object */;\n"
            f"\t\t\tproxyType = 1;\n"
            f"\t\t\tremoteGlobalIDString = {target_uid};\n"
            f"\t\t\tremoteInfo = {name};\n"
            f"\t\t}};"
        )
    def dep(uid, target_uid, proxy_uid, name):
        return (
            f"\t\t{uid} /* PBXTargetDependency */ = {{\n"
            f"\t\t\tisa = PBXTargetDependency;\n"
            f"\t\t\ttarget = {target_uid} /* {name} */;\n"
            f"\t\t\ttargetProxy = {proxy_uid} /* PBXContainerItemProxy */;\n"
            f"\t\t}};"
        )
    p.append(proxy(uids["PROXY_W"], uids["TARGET_W"], "GemmaWidget"))
    p.append(proxy(uids["PROXY_S"], uids["TARGET_S"], "GemmaShare"))
    p.append(dep(uids["DEP_W"], uids["TARGET_W"], uids["PROXY_W"], "GemmaWidget"))
    p.append(dep(uids["DEP_S"], uids["TARGET_S"], uids["PROXY_S"], "GemmaShare"))

    # --- Build settings / configs ---
    ext_base = {
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        # Let Xcode synthesize the standard CFBundle* keys (it knows the
        # app-extension product type) and MERGE our partial Info.plist, which
        # supplies only the NSExtension dict. A hand-written partial without
        # CFBundleIdentifier/Executable produces an invalid bundle plist that
        # the App Intents SSU training step can't parse.
        "GENERATE_INFOPLIST_FILE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SKIP_INSTALL": "YES",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "CLANG_ENABLE_MODULES": "YES",
    }
    w_settings = {**ext_base,
                  "ENABLE_PREVIEWS": "YES",
                  "INFOPLIST_FILE": "GemmaWidget/Info.plist",
                  "CODE_SIGN_ENTITLEMENTS": "GemmaWidget/GemmaWidget.entitlements",
                  "PRODUCT_BUNDLE_IDENTIFIER": "com.gemmaagent.app.widget"}
    s_settings = {**ext_base,
                  "INFOPLIST_FILE": "GemmaShare/Info.plist",
                  "CODE_SIGN_ENTITLEMENTS": "GemmaShare/GemmaShare.entitlements",
                  "PRODUCT_BUNDLE_IDENTIFIER": "com.gemmaagent.app.share"}
    dbg_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                 "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"}
    rel_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_OPTIMIZATION_LEVEL": "-Owholemodule",
                 "COPY_PHASE_STRIP": "NO"}

    def bc(uid, name, settings):
        return (
            f"\t\t{uid} /* {name} */ = {{\n"
            f"\t\t\tisa = XCBuildConfiguration;\n"
            f"\t\t\tbuildSettings = {{\n{fmt_build_settings(settings)}\n\t\t\t}};\n"
            f"\t\t\tname = {name};\n"
            f"\t\t}};"
        )
    p.append(bc(uids["BC_W_Debug"], "Debug", {**w_settings, **dbg_extra}))
    p.append(bc(uids["BC_W_Release"], "Release", {**w_settings, **rel_extra}))
    p.append(bc(uids["BC_S_Debug"], "Debug", {**s_settings, **dbg_extra}))
    p.append(bc(uids["BC_S_Release"], "Release", {**s_settings, **rel_extra}))

    def cl(uid, name, dbg, rel):
        return (
            f"\t\t{uid} /* Build configuration list for PBXNativeTarget \"{name}\" */ = {{\n"
            f"\t\t\tisa = XCConfigurationList;\n"
            f"\t\t\tbuildConfigurations = (\n"
            f"\t\t\t\t{dbg} /* Debug */,\n"
            f"\t\t\t\t{rel} /* Release */,\n"
            f"\t\t\t);\n"
            f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
            f"\t\t\tdefaultConfigurationName = Release;\n"
            f"\t\t}};"
        )
    p.append(cl(uids["CL_W"], "GemmaWidget", uids["BC_W_Debug"], uids["BC_W_Release"]))
    p.append(cl(uids["CL_S"], "GemmaShare", uids["BC_S_Debug"], uids["BC_S_Release"]))

    # --- Groups (navigator only) ---
    def grp(uid, name, children):
        ch = "\n".join(f"\t\t\t\t{c}," for c in children)
        return (
            f"\t\t{uid} /* {name} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n{ch}\n\t\t\t);\n"
            f"\t\t\tname = \"{name}\";\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )
    p.append(grp(uids["GR_Widget"], "GemmaWidget", [uids[f"FR_{n}"] for n, _ in WIDGET_OWN_FILES]))
    p.append(grp(uids["GR_Share"], "GemmaShare", [uids[f"FR_{n}"] for n, _ in SHARE_OWN_FILES]))
    p.append(grp(uids["GR_Extensions"], "Extensions", [uids["GR_Widget"], uids["GR_Share"]]))

    return "\n" + "\n".join(p) + "\n"

# ── Assemble project.pbxproj ──────────────────────────────────────────────────

def generate():
    content = (
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {\n"
        "\t};\n"
        "\tobjectVersion = 56;\n"
        "\tobjects = {\n"
        + build_files_section()
        + container_item_proxy_section()
        + file_references_section()
        + frameworks_build_phase()
        + groups_section()
        + native_target_section()
        + project_section()
        + resources_build_phase()
        + sources_build_phase()
        + target_dependency_section()
        + build_configurations_section()
        + config_lists_section()
        + swift_package_reference_section()
        + swift_package_product_section()
        + extensions_section()
        + "\n\t};\n"
        f"\trootObject = {uids['PROJECT']} /* Project object */;\n"
        "}\n"
    )
    return content

# ── Write files ───────────────────────────────────────────────────────────────

def write_assets():
    base = os.path.join(SOURCE_ROOT, "GemmaAgent", "Assets.xcassets")

    # Root Contents.json
    os.makedirs(base, exist_ok=True)
    with open(os.path.join(base, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)

    # AppIcon
    icon_dir = os.path.join(base, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)
    with open(os.path.join(icon_dir, "Contents.json"), "w") as f:
        json.dump({
            "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1}
        }, f, indent=2)

    # AccentColor
    accent_dir = os.path.join(base, "AccentColor.colorset")
    os.makedirs(accent_dir, exist_ok=True)
    with open(os.path.join(accent_dir, "Contents.json"), "w") as f:
        json.dump({
            "colors": [{
                "color": {
                    "color-space": "srgb",
                    "components": {"alpha": "1.000", "blue": "1.000", "green": "0.420", "red": "0.000"}
                },
                "idiom": "universal"
            }],
            "info": {"author": "xcode", "version": 1}
        }, f, indent=2)

    print(f"✓ Assets written to {base}")

def main():
    # 1. Write Assets.xcassets
    write_assets()

    # 2. Write project.pbxproj
    proj_dir = os.path.join(SOURCE_ROOT, "GemmaAgent.xcodeproj")
    os.makedirs(proj_dir, exist_ok=True)
    pbxproj_path = os.path.join(proj_dir, "project.pbxproj")
    content = generate()
    with open(pbxproj_path, "w") as f:
        f.write(content)
    print(f"✓ project.pbxproj written to {pbxproj_path}")

    # 3. Write a basic xcscheme so Xcode can run immediately
    schemes_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    os.makedirs(schemes_dir, exist_ok=True)
    scheme_path = os.path.join(schemes_dir, "GemmaAgent.xcscheme")
    scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uids['TARGET']}"
               BuildableName = "GemmaAgent.app"
               BlueprintName = "GemmaAgent"
               ReferencedContainer = "container:GemmaAgent.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uids['TARGET_TESTS']}"
               BuildableName = "GemmaAgentTests.xctest"
               BlueprintName = "GemmaAgentTests"
               ReferencedContainer = "container:GemmaAgent.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uids['TARGET_UITESTS']}"
               BuildableName = "GemmaAgentUITests.xctest"
               BlueprintName = "GemmaAgentUITests"
               ReferencedContainer = "container:GemmaAgent.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{uids['TARGET']}"
            BuildableName = "GemmaAgent.app"
            BlueprintName = "GemmaAgent"
            ReferencedContainer = "container:GemmaAgent.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{uids['TARGET']}"
            BuildableName = "GemmaAgent.app"
            BlueprintName = "GemmaAgent"
            ReferencedContainer = "container:GemmaAgent.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    with open(scheme_path, "w") as f:
        f.write(scheme_xml)
    print(f"✓ xcscheme written to {scheme_path}")

    print("\n✅ Done! Open GemmaAgent.xcodeproj in Xcode.")
    print("   • Set your Development Team in Signing & Capabilities")
    print("   • Connect a device (iOS 17+) and run")

if __name__ == "__main__":
    main()
