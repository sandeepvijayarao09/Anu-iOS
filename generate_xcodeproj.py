#!/usr/bin/env python3
"""
Generates Anu.xcodeproj for the Anu iOS app.
Run from the IOSApp directory: python3 generate_xcodeproj.py
"""

import os
import uuid
import json

# Signing team for device builds. Set ANU_TEAM_ID (your 10-character Team ID
# from Xcode → Settings → Accounts) before running this script; empty keeps
# the simulator-only default.
DEVELOPMENT_TEAM = os.environ.get("ANU_TEAM_ID", "")

# Bundle ID prefix for the app and its extensions; the App Group is
# "group." + this. The old com.anu.app ID is registered to another developer,
# so Anu uses the owner's namespace (the same one as Anu for Android).
BUNDLE_PREFIX = os.environ.get("ANU_BUNDLE_PREFIX", "io.github.sandeepvijayarao09.anu")

# ── Deterministic UUIDs so re-running produces the same file ──────────────────
_counter = [0]
def U():
    _counter[0] += 1
    return f"{_counter[0]:024X}"

# ── File list ──────────────────────────────────────────────────────────────────
SOURCE_ROOT = os.path.dirname(os.path.abspath(__file__))

SWIFT_FILES = [
    # (display_name, path_relative_to_SOURCE_ROOT)
    ("GeminiClient.swift",          "Sources/Anu/API/GeminiClient.swift"),
    ("GeminiModels.swift",          "Sources/Anu/API/GeminiModels.swift"),
    ("PrivateComputeModels.swift",  "Sources/Anu/API/PrivateComputeModels.swift"),
    ("PrivateComputeClient.swift",  "Sources/Anu/API/PrivateComputeClient.swift"),
    ("MacBrainClient.swift",        "Sources/Anu/API/MacBrainClient.swift"),
    ("EscalateToMacTool.swift",     "Sources/Anu/Tools/BuiltinTools/EscalateToMacTool.swift"),
    ("A2AClient.swift",             "Sources/Anu/Connectors/A2AClient.swift"),
    ("MacBrainView.swift",          "Sources/Anu/UI/MacBrainView.swift"),
    ("A2AAgentsView.swift",         "Sources/Anu/UI/A2AAgentsView.swift"),
    ("AgentMessage.swift",          "Sources/Anu/Agent/AgentMessage.swift"),
    ("AgentOrchestrator.swift",     "Sources/Anu/Agent/AgentOrchestrator.swift"),
    ("AgentOrchestrator+Sessions.swift", "Sources/Anu/Agent/AgentOrchestrator+Sessions.swift"),
    ("AgentOrchestrator+Modes.swift", "Sources/Anu/Agent/AgentOrchestrator+Modes.swift"),
    ("AgentOrchestrator+Details.swift", "Sources/Anu/Agent/AgentOrchestrator+Details.swift"),
    ("AnswerDetails.swift",         "Sources/Anu/Agent/AnswerDetails.swift"),
    ("TokenCalibration.swift",      "Sources/Anu/Agent/TokenCalibration.swift"),
    ("AgentState.swift",            "Sources/Anu/Agent/AgentState.swift"),
    ("ConversationWindow.swift",    "Sources/Anu/Agent/ConversationWindow.swift"),
    ("MessageAttachments.swift",    "Sources/Anu/Agent/MessageAttachments.swift"),
    ("DocumentReading.swift",       "Sources/Anu/Agent/DocumentReading.swift"),
    ("AgentOrchestrator+Media.swift", "Sources/Anu/Agent/AgentOrchestrator+Media.swift"),
    ("ShownSecrets.swift",          "Sources/Anu/Utilities/ShownSecrets.swift"),
    ("ScreenSecrets.swift",         "Sources/Anu/Utilities/ScreenSecrets.swift"),
    ("SharedMedia.swift",           "Sources/Anu/Workflows/SharedMedia.swift"),
    ("AttachmentViews.swift",       "Sources/Anu/UI/AttachmentViews.swift"),
    ("MemoryStore.swift",           "Sources/Anu/Agent/MemoryStore.swift"),
    ("MemoryExtraction.swift",      "Sources/Anu/Agent/MemoryExtraction.swift"),
    ("MemoryRelevance.swift",       "Sources/Anu/Agent/MemoryRelevance.swift"),
    ("MemoryLearner.swift",         "Sources/Anu/Agent/MemoryLearner.swift"),
    ("ModelClassifier.swift",       "Sources/Anu/Agent/ModelClassifier.swift"),
    ("EscalationRouter.swift",      "Sources/Anu/Agent/EscalationRouter.swift"),
    ("TaskClassifier.swift",        "Sources/Anu/Agent/TaskClassifier.swift"),
    ("RoutingDecision.swift",       "Sources/Anu/Agent/RoutingDecision.swift"),
    ("PlanModels.swift",            "Sources/Anu/Agent/PlanModels.swift"),
    ("Planner.swift",               "Sources/Anu/Agent/Planner.swift"),
    ("Critic.swift",                "Sources/Anu/Agent/Critic.swift"),
    ("PlanGate.swift",              "Sources/Anu/Agent/PlanGate.swift"),
    ("PlanPipeline.swift",          "Sources/Anu/Agent/PlanPipeline.swift"),
    ("PrivacyLedger.swift",         "Sources/Anu/Agent/PrivacyLedger.swift"),
    ("ToolBroker.swift",             "Sources/Anu/Agent/ToolBroker.swift"),
    ("ApprovalCenter.swift",         "Sources/Anu/Agent/ApprovalCenter.swift"),
    ("ToolAudit.swift",              "Sources/Anu/Agent/ToolAudit.swift"),
    ("ActionClaims.swift",           "Sources/Anu/Agent/ActionClaims.swift"),
    ("PhoneCommands.swift",          "Sources/Anu/Agent/PhoneCommands.swift"),
    ("AgentOrchestrator+Direct.swift", "Sources/Anu/Agent/AgentOrchestrator+Direct.swift"),
    ("DeviceGuard.swift",            "Sources/Anu/Agent/DeviceGuard.swift"),
    ("ChatSession.swift",           "Sources/Anu/Agent/ChatSession.swift"),
    ("CloudProvider.swift",         "Sources/Anu/Agent/CloudProvider.swift"),
    ("AskAnuIntent.swift",        "Sources/Anu/App/AskAnuIntent.swift"),
    ("WritingIntents.swift",        "Sources/Anu/App/WritingIntents.swift"),
    ("AssistantSearchIntent.swift", "Sources/Anu/App/AssistantSearchIntent.swift"),
    ("CalendarQueryIntents.swift",  "Sources/Anu/App/CalendarQueryIntents.swift"),
    ("DailyActionIntents.swift",    "Sources/Anu/App/DailyActionIntents.swift"),
    ("ContentView.swift",           "Sources/Anu/App/ContentView.swift"),
    ("AnuApp.swift",         "Sources/Anu/App/AnuApp.swift"),
    ("GemmaModel.swift",            "Sources/Anu/Models/GemmaModel.swift"),
    ("ModelCatalog.swift",          "Sources/Anu/Models/ModelCatalog.swift"),
    ("ModelManager.swift",          "Sources/Anu/Models/ModelManager.swift"),
    ("ModelAllowlist.swift",        "Sources/Anu/Models/ModelAllowlist.swift"),
    ("ModelDownloadManager.swift",  "Sources/Anu/Models/ModelDownloadManager.swift"),
    ("ModelFileInstaller.swift",    "Sources/Anu/Models/ModelFileInstaller.swift"),
    ("GemmaPromptParser.swift",     "Sources/Anu/Models/GemmaPromptParser.swift"),
    ("LiteRTLMModel.swift",         "Sources/Anu/Models/LiteRTLMModel.swift"),
    ("ModelConfig.swift",           "Sources/Anu/Models/ModelConfig.swift"),
    ("GenerationUsage.swift",       "Sources/Anu/Models/GenerationUsage.swift"),
    ("ModelSpeed.swift",            "Sources/Anu/Models/ModelSpeed.swift"),
    ("PromptLab.swift",             "Sources/Anu/Models/PromptLab.swift"),
    ("ScriptedModel.swift",         "Sources/Anu/Models/ScriptedModel.swift"),
    ("Tokenizer.swift",             "Sources/Anu/Models/Tokenizer.swift"),
    ("CalculatorTool.swift",        "Sources/Anu/Tools/BuiltinTools/CalculatorTool.swift"),
    ("EscalateToGeminiTool.swift",  "Sources/Anu/Tools/BuiltinTools/EscalateToGeminiTool.swift"),
    ("EscalateToPrivateCloudTool.swift", "Sources/Anu/Tools/BuiltinTools/EscalateToPrivateCloudTool.swift"),
    ("ImageGenerationTool.swift",   "Sources/Anu/Tools/BuiltinTools/ImageGenerationTool.swift"),
    ("WebSearchTool.swift",         "Sources/Anu/Tools/BuiltinTools/WebSearchTool.swift"),
    ("DateTimeTool.swift",          "Sources/Anu/Tools/BuiltinTools/DateTimeTool.swift"),
    ("UnitConverterTool.swift",     "Sources/Anu/Tools/BuiltinTools/UnitConverterTool.swift"),
    ("ToolDateParsing.swift",       "Sources/Anu/Tools/BuiltinTools/ToolDateParsing.swift"),
    ("RemindersTool.swift",         "Sources/Anu/Tools/BuiltinTools/RemindersTool.swift"),
    ("CalendarAccess.swift",        "Sources/Anu/Tools/BuiltinTools/CalendarAccess.swift"),
    ("CalendarTool.swift",          "Sources/Anu/Tools/BuiltinTools/CalendarTool.swift"),
    ("ContactsTool.swift",          "Sources/Anu/Tools/BuiltinTools/ContactsTool.swift"),
    ("ContactActionTool.swift",     "Sources/Anu/Tools/BuiltinTools/ContactActionTool.swift"),
    ("TimerTool.swift",             "Sources/Anu/Tools/BuiltinTools/TimerTool.swift"),
    ("SystemAlarmScheduler.swift",  "Sources/Anu/Tools/BuiltinTools/SystemAlarmScheduler.swift"),
    ("PhoneControlTools.swift",     "Sources/Anu/Tools/BuiltinTools/PhoneControlTools.swift"),
    ("ReadTextTool.swift",          "Sources/Anu/Tools/BuiltinTools/ReadTextTool.swift"),
    ("UtilityTools.swift",          "Sources/Anu/Tools/BuiltinTools/UtilityTools.swift"),
    ("PhotoLibraryTool.swift",      "Sources/Anu/Tools/BuiltinTools/PhotoLibraryTool.swift"),
    ("Tool.swift",                  "Sources/Anu/Tools/Tool.swift"),
    ("ToolPolicy.swift",             "Sources/Anu/Tools/ToolPolicy.swift"),
    ("ToolRegistry.swift",          "Sources/Anu/Tools/ToolRegistry.swift"),
    ("AgentTraceView.swift",        "Sources/Anu/UI/AgentTraceView.swift"),
    ("ChatView.swift",              "Sources/Anu/UI/ChatView.swift"),
    ("ChatViewComponents.swift",    "Sources/Anu/UI/ChatViewComponents.swift"),
    ("DesignSystem.swift",         "Sources/Anu/UI/DesignSystem.swift"),
    ("Typography.swift",            "Sources/Anu/UI/Typography.swift"),
    ("VoiceOrb.swift",              "Sources/Anu/UI/VoiceOrb.swift"),
    ("VoiceModeView.swift",         "Sources/Anu/UI/VoiceModeView.swift"),
    ("MemoryView.swift",            "Sources/Anu/UI/MemoryView.swift"),
    ("MessageBubble.swift",         "Sources/Anu/UI/MessageBubble.swift"),
    ("ModelManagerView.swift",      "Sources/Anu/UI/ModelManagerView.swift"),
    ("PrivacyView.swift",           "Sources/Anu/UI/PrivacyView.swift"),
    ("DataPrivacyViews.swift",      "Sources/Anu/UI/DataPrivacyViews.swift"),
    ("DataEraser.swift",            "Sources/Anu/Utilities/DataEraser.swift"),
    ("ApprovalSheet.swift",          "Sources/Anu/UI/ApprovalSheet.swift"),
    ("ActivityView.swift",           "Sources/Anu/UI/ActivityView.swift"),
    ("VaultView.swift",              "Sources/Anu/UI/VaultView.swift"),
    ("Vault.swift",                  "Sources/Anu/Vault/Vault.swift"),
    ("VaultModels.swift",            "Sources/Anu/Vault/VaultModels.swift"),
    ("ConnectorSecrets.swift",       "Sources/Anu/Vault/ConnectorSecrets.swift"),
    ("SecureFile.swift",             "Sources/Anu/Vault/SecureFile.swift"),
    ("DebugExport.swift",            "Sources/Anu/Utilities/DebugExport.swift"),
    ("ToolSelector.swift",           "Sources/Anu/Agent/ToolSelector.swift"),
    ("AgentSkill.swift",             "Sources/Anu/Skills/AgentSkill.swift"),
    ("SkillLibrary.swift",           "Sources/Anu/Skills/SkillLibrary.swift"),
    ("JSSandbox.swift",              "Sources/Anu/Skills/JSSandbox.swift"),
    ("SkillTools.swift",             "Sources/Anu/Skills/SkillTools.swift"),
    ("SkillsView.swift",             "Sources/Anu/UI/SkillsView.swift"),
    ("SettingsView.swift",          "Sources/Anu/UI/SettingsView.swift"),
    ("AboutAnswerSheet.swift",      "Sources/Anu/UI/AboutAnswerSheet.swift"),
    ("PromptLabView.swift",         "Sources/Anu/UI/PromptLabView.swift"),
    ("ModelSpeedSection.swift",     "Sources/Anu/UI/ModelSpeedSection.swift"),
    ("SessionListView.swift",       "Sources/Anu/UI/SessionListView.swift"),
    ("PrivateCloudView.swift",      "Sources/Anu/UI/PrivateCloudView.swift"),
    ("CameraCaptureView.swift",     "Sources/Anu/UI/CameraCaptureView.swift"),
    ("LiveCameraView.swift",        "Sources/Anu/UI/LiveCameraView.swift"),
    ("LiveVision.swift",            "Sources/Anu/Utilities/LiveVision.swift"),
    ("LiveLabelMatcher.swift",      "Sources/Anu/Utilities/LiveLabelMatcher.swift"),
    ("LiveCameraIntent.swift",      "Sources/Anu/App/LiveCameraIntent.swift"),
    ("ImageCreationSupport.swift",  "Sources/Anu/UI/ImageCreationSupport.swift"),
    ("PlatformCompat.swift",        "Sources/Anu/UI/PlatformCompat.swift"),
    ("JSONSchema.swift",            "Sources/Anu/Utilities/JSONSchema.swift"),
    ("KeychainStore.swift",         "Sources/Anu/Utilities/KeychainStore.swift"),
    ("StreamParser.swift",          "Sources/Anu/Utilities/StreamParser.swift"),
    ("ConversationStore.swift",     "Sources/Anu/Utilities/ConversationStore.swift"),
    ("PIISanitizer.swift",          "Sources/Anu/Utilities/PIISanitizer.swift"),
    ("SessionStore.swift",          "Sources/Anu/Utilities/SessionStore.swift"),
    ("DateFormatters.swift",        "Sources/Anu/Utilities/DateFormatters.swift"),
    ("DeviceAttestation.swift",     "Sources/Anu/Utilities/DeviceAttestation.swift"),
    ("SpeechSynthesizer.swift",     "Sources/Anu/Utilities/SpeechSynthesizer.swift"),
    ("SpotlightIndexer.swift",      "Sources/Anu/Utilities/SpotlightIndexer.swift"),
    ("SpeechRecognizer.swift",      "Sources/Anu/Utilities/SpeechRecognizer.swift"),
    ("StreamStopFilter.swift",      "Sources/Anu/Utilities/StreamStopFilter.swift"),
    ("ConnectorConfig.swift",       "Sources/Anu/Connectors/ConnectorConfig.swift"),
    ("ConnectorManager.swift",      "Sources/Anu/Connectors/ConnectorManager.swift"),
    ("MCPToolProxy.swift",          "Sources/Anu/Connectors/MCPToolProxy.swift"),
    ("MCPConnection.swift",         "Sources/Anu/Connectors/MCPConnection.swift"),
    ("RESTConnectorTool.swift",     "Sources/Anu/Connectors/RESTConnectorTool.swift"),
    ("AppLauncherTool.swift",       "Sources/Anu/Connectors/AppLauncherTool.swift"),
    ("MCPOAuth.swift",              "Sources/Anu/Connectors/MCPOAuth.swift"),
    ("MCPCatalog.swift",            "Sources/Anu/Connectors/MCPCatalog.swift"),
    ("MCPRegistryClient.swift",     "Sources/Anu/Connectors/MCPRegistryClient.swift"),
    ("UCPDiscovery.swift",          "Sources/Anu/Connectors/UCPDiscovery.swift"),
    ("GmailMIME.swift",             "Sources/Anu/Connectors/GmailMIME.swift"),
    ("GmailAuth.swift",             "Sources/Anu/Connectors/GmailAuth.swift"),
    ("GmailClient.swift",           "Sources/Anu/Connectors/GmailClient.swift"),
    ("GmailTools.swift",            "Sources/Anu/Connectors/GmailTools.swift"),
    ("SkillDetector.swift",         "Sources/Anu/Agent/SkillDetector.swift"),
    ("GmailSettingsView.swift",     "Sources/Anu/UI/GmailSettingsView.swift"),
    ("ConnectorsView.swift",        "Sources/Anu/UI/ConnectorsView.swift"),
    ("ConnectorsSubviews.swift",    "Sources/Anu/UI/ConnectorsSubviews.swift"),
    ("WorkflowsView.swift",         "Sources/Anu/UI/WorkflowsView.swift"),
    ("AppGroupStore.swift",         "Sources/Anu/Workflows/AppGroupStore.swift"),
    ("Workflow.swift",              "Sources/Anu/Workflows/Workflow.swift"),
    ("WorkflowStore.swift",         "Sources/Anu/Workflows/WorkflowStore.swift"),
    ("InboxStore.swift",            "Sources/Anu/Workflows/InboxStore.swift"),
    ("WorkflowEntity.swift",        "Sources/Anu/Workflows/WorkflowEntity.swift"),
    ("RunWorkflowIntent.swift",     "Sources/Anu/Workflows/RunWorkflowIntent.swift"),
    ("WorkflowManager.swift",       "Sources/Anu/Workflows/WorkflowManager.swift"),
    ("WorkflowSchedule.swift",      "Sources/Anu/Workflows/WorkflowSchedule.swift"),
    ("WorkflowScheduler.swift",     "Sources/Anu/Workflows/WorkflowScheduler.swift"),
    ("TurnTaking.swift",            "Sources/Anu/Voice/TurnTaking.swift"),
    ("WakePhrase.swift",            "Sources/Anu/Voice/WakePhrase.swift"),
    ("LiveTalk.swift",              "Sources/Anu/Voice/LiveTalk.swift"),
    ("SharedAudio.swift",           "Sources/Anu/Voice/SharedAudio.swift"),
    ("VoiceNote.swift",             "Sources/Anu/Voice/VoiceNote.swift"),
    ("VoiceNoteTranscriber.swift",  "Sources/Anu/Voice/VoiceNoteTranscriber.swift"),
    ("VoiceNoteRecorder.swift",     "Sources/Anu/Voice/VoiceNoteRecorder.swift"),
    ("VoiceNoteController.swift",   "Sources/Anu/Voice/VoiceNoteController.swift"),
    ("VoiceNoteViews.swift",        "Sources/Anu/Voice/VoiceNoteViews.swift"),
    ("VoiceAudio.swift",            "Sources/Anu/Voice/VoiceAudio.swift"),
    ("VoiceLoop.swift",             "Sources/Anu/Voice/VoiceLoop.swift"),
]
# ── "Hey Anu" from the user's samples (Android ADR-121). Own `+=` block so
# parallel edits to the lists above merge cleanly.
SWIFT_FILES += [
    ("WakeVoice.swift",             "Sources/Anu/Voice/WakeVoice.swift"),
    ("WakeVoiceStore.swift",        "Sources/Anu/Voice/WakeVoiceStore.swift"),
    ("WakeVoiceAudio.swift",        "Sources/Anu/Voice/WakeVoiceAudio.swift"),
    ("WakeVoiceViews.swift",        "Sources/Anu/Voice/WakeVoiceViews.swift"),
]

