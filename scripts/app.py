#!/usr/bin/env python3
"""One local macOS app CLI. Product-specific packaging belongs in macos-app.json."""
from __future__ import annotations
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
LIB = Path(__file__).resolve().parent / "lib"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")
SIGN_APP_SCRIPT = 'set -e; source "$1"; macos_signing_resolve "$2" "$3" "$4"; if [[ -n "$9" && "$MACOS_SIGN_TEAM_ID" != "$9" ]]; then echo "Signing team mismatch" >&2; exit 1; fi; macos_signing_sign_app "$5" "$6" "$7" "${10}"; printf "%s\\n%s\\n" "$MACOS_SIGN_IDENTITY" "$MACOS_SIGN_TEAM_ID" > "$8"'


def execute(argv, root, capture=False):
    return subprocess.run(list(map(str, argv)), cwd=root, check=True,
                          text=True, capture_output=capture)


def execute_native(argv, root):
    # subprocess.run kills its direct child on KeyboardInterrupt. Native runners
    # must retain their recorder while product-owned cleanup restores user state.
    process = subprocess.Popen(list(map(str, argv)), cwd=root)
    cancellation = {"signal": None, "deadline": None}
    def cancel(signum, frame):
        if cancellation["signal"] is None:
            cancellation.update(signal=signum, deadline=time.monotonic() + 130)
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
    previous = {value: signal.signal(value, cancel) for value in (signal.SIGINT, signal.SIGTERM)}
    try:
        while process.poll() is None:
            if cancellation["deadline"] is not None and time.monotonic() >= cancellation["deadline"]:
                # Only this owned runner PID is ended; app cleanup is never inferred.
                process.kill()
                process.wait()
                raise RuntimeError("Native runner exceeded its cancellation cleanup deadline; inspect its restoration report")
            time.sleep(0.05)
        if cancellation["signal"] is not None:
            raise RuntimeError("Native test interrupted; inspect its completed restoration report")
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, argv)
    finally:
        for value, handler in previous.items():
            signal.signal(value, handler)


def relative_file(root, value):
    if not isinstance(value, str) or not value or Path(value).is_absolute() or any(p in (".", "..") for p in value.split("/")):
        raise ValueError("Packaging paths must be repository relative")
    path = root / value
    if not path.resolve().is_relative_to(root) or not path.exists():
        raise ValueError(f"Missing or external packaging resource: {value}")
    return path


