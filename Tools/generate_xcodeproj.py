#!/usr/bin/env python3
"""Generate InfiniCal.xcodeproj (no XcodeGen required).

The project has two targets:
  * InfiniCal        — the SwiftUI app bundle
  * InfiniCalHelper  — the root daemon, embedded into Contents/Library/Helper

Run this after adding or removing a source file:  python3 Tools/generate_xcodeproj.py
"""

import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = "InfiniCal"

APP_TARGET = "InfiniCal"
HELPER_TARGET = "InfiniCalHelper"
HELPER_PRODUCT = "com.infinitycomputer.infinical.helper"


def uid(key: str) -> str:
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def rel(path: str) -> str:
    return os.path.relpath(path, ROOT)


APP_SOURCES = [
    "Sources/Core/SMC.swift",
    "Sources/Core/L10n.swift",
    "Sources/Core/Battery.swift",
    "Sources/Core/PowerEstimate.swift",
    "Sources/Core/PowerMeter.swift",
    "Sources/Core/PowerFormat.swift",
    "Sources/Core/ChargeController.swift",
    "Sources/Core/ChargeArbitration.swift",
    "Sources/Core/ControlResult.swift",
    "Sources/Core/DeviceProfile.swift",
    "Sources/Core/DeviceProfileStore.swift",
    "Sources/Core/Advice.swift",
    "Sources/Core/AdviceProvider.swift",
    "Sources/Core/SystemChargeLimit.swift",
    "Sources/Core/Models.swift",
    "Sources/Core/CalibrationModel.swift",
    "Sources/Core/CalibrationMath.swift",
    "Sources/Core/CalibrationEngine.swift",
    "Sources/Core/GPUStress.swift",
    "Sources/Core/HIDThermal.swift",
    "Sources/Core/HistoryStore.swift",
    "Sources/Core/StoreIO.swift",
    "Sources/Core/LowPower.swift",
    "Sources/Core/Automation.swift",
    "Sources/Core/ChargeSession.swift",
    "Sources/Core/UsageProfile.swift",
    "Sources/Core/SleepSession.swift",
    "Sources/Core/ScenarioLimit.swift",
    "Sources/Core/FanPresetFile.swift",
    "Sources/Core/HealthReport.swift",
    "Sources/Core/PDFCanvas.swift",
    "Sources/Core/Migration.swift",
    "Sources/Core/StorageMode.swift",
    "Sources/Core/SparkleUpdater.swift",
    "Sources/UI/UpdatePanel.swift",
    "Sources/Core/Notifier.swift",
    "Sources/Core/AnomalyAlerts.swift",
    "Sources/Core/SleepControl.swift",
    "Sources/Core/FanController.swift",
    "Sources/Core/Typography.swift",
    "Sources/Core/Metrics.swift",
    "Sources/Core/Theme.swift",
    "Sources/Core/AppState.swift",
    "Sources/UI/PageScaffold.swift",
    "Sources/UI/Charts.swift",
    "Sources/UI/PowerFlowView.swift",
    "Sources/UI/DashboardView.swift",
    "Sources/UI/ChargeControlView.swift",
    "Sources/UI/CalibrationPanel.swift",
    "Sources/UI/FanControlView.swift",
    "Sources/UI/PanelsBattery.swift",
    "Sources/UI/PanelsAutomation.swift",
    "Sources/UI/PanelsAppearance.swift",
    "Sources/UI/HardwareDiagnosticsView.swift",
    "Sources/UI/DeviceProfileCard.swift",
    "Sources/UI/HistoryPanel.swift",
    "Sources/UI/AdviceCard.swift",
    "Sources/UI/RootView.swift",
    "Sources/UI/AppDelegate.swift",
    "Sources/UI/MenuBar.swift",
    "Sources/UI/OnboardingSheet.swift",
    "Sources/main.swift",
]

HELPER_SOURCES = [
    "Sources/Core/L10n.swift",
    "Sources/Core/SMC.swift",
    "Helper/main.swift",
]

RESOURCES = ["Resources/AppIcon.icns", "Resources/en.json"]
PLIST = "Resources/Info.plist"
SPARKLE_FRAMEWORK = "Vendor/Sparkle.framework"

for path in APP_SOURCES + HELPER_SOURCES + RESOURCES + [PLIST, SPARKLE_FRAMEWORK]:
    assert os.path.exists(os.path.join(ROOT, path)), path

