#!/usr/bin/env python3
"""
Xcode project.pbxproj generator for 悬浮提词器

Usage: python3 generate_xcodeproj.py
Output: Teleprompter.xcodeproj/project.pbxproj
"""

import os
import uuid

PROJ_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(PROJ_DIR, "Teleprompter")
XCODE_DIR = os.path.join(PROJ_DIR, "Teleprompter.xcodeproj")
BUNDLE_ID = "com.teleprompter.1777642669"

def uid():
    return uuid.uuid4().hex.upper()[:24]

def esc(s):
    """Escape a string for OpenStep plist (just wrap in quotes)."""
    return f'"{s}"'

def collect_files(base_dir, extensions):
    """Collect all files with given extensions recursively."""
    results = []
    for root, dirs, files in os.walk(base_dir):
        for f in sorted(files):
            if any(f.endswith(ext) for ext in extensions):
                full = os.path.join(root, f)
                # Relative path from PROJ_DIR
                rel = os.path.relpath(full, PROJ_DIR)
                # Relative path from SRC_DIR
                rel_src = os.path.relpath(full, SRC_DIR)
                results.append((full, rel, rel_src))
    return results

# Collect all source files
swift_files = collect_files(SRC_DIR, [".swift"])
resource_files = collect_files(os.path.join(SRC_DIR, "Resources"), [".json", ".svg"])
# Only keep the xcassets folder reference, not individual files inside it
# Actually, xcassets is a directory, we reference it as a folder

all_swift = [(f, r, rs) for f, r, rs in swift_files]

print(f"Found {len(all_swift)} Swift files")

# Generate UUIDs
def make_files_and_groups():
    """
    Build PBXFileReference and PBXGroup entries.
    
    Returns:
        file_refs: {rel_path: oid} for all Swift files
        build_files: {rel_path: oid} for PBXBuildFile
        groups: {group_name: {children: [...], metadata}}
    """
    file_refs = {}
    build_files = {}
    
    # Create file references for all Swift files
    for full, rel, rel_src in all_swift:
        oid = uid()
        file_refs[rel] = oid
        bfid = uid()
        build_files[rel] = bfid

    # Add product reference
    product_ref_id = uid()
    product_build_file_id = None  # Not needed
    
    return file_refs, build_files, product_ref_id

def encode_value(v, indent=0):
    t = "    " * indent
    if isinstance(v, dict):
        items = []
        for k in sorted(v.keys()):
            items.append(f"{t}    {k} = {encode_value(v[k], indent + 1)};")
        return "{\n" + "\n".join(items) + "\n" + t + "}"
    elif isinstance(v, list):
        items = [f"{t}    {encode_value(item, indent + 1)}," for item in v]
        return "(\n" + "\n".join(items) + "\n" + t + ")"
    elif isinstance(v, str):
        return f'"{v}"'
    elif isinstance(v, bool):
        return "YES" if v else "NO"
    elif isinstance(v, int):
        return str(v)
    else:
        return str(v)