def load_config(root):
    config = json.loads((root / "macos-app.json").read_text())
    if config.get("schemaVersion") != 1 or config.get("buildSystem") not in ("swiftpm", "xcode"):
        raise ValueError("This local builder requires schemaVersion 1 and buildSystem swiftpm or xcode")
    for key in ("product", "executable"):
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", str(config.get(key, ""))):
            raise ValueError(f"Invalid {key}")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", str(config.get("bundleIdentifier", ""))):
        raise ValueError("Invalid bundle identifier")
    if not isinstance(config.get("appName"), str) or not config["appName"] or any(c in config["appName"] for c in '/\\\r\n\0'):
        raise ValueError("Invalid appName")
    if not re.fullmatch(r"[1-9][0-9]*(?:\.(?:0|[1-9][0-9]*)){1,2}", str(config.get("minimumSystemVersion", ""))):
        raise ValueError("Invalid minimumSystemVersion")
    paths = config.get("paths", {})
    if not isinstance(paths, dict):
        raise ValueError("paths must be an object")
    if paths.get("entitlements"):
        if not isinstance(plistlib.loads(relative_file(root, paths["entitlements"]).read_bytes()), dict):
            raise ValueError("Entitlements must be a plist dictionary")
    test_scripts = config.get("testScripts", [])
    if not isinstance(test_scripts, list):
        raise ValueError("testScripts must be a list of product regression scripts")
    for script in test_scripts:
        path = relative_file(root, script)
        if not path.is_file() or path.suffix not in (".sh", ".py"):
            raise ValueError("Product test scripts must be .sh or .py files")
    if config["buildSystem"] == "xcode":
        project = relative_file(root, paths.get("project"))
        if not project.is_dir() or project.suffix != ".xcodeproj":
            raise ValueError("paths.project must be an Xcode project directory")
        xcode = config.get("xcode", {})
        if not isinstance(xcode, dict) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_. -]*", str(xcode.get("scheme", ""))):
            raise ValueError("Invalid Xcode scheme")
        if not test_scripts:
            raise ValueError("testScripts must declare the Xcode product's regression scripts")
    native_tests = config.get("nativeTests", {})
    if not isinstance(native_tests, dict) or set(native_tests) - {"localizationScript"}:
        raise ValueError("nativeTests supports localizationScript only")
    if native_tests and not relative_file(root, native_tests.get("localizationScript")).is_file():
        raise ValueError("Native localization script must be a file")
    packaging = config.setdefault("packaging", {})
    if not isinstance(packaging, dict):
        raise ValueError("packaging must be an object")
    if packaging.get("infoPlist"):
        plistlib.loads(relative_file(root, packaging["infoPlist"]).read_bytes())
    metadata = packaging.setdefault("metadata", {})
    if not isinstance(metadata, dict):
        raise ValueError("packaging.metadata must be an object")
    protected = {"CFBundleExecutable", "CFBundleIdentifier", "CFBundlePackageType", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"}
    if protected.intersection(metadata):
        raise ValueError("Packaging metadata cannot override identity, version or minimum OS")
    allowed = {"CFBundleName", "CFBundleDisplayName", "CFBundleDevelopmentRegion", "CFBundleLocalizations", "CFBundleIconFile", "LSUIElement", "NSHighResolutionCapable", "LSMultipleInstancesProhibited", "LSApplicationCategoryType", "NSAppTransportSecurity", "NSAccessibilityUsageDescription"}
    if set(metadata) - allowed:
        raise ValueError("Unsupported packaging metadata key; use an infoPlist for other keys")
    for key in ("LSUIElement", "NSHighResolutionCapable", "LSMultipleInstancesProhibited"):
        if key in metadata and type(metadata[key]) is not bool:
            raise ValueError(f"packaging.metadata.{key} must be boolean")
    if "CFBundleLocalizations" in metadata and (not isinstance(metadata["CFBundleLocalizations"], list) or any(not isinstance(v, str) for v in metadata["CFBundleLocalizations"])):
        raise ValueError("CFBundleLocalizations must be a string list")
    # plistlib validates values before any build or output directory is created.
    plistlib.dumps(metadata)
    names = set()
    for key in ("resources", "resourceBundles", "dependencyLicenses"):
        values = packaging.setdefault(key, [])
        if not isinstance(values, list) or any(not isinstance(v, str) for v in values):
            raise ValueError(f"packaging.{key} must be a string list")
        for value in values:
            if key == "resources":
                path = relative_file(root, value)
                if path.name in names:
                    raise ValueError("Duplicate resource basename")
                names.add(path.name)
            elif Path(value).name != value or not re.fullmatch(r"[A-Za-z0-9_.-]+", value) or value in (".", ".."):
                raise ValueError(f"Invalid packaging.{key} basename")
    if config["buildSystem"] == "xcode" and (packaging["resourceBundles"] or packaging["dependencyLicenses"]):
        raise ValueError("Xcode owns its compiled resource bundles and dependency licenses; SwiftPM packaging inputs must be empty")
    return config


def resolve_options(args, root, config):
    if args.native:
        if args.command != "test":
            raise ValueError("--native is available only for test")
        if not args.app or not args.output or not Path(args.app).is_absolute() or not Path(args.output).is_absolute():
            raise ValueError("Native tests require explicit absolute --app and --output paths")
        if not config.get("nativeTests", {}).get("localizationScript"):
            raise ValueError("This product has no native localization test script")
        args.case = args.case or "localization"
        args.timeout_seconds = args.timeout_seconds if args.timeout_seconds is not None else 90.0
        if not math.isfinite(args.timeout_seconds) or not 0 < args.timeout_seconds <= 86400:
            raise ValueError("--timeout-seconds must be finite and in (0, 86400]")
        args.app = Path(args.app).resolve(strict=True)
        if args.app.suffix != ".app" or not args.app.is_dir():
            raise ValueError("--app must be an existing app bundle")
        info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
        if (info.get("CFBundlePackageType"), info.get("CFBundleIdentifier"), info.get("CFBundleExecutable")) != ("APPL", config["bundleIdentifier"], config["executable"]):
            raise ValueError("Native app identity does not match this product")
        binary = (args.app / "Contents/MacOS" / config["executable"]).resolve(strict=True)
        if not binary.is_relative_to(args.app) or not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError("Native app executable must be contained and executable")
    elif args.app or args.case or args.timeout_seconds is not None:
        raise ValueError("--app, --case and --timeout-seconds require test --native")
    args.configuration = args.configuration or ("release" if args.command == "package" else "debug")
    args.arch = args.arch or ("universal" if args.command == "package" else "native")
    args.sign = args.sign or ("ad-hoc" if args.command == "package" else "auto")
    args.version = args.version or relative_file(root, config.get("versionFile", "VERSION")).read_text().strip()
    match = VERSION.fullmatch(args.version)
    if not match or any(v.isdigit() and len(v) > 1 and v.startswith("0") for v in (match[4] or "").split(".")):
        raise ValueError("Version must be strict SemVer without build metadata")
    if not re.fullmatch(r"[1-9][0-9]*", args.build):
        raise ValueError("Build must be a positive integer")
    if args.arch == "native":
        args.arch = {"aarch64": "arm64", "AMD64": "x86_64"}.get(platform.machine(), platform.machine())
    if args.arch not in ("arm64", "x86_64", "universal"):
        raise ValueError("Unsupported native architecture")
    if args.command == "test" and args.arch == "universal":
        raise ValueError("Tests require a single native execution architecture")
    args.output = Path(args.output or (root / "dist/release" / args.arch if args.command == "package" else root / "dist/dev")).absolute()
    if ".." in args.output.parts or args.output == root or root.is_relative_to(args.output):
        raise ValueError("Output cannot replace the repository or an ancestor")
    if args.output.is_relative_to(root) and not args.output.is_relative_to(root / "dist"):
        raise ValueError("Repository outputs must stay under dist")
    for path in (args.output, *args.output.parents):
        if path.is_symlink():
            raise ValueError("Output cannot traverse symlinks")
    if args.output.exists() and not args.output.is_dir():
        raise ValueError("Output must be a directory")
    if args.native:
        if args.output == args.app or args.output.is_relative_to(args.app) or args.app.is_relative_to(args.output):
            raise ValueError("Native output must not overlap the app bundle")
        if args.output.exists() and any(args.output.iterdir()):
            raise ValueError("Native output must be new or empty")
        if not args.output.parent.is_dir() or not os.access(args.output.parent, os.W_OK):
            raise ValueError("Native output requires an existing writable parent")
    return args


def swift_args(root, config, args, arch, operation="build"):
    argv = ["swift", operation, "--disable-sandbox", "-c", args.configuration,
            "--scratch-path", root / ".build/app" / args.configuration / arch,
            "--triple", f"{arch}-apple-macosx{config['minimumSystemVersion']}"]
    if operation == "build":
        argv += ["--product", config["executable"]]
    return list(map(str, argv))


def xcode_args(root, config, args):
    arches = "arm64 x86_64" if args.arch == "universal" else args.arch
    argv = ["xcodebuild", "build", "-project", root / config["paths"]["project"],
                         "-scheme", config["xcode"]["scheme"], "-configuration", args.configuration.title(),
                         "-destination", "generic/platform=macOS", "-derivedDataPath",
                         root / ".build/app" / args.configuration / args.arch,
                         f"ARCHS={arches}", "ONLY_ACTIVE_ARCH=NO", "ENABLE_DEBUG_DYLIB=NO", "CODE_SIGNING_ALLOWED=NO",
                         "CODE_SIGNING_REQUIRED=NO", f"CURRENT_PROJECT_VERSION={args.build}",
                         f"MARKETING_VERSION={args.version.split('-')[0]}",
                         f"MACOSX_DEPLOYMENT_TARGET={config['minimumSystemVersion']}"]
    # Ephemeral runners rebuild this SDK-wide index even after a cache hit.
    if os.environ.get("GITHUB_ACTIONS") == "true":
        argv.append("SDK_STAT_CACHE_ENABLE=NO")
    return list(map(str, argv))


def test_commands(root, config, args):
    if args.native:
        return [["bash", str(root / config["nativeTests"]["localizationScript"]),
                 "--app", str(args.app), "--output", str(args.output),
                 "--case", args.case, "--timeout-seconds", str(args.timeout_seconds)]]
    commands = [swift_args(root, config, args, args.arch, "test")] if config["buildSystem"] == "swiftpm" else []
    for script in config.get("testScripts", []):
        runner = ["python3", "-B"] if Path(script).suffix == ".py" else ["bash"]
        cache = root / ".build/app" / args.configuration / args.arch / "test-module-cache"
        commands.append(["env", f"TEST_ARCH={args.arch}", f"TEST_MODULE_CACHE_PATH={cache}", *runner, str(root / script)])
    return commands


def plan(root, config, args, app_args):
    arches = ["arm64", "x86_64"] if args.arch == "universal" else [args.arch]
    commands = []
    if args.command == "test":
        commands = test_commands(root, config, args)
    elif config["buildSystem"] == "xcode":
        commands.append(xcode_args(root, config, args))
    else:
        for arch in arches:
            argv = swift_args(root, config, args, arch)
            commands.extend([argv, argv + ["--show-bin-path"]])
    if args.command != "test":
        if len(arches) == 2 and config["buildSystem"] == "swiftpm":
            commands.append(["lipo", "-create", *[f"$BIN_PATH_{a}/{config['executable']}" for a in arches], "-output", "$STAGING_APP/Contents/MacOS/" + config["executable"]])
        previous = str(args.output / ("app" if args.command == "package" else "") / (config["appName"] + ".app"))
        commands.append(["bash", "-c", SIGN_APP_SCRIPT, "app-sign", str(LIB / "signing.sh"),
                         "-" if args.sign == "ad-hoc" else "$MACOS_SIGNING_IDENTITY",
                         "$CODE_SIGN_KEYCHAIN", "1" if args.sign == "developer-id" else "0",
                         "$STAGING_APP", config["bundleIdentifier"], previous, "$SIGNING_STATE",
                         "" if args.sign == "ad-hoc" else "$MACOS_TEAM_ID",
                         str(root / config["paths"]["entitlements"]) if config.get("paths", {}).get("entitlements") else ""])
        if args.command == "package":
            commands += [["hdiutil", "create", "-volname", config["appName"], "-srcfolder", "$DMG_CONTENT", "-ov", "-format", "UDZO", "$STAGING/" + artifact_name(config, args)],
                         ["codesign", "--force", "--sign", "$RESOLVED_IDENTITY",
                          "--timestamp=none" if args.sign == "ad-hoc" else "--timestamp", "$STAGING_DMG"]]
        if args.command == "run":
            app = str(args.output / (config["appName"] + ".app"))
            commands += [["swift", str(LIB / "RunApp.swift"), "--stop", app],
                         ["swift", str(LIB / "RunApp.swift"), "--launch", app, "--", *app_args]]
    return {"command": args.command, "configuration": args.configuration, "architecture": args.arch,
            "version": args.version, "build": args.build, "sign": args.sign, "output": str(args.output),
            "packaging": config["packaging"], "commands": commands,
            "bundleAssembly": "copy complete Xcode app bundle" if config["buildSystem"] == "xcode" else "copy executable and every SwiftPM *.bundle; declared resourceBundles required",
            "filesystemSteps": ["assemble fresh staged app from compiler output and declared resources", "sign and verify staged app against previous identity", "create/sign DMG and call release_contract.create_manifest after signing" if args.command == "package" else "no DMG", "atomically replace destination only after every prior step succeeds"] if args.command != "test" else [],
            "signingPlaceholders": "Identity/team/keychain placeholders refer to common MACOS_* environment; auto selects identity at execution, optional keychain is omitted when unset"}


def artifact_name(config, args):
    return f"{config['product']}-{args.version}-{args.arch}.dmg"


def copy_item(source, target):
    if source.is_dir():
        shutil.copytree(source, target)
    else:
        shutil.copy2(source, target)


def assemble(root, config, args, stage):
    if config["buildSystem"] == "xcode":
        return assemble_xcode(root, config, args, stage)
    app = stage / (config["appName"] + ".app")
    resources = app / "Contents/Resources"
    binary = app / "Contents/MacOS" / config["executable"]
    resources.mkdir(parents=True)
    binary.parent.mkdir()
    arches = ["arm64", "x86_64"] if args.arch == "universal" else [args.arch]
    bins = []
    for arch in arches:
        argv = swift_args(root, config, args, arch)
        execute(argv, root)
        directory = Path(execute(argv + ["--show-bin-path"], root, capture=True).stdout.strip())
        if not directory.is_absolute():
            directory = root / directory
        if not (directory / config["executable"]).is_file():
            raise ValueError("SwiftPM did not produce the configured executable")
        bins.append(directory)
    if len(bins) == 2:
        execute(["lipo", "-create", *[p / config["executable"] for p in bins], "-output", binary], root)
    else:
        shutil.copy2(bins[0] / config["executable"], binary)
    binary.chmod(binary.stat().st_mode | 0o111)
    packaging = config["packaging"]
    info = plistlib.loads((root / packaging["infoPlist"]).read_bytes()) if packaging.get("infoPlist") else {
        "CFBundleName": config["appName"], "CFBundleDisplayName": config["appName"],
        "CFBundleDevelopmentRegion": "en", "LSUIElement": True, "NSHighResolutionCapable": True}
    info.update(packaging["metadata"])
    info.update(CFBundleExecutable=config["executable"], CFBundleIdentifier=config["bundleIdentifier"],
                CFBundlePackageType="APPL", CFBundleShortVersionString=args.version.split("-")[0],
                CFBundleVersion=args.build, LSMinimumSystemVersion=config["minimumSystemVersion"])
    for value in packaging["resources"]:
        source = relative_file(root, value)
        copy_item(source, resources / source.name)
    bundles = {}
    for directory in bins:
        for bundle in sorted(directory.glob("*.bundle")):
            bundles.setdefault(bundle.name, bundle)
    if not set(packaging["resourceBundles"]).issubset(bundles):
        raise ValueError("Required SwiftPM resource bundle is missing")
    for name, source in bundles.items():
        if (resources / name).exists():
            raise ValueError("SwiftPM bundle collides with a configured resource")
        copy_item(source, resources / name)
    for dependency in packaging["dependencyLicenses"]:
        checkout_root = root / ".build/app" / args.configuration / arches[0] / "checkouts"
        checkout = next((checkout_root / name for name in (dependency, dependency.lower()) if (checkout_root / name).is_dir()), None)
        license_path = next((checkout / name for name in ("LICENSE", "LICENSE.txt", "LICENSE.md") if checkout and (checkout / name).is_file()), None)
        if license_path is None:
            raise ValueError(f"Dependency license missing: {dependency}")
        (resources / "Licenses").mkdir(exist_ok=True)
        shutil.copy2(license_path, resources / "Licenses" / (dependency + ".txt"))
        for name in ("NOTICE", "NOTICE.txt", "NOTICE.md"):
            if (checkout / name).is_file():
                shutil.copy2(checkout / name, resources / "Licenses" / (dependency + "-NOTICE.txt"))
                break
    icons = sorted(resources.glob("*.icns"))
    if icons and "CFBundleIconFile" not in info:
        info["CFBundleIconFile"] = icons[0].name
    localizations = sorted({p.stem for p in resources.rglob("*.lproj")})
    if localizations and "CFBundleLocalizations" not in info:
        info["CFBundleLocalizations"] = localizations
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
    return app


def assemble_xcode(root, config, args, stage):
    execute(xcode_args(root, config, args), root)
    compiled = root / ".build/app" / args.configuration / args.arch / "Build/Products" / args.configuration.title() / (config["appName"] + ".app")
    info = plistlib.loads((compiled / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleExecutable": config["executable"], "CFBundleIdentifier": config["bundleIdentifier"], "CFBundlePackageType": "APPL"}
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("Xcode app identity does not match macos-app.json")
    if not (compiled / "Contents/MacOS" / config["executable"]).is_file():
        raise ValueError("Xcode did not produce the configured executable")
    app = stage / compiled.name
    shutil.copytree(compiled, app, symlinks=True)
    packaging = config["packaging"]
    info.update(packaging["metadata"])
    info.update(CFBundleShortVersionString=args.version.split("-")[0], CFBundleVersion=args.build,
                LSMinimumSystemVersion=config["minimumSystemVersion"])
    resources = app / "Contents/Resources"
    for value in packaging["resources"]:
        source = relative_file(root, value)
        resources.mkdir(exist_ok=True)
        if (resources / source.name).exists():
            raise ValueError("Configured resource collides with an Xcode bundle resource")
        copy_item(source, resources / source.name)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
    return app


def sign_app(root, config, args, app, previous, state):
    requested = "-" if args.sign == "ad-hoc" else os.environ.get("MACOS_SIGNING_IDENTITY", "")
    keychain = os.environ.get("CODE_SIGN_KEYCHAIN", os.environ.get("KEYCHAIN_PATH", ""))
    try:
        execute(["bash", "-c", SIGN_APP_SCRIPT, "app-sign", LIB / "signing.sh", requested, keychain,
                 "1" if args.sign == "developer-id" else "0", app, config["bundleIdentifier"], previous, state,
                 os.environ.get("MACOS_TEAM_ID", "") if args.sign != "ad-hoc" else "",
                 relative_file(root, config["paths"]["entitlements"]) if config.get("paths", {}).get("entitlements") else ""], root, capture=True)
    except subprocess.CalledProcessError as error:
        # These fixed helper guards explain safe recovery. Never echo captured
        # stderr or command argv: unrelated tool failures can contain secrets.
        known_guards = {
            "Refusing to replace a Developer ID app with ad hoc or development signing. Use a separate development output directory.":
                "The existing output uses Developer ID and has been preserved. Use a new --output directory, or --sign developer-id with the same signing identity.",
            "New app does not satisfy the previous signing identity; refusing to replace it.":
                "The new app does not match the previous signing identity. Existing output has been preserved; use the same Developer ID identity or a new --output directory.",
            "Could not read the previous Developer ID app designated requirement.":
                "The previous Developer ID signature could not be checked. Existing output has been preserved; inspect it or use a new --output directory.",
            "Signing team mismatch":
                "The selected signing identity does not match MACOS_TEAM_ID. Configure a matching identity and team; existing output was not replaced.",
            "A valid Developer ID Application identity is required.":
                "Developer ID Application signing identity is unavailable. Configure MACOS_SIGNING_IDENTITY with an available identity, or use --sign ad-hoc with a new --output directory.",
            "A Developer ID Application identity is required; ad hoc and development identities are not accepted.":
                "Developer ID signing requires a Developer ID Application identity. Configure MACOS_SIGNING_IDENTITY accordingly; existing output was not replaced.",
            "Multiple signing identities match; specify a full name or SHA-1:":
                "Multiple signing identities match. Set MACOS_SIGNING_IDENTITY to one full Developer ID Application name or SHA-1; existing output was not replaced.",
        }
        for line in error.stderr.splitlines() if isinstance(error.stderr, str) else ():
            if line in known_guards:
                raise RuntimeError(known_guards[line]) from None
        raise
    identity, team = state.read_text().splitlines()
    return identity, team, keychain


def replace_atomically(source, destination):
    backup_dir = Path(tempfile.mkdtemp(prefix=".app-previous-", dir=destination.parent))
    backup = backup_dir / "item"
    if destination.exists():
        destination.rename(backup)
    try:
        source.rename(destination)
    except BaseException:
        if backup.exists():
            backup.rename(destination)
        backup_dir.rmdir()
        raise
    if backup.exists():
        shutil.rmtree(backup)
    backup_dir.rmdir()


def import_local(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def perform(root, config, args, app_args):
    if args.command == "test":
        for command in test_commands(root, config, args):
            (execute_native if args.native else execute)(command, root)
        return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".app-stage-", dir=args.output.parent) as temporary:
        work = Path(temporary)
        payload = work / "payload"
        payload.mkdir()
        app_dir = payload / "app" if args.command == "package" else payload
        app_dir.mkdir(exist_ok=True)
        app = assemble(root, config, args, app_dir)
        previous = args.output / ("app" if args.command == "package" else "") / (config["appName"] + ".app")
        identity, team, keychain = sign_app(root, config, args, app, previous, work / "signing-state")
        if args.command == "package":
            image = work / "image"
            image.mkdir()
            shutil.copytree(app, image / app.name)
            (image / "Applications").symlink_to("/Applications")
            dmg = payload / artifact_name(config, args)
            execute(["hdiutil", "create", "-volname", config["appName"], "-srcfolder", image, "-ov", "-format", "UDZO", dmg], root, capture=True)
            signing = ["codesign", "--force", "--sign", identity]
            signing += ["--timestamp"] if team else ["--timestamp=none"]
            if keychain:
                signing += ["--keychain", keychain]
            execute(signing + [dmg], root, capture=True)
            sys.path.insert(0, str(LIB / "release"))
            contract = import_local(LIB / "release/release_contract.py", "release_contract")
            manifest = contract.create_manifest(config, root, app, dmg, args.version, args.build, args.arch, bool(team), team or None)
            dmg.with_suffix(".json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            dmg.with_suffix(".dmg.sha256").write_text(f"{manifest['artifact']['sha256']}  {dmg.name}\n")
            replace_atomically(payload, args.output)
        else:
            args.output.mkdir(exist_ok=True)
            replace_atomically(app, previous)
    if args.command == "run":
        execute(["swift", LIB / "RunApp.swift", "--stop", previous], root)
        execute(["swift", LIB / "RunApp.swift", "--launch", previous, "--", *app_args], root)
    print(json.dumps({"command": args.command, "output": str(args.output)}, sort_keys=True))


def main(argv=None, root=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    root = Path(root).resolve() if root else Path(__file__).resolve().parent.parent
    if argv and argv[0] == "release":
        return import_local(LIB / "pipeline.py", "app_pipeline").main(argv[1:])
    app_args = []
    if "--" in argv:
        index = argv.index("--")
        app_args, argv = argv[index + 1:], argv[:index]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "run", "test", "package"))
    parser.add_argument("--configuration", choices=("debug", "release"))
    parser.add_argument("--arch", choices=("native", "arm64", "x86_64", "universal"))
    parser.add_argument("--version")
    parser.add_argument("--build", default="1")
    parser.add_argument("--output")
    parser.add_argument("--sign", choices=("auto", "ad-hoc", "developer-id"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--native", action="store_true", help="Run native localization acceptance on a visible desktop using a prebuilt app")
    parser.add_argument("--case", choices=("localization",))
    parser.add_argument("--app", help="Absolute prebuilt app path for native tests")
    parser.add_argument("--timeout-seconds", type=float, help="Native test execution deadline; cleanup has its own bounded grace period")
    args = parser.parse_args(argv)
    if app_args and args.command != "run":
        parser.error("Only run accepts app arguments after --")
    config = load_config(root)
    args = resolve_options(args, root, config)
    result = plan(root, config, args, app_args)
    if args.dry_run:
        print(json.dumps(result, indent=2))
        return result
    perform(root, config, args, app_args)
    return result


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, KeyError, OSError, subprocess.CalledProcessError) as error:
        message = "External command failed" if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f"app: {message}", file=sys.stderr)
        sys.exit(1)