APP_PRODUCT = uid("product-app")
HELPER_PRODUCT_REF = uid("product-helper")
PROJECT_OBJ = uid("project")
MAIN_GROUP = uid("group-main")
PRODUCTS_GROUP = uid("group-products")
SOURCES_GROUP = uid("group-sources")
CORE_GROUP = uid("group-core")
UI_GROUP = uid("group-ui")
HELPER_GROUP = uid("group-helper")
RESOURCES_GROUP = uid("group-resources")

APP_TARGET_ID = uid("target-app")
HELPER_TARGET_ID = uid("target-helper")

APP_SOURCES_PHASE = uid("phase-app-sources")
APP_RESOURCES_PHASE = uid("phase-app-resources")
APP_FRAMEWORKS_PHASE = uid("phase-app-frameworks")
APP_COPY_PHASE = uid("phase-app-copy")
APP_EMBED_FRAMEWORKS_PHASE = uid("phase-app-embed-frameworks")
HELPER_SOURCES_PHASE = uid("phase-helper-sources")
HELPER_FRAMEWORKS_PHASE = uid("phase-helper-frameworks")

APP_CONFIG_LIST = uid("config-list-app")
HELPER_CONFIG_LIST = uid("config-list-helper")
PROJECT_CONFIG_LIST = uid("config-list-project")
APP_DEBUG = uid("config-app-debug")
APP_RELEASE = uid("config-app-release")
HELPER_DEBUG = uid("config-helper-debug")
HELPER_RELEASE = uid("config-helper-release")
PROJECT_DEBUG = uid("config-project-debug")
PROJECT_RELEASE = uid("config-project-release")

DEPENDENCY = uid("dependency-app-helper")
CONTAINER_PROXY = uid("proxy-app-helper")

FILE_REF = {path: uid("file-" + path) for path in APP_SOURCES + HELPER_SOURCES + RESOURCES + [PLIST]}
BUILD_FILE = {}

# ---------------------------------------------------------------- file refs

file_ref_lines = []
for path in APP_SOURCES + HELPER_SOURCES:
    file_ref_lines.append(
        f'\t\t{FILE_REF[path]} /* {os.path.basename(path)} */ = {{isa = PBXFileReference; '
        f'lastKnownFileType = sourcecode.swift; path = {os.path.basename(path)}; sourceTree = "<group>"; }};'
    )
for path in RESOURCES:
    file_ref_lines.append(
        f'\t\t{FILE_REF[path]} /* {os.path.basename(path)} */ = {{isa = PBXFileReference; '
        f'lastKnownFileType = file; path = {os.path.basename(path)}; sourceTree = "<group>"; }};'
    )
file_ref_lines.append(
    f'\t\t{FILE_REF[PLIST]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; '
    f'path = Info.plist; sourceTree = "<group>"; }};'
)
file_ref_lines.append(
    f'\t\t{APP_PRODUCT} /* {APP_TARGET}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; '
    f'includeInIndex = 0; path = {APP_TARGET}.app; sourceTree = BUILT_PRODUCTS_DIR; }};'
)
file_ref_lines.append(
    f'\t\t{HELPER_PRODUCT_REF} /* {HELPER_PRODUCT} */ = {{isa = PBXFileReference; explicitFileType = '
    f'"compiled.mach-o.executable"; includeInIndex = 0; path = {HELPER_PRODUCT}; sourceTree = BUILT_PRODUCTS_DIR; }};'
)
SPARKLE_REF = uid("file-" + SPARKLE_FRAMEWORK)
file_ref_lines.append(
    f'\t\t{SPARKLE_REF} /* Sparkle.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; '
    f'name = Sparkle.framework; path = {SPARKLE_FRAMEWORK}; sourceTree = "<group>"; }};'
)

# ---------------------------------------------------------------- build files

build_file_lines = []
for path in APP_SOURCES:
    bid = uid("build-app-" + path)
    BUILD_FILE[("app", path)] = bid
    build_file_lines.append(
        f'\t\t{bid} /* {os.path.basename(path)} in Sources */ = {{isa = PBXBuildFile; fileRef = {FILE_REF[path]} '
        f'/* {os.path.basename(path)} */; }};'
    )
for path in HELPER_SOURCES:
    bid = uid("build-helper-" + path)
    BUILD_FILE[("helper", path)] = bid
    build_file_lines.append(
        f'\t\t{bid} /* {os.path.basename(path)} in Sources */ = {{isa = PBXBuildFile; fileRef = {FILE_REF[path]} '
        f'/* {os.path.basename(path)} */; }};'
    )
