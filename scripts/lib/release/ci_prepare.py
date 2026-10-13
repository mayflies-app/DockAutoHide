#!/usr/bin/env python3
"""CI packaging with the common app builder, temporary keychain and notarization."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

import ci_security
import release_contract as contract

DEVELOPER_DIRECTORY = "/Applications/Xcode_27.0.app/Contents/Developer"


def verify_toolchain(developer_directory=None):
    """Read public tool versions without selecting, installing, or invoking a builder."""
    directory = developer_directory or DEVELOPER_DIRECTORY
    if not Path(directory).is_dir():
        raise ValueError("Pinned Xcode developer directory does not exist")
    environment = dict(os.environ, DEVELOPER_DIR=directory)
    xcode_text = contract.output(["xcodebuild", "-version"], env=environment)
    xcode = re.search(r"^Xcode ([0-9]+(?:\.[0-9]+){1,2})$", xcode_text, re.MULTILINE)
    sdk = contract.output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], env=environment).strip()
    swift_text = contract.output(["xcrun", "swift", "--version"], env=environment)
    swift = re.search(r"\bSwift version ([0-9]+(?:\.[0-9]+){1,2})\b", swift_text)
    if not xcode or contract.minimum_version(xcode[1]) < (27, 0, 0):
        raise ValueError("The release requires Xcode 27.0 or later")
    if contract.minimum_version(sdk) < (27, 0, 0):
        raise ValueError("The release requires macOS SDK 27.0 or later")
    if not swift or contract.minimum_version(swift[1]) < (6, 4, 0):
        raise ValueError("The release requires Swift 6.4 or later")
    fingerprint = hashlib.sha256((xcode_text + "\n" + sdk + "\n" + swift_text).encode()).hexdigest()
    architecture = {"aarch64": "arm64", "AMD64": "x86_64"}.get(platform.machine(), platform.machine())
    if architecture not in ("arm64", "x86_64"):
        raise ValueError("Unsupported native build architecture")
    return {"developerDirectory": directory, "xcode": xcode[1], "macosSDK": sdk, "swift": swift[1],
            "cacheFingerprint": fingerprint, "nativeArchitecture": architecture}


def package_environment(environment):
    """Keep signing selectors while excluding secrets from persisted build metadata."""
    private = {"MACOS_CERTIFICATE", "MACOS_CERTIFICATE_PASSWORD", "MACOS_KEYCHAIN_PASSWORD",
               "APPLE_NOTARIZATION_PRIVATE_KEY", "HOMEBREW_TAP_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"}
    return {name: value for name, value in environment.items() if name not in private}


def prepare(config_path, version, build, architecture, output, signed=False, notarized=False):
    requested_config = Path(config_path).absolute()
    config_path = Path(config_path).resolve()
    config = contract.load_config(config_path)
    root = config_path.parent
    contract.validate_version(version)
    contract.validate_build(build)
    if architecture not in contract.ARCHITECTURES:
        raise ValueError("Unsupported CI architecture")
    if notarized and not signed:
        raise ValueError("CI notarization requires Developer ID signing")
    requested_output = Path(output)
    if not requested_output.is_absolute() or ".." in requested_output.parts:
        raise ValueError("CI output must be an absolute owned path")
    # Accept the checkout's original spelling (e.g. macOS /var alias) while
    # checking every repository-owned path before following any symlink.
    relative = None
    for checkout in (requested_config.parent, root):
        try:
            relative = requested_output.relative_to(checkout)
            break
        except ValueError:
            pass
    if relative != Path("dist") / "release" / architecture:
        raise ValueError("CI output must be root/dist/release/<architecture>")
    output = root / relative
    for path in (root / "dist", root / "dist/release", output):
        if path.is_symlink():
            raise ValueError("CI output cannot traverse a repository symlink")
        if path != output and path.exists() and not path.is_dir():
            raise ValueError("CI output parent must be a directory")
    if output.exists():
        raise ValueError("CI preparation requires a new output directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, "-B", str(root / "scripts/app.py"), "package", "--version", version, "--build", build,
               "--arch", architecture, "--output", str(output), "--sign", "developer-id" if signed else "ad-hoc"]
    if signed:
        with ci_security.temporary_keychain() as environment:
            contract.run(command, cwd=root, env=package_environment(environment))
    else:
        contract.run(command, cwd=root, env=package_environment(os.environ))
    app = output / "app" / (config["appName"] + ".app")
    dmg = output / contract.artifact_name(config, version, architecture)
    receipt = None
    if notarized:
        receipt = dmg.with_suffix(".notary.json")
        ci_security.notarize(dmg, receipt)
    manifest = contract.create_manifest(config, root, app, dmg, version, build, architecture,
                                        signed, os.environ.get("MACOS_TEAM_ID"), receipt)
    dmg.with_suffix(".json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    dmg.with_suffix(".dmg.sha256").write_text(f"{manifest['artifact']['sha256']}  {dmg.name}\n")
    print(json.dumps({"artifact": manifest["artifact"], "notarization": manifest["notarization"]}, indent=2))
    return manifest


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["verify-toolchain"]:
        result = verify_toolchain()
        if os.environ.get("GITHUB_OUTPUT"):
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as stream:
                stream.write(f"fingerprint={result['cacheFingerprint']}\narchitecture={result['nativeArchitecture']}\n")
        print(json.dumps(result, indent=2, sort_keys=True))
        return result
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("macos-app.json"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--arch", choices=contract.ARCHITECTURES, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sign-mode", choices=("ad-hoc", "developer-id"), default="ad-hoc")
    parser.add_argument("--notarize", action="store_true")
    parser.add_argument("--ci", action="store_true")
    parser.add_argument("--allow-remote", action="store_true")
    args = parser.parse_args(argv)
    contract.require_ci_remote(args.ci, args.allow_remote)
    return prepare(args.config, args.version, args.build, args.arch, args.output,
                   args.sign_mode == "developer-id", args.notarize)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print("CI preparation error: " + ("external command failed" if isinstance(error, subprocess.CalledProcessError) else str(error)), file=sys.stderr)
        sys.exit(1)