def generate():
    # === 1. Create UUIDs ===
    
    # File references
    file_refs = {}  # rel_path -> oid
    build_files = {}  # rel_path -> oid
    
    for full, rel, rel_src in all_swift:
        froid = uid()
        bfoid = uid()
        file_refs[rel] = froid
        build_files[rel] = bfoid
    
    # Product reference (Teleprompter.app)
    product_ref_id = uid()
    
    # Asset catalog reference
    assets_froid = uid()
    
    # Preview Assets reference
    preview_assets_froid = uid()
    
    # Info.plist reference
    info_plist_froid = uid()
    
    # Entitlements reference
    entitlements_froid = uid()
    
    # === 2. Create groups ===
    
    # Build group hierarchy based on directory structure
    # We need: root -> Teleprompter -> {App, Features/{PIP,Teleprompter,Audio,ScriptEditor,Settings,Usage}, Models, Services, Resources, Supporting/{Extensions}}
    
    # Leaf group IDs (for real directories)
    app_group_id = uid()
    pip_group_id = uid()
    teleprompter_feat_group_id = uid()
    audio_group_id = uid()
    script_group_id = uid()
    settings_group_id = uid()
    usage_group_id = uid()
    features_group_id = uid()
    models_group_id = uid()
    services_group_id = uid()
    resources_group_id = uid()
    supporting_group_id = uid()
    extensions_group_id = uid()
    teleprompter_group_id = uid()
    root_group_id = uid()
    
    # Build children lists for each group
    app_children = []
    pip_children = []
    teleprompter_feat_children = []
    audio_children = []
    script_children = []
    settings_children = []
    usage_children = []
    models_children = []
    services_children = []
    ext_children = []
    supporting_children = []
    teleprompter_root_children = []
    
    # Categorize each Swift file into the appropriate group
    for full, rel, rel_src in all_swift:
        froid = file_refs[rel]
        if rel_src.startswith("App/"):
            app_children.append(froid)
        elif rel_src.startswith("Features/PIP/"):
            pip_children.append(froid)
        elif rel_src.startswith("Features/Teleprompter/"):
            teleprompter_feat_children.append(froid)
        elif rel_src.startswith("Features/Audio/"):
            audio_children.append(froid)
        elif rel_src.startswith("Features/ScriptEditor/"):
            script_children.append(froid)
        elif rel_src.startswith("Features/Settings/"):
            settings_children.append(froid)
        elif rel_src.startswith("Features/Usage/"):
            usage_children.append(froid)
        elif rel_src.startswith("Models/"):
            models_children.append(froid)
        elif rel_src.startswith("Services/"):
            services_children.append(froid)
        elif rel_src.startswith("Supporting/Extensions/"):
            ext_children.append(froid)
        elif rel_src.startswith("Supporting/"):
            supporting_children.append(froid)
        else:
            # Files at the root of Teleprompter/ (like UIColor+Hex.swift, Color+Hex.swift)
            # Add them directly to the Teleprompter group
            teleprompter_root_children.append(froid)
    
    # Also add Info.plist to the teleprompter group directly
    # Add Assets.xcassets to resources group
    
    # === 3. Build the sections ===
    
    sections = {}
    
    # --- PBXBuildFile ---
    build_file_section = {}
    for rel, bfid in build_files.items():
        build_file_section[bfid] = {
            "isa": "PBXBuildFile",
            "fileRef": file_refs[rel],
        }
    # Asset catalog build file
    assets_build_froid = uid()
    build_file_section[assets_build_froid] = {
        "isa": "PBXBuildFile",
        "fileRef": assets_froid,
    }
    
    sections["PBXBuildFile"] = build_file_section
    
    # --- PBXFileReference ---
    file_ref_section = {}
    for rel, froid in file_refs.items():
        # rel 是相对于 PROJ_DIR 的路径，如 "Teleprompter/Features/Store/PaywallView.swift"
        # 转换为相对于 SRC_DIR 的路径，如 "Features/Store/PaywallView.swift"
        # 因为 main group 会设置 path = "Teleprompter"
        rel_src = os.path.relpath(os.path.join(PROJ_DIR, rel), SRC_DIR)
        file_ref_section[froid] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": "sourcecode.swift",
            "path": rel_src,
            "sourceTree": "<group>",
        }
    
    # Product reference
    file_ref_section[product_ref_id] = {
        "isa": "PBXFileReference",
        "explicitFileType": "wrapper.application",
        "includeInIndex": 0,
        "path": "Teleprompter.app",
        "sourceTree": "BUILT_PRODUCTS_DIR",
    }
    
    # Assets.xcassets
    file_ref_section[assets_froid] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "folder.assetcatalog",
        "path": "Assets.xcassets",
        "sourceTree": "<group>",
    }
    
    # Preview Assets.xcassets
    file_ref_section[preview_assets_froid] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "folder.assetcatalog",
        "path": "Preview Assets.xcassets",
        "sourceTree": "<group>",
    }
    
    # Info.plist
    file_ref_section[info_plist_froid] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "text.plist.xml",
        "path": "Info.plist",
        "sourceTree": "<group>",
    }
    
    # Entitlements
    file_ref_section[entitlements_froid] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "text.plist.xml",
        "path": "Teleprompter.entitlements",
        "sourceTree": "<group>",
    }
    
    sections["PBXFileReference"] = file_ref_section
    
    # --- PBXGroup ---
    group_section = {
        app_group_id: {
            "isa": "PBXGroup",
            "children": sorted(app_children),
            "name": "App",
            "path": "App",
            "sourceTree": "<group>",
        },
        pip_group_id: {
            "isa": "PBXGroup",
            "children": sorted(pip_children),
            "name": "PIP",
            "path": "PIP",
            "sourceTree": "<group>",
        },
        teleprompter_feat_group_id: {
            "isa": "PBXGroup",
            "children": sorted(teleprompter_feat_children),
            "name": "Teleprompter",
            "path": "Teleprompter",
            "sourceTree": "<group>",
        },
        audio_group_id: {
            "isa": "PBXGroup",
            "children": sorted(audio_children),
            "name": "Audio",
            "path": "Audio",
            "sourceTree": "<group>",
        },
        script_group_id: {
            "isa": "PBXGroup",
            "children": sorted(script_children),
            "name": "ScriptEditor",
            "path": "ScriptEditor",
            "sourceTree": "<group>",
        },
        settings_group_id: {
            "isa": "PBXGroup",
            "children": sorted(settings_children),
            "name": "Settings",
            "path": "Settings",
            "sourceTree": "<group>",
        },
        usage_group_id: {
            "isa": "PBXGroup",
            "children": sorted(usage_children),
            "name": "Usage",
            "path": "Usage",
            "sourceTree": "<group>",
        },
        features_group_id: {
            "isa": "PBXGroup",
            "children": sorted([
                pip_group_id, teleprompter_feat_group_id, audio_group_id,
                script_group_id, settings_group_id, usage_group_id,
            ]),
            "name": "Features",
            "path": "Features",
            "sourceTree": "<group>",
        },
        models_group_id: {
            "isa": "PBXGroup",
            "children": sorted(models_children),
            "name": "Models",
            "path": "Models",
            "sourceTree": "<group>",
        },
        services_group_id: {
            "isa": "PBXGroup",
            "children": sorted(services_children),
            "name": "Services",
            "path": "Services",
            "sourceTree": "<group>",
        },
        resources_group_id: {
            "isa": "PBXGroup",
            "children": sorted([assets_froid, preview_assets_froid]),
            "name": "Resources",
            "path": "Resources",
            "sourceTree": "<group>",
        },
        extensions_group_id: {
            "isa": "PBXGroup",
            "children": sorted(ext_children),
            "name": "Extensions",
            "path": "Extensions",
            "sourceTree": "<group>",
        },
        supporting_group_id: {
            "isa": "PBXGroup",
            "children": sorted(supporting_children + [extensions_group_id]),
            "name": "Supporting",
            "path": "Supporting",
            "sourceTree": "<group>",
        },
        teleprompter_group_id: {
            "isa": "PBXGroup",
            "children": sorted([
                app_group_id, features_group_id, models_group_id,
                services_group_id, resources_group_id, supporting_group_id,
                info_plist_froid, entitlements_froid,
            ] + teleprompter_root_children),
            "name": "Teleprompter",
            "path": "Teleprompter",
            "sourceTree": "<group>",
        },
        root_group_id: {
            "isa": "PBXGroup",
            "children": [teleprompter_group_id, product_ref_id],
            "sourceTree": "<group>",
        },
    }
    sections["PBXGroup"] = group_section
    
    # --- Build Phases ---
    sources_phase_id = uid()
    sources_build_file_ids = sorted(build_files.values())
    sections["PBXSourcesBuildPhase"] = {
        sources_phase_id: {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": sources_build_file_ids,
            "runOnlyForDeploymentPostprocessing": 0,
        },
    }
    
    frameworks_phase_id = uid()
    sections["PBXFrameworksBuildPhase"] = {
        frameworks_phase_id: {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": "2147483647",
            "files": [],
            "runOnlyForDeploymentPostprocessing": 0,
        },
    }
    
    resources_phase_id = uid()
    sections["PBXResourcesBuildPhase"] = {
        resources_phase_id: {
            "isa": "PBXResourcesBuildPhase",
            "buildActionMask": "2147483647",
            "files": [assets_build_froid],
            "runOnlyForDeploymentPostprocessing": 0,
        },
    }
    
    # --- XCBuildConfiguration ---
    target_debug_id = uid()
    target_release_id = uid()
    project_debug_id = uid()
    project_release_id = uid()
    
    target_debug_config = {
        "isa": "XCBuildConfiguration",
        "buildSettings": {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "CODE_SIGN_ENTITLEMENTS": "Teleprompter/Teleprompter.entitlements",
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": "2P5UG67845",
            "CURRENT_PROJECT_VERSION": 1,
            "ENABLE_PREVIEWS": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "INFOPLIST_FILE": "Teleprompter/Info.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "MARKETING_VERSION": "1.0",
            "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
            "PRODUCT_NAME": "Teleprompter",
            "SWIFT_VERSION": "5.0",
            "TARGETED_DEVICE_FAMILY": "1,2",
        },
        "name": "Debug",
    }
    
    target_release_config = {
        "isa": "XCBuildConfiguration",
        "buildSettings": {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "CODE_SIGN_ENTITLEMENTS": "Teleprompter/Teleprompter.entitlements",
            "CODE_SIGN_STYLE": "Automatic",
            "DEVELOPMENT_TEAM": "2P5UG67845",
            "CURRENT_PROJECT_VERSION": 1,
            "ENABLE_PREVIEWS": "YES",
            "INFOPLIST_FILE": "Teleprompter/Info.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "MARKETING_VERSION": "1.0",
            "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
            "PRODUCT_NAME": "Teleprompter",
            "SWIFT_VERSION": "5.0",
            "TARGETED_DEVICE_FAMILY": "1,2",
        },
        "name": "Release",
    }
    
    project_debug_config = {
        "isa": "XCBuildConfiguration",
        "buildSettings": {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ANALYZER_NONNULL": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
            "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_NO_COMMON_BLOCKS": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "ONLY_ACTIVE_ARCH": "YES",
            "SDKROOT": "iphoneos",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        },
        "name": "Debug",
    }
    
    project_release_config = {
        "isa": "XCBuildConfiguration",
        "buildSettings": {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ANALYZER_NONNULL": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
            "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "COPY_PHASE_STRIP": "NO",
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_NS_ASSERTIONS": "NO",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "GCC_NO_COMMON_BLOCKS": "YES",
            "GCC_OPTIMIZATION_LEVEL": "s",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "SDKROOT": "iphoneos",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "VALIDATE_PRODUCT": "YES",
        },
        "name": "Release",
    }
    
    sections["XCBuildConfiguration"] = {
        target_debug_id: target_debug_config,
        target_release_id: target_release_config,
        project_debug_id: project_debug_config,
        project_release_id: project_release_config,
    }
    
    # --- XCConfigurationList ---
    target_config_list_id = uid()
    project_config_list_id = uid()
    
    sections["XCConfigurationList"] = {
        target_config_list_id: {
            "isa": "XCConfigurationList",
            "buildConfigurations": [target_debug_id, target_release_id],
            "defaultConfigurationIsVisible": 0,
            "defaultConfigurationName": "Release",
        },
        project_config_list_id: {
            "isa": "XCConfigurationList",
            "buildConfigurations": [project_debug_id, project_release_id],
            "defaultConfigurationIsVisible": 0,
            "defaultConfigurationName": "Release",
        },
    }
    
    # --- PBXNativeTarget ---
    target_id = uid()
    sections["PBXNativeTarget"] = {
        target_id: {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": target_config_list_id,
            "buildPhases": [sources_phase_id, frameworks_phase_id, resources_phase_id],
            "buildRules": [],
            "dependencies": [],
            "name": "Teleprompter",
            "productName": "Teleprompter",
            "productReference": product_ref_id,
            "productType": "com.apple.product-type.application",
        },
    }
    
    # --- PBXProject ---
    project_id = uid()
    sections["PBXProject"] = {
        project_id: {
            "isa": "PBXProject",
            "attributes": {
                "BuildIndependentTargetsInParallel": 1,
                "LastSwiftUpdateCheck": 1620,
                "LastUpgradeCheck": 1620,
            },
            "buildConfigurationList": project_config_list_id,
            "compatibilityVersion": "Xcode 14.0",
            "developmentRegion": "zh-Hans",
            "hasScannedForEncodings": 0,
            "knownRegions": ["en", "zh-Hans", "Base"],
            "mainGroup": root_group_id,
            "productRefGroup": teleprompter_group_id,
            "projectDirPath": "",
            "projectRoot": "",
            "targets": [target_id],
        },
    }
    
    # === 4. Write pbxproj ===
    os.makedirs(XCODE_DIR, exist_ok=True)
    
    lines = [
        "// !$*UTF8*$!",
        "{",
        "\tarchiveVersion = 1;",
        "\tclasses = {",
        "\t};",
        "\tobjectVersion = 56;",
        "\tobjects = {",
    ]
    
    section_order = [
        "PBXBuildFile",
        "PBXFileReference",
        "PBXFrameworksBuildPhase",
        "PBXGroup",
        "PBXNativeTarget",
        "PBXProject",
        "PBXResourcesBuildPhase",
        "PBXSourcesBuildPhase",
        "XCBuildConfiguration",
        "XCConfigurationList",
    ]
    
    for section_name in section_order:
        if section_name in sections and sections[section_name]:
            section_data = sections[section_name]
            lines.append("")
            lines.append(f"/* Begin {section_name} section */")
            for oid, obj in sorted(section_data.items()):
                encoded = encode_value(obj, indent=2)
                lines.append(f"\t\t{oid} = {encoded};")
            lines.append(f"/* End {section_name} section */")
    
    lines.append("\t};")
    lines.append(f"\trootObject = {project_id};")
    lines.append("}")
    
    content = "\n".join(lines)
    
    pbxproj_path = os.path.join(XCODE_DIR, "project.pbxproj")
    with open(pbxproj_path, "w", encoding="utf-8") as f:
        f.write(content)
    
    print(f"✅ Xcode project generated: {pbxproj_path}")
    print(f"   Swift files: {len(all_swift)}")
    print(f"   Groups: {len(group_section)}")

if __name__ == "__main__":
    generate()