TEST_FILES = [
    ("MacBrainClientTests.swift",   "Tests/AnuTests/MacBrainClientTests.swift"),
    ("A2AClientTests.swift",        "Tests/AnuTests/A2AClientTests.swift"),
    ("LiveCameraTests.swift",       "Tests/AnuTests/LiveCameraTests.swift"),
    ("TurnTakingTests.swift",       "Tests/AnuTests/TurnTakingTests.swift"),
    ("WakePhraseTests.swift",       "Tests/AnuTests/WakePhraseTests.swift"),
    ("VoiceNoteTests.swift",        "Tests/AnuTests/VoiceNoteTests.swift"),
    ("VoiceLoopTests.swift",        "Tests/AnuTests/VoiceLoopTests.swift"),
    ("CalculatorToolTests.swift",   "Tests/AnuTests/CalculatorToolTests.swift"),
    ("NativeToolCallParsingTests.swift", "Tests/AnuTests/NativeToolCallParsingTests.swift"),
    ("ResponseParserTests.swift",   "Tests/AnuTests/ResponseParserTests.swift"),
    ("LiteRTEngineTests.swift",     "Tests/AnuTests/LiteRTEngineTests.swift"),
    ("StreamStopFilterTests.swift", "Tests/AnuTests/StreamStopFilterTests.swift"),
    ("AgentOrchestratorTests.swift","Tests/AnuTests/AgentOrchestratorTests.swift"),
    ("ToolBrokerTests.swift",        "Tests/AnuTests/ToolBrokerTests.swift"),
    ("PhoneCommandsTests.swift",     "Tests/AnuTests/PhoneCommandsTests.swift"),
    ("PhoneControlToolsTests.swift", "Tests/AnuTests/PhoneControlToolsTests.swift"),
    ("DeviceGuardTests.swift",       "Tests/AnuTests/DeviceGuardTests.swift"),
    ("DirectTierTests.swift",        "Tests/AnuTests/DirectTierTests.swift"),
    ("VaultTests.swift",             "Tests/AnuTests/VaultTests.swift"),
    ("SecureFileTests.swift",        "Tests/AnuTests/SecureFileTests.swift"),
    ("DebugExportTests.swift",       "Tests/AnuTests/DebugExportTests.swift"),
    ("ToolSelectorTests.swift",      "Tests/AnuTests/ToolSelectorTests.swift"),
    ("AgentSkillTests.swift",        "Tests/AnuTests/AgentSkillTests.swift"),
    ("JSSandboxTests.swift",         "Tests/AnuTests/JSSandboxTests.swift"),
    ("SkillToolsTests.swift",        "Tests/AnuTests/SkillToolsTests.swift"),
    ("ActionClaimsTests.swift",      "Tests/AnuTests/ActionClaimsTests.swift"),
    ("KeychainStoreTests.swift",    "Tests/AnuTests/KeychainStoreTests.swift"),
    ("MemoryStoreTests.swift",      "Tests/AnuTests/MemoryStoreTests.swift"),
    ("MemoryPipelineTests.swift",   "Tests/AnuTests/MemoryPipelineTests.swift"),
    ("MemoryExtractionTests.swift", "Tests/AnuTests/MemoryExtractionTests.swift"),
    ("MemoryRelevanceTests.swift",  "Tests/AnuTests/MemoryRelevanceTests.swift"),
    ("StreamParserTests.swift",     "Tests/AnuTests/StreamParserTests.swift"),
    ("GenerationConfigTests.swift", "Tests/AnuTests/GenerationConfigTests.swift"),
    ("ClassifierEvalTests.swift",   "Tests/AnuTests/ClassifierEvalTests.swift"),
    ("ClassifierTests.swift",       "Tests/AnuTests/ClassifierTests.swift"),
    ("EscalationRouterTests.swift", "Tests/AnuTests/EscalationRouterTests.swift"),
    ("PIISanitizerTests.swift",     "Tests/AnuTests/PIISanitizerTests.swift"),
    ("ConversationWindowTests.swift","Tests/AnuTests/ConversationWindowTests.swift"),
    ("AnswerDetailsTests.swift",    "Tests/AnuTests/AnswerDetailsTests.swift"),
    ("TokenCalibrationTests.swift", "Tests/AnuTests/TokenCalibrationTests.swift"),
    ("PromptLabTests.swift",        "Tests/AnuTests/PromptLabTests.swift"),
    ("ModelSpeedTests.swift",       "Tests/AnuTests/ModelSpeedTests.swift"),
    ("ScriptedModelTests.swift",    "Tests/AnuTests/ScriptedModelTests.swift"),
    ("ChatTemplateTests.swift",     "Tests/AnuTests/ChatTemplateTests.swift"),
    ("JSONValueTests.swift",        "Tests/AnuTests/JSONValueTests.swift"),
    ("QueuedMockModel.swift",       "Tests/AnuTests/QueuedMockModel.swift"),
    ("PlanParserTests.swift",       "Tests/AnuTests/PlanParserTests.swift"),
    ("PlanGateTests.swift",         "Tests/AnuTests/PlanGateTests.swift"),
    ("PlannerTests.swift",          "Tests/AnuTests/PlannerTests.swift"),
    ("CriticTests.swift",           "Tests/AnuTests/CriticTests.swift"),
    ("PlanPipelineTests.swift",     "Tests/AnuTests/PlanPipelineTests.swift"),
    ("PrivacyLedgerTests.swift",    "Tests/AnuTests/PrivacyLedgerTests.swift"),
    ("DataEraserTests.swift",       "Tests/AnuTests/DataEraserTests.swift"),
    ("SessionStoreTests.swift",     "Tests/AnuTests/SessionStoreTests.swift"),
    ("PrivacyLedgerSessionTests.swift", "Tests/AnuTests/PrivacyLedgerSessionTests.swift"),
    ("PrivateComputeClientTests.swift", "Tests/AnuTests/PrivateComputeClientTests.swift"),
    ("CloudProviderTests.swift",    "Tests/AnuTests/CloudProviderTests.swift"),
    ("GeminiClientTests.swift",     "Tests/AnuTests/GeminiClientTests.swift"),
    ("DeviceAttestationTests.swift","Tests/AnuTests/DeviceAttestationTests.swift"),
    ("ModelManagerTests.swift",     "Tests/AnuTests/ModelManagerTests.swift"),
    ("ModelDownloadTests.swift",    "Tests/AnuTests/ModelDownloadTests.swift"),
    ("GemmaPromptParserTests.swift", "Tests/AnuTests/GemmaPromptParserTests.swift"),
    ("WorkflowTests.swift",         "Tests/AnuTests/WorkflowTests.swift"),
    ("DateTimeToolTests.swift",     "Tests/AnuTests/DateTimeToolTests.swift"),
    ("UnitConverterToolTests.swift","Tests/AnuTests/UnitConverterToolTests.swift"),
    ("ConnectorConfigTests.swift",  "Tests/AnuTests/ConnectorConfigTests.swift"),
    ("MCPToolProxyTests.swift",     "Tests/AnuTests/MCPToolProxyTests.swift"),
    ("RESTConnectorToolTests.swift","Tests/AnuTests/RESTConnectorToolTests.swift"),
    ("AppLauncherToolTests.swift",  "Tests/AnuTests/AppLauncherToolTests.swift"),
    ("ConnectorManagerTests.swift", "Tests/AnuTests/ConnectorManagerTests.swift"),
    ("ToolRegistryTests.swift",     "Tests/AnuTests/ToolRegistryTests.swift"),
    ("MCPAuthMigrationTests.swift", "Tests/AnuTests/MCPAuthMigrationTests.swift"),
    ("JSONKeychainBoxTests.swift",  "Tests/AnuTests/JSONKeychainBoxTests.swift"),
    ("MCPCatalogTests.swift",       "Tests/AnuTests/MCPCatalogTests.swift"),
    ("MCPRegistryClientTests.swift","Tests/AnuTests/MCPRegistryClientTests.swift"),
    ("UCPDiscoveryTests.swift",     "Tests/AnuTests/UCPDiscoveryTests.swift"),
    ("ImageGenerationToolTests.swift", "Tests/AnuTests/ImageGenerationToolTests.swift"),
    ("SpeechSynthesizerTests.swift",   "Tests/AnuTests/SpeechSynthesizerTests.swift"),
    ("SpotlightIndexerTests.swift",    "Tests/AnuTests/SpotlightIndexerTests.swift"),
    ("WritingIntentsTests.swift",      "Tests/AnuTests/WritingIntentsTests.swift"),
    ("DailyActionIntentsTests.swift",  "Tests/AnuTests/DailyActionIntentsTests.swift"),
    ("ReadTextToolTests.swift",        "Tests/AnuTests/ReadTextToolTests.swift"),
    ("UtilityToolsTests.swift",        "Tests/AnuTests/UtilityToolsTests.swift"),
    ("PictureSecretsTests.swift",      "Tests/AnuTests/PictureSecretsTests.swift"),
    ("MediaAttachmentsTests.swift",    "Tests/AnuTests/MediaAttachmentsTests.swift"),
    ("DocumentReadingTests.swift",     "Tests/AnuTests/DocumentReadingTests.swift"),
    ("PhotosIntegrationTests.swift",   "Tests/AnuTests/PhotosIntegrationTests.swift"),
    ("EventKitIntegrationTests.swift", "Tests/AnuTests/EventKitIntegrationTests.swift"),
    ("ContactsIntegrationTests.swift",  "Tests/AnuTests/ContactsIntegrationTests.swift"),
    ("GmailMIMETests.swift",           "Tests/AnuTests/GmailMIMETests.swift"),
    ("GmailConnectorTests.swift",      "Tests/AnuTests/GmailConnectorTests.swift"),
    ("SkillDetectorTests.swift",       "Tests/AnuTests/SkillDetectorTests.swift"),
]