for path in RESOURCES:
    bid = uid("build-res-" + path)
    BUILD_FILE[("res", path)] = bid
    build_file_lines.append(
        f'\t\t{bid} /* {os.path.basename(path)} in Resources */ = {{isa = PBXBuildFile; fileRef = {FILE_REF[path]} '
        f'/* {os.path.basename(path)} */; }};'
    )
EMBED_BUILD_FILE = uid("build-embed-helper")
build_file_lines.append(
    f'\t\t{EMBED_BUILD_FILE} /* {HELPER_PRODUCT} in Embed Helper */ = {{isa = PBXBuildFile; '
    f'fileRef = {HELPER_PRODUCT_REF} /* {HELPER_PRODUCT} */; settings = {{ATTRIBUTES = (CodeSignOnCopy, ); }}; }};'
)
SPARKLE_LINK_FILE = uid("build-link-sparkle")
build_file_lines.append(
    f'\t\t{SPARKLE_LINK_FILE} /* Sparkle.framework in Frameworks */ = {{isa = PBXBuildFile; '
    f'fileRef = {SPARKLE_REF} /* Sparkle.framework */; }};'
)
SPARKLE_EMBED_FILE = uid("build-embed-sparkle")
build_file_lines.append(
    f'\t\t{SPARKLE_EMBED_FILE} /* Sparkle.framework in Embed Frameworks */ = {{isa = PBXBuildFile; '
    f'fileRef = {SPARKLE_REF} /* Sparkle.framework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};'
)

# ---------------------------------------------------------------- groups

core_children = "\n".join(
    f'\t\t\t\t{FILE_REF[p]} /* {os.path.basename(p)} */,' for p in APP_SOURCES if p.startswith("Sources/Core")
)
ui_children = "\n".join(
    f'\t\t\t\t{FILE_REF[p]} /* {os.path.basename(p)} */,' for p in APP_SOURCES if p.startswith("Sources/UI")
)
sources_children = "\n".join([
    f"\t\t\t\t{CORE_GROUP} /* Core */,",
    f"\t\t\t\t{UI_GROUP} /* UI */,",
    f"\t\t\t\t{FILE_REF['Sources/main.swift']} /* main.swift */,",
])
helper_children = f'\t\t\t\t{FILE_REF["Helper/main.swift"]} /* main.swift */,'
resources_children = "\n".join(
    [f"\t\t\t\t{FILE_REF[PLIST]} /* Info.plist */,"] +
    [f"\t\t\t\t{FILE_REF[p]} /* {os.path.basename(p)} */," for p in RESOURCES]
)

group_lines = [
    f'''\t\t{MAIN_GROUP} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{SOURCES_GROUP} /* Sources */,
\t\t\t\t{HELPER_GROUP} /* Helper */,
\t\t\t\t{RESOURCES_GROUP} /* Resources */,
\t\t\t\t{SPARKLE_REF} /* Sparkle.framework */,
\t\t\t\t{PRODUCTS_GROUP} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};''',
    f'''\t\t{PRODUCTS_GROUP} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{APP_PRODUCT} /* {APP_TARGET}.app */,
\t\t\t\t{HELPER_PRODUCT_REF} /* {HELPER_PRODUCT} */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};''',
    f'''\t\t{SOURCES_GROUP} /* Sources */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{sources_children}
\t\t\t);
\t\t\tpath = Sources;
\t\t\tsourceTree = "<group>";
\t\t}};''',
    f'''\t\t{CORE_GROUP} /* Core */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{core_children}
\t\t\t);
\t\t\tpath = Core;
\t\t\tsourceTree = "<group>";
\t\t}};''',
    f'''\t\t{UI_GROUP} /* UI */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{ui_children}
\t\t\t);
\t\t\tpath = UI;
\t\t\tsourceTree = "<group>";
\t\t}};''',
    f'''\t\t{HELPER_GROUP} /* Helper */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{helper_children}
\t\t\t);
\t\t\tpath = Helper;
\t\t\tsourceTree = "<group>";
\t\t}};''',
    f'''\t\t{RESOURCES_GROUP} /* Resources */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{resources_children}
\t\t\t);
\t\t\tpath = Resources;
\t\t\tsourceTree = "<group>";
\t\t}};''',
]

# ---------------------------------------------------------------- phases

