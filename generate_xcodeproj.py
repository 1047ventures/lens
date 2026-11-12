#!/usr/bin/env python3
"""
Generates a minimal but complete Lens.xcodeproj/project.pbxproj.
Run once to create the Xcode project, then open with Xcode (or build with xcodebuild).
Adapted from ../PhotosPruner/generate_xcodeproj.py, generalized to support an
arbitrary number of source sub-groups (Models/Services/ViewModels/Views).
"""

import os
import uuid

def make_uuid():
    return uuid.uuid4().hex.upper()[:24]

APP_NAME = "Lens"

# ---- File references ----
FILES = [
    # (relative path from project root, group path in Xcode)
    (f"{APP_NAME}/{APP_NAME}App.swift",                  APP_NAME),
    (f"{APP_NAME}/Info.plist",                            APP_NAME),
    (f"{APP_NAME}/{APP_NAME}.entitlements",               APP_NAME),

    (f"{APP_NAME}/Models/MediaFile.swift",                f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/DuplicateGroup.swift",           f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/CacheItem.swift",                f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/ArchiveCandidate.swift",         f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/OrganizeProposal.swift",         f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/ActionLogEntry.swift",           f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/TrustSettings.swift",            f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/OrganizeRule.swift",             f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/OrganizeSettings.swift",         f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/ScanOverview.swift",             f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Models/Project.swift",                  f"{APP_NAME}/Models"),

    (f"{APP_NAME}/Services/FileScanner.swift",            f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/HashingService.swift",         f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/PremiereProjectParser.swift",  f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/PremiereCacheFinder.swift",    f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/OrganizerService.swift",       f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/StaleFootageService.swift",    f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/ActionLogStore.swift",         f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/FileActionExecutor.swift",     f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/VideoMetadataService.swift",   f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/ThumbnailService.swift",       f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/ProjectStore.swift",           f"{APP_NAME}/Services"),

    (f"{APP_NAME}/ViewModels/ScanViewModel.swift",        f"{APP_NAME}/ViewModels"),

    (f"{APP_NAME}/Views/ContentView.swift",               f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/DuplicatesView.swift",            f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/CacheCleanupView.swift",          f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/OrganizeView.swift",              f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/ArchiveCandidatesView.swift",     f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/SettingsView.swift",              f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/ThumbnailImageView.swift",        f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/Theme.swift",                     f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/TodayView.swift",                 f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/ProjectsView.swift",              f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/ProjectDetailView.swift",         f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/FootageView.swift",               f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/PipelineView.swift",              f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/DealDetailView.swift",            f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/ProposalBuilderView.swift",       f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/LoginsView.swift",                f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/BankLoginView.swift",             f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Services/DriveCatalog.swift",           f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/PhotosLibrary.swift",          f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Views/LibraryDrivesView.swift",         f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/LibraryFolderView.swift",         f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/AskLensView.swift",               f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/MoneyView.swift",                 f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Views/GearView.swift",                  f"{APP_NAME}/Views"),
    (f"{APP_NAME}/Models/Money.swift",                    f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Services/MoneyStore.swift",             f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/Updater.swift",                f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/LensAI.swift",                 f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/Connections.swift",            f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Models/Deal.swift",                     f"{APP_NAME}/Models"),
    (f"{APP_NAME}/Services/Estimator.swift",              f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/DealStore.swift",              f"{APP_NAME}/Services"),
    (f"{APP_NAME}/Services/ProposalRenderer.swift",       f"{APP_NAME}/Services"),
]

SWIFT_FILES = [f for f, _ in FILES if f.endswith(".swift")]

# Sub-groups nested under the top-level app group (excludes the app group itself).
SUBGROUP_NAMES = ["Models", "Services", "ViewModels", "Views"]

# Assign stable UUIDs
IDs = {path: make_uuid() for path, _ in FILES}
BUILD_IDS = {path: make_uuid() for path in SWIFT_FILES}

TARGET_ID      = make_uuid()
PROJECT_ID     = make_uuid()
MAIN_GROUP_ID  = make_uuid()
PRODUCTS_ID    = make_uuid()
APP_REF_ID     = make_uuid()
ASSETS_ID       = make_uuid()  # Assets.xcassets folder reference
ASSETS_BUILD_ID = make_uuid()  # Assets.xcassets in Resources
BUILD_PHASE_SOURCES_ID = make_uuid()
BUILD_PHASE_FRAMEWORKS_ID = make_uuid()
BUILD_PHASE_RESOURCES_ID  = make_uuid()
DEBUG_CONFIG_ID  = make_uuid()
RELEASE_CONFIG_ID = make_uuid()
TARGET_DEBUG_CONFIG_ID  = make_uuid()
TARGET_RELEASE_CONFIG_ID = make_uuid()
CONFIG_LIST_PROJECT_ID = make_uuid()
CONFIG_LIST_TARGET_ID  = make_uuid()

APP_GROUP_ID = make_uuid()  # <APP_NAME> source root group
SUBGROUP_IDS = {name: make_uuid() for name in SUBGROUP_NAMES}

def file_ref_section():
    lines = ["/* Begin PBXFileReference section */"]
    for path, _ in FILES:
        fid = IDs[path]
        name = os.path.basename(path)
        if name.endswith(".swift"):
            ftype = "sourcecode.swift"
        elif name.endswith(".plist"):
            ftype = "text.plist.xml"
        elif name.endswith(".entitlements"):
            ftype = "text.plist.entitlements"
        else:
            ftype = "text"
        lines.append(f'\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {name}; sourceTree = "<group>"; }};')
    lines.append(f'\t\t{APP_REF_ID} /* {APP_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    lines.append(f'\t\t{ASSETS_ID} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
    lines.append("/* End PBXFileReference section */")
    return "\n".join(lines)

def build_file_section():
    lines = ["/* Begin PBXBuildFile section */"]
    for path in SWIFT_FILES:
        bid = BUILD_IDS[path]
        fid = IDs[path]
        name = os.path.basename(path)
        lines.append(f'\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};')
    lines.append(f'\t\t{ASSETS_BUILD_ID} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ASSETS_ID} /* Assets.xcassets */; }};')
    lines.append("/* End PBXBuildFile section */")
    return "\n".join(lines)

def group_section():
    lines = ["/* Begin PBXGroup section */"]

    # Root group
    lines.append(f'\t\t{MAIN_GROUP_ID} = {{')
    lines.append('\t\t\tisa = PBXGroup;')
    lines.append('\t\t\tchildren = (')
    lines.append(f'\t\t\t\t{APP_GROUP_ID} /* {APP_NAME} */,')
    lines.append(f'\t\t\t\t{PRODUCTS_ID} /* Products */,')
    lines.append('\t\t\t);')
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append('\t\t};')

    # Products group
    lines.append(f'\t\t{PRODUCTS_ID} /* Products */ = {{')
    lines.append('\t\t\tisa = PBXGroup;')
    lines.append('\t\t\tchildren = (')
    lines.append(f'\t\t\t\t{APP_REF_ID} /* {APP_NAME}.app */,')
    lines.append('\t\t\t);')
    lines.append('\t\t\tname = Products;')
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append('\t\t};')

    # App source root group
    top_level_files = [p for p, g in FILES if g == APP_NAME]
    lines.append(f'\t\t{APP_GROUP_ID} /* {APP_NAME} */ = {{')
    lines.append('\t\t\tisa = PBXGroup;')
    lines.append('\t\t\tchildren = (')
    for path in top_level_files:
        fid = IDs[path]
        name = os.path.basename(path)
        lines.append(f'\t\t\t\t{fid} /* {name} */,')
    lines.append(f'\t\t\t\t{ASSETS_ID} /* Assets.xcassets */,')
    for name in SUBGROUP_NAMES:
        lines.append(f'\t\t\t\t{SUBGROUP_IDS[name]} /* {name} */,')
    lines.append('\t\t\t);')
    lines.append(f'\t\t\tpath = {APP_NAME};')
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append('\t\t};')

    # Sub groups
    for name in SUBGROUP_NAMES:
        gid = SUBGROUP_IDS[name]
        gpaths = [p for p, g in FILES if g == f"{APP_NAME}/{name}"]
        lines.append(f'\t\t{gid} /* {name} */ = {{')
        lines.append('\t\t\tisa = PBXGroup;')
        lines.append('\t\t\tchildren = (')
        for path in gpaths:
            fid = IDs[path]
            fname = os.path.basename(path)
            lines.append(f'\t\t\t\t{fid} /* {fname} */,')
        lines.append('\t\t\t);')
        lines.append(f'\t\t\tpath = {name};')
        lines.append('\t\t\tsourceTree = "<group>";')
        lines.append('\t\t};')

    lines.append("/* End PBXGroup section */")
    return "\n".join(lines)

def sources_phase():
    lines = [
        "/* Begin PBXSourcesBuildPhase section */",
        f'\t\t{BUILD_PHASE_SOURCES_ID} /* Sources */ = {{',
        '\t\t\tisa = PBXSourcesBuildPhase;',
        '\t\t\tbuildActionMask = 2147483647;',
        '\t\t\tfiles = (',
    ]
    for path in SWIFT_FILES:
        bid = BUILD_IDS[path]
        name = os.path.basename(path)
        lines.append(f'\t\t\t\t{bid} /* {name} in Sources */,')
    lines += [
        '\t\t\t);',
        '\t\t\trunOnlyForDeploymentPostprocessing = 0;',
        '\t\t};',
        "/* End PBXSourcesBuildPhase section */",
    ]
    return "\n".join(lines)

def frameworks_phase():
    return f"""/* Begin PBXFrameworksBuildPhase section */
\t\t{BUILD_PHASE_FRAMEWORKS_ID} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */"""

def resources_phase():
    return f"""/* Begin PBXResourcesBuildPhase section */
\t\t{BUILD_PHASE_RESOURCES_ID} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ASSETS_BUILD_ID} /* Assets.xcassets in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */"""

def native_target():
    return f"""/* Begin PBXNativeTarget section */
\t\t{TARGET_ID} /* {APP_NAME} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {CONFIG_LIST_TARGET_ID} /* Build configuration list for PBXNativeTarget "{APP_NAME}" */;
\t\t\tbuildPhases = (
\t\t\t\t{BUILD_PHASE_SOURCES_ID} /* Sources */,
\t\t\t\t{BUILD_PHASE_FRAMEWORKS_ID} /* Frameworks */,
\t\t\t\t{BUILD_PHASE_RESOURCES_ID} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = {APP_NAME};
\t\t\tproductName = {APP_NAME};
\t\t\tproductReference = {APP_REF_ID} /* {APP_NAME}.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */"""

def project_section():
    return f"""/* Begin PBXProject section */
\t\t{PROJECT_ID} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{TARGET_ID} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {CONFIG_LIST_PROJECT_ID} /* Build configuration list for PBXProject "{APP_NAME}" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {MAIN_GROUP_ID};
\t\t\tproductRefGroup = {PRODUCTS_ID} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{TARGET_ID} /* {APP_NAME} */,
\t\t\t);
\t\t}};
/* End PBXProject section */"""

def build_configs():
    entitlements_path = f"{APP_NAME}/{APP_NAME}.entitlements"
    return f"""/* Begin XCBuildConfiguration section */
\t\t{DEBUG_CONFIG_ID} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{RELEASE_CONFIG_ID} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t\tVALIDATE_PRODUCT = YES;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{TARGET_DEBUG_CONFIG_ID} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = {entitlements_path};
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tINFOPLIST_FILE = {APP_NAME}/Info.plist;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.1047ventures.lens";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{TARGET_RELEASE_CONFIG_ID} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = {entitlements_path};
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tINFOPLIST_FILE = {APP_NAME}/Info.plist;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.1047ventures.lens";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */"""

def config_lists():
    return f"""/* Begin XCConfigurationList section */
\t\t{CONFIG_LIST_PROJECT_ID} /* Build configuration list for PBXProject "{APP_NAME}" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{DEBUG_CONFIG_ID} /* Debug */,
\t\t\t\t{RELEASE_CONFIG_ID} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{CONFIG_LIST_TARGET_ID} /* Build configuration list for PBXNativeTarget "{APP_NAME}" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{TARGET_DEBUG_CONFIG_ID} /* Debug */,
\t\t\t\t{TARGET_RELEASE_CONFIG_ID} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */"""

def generate():
    pbxproj = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

{file_ref_section()}

{build_file_section()}

{group_section()}

{sources_phase()}

{frameworks_phase()}

{resources_phase()}

{native_target()}

{project_section()}

{build_configs()}

{config_lists()}

\t}};
\trootObject = {PROJECT_ID} /* Project object */;
}}
"""
    out_dir = os.path.join(os.path.dirname(__file__), f"{APP_NAME}.xcodeproj")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "project.pbxproj")
    with open(out_path, "w") as f:
        f.write(pbxproj)
    print(f"Generated: {out_path}")
    print(f"Open with: open {APP_NAME}.xcodeproj")

if __name__ == "__main__":
    generate()