UITEST_FILES = [
    ("AnuUITests.swift",     "UITests/AnuUITests.swift"),
]

# ── Writing action extension + Anu keyboard: app-side sources and tests ──────
# (Android parity rows 20–21, ADR-042/109/122/149.) The pure logic lives in the
# app so the unit tests can reach it, and is ALSO compiled into the two
# extensions below (WRITING_EXT_SHARED_FILES / KEYBOARD_EXT_SHARED_FILES).
# Kept as its own `+=` block so parallel edits to the lists above merge cleanly.
SWIFT_FILES += [
    ("WritingKit.swift",            "Sources/Anu/Writing/WritingKit.swift"),
    ("WritingHandoff.swift",        "Sources/Anu/Writing/WritingHandoff.swift"),
    ("WritingHandoffRunner.swift",  "Sources/Anu/Writing/WritingHandoffRunner.swift"),
    ("WritingActionModel.swift",    "Sources/Anu/Writing/WritingActionModel.swift"),
    ("KeyboardLayout.swift",        "Sources/Anu/Keyboard/KeyboardLayout.swift"),
    ("KeyboardFieldPolicy.swift",   "Sources/Anu/Keyboard/KeyboardFieldPolicy.swift"),
    ("KeyboardText.swift",          "Sources/Anu/Keyboard/KeyboardText.swift"),
    ("KeyboardAssist.swift",        "Sources/Anu/Keyboard/KeyboardAssist.swift"),
    ("KeyboardSettingsView.swift",  "Sources/Anu/Keyboard/KeyboardSettingsView.swift"),
]
# ── Native forms of features iOS blocks (Android ADR-108, ADR-093, Daily
# Brief, ADR-083): live talk's Live Activity, Anu's notes, the Daily Brief,
# and questions about a screenshot. Own `+=` block so parallel edits merge.
SWIFT_FILES += [
    ("LiveTalkActivity.swift",      "Sources/Anu/Voice/LiveTalkActivity.swift"),
    ("LiveTalkPresence.swift",      "Sources/Anu/Voice/LiveTalkPresence.swift"),
    ("NoteStore.swift",             "Sources/Anu/Notes/NoteStore.swift"),
    ("NotesTools.swift",            "Sources/Anu/Notes/NotesTools.swift"),
    ("NotesView.swift",             "Sources/Anu/Notes/NotesView.swift"),
    ("DailyBrief.swift",            "Sources/Anu/Brief/DailyBrief.swift"),
    ("DailyBriefTool.swift",        "Sources/Anu/Brief/DailyBriefTool.swift"),
    ("DailyBriefView.swift",        "Sources/Anu/Brief/DailyBriefView.swift"),
    ("BriefMeIntent.swift",         "Sources/Anu/Brief/BriefMeIntent.swift"),
    ("ScreenQuestion.swift",        "Sources/Anu/Screen/ScreenQuestion.swift"),
    ("VisualAsk.swift",             "Sources/Anu/Screen/VisualAsk.swift"),
]
TEST_FILES += [
    ("NativeFormsTests.swift",      "Tests/AnuTests/NativeFormsTests.swift"),
    ("DailyBriefToolTests.swift",   "Tests/AnuTests/DailyBriefToolTests.swift"),
    ("ScreenTurnPrivacyTests.swift", "Tests/AnuTests/ScreenTurnPrivacyTests.swift"),
    ("WarmStartTests.swift",         "Tests/AnuTests/WarmStartTests.swift"),
    ("ModelFileInstallerTests.swift", "Tests/AnuTests/ModelFileInstallerTests.swift"),
]
TEST_FILES += [
    ("SyntheticSpeech.swift",       "Tests/AnuTests/SyntheticSpeech.swift"),
    ("WakeVoiceTests.swift",        "Tests/AnuTests/WakeVoiceTests.swift"),
]
TEST_FILES += [
    ("WritingKitTests.swift",       "Tests/AnuTests/WritingKitTests.swift"),
    ("WritingHandoffTests.swift",   "Tests/AnuTests/WritingHandoffTests.swift"),
    ("KeyboardLogicTests.swift",    "Tests/AnuTests/KeyboardLogicTests.swift"),
    ("KeyboardAssistTests.swift",   "Tests/AnuTests/KeyboardAssistTests.swift"),
]