app_source_files = "\n".join(
    f'\t\t\t\t{BUILD_FILE[("app", p)]} /* {os.path.basename(p)} in Sources */,' for p in APP_SOURCES
)
helper_source_files = "\n".join(
    f'\t\t\t\t{BUILD_FILE[("helper", p)]} /* {os.path.basename(p)} in Sources */,' for p in HELPER_SOURCES
)
resource_files = "\n".join(
    f'\t\t\t\t{BUILD_FILE[("res", p)]} /* {os.path.basename(p)} in Resources */,' for p in RESOURCES
)

phase_lines = [
    f'''\t\t{APP_SOURCES_PHASE} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{app_source_files}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
    f'''\t\t{APP_RESOURCES_PHASE} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{resource_files}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
    f'''\t\t{APP_FRAMEWORKS_PHASE} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{SPARKLE_LINK_FILE} /* Sparkle.framework in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
    f'''\t\t{APP_COPY_PHASE} /* Embed Helper */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = Contents/Library/Helper;
\t\t\tdstSubfolderSpec = 1;
\t\t\tfiles = (
\t\t\t\t{EMBED_BUILD_FILE} /* {HELPER_PRODUCT} in Embed Helper */,
\t\t\t);
\t\t\tname = "Embed Helper";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
    f'''\t\t{APP_EMBED_FRAMEWORKS_PHASE} /* Embed Frameworks */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 10;
\t\t\tfiles = (
\t\t\t\t{SPARKLE_EMBED_FILE} /* Sparkle.framework in Embed Frameworks */,
\t\t\t);
\t\t\tname = "Embed Frameworks";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
    f'''\t\t{HELPER_SOURCES_PHASE} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{helper_source_files}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
    f'''\t\t{HELPER_FRAMEWORKS_PHASE} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};''',
]

# ---------------------------------------------------------------- targets

target_lines = [
    f'''\t\t{APP_TARGET_ID} /* {APP_TARGET} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {APP_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "{APP_TARGET}" */;
\t\t\tbuildPhases = (
\t\t\t\t{APP_SOURCES_PHASE} /* Sources */,
\t\t\t\t{APP_FRAMEWORKS_PHASE} /* Frameworks */,
\t\t\t\t{APP_RESOURCES_PHASE} /* Resources */,
\t\t\t\t{APP_EMBED_FRAMEWORKS_PHASE} /* Embed Frameworks */,
\t\t\t\t{APP_COPY_PHASE} /* Embed Helper */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{DEPENDENCY} /* PBXTargetDependency */,
\t\t\t);
\t\t\tname = {APP_TARGET};
\t\t\tproductName = {APP_TARGET};
\t\t\tproductReference = {APP_PRODUCT} /* {APP_TARGET}.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};''',
    f'''\t\t{HELPER_TARGET_ID} /* {HELPER_TARGET} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {HELPER_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "{HELPER_TARGET}" */;
\t\t\tbuildPhases = (
\t\t\t\t{HELPER_SOURCES_PHASE} /* Sources */,
\t\t\t\t{HELPER_FRAMEWORKS_PHASE} /* Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = {HELPER_TARGET};
\t\t\tproductName = {HELPER_TARGET};
\t\t\tproductReference = {HELPER_PRODUCT_REF} /* {HELPER_PRODUCT} */;
\t\t\tproductType = "com.apple.product-type.tool";
\t\t}};''',
    f'''\t\t{DEPENDENCY} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {HELPER_TARGET_ID} /* {HELPER_TARGET} */;
\t\t\ttargetProxy = {CONTAINER_PROXY} /* PBXContainerItemProxy */;
\t\t}};''',
    f'''\t\t{CONTAINER_PROXY} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {PROJECT_OBJ} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {HELPER_TARGET_ID};
\t\t\tremoteInfo = {HELPER_TARGET};
\t\t}};''',
]

# ---------------------------------------------------------------- project

project_line = f'''\t\t{PROJECT_OBJ} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{APP_TARGET_ID} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t\t{HELPER_TARGET_ID} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "{PROJECT}" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = zh_CN;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t\tzh_CN,
\t\t\t);
\t\t\tmainGroup = {MAIN_GROUP};
\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{APP_TARGET_ID} /* {APP_TARGET} */,
\t\t\t\t{HELPER_TARGET_ID} /* {HELPER_TARGET} */,
\t\t\t);
\t\t}};'''

# ---------------------------------------------------------------- build settings

common = '''\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = NO;
\t\t\t\tCODE_SIGN_IDENTITY = "-";
\t\t\t\tCODE_SIGN_STYLE = Manual;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_HARDENED_RUNTIME = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_VERSION = 5.0;
'''

project_debug = common + '''\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
'''
project_release = common + '''\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tONLY_ACTIVE_ARCH = NO;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
'''

