# MediaPipe LLM Inference — runs the official Gemma 4 E4B .litertlm package.
# After re-running generate_xcodeproj.py, ALWAYS re-run `pod install`
# (regeneration wipes the pods integration from the pbxproj).
#
# The generator ALSO declares a Swift Package Manager dependency (the official
# MCP SDK) directly in project.pbxproj. `pod install` preserves the SPM keys
# (packageReferences / packageProductDependencies / productRef build file), so
# the order is: 1) python3 generate_xcodeproj.py  2) xcodebuild
# -resolvePackageDependencies  3) pod install  4) build/test via the workspace.
platform :ios, '17.0'

target 'GemmaAgent' do
  use_frameworks! :linkage => :static
  pod 'MediaPipeTasksGenAI'
  pod 'MediaPipeTasksGenAIC'

  # Do NOT integrate pods into the test targets:
  # - the app imports MediaPipe @_implementationOnly, so @testable import
  #   resolves without the module
  # - linking the static SDK twice (app + test bundle) aborts at launch
  #   with a duplicate MediaPipe calculator registration
end