# ── Siri / Spotlight surface (Apple integration A4–A8): entities, indexing,
# long-running model intents, Focus filter. App target (and AnuMac) only.
# Kept as its own `+=` block so parallel edits to the lists above merge cleanly.
SWIFT_FILES += [
    ("AnuEntities.swift",           "Sources/Anu/App/AnuEntities.swift"),
    ("AnuSearchIndex.swift",        "Sources/Anu/App/AnuSearchIndex.swift"),
    ("OpenEntityIntents.swift",     "Sources/Anu/App/OpenEntityIntents.swift"),
    ("ModelIntentSupport.swift",    "Sources/Anu/App/ModelIntentSupport.swift"),
    ("FocusFilterIntent.swift",     "Sources/Anu/App/FocusFilterIntent.swift"),
]
TEST_FILES += [
    ("AppIntentsSurfaceTests.swift", "Tests/AnuTests/AppIntentsSurfaceTests.swift"),
]

# ── Apple's models: Foundation Models tiers, native tools, consent (A1-A3, A9) ──
# Kept as its own `+=` block so parallel edits to the lists above merge cleanly.
SWIFT_FILES += [
    ("AppleModelAvailability.swift",   "Sources/Anu/Models/AppleModelAvailability.swift"),
    ("AppleFoundationModel.swift",     "Sources/Anu/Models/AppleFoundationModel.swift"),
    ("GemmaFoundationModel.swift",     "Sources/Anu/Models/GemmaFoundationModel.swift"),
    ("AgentOrchestrator+Apple.swift",  "Sources/Anu/Agent/AgentOrchestrator+Apple.swift"),
    ("AgentOrchestrator+Warm.swift",   "Sources/Anu/Agent/AgentOrchestrator+Warm.swift"),
    ("AIShareConsent.swift",           "Sources/Anu/Agent/AIShareConsent.swift"),
    ("EscalateToApplePCCTool.swift",   "Sources/Anu/Tools/BuiltinTools/EscalateToApplePCCTool.swift"),
    ("AIShareConsentViews.swift",      "Sources/Anu/UI/AIShareConsentViews.swift"),
]
TEST_FILES += [
    ("AppleModelTierTests.swift",      "Tests/AnuTests/AppleModelTierTests.swift"),
    ("AppleFoundationModelTests.swift", "Tests/AnuTests/AppleFoundationModelTests.swift"),
    ("GuidedMemoryExtractionTests.swift", "Tests/AnuTests/GuidedMemoryExtractionTests.swift"),
    ("KeySaveTests.swift",             "Tests/AnuTests/KeySaveTests.swift"),
    ("VisualAskTests.swift",           "Tests/AnuTests/VisualAskTests.swift"),
    ("PhotoThenActionTests.swift",     "Tests/AnuTests/PhotoThenActionTests.swift"),
    ("NativeToolCallingTests.swift",   "Tests/AnuTests/NativeToolCallingTests.swift"),
    ("FoundationModelsBridgeTests.swift", "Tests/AnuTests/FoundationModelsBridgeTests.swift"),
    ("AIShareConsentTests.swift",      "Tests/AnuTests/AIShareConsentTests.swift"),
]

# Android parity follow-ups: memory tools, engine speech (barge-in), media rules.
SWIFT_FILES += [
    ("MemoryTools.swift",           "Sources/Anu/Tools/BuiltinTools/MemoryTools.swift"),
    ("MediaPolicy.swift",           "Sources/Anu/Agent/MediaPolicy.swift"),
    ("EngineSpeech.swift",          "Sources/Anu/Voice/EngineSpeech.swift"),
    ("DuplexVoiceEngine.swift",     "Sources/Anu/Voice/DuplexVoiceEngine.swift"),
]
TEST_FILES += [
    ("MemoryToolsTests.swift",      "Tests/AnuTests/MemoryToolsTests.swift"),
    ("MediaPolicyTests.swift",      "Tests/AnuTests/MediaPolicyTests.swift"),
    ("EngineSpeechTests.swift",     "Tests/AnuTests/EngineSpeechTests.swift"),
]

# Optional model resource — included only when present on disk. The bundled
# Gemma 4 E4B weights go in the Resources phase; every other model the app can
# run (E2B, E4B) is fetched at runtime by the download manager.
LITERT_MODEL_PATH = "Anu/gemma4e4b.litertlm"

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
uids["FR_Skills"]       = U()  # Anu/Skills folder reference (bundled Agent Skills)
uids["BF_Skills"]       = U()  # Resources phase
uids["FR_LiveDetector"] = U()  # Anu/LiveDetector.mlmodelc: Apple's YOLOv3 Tiny for the live camera
uids["BF_LiveDetector"] = U()  # Resources phase (iOS app only; the camera is iOS-only)
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
uids["GR_Vault"]        = U()
uids["GR_Skills"]       = U()
uids["GR_Voice"]        = U()
uids["GR_Native"]       = U()  # Notes/, Brief/, Screen/
uids["GR_Utilities"]    = U()
uids["GR_Connectors"]   = U()
uids["GR_Workflows"]    = U()
uids["GR_Resources"]    = U()

# Swift Package Manager: the official MCP SDK (app target only)
uids["PKG_MCP"]         = U()  # XCRemoteSwiftPackageReference
uids["PRODDEP_MCP"]     = U()  # XCSwiftPackageProductDependency (product "MCP")
uids["BF_MCP"]          = U()  # PBXBuildFile linking the product in app Frameworks

# LiteRT-LM — vendored LOCAL Swift package (ThirdParty/LiteRTLM), macOS only.
# Consumed as a local package because Xcode refuses to link the upstream
# product (it declares an unsafe `-all_load` flag) into a generated app target,
# even pinned by revision. Local packages aren't subject to that rule; the flag
# is applied on AnuMac via OTHER_LDFLAGS instead. Same static-link setup as the
# AI Edge Gallery Mac app. iOS keeps MediaPipe (no macOS slice).
uids["PKG_LITERTLM"]     = U()  # XCLocalSwiftPackageReference (ThirdParty/LiteRTLM)
uids["PRODDEP_LITERTLM"] = U()  # XCSwiftPackageProductDependency (product "LiteRTLM")
uids["BF_MAC_LITERTLM"]  = U()  # PBXBuildFile linking LiteRTLM in AnuMac Frameworks
uids["BF_LITERTLM_IOS"]  = U()  # PBXBuildFile linking LiteRTLM in the iOS Anu Frameworks

# AppIntents.framework — explicit link so the App Intents metadata processor
# runs and the "Ask Anu" App Shortcut registers with Siri/Spotlight.
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
APP_GROUP_ID = "group." + BUNDLE_PREFIX

# Files compiled into each extension target. Shared files reuse the app's
# FR_<name> file reference but get their OWN PBXBuildFile per target.
WIDGET_SHARED_FILES = ["Workflow.swift", "WorkflowSchedule.swift", "WorkflowStore.swift", "InboxStore.swift",
                       "AppGroupStore.swift", "WorkflowEntity.swift", "RunWorkflowIntent.swift"]
WIDGET_OWN_FILES = [("AnuWidget.swift", "AnuWidget/AnuWidget.swift")]
# Live talk's Live Activity (ADR-108's iOS form): the attributes and its
# Mute/End intents are shared with the app; the widget draws it.
WIDGET_SHARED_FILES += ["LiveTalkActivity.swift"]
WIDGET_OWN_FILES += [("LiveTalkLiveActivity.swift", "AnuWidget/LiveTalkLiveActivity.swift")]
SHARE_SHARED_FILES = ["InboxStore.swift", "AppGroupStore.swift", "SharedMedia.swift", "SecureFile.swift", "SharedAudio.swift"]
SHARE_OWN_FILES = [("ShareViewController.swift", "AnuShare/ShareViewController.swift")]

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

# ── Native macOS app target (AnuMac) ─────────────────────────────────────────
# A real SDKROOT=macosx SwiftUI app, sharing the same Swift sources as the iOS
# app (each via its OWN PBXBuildFile pointing at the shared FR_<name>). The
# vendored LiteRT-LM package (ThirdParty/LiteRTLM) IS linked (BF_MAC_LITERTLM),
# so Gemma 4 runs on the Mac's Metal GPU; Apple Foundation Models and the
# cloud tiers work as on iOS.
uids["TARGET_MAC"]         = U()
uids["PRODUCT_MAC"]        = U()
uids["PHASE_MAC_Sources"]    = U()
uids["PHASE_MAC_Resources"]  = U()
uids["PHASE_MAC_Frameworks"] = U()
uids["CL_MAC"]             = U()
uids["BC_MAC_Debug"]       = U()
uids["BC_MAC_Release"]     = U()
# Own build files for every shared Swift source (reuse the FR_<name> refs).
for _n, _ in SWIFT_FILES:
    uids[f"BF_MAC_{_n}"] = U()
# Resource / framework / model build files for the mac target.
uids["BF_MAC_MCP"]        = U()  # productRef = PRODDEP_MCP (shared)
uids["BF_MAC_AppIntents"] = U()
uids["BF_MAC_Assets"]     = U()
uids["BF_MAC_Privacy"]    = U()
uids["BF_MAC_Skills"]     = U()

# ── Writing action extension (AnuWriting) + Anu keyboard (AnuKeyboard) ───────
# Two more .appex targets built exactly like AnuWidget/AnuShare: shared app
# sources get their OWN PBXBuildFile per target (reusing the app's FR_<name>),
# extension-only sources get their own file refs. Embedded by a SEPARATE copy
# phase (PHASE_EmbedWK) so the widget/share embed phase stays untouched.
# Neither extension can load Gemma: they use Apple's on-device Foundation
# Models when available, else hand the text to the app through the App Group.
WRITING_EXT_SHARED_FILES = ["AppGroupStore.swift", "WritingKit.swift", "WritingHandoff.swift",
                            "WritingActionModel.swift"]
WRITING_EXT_OWN_FILES = [
    ("WritingActionViewController.swift", "AnuWriting/WritingActionViewController.swift"),
    ("WritingActionView.swift",           "AnuWriting/WritingActionView.swift"),
    ("ExtensionWritingEngine.swift",      "AnuExtensionsShared/ExtensionWritingEngine.swift"),
]
KEYBOARD_EXT_SHARED_FILES = ["AppGroupStore.swift", "WritingKit.swift", "WritingHandoff.swift",
                             "KeyboardLayout.swift", "KeyboardFieldPolicy.swift", "KeyboardText.swift",
                             "KeyboardAssist.swift"]
KEYBOARD_EXT_OWN_FILES = [
    ("KeyboardViewController.swift", "AnuKeyboard/KeyboardViewController.swift"),
    ("KeyboardView.swift",           "AnuKeyboard/KeyboardView.swift"),
]
# ExtensionWritingEngine.swift is compiled into BOTH extensions (one file ref,
# one build file per target); it is never part of the app or AnuMac.
WK_COMMON_OWN = "ExtensionWritingEngine.swift"

for _n, _p in WRITING_EXT_OWN_FILES + KEYBOARD_EXT_OWN_FILES:
    uids[f"FR_{_n}"] = U()
for _t in ("WR", "KB"):
    for _k in ("TARGET", "PRODUCT", "PHASE_Sources", "PHASE_Frameworks", "PHASE_Resources",
               "CL", "BC_Debug", "BC_Release", "PROXY", "DEP", "BF_Embed"):
        uids[f"{_k}_{_t}"] = U()
for _n in WRITING_EXT_SHARED_FILES + [n for n, _ in WRITING_EXT_OWN_FILES]:
    uids[f"BF_WR_{_n}"] = U()
for _n in KEYBOARD_EXT_SHARED_FILES + [n for n, _ in KEYBOARD_EXT_OWN_FILES] + [WK_COMMON_OWN]:
    uids[f"BF_KB_{_n}"] = U()
uids["PHASE_EmbedWK"]    = U()
uids["GR_WK"]            = U()  # "Writing & Keyboard" navigator hub
uids["GR_WK_Writing"]    = U()  # Sources/Anu/Writing
uids["GR_WK_Keyboard"]   = U()  # Sources/Anu/Keyboard
uids["GR_WK_WritingExt"] = U()  # AnuWriting/ + AnuExtensionsShared/
uids["GR_WK_KeyboardExt"] = U() # AnuKeyboard/