app_common = '''\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tARCHS = (
\t\t\t\t\tarm64,
\t\t\t\t\tx86_64,
\t\t\t\t);
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = "";
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 46;
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;
\t\t\t\tFRAMEWORK_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(SRCROOT)/Vendor",
\t\t\t\t);
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0.37;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.infinitycomputer.infinical;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
'''

helper_common = '''\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 12.0;
\t\t\t\tARCHS = (
\t\t\t\t\tarm64,
\t\t\t\t\tx86_64,
\t\t\t\t);
\t\t\t\tCURRENT_PROJECT_VERSION = 46;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tMARKETING_VERSION = 1.0.37;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.infinitycomputer.infinical.helper;
\t\t\t\tPRODUCT_NAME = com.infinitycomputer.infinical.helper;
\t\t\t\tSKIP_INSTALL = YES;
'''

config_lines = [
    f'''\t\t{PROJECT_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{project_debug}\t\t\t}};
\t\t\tname = Debug;
\t\t}};''',
    f'''\t\t{PROJECT_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{project_release}\t\t\t}};
\t\t\tname = Release;
\t\t}};''',
    f'''\t\t{APP_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{app_common}\t\t\t}};
\t\t\tname = Debug;
\t\t}};''',
    f'''\t\t{APP_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{app_common}\t\t\t}};
\t\t\tname = Release;
\t\t}};''',
    f'''\t\t{HELPER_DEBUG} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{helper_common}\t\t\t}};
\t\t\tname = Debug;
\t\t}};''',
    f'''\t\t{HELPER_RELEASE} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{helper_common}\t\t\t}};
\t\t\tname = Release;
\t\t}};''',
]

config_list_lines = [
    f'''\t\t{PROJECT_CONFIG_LIST} /* Build configuration list for PBXProject "{PROJECT}" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{PROJECT_DEBUG} /* Debug */,
\t\t\t\t{PROJECT_RELEASE} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''',
    f'''\t\t{APP_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "{APP_TARGET}" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{APP_DEBUG} /* Debug */,
\t\t\t\t{APP_RELEASE} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''',
    f'''\t\t{HELPER_CONFIG_LIST} /* Build configuration list for PBXNativeTarget "{HELPER_TARGET}" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{HELPER_DEBUG} /* Debug */,
\t\t\t\t{HELPER_RELEASE} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};''',
]


def section(name: str, lines) -> str:
    body = "\n".join(lines)
    return f"/* Begin {name} section */\n{body}\n/* End {name} section */\n"


pbxproj = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

{section("PBXBuildFile", build_file_lines)}
{section("PBXContainerItemProxy", [target_lines[3]])}
{section("PBXCopyFilesBuildPhase", [phase_lines[3]])}
{section("PBXFileReference", file_ref_lines)}
{section("PBXFrameworksBuildPhase", [phase_lines[2], phase_lines[5]])}
{section("PBXGroup", group_lines)}
{section("PBXNativeTarget", [target_lines[0], target_lines[1]])}
{section("PBXProject", [project_line])}
{section("PBXResourcesBuildPhase", [phase_lines[1]])}
{section("PBXSourcesBuildPhase", [phase_lines[0], phase_lines[4]])}
{section("PBXTargetDependency", [target_lines[2]])}
{section("XCBuildConfiguration", config_lines)}
{section("XCConfigurationList", config_list_lines)}
\t}};
\trootObject = {PROJECT_OBJ} /* Project object */;
}}
"""

project_dir = os.path.join(ROOT, PROJECT + ".xcodeproj")
os.makedirs(os.path.join(project_dir, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(project_dir, "project.pbxproj"), "w", encoding="utf-8") as handle:
    handle.write(pbxproj)

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{APP_TARGET_ID}"
               BuildableName = "{APP_TARGET}.app"
               BlueprintName = "{APP_TARGET}"
               ReferencedContainer = "container:{PROJECT}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_TARGET_ID}"
            BuildableName = "{APP_TARGET}.app"
            BlueprintName = "{APP_TARGET}"
            ReferencedContainer = "container:{PROJECT}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_TARGET_ID}"
            BuildableName = "{APP_TARGET}.app"
            BlueprintName = "{APP_TARGET}"
            ReferencedContainer = "container:{PROJECT}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
with open(os.path.join(project_dir, "xcshareddata", "xcschemes", APP_TARGET + ".xcscheme"), "w", encoding="utf-8") as handle:
    handle.write(scheme)

print("wrote", project_dir)