# Per-extension privacy manifests (App Store: every bundle with an executable
# that uses a required-reason API carries its own PrivacyInfo.xcprivacy).
EXT_PRIVACY = {"W": "AnuWidget", "S": "AnuShare", "WR": "AnuWriting", "KB": "AnuKeyboard"}
for _t in EXT_PRIVACY:
    uids[f"FR_Privacy_{_t}"] = U()
    uids[f"BF_Privacy_{_t}"] = U()

def ext_privacy_objects(targets):
    """PBXFileReference + PBXBuildFile lines for these extensions' manifests."""
    out = []
    for t in targets:
        folder = EXT_PRIVACY[t]
        out.append(f"\t\t{uids[f'FR_Privacy_{t}']} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = PrivacyInfo.xcprivacy; path = {folder}/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT; }};")
        out.append(f"\t\t{uids[f'BF_Privacy_{t}']} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {uids[f'FR_Privacy_{t}']} /* PrivacyInfo.xcprivacy */; }};")
    return out

def ext_privacy_resource(t):
    return [(uids[f"BF_Privacy_{t}"], "PrivacyInfo.xcprivacy in Resources")]

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
    parts.append(f"\t\t{uids['BF_LITERTLM_IOS']} /* LiteRTLM in Frameworks */ = {{isa = PBXBuildFile; productRef = {uids['PRODDEP_LITERTLM']} /* LiteRTLM */; }};")
    parts.append(f"\t\t{uids['BF_AppIntents']} /* AppIntents.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {uids['FR_AppIntents']} /* AppIntents.framework */; }};")
    parts.append(f"\t\t{uids['BF_Assets']} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Assets']} /* Assets.xcassets */; }};")
    parts.append(f"\t\t{uids['BF_Privacy']} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Privacy']} /* PrivacyInfo.xcprivacy */; }};")
    parts.append(f"\t\t{uids['BF_Skills']} /* Skills in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Skills']} /* Skills */; }};")
    parts.append(f"\t\t{uids['BF_LiveDetector']} /* LiveDetector.mlmodelc in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_LiveDetector']} /* LiveDetector.mlmodelc */; }};")
    if has_litert_model():
        parts.append(f"\t\t{uids['BF_LiteRT']} /* gemma4e4b.litertlm in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_LiteRT']} /* gemma4e4b.litertlm */; }};")
    return section("PBXBuildFile", "\n".join(parts))

def _pbx(v):
    """Quote a pbxproj string value when it contains characters the parser
    treats specially (spaces, commas, +, parens, $) or is empty. Lets us use
    idiomatic Swift extension filenames like `AgentOrchestrator+Sessions.swift`."""
    return f'"{v}"' if (v == "" or any(c in v for c in ' ,$+()')) else v

def file_references_section():
    parts = []
    for name, path in SWIFT_FILES + TEST_FILES + UITEST_FILES:
        uid = uids[f"FR_{name}"]
        parts.append(f"\t\t{uid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {_pbx(name)}; path = {_pbx(path)}; sourceTree = SOURCE_ROOT; }};")
    # Assets
    parts.append(f"\t\t{uids['FR_Assets']} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = Assets.xcassets; path = Anu/Assets.xcassets; sourceTree = SOURCE_ROOT; }};")
    parts.append(f"\t\t{uids['FR_Privacy']} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = PrivacyInfo.xcprivacy; path = Anu/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT; }};")
    parts.append(f"\t\t{uids['FR_Skills']} /* Skills */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = Skills; path = Anu/Skills; sourceTree = SOURCE_ROOT; }};")
    parts.append(f"\t\t{uids['FR_LiveDetector']} /* LiveDetector.mlmodelc */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = LiveDetector.mlmodelc; path = Anu/LiveDetector.mlmodelc; sourceTree = SOURCE_ROOT; }};")
    if has_litert_model():
        parts.append(f"\t\t{uids['FR_LiteRT']} /* gemma4e4b.litertlm */ = {{isa = PBXFileReference; lastKnownFileType = file; name = gemma4e4b.litertlm; path = {LITERT_MODEL_PATH}; sourceTree = SOURCE_ROOT; }};")
    # System frameworks
    parts.append(f"\t\t{uids['FR_AppIntents']} /* AppIntents.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = AppIntents.framework; path = System/Library/Frameworks/AppIntents.framework; sourceTree = SDKROOT; }};")
    # Products
    parts.append(f"\t\t{uids['PRODUCT_APP']} /* Anu.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Anu.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    parts.append(f"\t\t{uids['PRODUCT_TESTS']} /* AnuTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = AnuTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};")
    parts.append(f"\t\t{uids['PRODUCT_UITESTS']} /* AnuUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = AnuUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};")
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
        proxy(uids["PROXY_Tests"], uids["TARGET"], "Anu"),
        proxy(uids["PROXY_UITests"], uids["TARGET"], "Anu"),
    ]
    return section("PBXContainerItemProxy", "\n".join(parts))

def target_dependency_section():
    def dep(uid, proxy_uid):
        return (
            f"\t\t{uid} /* PBXTargetDependency */ = {{\n"
            f"\t\t\tisa = PBXTargetDependency;\n"
            f"\t\t\ttarget = {uids['TARGET']} /* Anu */;\n"
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
        prefix = f"Sources/Anu/{folder}/"
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
                     uids["GR_Extensions"], uids["GR_Resources"], uids["GR_Products"],
                     uids["GR_WK"],  # writing + keyboard
                     uids["GR_Native"]]  # notes, daily brief, screen questions
    parts.append(group(uids["GR_Root"], "Anu", root_children))

    # Products
    parts.append(group(uids["GR_Products"], "Products",
                       [uids["PRODUCT_APP"], uids["PRODUCT_TESTS"], uids["PRODUCT_UITESTS"],
                        uids["PRODUCT_W"], uids["PRODUCT_S"], uids["PRODUCT_MAC"]]))

    # Test groups
    parts.append(group(uids["GR_Tests"], "AnuTests", [uids[f"FR_{n}"] for n, _ in TEST_FILES]))
    parts.append(group(uids["GR_UITests"], "AnuUITests", [uids[f"FR_{n}"] for n, _ in UITEST_FILES]))

    # Resources
    resource_children = [uids["FR_Assets"], uids["FR_Privacy"], uids["FR_Skills"], uids["FR_LiveDetector"]]
    if has_litert_model():
        resource_children.append(uids["FR_LiteRT"])
    parts.append(group(uids["GR_Resources"], "Resources", resource_children))

    # Sources/Anu top-level
    src_children = [
        uids["GR_App"], uids["GR_Agent"], uids["GR_Models"],
        uids["GR_Tools"], uids["GR_Connectors"], uids["GR_Workflows"],
        uids["GR_UI"], uids["GR_API"], uids["GR_Utilities"], uids["GR_Vault"], uids["GR_Skills"],
        uids["GR_Voice"]
    ]
    parts.append(group(uids["GR_Sources"], "Anu", src_children))

    # Sub-groups
    parts.append(group(uids["GR_API"],        "API",          file_refs_for("API")))
    parts.append(group(uids["GR_Agent"],       "Agent",        file_refs_for("Agent")))
    parts.append(group(uids["GR_App"],         "App",          file_refs_for("App")))
    parts.append(group(uids["GR_Models"],      "Models",       file_refs_for("Models")))
    parts.append(group(uids["GR_Connectors"],  "Connectors",   file_refs_for("Connectors")))
    parts.append(group(uids["GR_Workflows"],   "Workflows",    file_refs_for("Workflows")))
    parts.append(group(uids["GR_Utilities"],   "Utilities",    file_refs_for("Utilities")))
    parts.append(group(uids["GR_UI"],          "UI",           file_refs_for("UI")))
    parts.append(group(uids["GR_Vault"],       "Vault",        file_refs_for("Vault")))
    parts.append(group(uids["GR_Skills"],      "Skills",       file_refs_for("Skills")))
    parts.append(group(uids["GR_Voice"],       "Voice",        file_refs_for("Voice")))
    parts.append(group(uids["GR_Native"], "Notes, Brief & Screen",
                       file_refs_for("Notes") + file_refs_for("Brief") + file_refs_for("Screen")))

    # Tools: Tool.swift + ToolRegistry.swift + BuiltinTools sub-group
    tool_direct = [uids[f"FR_{n}"] for n, p in SWIFT_FILES
                   if p.startswith("Sources/Anu/Tools/") and "/BuiltinTools/" not in p]
    builtin_refs = file_refs_for("Tools/BuiltinTools")
    parts.append(group(uids["GR_BuiltinTools"], "BuiltinTools", builtin_refs))
    parts.append(group(uids["GR_Tools"],         "Tools",        tool_direct + [uids["GR_BuiltinTools"]]))

    return section("PBXGroup", "\n".join(parts))

def native_target_section():
    app_target = (
        f"\t\t{uids['TARGET']} /* Anu */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {uids['CL_Target']} /* Build configuration list for PBXNativeTarget \"Anu\" */;\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{uids['PHASE_Sources']} /* Sources */,\n"
        f"\t\t\t\t{uids['PHASE_Resources']} /* Resources */,\n"
        f"\t\t\t\t{uids['PHASE_Frameworks']} /* Frameworks */,\n"
        f"\t\t\t\t{uids['PHASE_EmbedExt']} /* Embed App Extensions */,\n"
        f"\t\t\t\t{uids['PHASE_EmbedWK']} /* Embed Writing and Keyboard Extensions */,\n"  # writing + keyboard
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n"
        f"\t\t\t);\n"
        f"\t\t\tdependencies = (\n"
        f"\t\t\t\t{uids['DEP_W']} /* PBXTargetDependency */,\n"
        f"\t\t\t\t{uids['DEP_S']} /* PBXTargetDependency */,\n"
        f"\t\t\t\t{uids['DEP_WR']} /* PBXTargetDependency */,\n"  # writing extension
        f"\t\t\t\t{uids['DEP_KB']} /* PBXTargetDependency */,\n"  # keyboard extension
        f"\t\t\t);\n"
        f"\t\t\tname = Anu;\n"
        f"\t\t\tpackageProductDependencies = (\n"
        f"\t\t\t\t{uids['PRODDEP_MCP']} /* MCP */,\n"
        f"\t\t\t\t{uids['PRODDEP_LITERTLM']} /* LiteRTLM */,\n"
        f"\t\t\t);\n"
        f"\t\t\tproductName = Anu;\n"
        f"\t\t\tproductReference = {uids['PRODUCT_APP']} /* Anu.app */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.application\";\n"
        f"\t\t}};"
    )
    tests_target = (
        f"\t\t{uids['TARGET_TESTS']} /* AnuTests */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {uids['CL_Tests']} /* Build configuration list for PBXNativeTarget \"AnuTests\" */;\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{uids['PHASE_TestsSources']} /* Sources */,\n"
        f"\t\t\t\t{uids['PHASE_TestsFrameworks']} /* Frameworks */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n"
        f"\t\t\t);\n"
        f"\t\t\tdependencies = (\n"
        f"\t\t\t\t{uids['DEP_Tests']} /* PBXTargetDependency */,\n"
        f"\t\t\t);\n"
        f"\t\t\tname = AnuTests;\n"
        f"\t\t\tproductName = AnuTests;\n"
        f"\t\t\tproductReference = {uids['PRODUCT_TESTS']} /* AnuTests.xctest */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";\n"
        f"\t\t}};"
    )
    uitests_target = (
        f"\t\t{uids['TARGET_UITESTS']} /* AnuUITests */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {uids['CL_UITests']} /* Build configuration list for PBXNativeTarget \"AnuUITests\" */;\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{uids['PHASE_UITestsSources']} /* Sources */,\n"
        f"\t\t\t\t{uids['PHASE_UITestsFrameworks']} /* Frameworks */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n"
        f"\t\t\t);\n"
        f"\t\t\tdependencies = (\n"
        f"\t\t\t\t{uids['DEP_UITests']} /* PBXTargetDependency */,\n"
        f"\t\t\t);\n"
        f"\t\t\tname = AnuUITests;\n"
        f"\t\t\tproductName = AnuUITests;\n"
        f"\t\t\tproductReference = {uids['PRODUCT_UITESTS']} /* AnuUITests.xctest */;\n"
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
        f"\t\t\t\t\t{uids['TARGET_MAC']} = {{\n"
        f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        f"\t\t\t\t\t}};\n"
        f"\t\t\t\t}};\n"
        f"\t\t\t}};\n"
        f"\t\t\tbuildConfigurationList = {uids['CL_Project']} /* Build configuration list for PBXProject \"Anu\" */;\n"
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
        f"\t\t\t\t{uids['PKG_LITERTLM']} /* XCLocalSwiftPackageReference \"ThirdParty/LiteRTLM\" */,\n"
        f"\t\t\t);\n"
        f"\t\t\tproductRefGroup = {uids['GR_Products']} /* Products */;\n"
        f"\t\t\tprojectDirPath = \"\";\n"
        f"\t\t\tprojectRoot = \"\";\n"
        f"\t\t\ttargets = (\n"
        f"\t\t\t\t{uids['TARGET']} /* Anu */,\n"
        f"\t\t\t\t{uids['TARGET_TESTS']} /* AnuTests */,\n"
        f"\t\t\t\t{uids['TARGET_UITESTS']} /* AnuUITests */,\n"
        f"\t\t\t\t{uids['TARGET_W']} /* AnuWidget */,\n"
        f"\t\t\t\t{uids['TARGET_S']} /* AnuShare */,\n"
        f"\t\t\t\t{uids['TARGET_MAC']} /* AnuMac */,\n"
        f"\t\t\t\t{uids['TARGET_WR']} /* AnuWriting */,\n"  # writing extension
        f"\t\t\t\t{uids['TARGET_KB']} /* AnuKeyboard */,\n"  # keyboard extension
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
    parts = [
        phase(uids["PHASE_Sources"], SWIFT_FILES),
        phase(uids["PHASE_TestsSources"], TEST_FILES),
        phase(uids["PHASE_UITestsSources"], UITEST_FILES),
    ]
    return section("PBXSourcesBuildPhase", "\n".join(parts))

def resources_build_phase():
    lines_list = [
        f"\t\t\t\t{uids['BF_Assets']} /* Assets.xcassets in Resources */,",
        f"\t\t\t\t{uids['BF_Privacy']} /* PrivacyInfo.xcprivacy in Resources */,",
        f"\t\t\t\t{uids['BF_Skills']} /* Skills in Resources */,",
        f"\t\t\t\t{uids['BF_LiveDetector']} /* LiveDetector.mlmodelc in Resources */,",
    ]
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
        f"\t\t\t\t{uids['BF_LITERTLM_IOS']} /* LiteRTLM in Frameworks */,",
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
        "CODE_SIGN_ENTITLEMENTS": "Anu/Anu.entitlements",
        "COREML_CODEGEN_LANGUAGE": "None",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": DEVELOPMENT_TEAM,
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        # Partial plist merged into the generated one, for keys with no
        # INFOPLIST_KEY_ setting (see the comment in Anu/Info.plist).
        "INFOPLIST_FILE": "Anu/Info.plist",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_NSMicrophoneUsageDescription": "Anu listens through the microphone only while you talk to it or record a voice note.",
        "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription": "Anu turns what you say into text so you can talk to it. Recognition runs on this device when your language supports it; otherwise Apple's speech service transcribes it.",
        "INFOPLIST_KEY_NSRemindersFullAccessUsageDescription": "Anu reads and creates reminders only when you ask it to, for example to add a to-do or list what's due.",
        "INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription": "Anu reads and adds calendar events only when you ask it to, for example to check what's on today or book a meeting.",
        "INFOPLIST_KEY_NSContactsUsageDescription": "Anu looks up a contact's phone number or email only when you ask it to find, call, text or email someone.",
        "INFOPLIST_KEY_NSPhotoLibraryUsageDescription": "Anu looks at your photo library only when you ask about it, such as how many photos you have or when your latest ones were taken.",
        "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription": "Anu saves an image to your photo library when you ask it to.",
        "INFOPLIST_KEY_NSCameraUsageDescription": "Anu uses the camera when you point it at something to ask about it or take a photo for the chat.",
        # Vault reveal + unlock (LocalAuthentication .deviceOwnerAuthentication).
        "INFOPLIST_KEY_NSFaceIDUsageDescription": "Anu uses Face ID to unlock your vault before it shows a saved key or password.",
        # Only Apple's own encryption (HTTPS via URLSession, CryptoKit AES-GCM
        # for files on the device, Keychain): exempt, so no export documents.
        "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
        # Your Mac (Ollama) and A2A agents on the user's network. The partial
        # Info.plist adds ATS NSAllowsLocalNetworking for plain-HTTP LAN addresses.
        "INFOPLIST_KEY_NSLocalNetworkUsageDescription": "Anu connects to your own Mac and the agents you add on your network, only when you ask it to.",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        # Live talk's Live Activity (ADR-108's iOS form).
        "INFOPLIST_KEY_NSSupportsLiveActivities": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad":
            "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone":
            "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        # Force-load the LiteRT-LM static runtime + find the embedded dylib at
        # runtime (iOS apps embed in <app>/Frameworks). Same setup as AnuMac.
        # AlarmKit exists from iOS 26; weak-linked so iOS 17-25 still launch.
        # FoundationModels (Apple's models, parity A1-A3) likewise: iOS 26+,
        # every use behind #available.
        "OTHER_LDFLAGS": "$(inherited) -Xlinker -all_load -weak_framework AlarmKit -weak_framework FoundationModels",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX,
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
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Anu.app/Anu",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": DEVELOPMENT_TEAM,
        "GENERATE_INFOPLIST_FILE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX + ".tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
        # The Apple-model tests import FoundationModels (iOS 26+); weak-linked
        # like the app so the bundle loads on older simulators too.
        "OTHER_LDFLAGS": "$(inherited) -weak_framework FoundationModels",
    }
    uitest_common = {k: v for k, v in test_common.items()
                     if k not in ("BUNDLE_LOADER", "TEST_HOST")}
    uitest_common["TEST_TARGET_NAME"] = "Anu"
    uitest_common["PRODUCT_BUNDLE_IDENTIFIER"] = BUNDLE_PREFIX + ".uitests"

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
        f"\t\t{uids['CL_Project']} /* Build configuration list for PBXProject \"Anu\" */ = {{\n"
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
        f"\t\t{uids['CL_Target']} /* Build configuration list for PBXNativeTarget \"Anu\" */ = {{\n"
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
        f"\t\t{uids['CL_Tests']} /* Build configuration list for PBXNativeTarget \"AnuTests\" */ = {{\n"
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
        f"\t\t{uids['CL_UITests']} /* Build configuration list for PBXNativeTarget \"AnuUITests\" */ = {{\n"
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
    litertlm = (
        f"\t\t{uids['PRODDEP_LITERTLM']} /* LiteRTLM */ = {{\n"
        f"\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tpackage = {uids['PKG_LITERTLM']} /* XCLocalSwiftPackageReference \"ThirdParty/LiteRTLM\" */;\n"
        f"\t\t\tproductName = LiteRTLM;\n"
        f"\t\t}};"
    )
    return section("XCSwiftPackageProductDependency", content + "\n" + litertlm)


def local_swift_package_reference_section():
    content = (
        f"\t\t{uids['PKG_LITERTLM']} /* XCLocalSwiftPackageReference \"ThirdParty/LiteRTLM\" */ = {{\n"
        f"\t\t\tisa = XCLocalSwiftPackageReference;\n"
        f"\t\t\trelativePath = \"ThirdParty/LiteRTLM\";\n"
        f"\t\t}};"
    )
    return section("XCLocalSwiftPackageReference", content)

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
    p.append(f"\t\t{uids['BF_EmbedW']} /* AnuWidget.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {uids['PRODUCT_W']} /* AnuWidget.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")
    p.append(f"\t\t{uids['BF_EmbedS']} /* AnuShare.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {uids['PRODUCT_S']} /* AnuShare.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")

    # --- PBXFileReference (own sources + the .appex products) ---
    for n, path in WIDGET_OWN_FILES + SHARE_OWN_FILES:
        p.append(f"\t\t{uids[f'FR_{n}']} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {_pbx(n)}; path = {_pbx(path)}; sourceTree = SOURCE_ROOT; }};")
    p.append(f"\t\t{uids['PRODUCT_W']} /* AnuWidget.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = AnuWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; }};")
    p.append(f"\t\t{uids['PRODUCT_S']} /* AnuShare.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = AnuShare.appex; sourceTree = BUILT_PRODUCTS_DIR; }};")

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
    p.append(phase(uids["PHASE_W_Resources"], "PBXResourcesBuildPhase", "Resources", ext_privacy_resource("W")))
    p.append(phase(uids["PHASE_S_Sources"], "PBXSourcesBuildPhase", "Sources", s_src))
    p.append(phase(uids["PHASE_S_Frameworks"], "PBXFrameworksBuildPhase", "Frameworks", []))
    p.append(phase(uids["PHASE_S_Resources"], "PBXResourcesBuildPhase", "Resources", ext_privacy_resource("S")))
    p.extend(ext_privacy_objects(["W", "S"]))

    # --- Embed App Extensions copy phase (added to the app target's phases) ---
    p.append(
        f"\t\t{uids['PHASE_EmbedExt']} /* Embed App Extensions */ = {{\n"
        f"\t\t\tisa = PBXCopyFilesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tdstPath = \"\";\n"
        f"\t\t\tdstSubfolderSpec = 13;\n"
        f"\t\t\tfiles = (\n"
        f"\t\t\t\t{uids['BF_EmbedW']} /* AnuWidget.appex in Embed App Extensions */,\n"
        f"\t\t\t\t{uids['BF_EmbedS']} /* AnuShare.appex in Embed App Extensions */,\n"
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
    p.append(ext_target(uids["TARGET_W"], "AnuWidget", uids["CL_W"],
                        uids["PHASE_W_Sources"], uids["PHASE_W_Frameworks"], uids["PHASE_W_Resources"], uids["PRODUCT_W"]))
    p.append(ext_target(uids["TARGET_S"], "AnuShare", uids["CL_S"],
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
    p.append(proxy(uids["PROXY_W"], uids["TARGET_W"], "AnuWidget"))
    p.append(proxy(uids["PROXY_S"], uids["TARGET_S"], "AnuShare"))
    p.append(dep(uids["DEP_W"], uids["TARGET_W"], uids["PROXY_W"], "AnuWidget"))
    p.append(dep(uids["DEP_S"], uids["TARGET_S"], uids["PROXY_S"], "AnuShare"))

    # --- Build settings / configs ---
    ext_base = {
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": DEVELOPMENT_TEAM,
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
                  "INFOPLIST_FILE": "AnuWidget/Info.plist",
                  "CODE_SIGN_ENTITLEMENTS": "AnuWidget/AnuWidget.entitlements",
                  "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX + ".widget"}
    s_settings = {**ext_base,
                  "INFOPLIST_FILE": "AnuShare/Info.plist",
                  "CODE_SIGN_ENTITLEMENTS": "AnuShare/AnuShare.entitlements",
                  "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX + ".share"}
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
    p.append(cl(uids["CL_W"], "AnuWidget", uids["BC_W_Debug"], uids["BC_W_Release"]))
    p.append(cl(uids["CL_S"], "AnuShare", uids["BC_S_Debug"], uids["BC_S_Release"]))

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
    p.append(grp(uids["GR_Widget"], "AnuWidget", [uids[f"FR_{n}"] for n, _ in WIDGET_OWN_FILES] + [uids["FR_Privacy_W"]]))
    p.append(grp(uids["GR_Share"], "AnuShare", [uids[f"FR_{n}"] for n, _ in SHARE_OWN_FILES] + [uids["FR_Privacy_S"]]))
    p.append(grp(uids["GR_Extensions"], "Extensions", [uids["GR_Widget"], uids["GR_Share"]]))

    return "\n" + "\n".join(p) + "\n"

# ── Native macOS app target (AnuMac) ─────────────────────────────────────────
#
# Emitted as one concatenated block into the flat `objects` dict, exactly like
# extensions_section(). AnuMac compiles the SAME Swift sources as the iOS app
# (each via its OWN PBXBuildFile reusing the shared FR_<name>), links the MCP
# SwiftPM product + AppIntents, and links the vendored LiteRT-LM package, so the
# on-device brain is Gemma 4 on the Metal GPU, with Apple Foundation Models and
# the cloud tiers as on iOS. The mac target has no dependency on the iOS app and embeds no
# extensions; the iOS widget/share appex are iOS-only.

def macos_target_section():
    p = []

    # --- PBXBuildFile: one per shared Swift source (reuse FR_<name>) ---
    for n, _ in SWIFT_FILES:
        p.append(f"\t\t{uids[f'BF_MAC_{n}']} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {uids[f'FR_{n}']} /* {n} */; }};")
    # Frameworks: the MCP product (productRef, shared dependency) + AppIntents
    p.append(f"\t\t{uids['BF_MAC_MCP']} /* MCP in Frameworks */ = {{isa = PBXBuildFile; productRef = {uids['PRODDEP_MCP']} /* MCP */; }};")
    p.append(f"\t\t{uids['BF_MAC_LITERTLM']} /* LiteRTLM in Frameworks */ = {{isa = PBXBuildFile; productRef = {uids['PRODDEP_LITERTLM']} /* LiteRTLM */; }};")
    p.append(f"\t\t{uids['BF_MAC_AppIntents']} /* AppIntents.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {uids['FR_AppIntents']} /* AppIntents.framework */; }};")
    # Resources + Core ML model (reuse the iOS file refs)
    p.append(f"\t\t{uids['BF_MAC_Assets']} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Assets']} /* Assets.xcassets */; }};")
    p.append(f"\t\t{uids['BF_MAC_Privacy']} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Privacy']} /* PrivacyInfo.xcprivacy */; }};")
    p.append(f"\t\t{uids['BF_MAC_Skills']} /* Skills in Resources */ = {{isa = PBXBuildFile; fileRef = {uids['FR_Skills']} /* Skills */; }};")
    # --- PBXFileReference: the .app product ---
    p.append(f"\t\t{uids['PRODUCT_MAC']} /* AnuMac.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AnuMac.app; sourceTree = BUILT_PRODUCTS_DIR; }};")

    # --- Build phases ---
    src_lines = [f"\t\t\t\t{uids[f'BF_MAC_{n}']} /* {n} in Sources */," for n, _ in SWIFT_FILES]
    p.append(
        f"\t\t{uids['PHASE_MAC_Sources']} /* Sources */ = {{\n"
        f"\t\t\tisa = PBXSourcesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n" + "\n".join(src_lines) + "\n\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};"
    )
    res_lines = [
        f"\t\t\t\t{uids['BF_MAC_Assets']} /* Assets.xcassets in Resources */,",
        f"\t\t\t\t{uids['BF_MAC_Privacy']} /* PrivacyInfo.xcprivacy in Resources */,",
        f"\t\t\t\t{uids['BF_MAC_Skills']} /* Skills in Resources */,",
    ]
    p.append(
        f"\t\t{uids['PHASE_MAC_Resources']} /* Resources */ = {{\n"
        f"\t\t\tisa = PBXResourcesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n" + "\n".join(res_lines) + "\n\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};"
    )
    fw_lines = [
        f"\t\t\t\t{uids['BF_MAC_MCP']} /* MCP in Frameworks */,",
        f"\t\t\t\t{uids['BF_MAC_LITERTLM']} /* LiteRTLM in Frameworks */,",
        f"\t\t\t\t{uids['BF_MAC_AppIntents']} /* AppIntents.framework in Frameworks */,",
    ]
    p.append(
        f"\t\t{uids['PHASE_MAC_Frameworks']} /* Frameworks */ = {{\n"
        f"\t\t\tisa = PBXFrameworksBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n" + "\n".join(fw_lines) + "\n\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};"
    )

    # --- Native target ---
    p.append(
        f"\t\t{uids['TARGET_MAC']} /* AnuMac */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {uids['CL_MAC']} /* Build configuration list for PBXNativeTarget \"AnuMac\" */;\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{uids['PHASE_MAC_Sources']} /* Sources */,\n"
        f"\t\t\t\t{uids['PHASE_MAC_Resources']} /* Resources */,\n"
        f"\t\t\t\t{uids['PHASE_MAC_Frameworks']} /* Frameworks */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n"
        f"\t\t\tdependencies = (\n\t\t\t);\n"
        f"\t\t\tname = AnuMac;\n"
        f"\t\t\tpackageProductDependencies = (\n"
        f"\t\t\t\t{uids['PRODDEP_MCP']} /* MCP */,\n"
        f"\t\t\t\t{uids['PRODDEP_LITERTLM']} /* LiteRTLM */,\n"
        f"\t\t\t);\n"
        f"\t\t\tproductName = AnuMac;\n"
        f"\t\t\tproductReference = {uids['PRODUCT_MAC']} /* AnuMac.app */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.application\";\n"
        f"\t\t}};"
    )

    # --- Build settings (fresh dict — only macOS-valid keys) ---
    mac_base = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_ENTITLEMENTS": "AnuMac/AnuMac.entitlements",
        "COMBINE_HIDPI_IMAGES": "YES",
        "COREML_CODEGEN_LANGUAGE": "None",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": DEVELOPMENT_TEAM,
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "Anu",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.productivity",
        "INFOPLIST_KEY_NSMicrophoneUsageDescription": "Anu listens through the microphone only while you talk to it or record a voice note.",
        "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription": "Anu turns what you say into text so you can talk to it. Recognition runs on this device when your language supports it; otherwise Apple's speech service transcribes it.",
        "INFOPLIST_KEY_NSRemindersFullAccessUsageDescription": "Anu reads and creates reminders only when you ask it to, for example to add a to-do or list what's due.",
        "INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription": "Anu reads and adds calendar events only when you ask it to, for example to check what's on today or book a meeting.",
        "INFOPLIST_KEY_NSContactsUsageDescription": "Anu looks up a contact's phone number or email only when you ask it to find, call, text or email someone.",
        "INFOPLIST_KEY_NSPhotoLibraryUsageDescription": "Anu looks at your photo library only when you ask about it, such as how many photos you have or when your latest ones were taken.",
        "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription": "Anu saves an image to your photo library when you ask it to.",
        "INFOPLIST_KEY_NSCameraUsageDescription": "Anu uses the camera when you point it at something to ask about it or take a photo for the chat.",
        # Vault reveal + unlock (LocalAuthentication .deviceOwnerAuthentication).
        "INFOPLIST_KEY_NSFaceIDUsageDescription": "Anu uses Face ID to unlock your vault before it shows a saved key or password.",
        # Only Apple's own encryption (HTTPS via URLSession, CryptoKit AES-GCM
        # for files on the device, Keychain): exempt, so no export documents.
        "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
        # Your Mac (Ollama) and A2A agents on the user's network. The partial
        # Info.plist adds ATS NSAllowsLocalNetworking for plain-HTTP LAN addresses.
        "INFOPLIST_KEY_NSLocalNetworkUsageDescription": "Anu connects to your own Mac and the agents you add on your network, only when you ask it to.",
        "INFOPLIST_FILE": "Anu/Info.plist",
        "MACOSX_DEPLOYMENT_TARGET": "15.0",
        # Force-load the LiteRT-LM static archive (the flag upstream put on its
        # SPM product as an unsafe flag; applied here so the local package needs
        # no unsafe flags). Matches how the AI Edge Gallery Mac app links it.
        # FoundationModels is macOS 26+ and the Mac target deploys to 15, so it's
        # weak-linked and every use is behind #available (parity A1-A3).
        "OTHER_LDFLAGS": "$(inherited) -Xlinker -all_load -weak_framework FoundationModels",
        # Find the embedded LiteRT-LM dylib (Contents/Frameworks) at runtime.
        # A generated Mac target doesn't get Xcode's default rpath, so without
        # this dyld fails at launch: "Library not loaded: @rpath/libCLiteRTLM_mac.dylib".
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "macosx",
        "SUPPORTED_PLATFORMS": "macosx",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": "5.0",
    }
    mac_dbg = {**mac_base, "DEBUG_INFORMATION_FORMAT": "dwarf",
               "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
               "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
               "ONLY_ACTIVE_ARCH": "YES"}
    mac_rel = {**mac_base, "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
               "SWIFT_OPTIMIZATION_LEVEL": "-Owholemodule",
               "COPY_PHASE_STRIP": "NO"}

    def bc(uid, name, settings):
        return (
            f"\t\t{uid} /* {name} */ = {{\n"
            f"\t\t\tisa = XCBuildConfiguration;\n"
            f"\t\t\tbuildSettings = {{\n{fmt_build_settings(settings)}\n\t\t\t}};\n"
            f"\t\t\tname = {name};\n"
            f"\t\t}};"
        )
    p.append(bc(uids["BC_MAC_Debug"], "Debug", mac_dbg))
    p.append(bc(uids["BC_MAC_Release"], "Release", mac_rel))

    p.append(
        f"\t\t{uids['CL_MAC']} /* Build configuration list for PBXNativeTarget \"AnuMac\" */ = {{\n"
        f"\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{uids['BC_MAC_Debug']} /* Debug */,\n"
        f"\t\t\t\t{uids['BC_MAC_Release']} /* Release */,\n"
        f"\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
        f"\t\t\tdefaultConfigurationName = Release;\n"
        f"\t\t}};"
    )

    return "\n" + "\n".join(p) + "\n"

# ── Writing action extension + Anu keyboard targets ──────────────────────────
#
# Same shape as extensions_section() (flat objects dict, one block for every
# isa), for the two extensions added for Android parity rows 20–21. The app
# target gains PHASE_EmbedWK + DEP_WR/DEP_KB via one-line hooks in
# native_target_section(), project_section(), groups_section() and generate().

def writing_keyboard_extensions_section():
    p = []
    wr_files = WRITING_EXT_SHARED_FILES + [n for n, _ in WRITING_EXT_OWN_FILES]
    kb_files = KEYBOARD_EXT_SHARED_FILES + [n for n, _ in KEYBOARD_EXT_OWN_FILES] + [WK_COMMON_OWN]

    # --- PBXBuildFile ---
    for n in wr_files:
        p.append(f"\t\t{uids[f'BF_WR_{n}']} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {uids[f'FR_{n}']} /* {n} */; }};")
    for n in kb_files:
        p.append(f"\t\t{uids[f'BF_KB_{n}']} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {uids[f'FR_{n}']} /* {n} */; }};")
    p.append(f"\t\t{uids['BF_Embed_WR']} /* AnuWriting.appex in Embed Writing and Keyboard Extensions */ = {{isa = PBXBuildFile; fileRef = {uids['PRODUCT_WR']} /* AnuWriting.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")
    p.append(f"\t\t{uids['BF_Embed_KB']} /* AnuKeyboard.appex in Embed Writing and Keyboard Extensions */ = {{isa = PBXBuildFile; fileRef = {uids['PRODUCT_KB']} /* AnuKeyboard.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")

    # --- PBXFileReference (extension-only sources + products) ---
    for n, path in WRITING_EXT_OWN_FILES + KEYBOARD_EXT_OWN_FILES:
        p.append(f"\t\t{uids[f'FR_{n}']} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = {_pbx(n)}; path = {_pbx(path)}; sourceTree = SOURCE_ROOT; }};")
    p.append(f"\t\t{uids['PRODUCT_WR']} /* AnuWriting.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = AnuWriting.appex; sourceTree = BUILT_PRODUCTS_DIR; }};")
    p.append(f"\t\t{uids['PRODUCT_KB']} /* AnuKeyboard.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = AnuKeyboard.appex; sourceTree = BUILT_PRODUCTS_DIR; }};")

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
    for t, files in (("WR", wr_files), ("KB", kb_files)):
        src = [(uids[f'BF_{t}_{n}'], f"{n} in Sources") for n in files]
        p.append(phase(uids[f"PHASE_Sources_{t}"], "PBXSourcesBuildPhase", "Sources", src))
        p.append(phase(uids[f"PHASE_Frameworks_{t}"], "PBXFrameworksBuildPhase", "Frameworks", []))
        p.append(phase(uids[f"PHASE_Resources_{t}"], "PBXResourcesBuildPhase", "Resources", ext_privacy_resource(t)))
    p.extend(ext_privacy_objects(["WR", "KB"]))

    # --- Embed phase on the app (its own, beside "Embed App Extensions") ---
    p.append(
        f"\t\t{uids['PHASE_EmbedWK']} /* Embed Writing and Keyboard Extensions */ = {{\n"
        f"\t\t\tisa = PBXCopyFilesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tdstPath = \"\";\n"
        f"\t\t\tdstSubfolderSpec = 13;\n"
        f"\t\t\tfiles = (\n"
        f"\t\t\t\t{uids['BF_Embed_WR']} /* AnuWriting.appex in Embed Writing and Keyboard Extensions */,\n"
        f"\t\t\t\t{uids['BF_Embed_KB']} /* AnuKeyboard.appex in Embed Writing and Keyboard Extensions */,\n"
        f"\t\t\t);\n"
        f"\t\t\tname = \"Embed Writing and Keyboard Extensions\";\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};"
    )

    # --- Native targets, proxies, dependencies ---
    for t, name in (("WR", "AnuWriting"), ("KB", "AnuKeyboard")):
        p.append(
            f"\t\t{uids[f'TARGET_{t}']} /* {name} */ = {{\n"
            f"\t\t\tisa = PBXNativeTarget;\n"
            f"\t\t\tbuildConfigurationList = {uids[f'CL_{t}']} /* Build configuration list for PBXNativeTarget \"{name}\" */;\n"
            f"\t\t\tbuildPhases = (\n"
            f"\t\t\t\t{uids[f'PHASE_Sources_{t}']} /* Sources */,\n"
            f"\t\t\t\t{uids[f'PHASE_Frameworks_{t}']} /* Frameworks */,\n"
            f"\t\t\t\t{uids[f'PHASE_Resources_{t}']} /* Resources */,\n"
            f"\t\t\t);\n"
            f"\t\t\tbuildRules = (\n\t\t\t);\n"
            f"\t\t\tdependencies = (\n\t\t\t);\n"
            f"\t\t\tname = {name};\n"
            f"\t\t\tproductName = {name};\n"
            f"\t\t\tproductReference = {uids[f'PRODUCT_{t}']} /* {name}.appex */;\n"
            f"\t\t\tproductType = \"com.apple.product-type.app-extension\";\n"
            f"\t\t}};"
        )
        p.append(
            f"\t\t{uids[f'PROXY_{t}']} /* PBXContainerItemProxy */ = {{\n"
            f"\t\t\tisa = PBXContainerItemProxy;\n"
            f"\t\t\tcontainerPortal = {uids['PROJECT']} /* Project object */;\n"
            f"\t\t\tproxyType = 1;\n"
            f"\t\t\tremoteGlobalIDString = {uids[f'TARGET_{t}']};\n"
            f"\t\t\tremoteInfo = {name};\n"
            f"\t\t}};"
        )
        p.append(
            f"\t\t{uids[f'DEP_{t}']} /* PBXTargetDependency */ = {{\n"
            f"\t\t\tisa = PBXTargetDependency;\n"
            f"\t\t\ttarget = {uids[f'TARGET_{t}']} /* {name} */;\n"
            f"\t\t\ttargetProxy = {uids[f'PROXY_{t}']} /* PBXContainerItemProxy */;\n"
            f"\t\t}};"
        )

    # --- Build settings ---
    base = {
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": DEVELOPMENT_TEAM,
        # Xcode synthesizes CFBundle* and merges our partial Info.plist (the
        # NSExtension dict), as for AnuWidget/AnuShare.
        "GENERATE_INFOPLIST_FILE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SKIP_INSTALL": "YES",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "CLANG_ENABLE_MODULES": "YES",
        # Apple Foundation Models is iOS 26+; the extensions deploy to 17, so
        # the framework is weak-linked and every use is behind #available.
        "OTHER_LDFLAGS": "$(inherited) -weak_framework FoundationModels",
        # Extensions may only use extension-safe API (no UIApplication.shared).
        "APPLICATION_EXTENSION_API_ONLY": "YES",
    }
    settings = {
        "WR": {**base,
               "INFOPLIST_FILE": "AnuWriting/Info.plist",
               "CODE_SIGN_ENTITLEMENTS": "AnuWriting/AnuWriting.entitlements",
               "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX + ".writing"},
        "KB": {**base,
               "INFOPLIST_FILE": "AnuKeyboard/Info.plist",
               "CODE_SIGN_ENTITLEMENTS": "AnuKeyboard/AnuKeyboard.entitlements",
               "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX + ".keyboard"},
    }
    dbg_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                 "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"}
    rel_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_OPTIMIZATION_LEVEL": "-Owholemodule",
                 "COPY_PHASE_STRIP": "NO"}
    for t, name in (("WR", "AnuWriting"), ("KB", "AnuKeyboard")):
        for key, cfg, extra in (("BC_Debug", "Debug", dbg_extra), ("BC_Release", "Release", rel_extra)):
            p.append(
                f"\t\t{uids[f'{key}_{t}']} /* {cfg} */ = {{\n"
                f"\t\t\tisa = XCBuildConfiguration;\n"
                f"\t\t\tbuildSettings = {{\n{fmt_build_settings({**settings[t], **extra})}\n\t\t\t}};\n"
                f"\t\t\tname = {cfg};\n"
                f"\t\t}};"
            )
        p.append(
            f"\t\t{uids[f'CL_{t}']} /* Build configuration list for PBXNativeTarget \"{name}\" */ = {{\n"
            f"\t\t\tisa = XCConfigurationList;\n"
            f"\t\t\tbuildConfigurations = (\n"
            f"\t\t\t\t{uids[f'BC_Debug_{t}']} /* Debug */,\n"
            f"\t\t\t\t{uids[f'BC_Release_{t}']} /* Release */,\n"
            f"\t\t\t);\n"
            f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
            f"\t\t\tdefaultConfigurationName = Release;\n"
            f"\t\t}};"
        )

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
    def app_refs(folder):
        return [uids[f"FR_{n}"] for n, path in SWIFT_FILES if path.startswith(f"Sources/Anu/{folder}/")]
    p.append(grp(uids["GR_WK_Writing"], "Writing", app_refs("Writing")))
    p.append(grp(uids["GR_WK_Keyboard"], "Keyboard", app_refs("Keyboard")))
    p.append(grp(uids["GR_WK_WritingExt"], "AnuWriting", [uids[f"FR_{n}"] for n, _ in WRITING_EXT_OWN_FILES] + [uids["FR_Privacy_WR"]]))
    p.append(grp(uids["GR_WK_KeyboardExt"], "AnuKeyboard", [uids[f"FR_{n}"] for n, _ in KEYBOARD_EXT_OWN_FILES] + [uids["FR_Privacy_KB"]]))
    p.append(grp(uids["GR_WK"], "Writing & Keyboard",
                 [uids["GR_WK_Writing"], uids["GR_WK_Keyboard"], uids["GR_WK_WritingExt"], uids["GR_WK_KeyboardExt"],
                  uids["PRODUCT_WR"], uids["PRODUCT_KB"]]))

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
        + local_swift_package_reference_section()
        + extensions_section()
        + macos_target_section()
        + writing_keyboard_extensions_section()
        + "\n\t};\n"
        f"\trootObject = {uids['PROJECT']} /* Project object */;\n"
        "}\n"
    )
    return content

# ── Write files ───────────────────────────────────────────────────────────────

def write_assets():
    base = os.path.join(SOURCE_ROOT, "Anu", "Assets.xcassets")

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
    proj_dir = os.path.join(SOURCE_ROOT, "Anu.xcodeproj")
    os.makedirs(proj_dir, exist_ok=True)
    pbxproj_path = os.path.join(proj_dir, "project.pbxproj")
    content = generate()
    with open(pbxproj_path, "w") as f:
        f.write(content)
    print(f"✓ project.pbxproj written to {pbxproj_path}")

    # 3. Write a basic xcscheme so Xcode can run immediately
    schemes_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    os.makedirs(schemes_dir, exist_ok=True)
    scheme_path = os.path.join(schemes_dir, "Anu.xcscheme")
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
               BuildableName = "Anu.app"
               BlueprintName = "Anu"
               ReferencedContainer = "container:Anu.xcodeproj">
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
               BuildableName = "AnuTests.xctest"
               BlueprintName = "AnuTests"
               ReferencedContainer = "container:Anu.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{uids['TARGET_UITESTS']}"
               BuildableName = "AnuUITests.xctest"
               BlueprintName = "AnuUITests"
               ReferencedContainer = "container:Anu.xcodeproj">
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
            BuildableName = "Anu.app"
            BlueprintName = "Anu"
            ReferencedContainer = "container:Anu.xcodeproj">
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
            BuildableName = "Anu.app"
            BlueprintName = "Anu"
            ReferencedContainer = "container:Anu.xcodeproj">
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

    # 3b. Write the macOS scheme (build + run AnuMac; no test target on macOS)
    mac_scheme_path = os.path.join(schemes_dir, "AnuMac.xcscheme")
    mac_scheme_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
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
               BlueprintIdentifier = "{uids['TARGET_MAC']}"
               BuildableName = "AnuMac.app"
               BlueprintName = "AnuMac"
               ReferencedContainer = "container:Anu.xcodeproj">
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
            BlueprintIdentifier = "{uids['TARGET_MAC']}"
            BuildableName = "AnuMac.app"
            BlueprintName = "AnuMac"
            ReferencedContainer = "container:Anu.xcodeproj">
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
            BlueprintIdentifier = "{uids['TARGET_MAC']}"
            BuildableName = "AnuMac.app"
            BlueprintName = "AnuMac"
            ReferencedContainer = "container:Anu.xcodeproj">
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
    with open(mac_scheme_path, "w") as f:
        f.write(mac_scheme_xml)
    print(f"✓ xcscheme written to {mac_scheme_path}")

    print("\n✅ Done! Open Anu.xcodeproj in Xcode.")
    print("   • Set your Development Team in Signing & Capabilities")
    print("   • Connect a device (iOS 17+) and run")

if __name__ == "__main__":
    main()
