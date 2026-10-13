#!/usr/bin/env python3
"""CI packaging with the common app builder, temporary keychain and notarization."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import tempfile

import ci_security
import release_contract as contract

DEVELOPER_DIRECTORY = "/Applications/Xcode_27.0.app/Contents/Developer"
INPUT_METADATA = ".source-inputs.json"


def input_cache_directory(root, requested):
    requested = Path(requested)
    if ".." in requested.parts:
        raise ValueError("Input cache cannot traverse parent directories")
    path = requested if requested.is_absolute() else root / requested
    try:
        relative = path.relative_to(root)
    except ValueError:
        raise ValueError("Input cache must belong to the checkout") from None
    if relative.parts[:2] != (".build", "app") or len(relative.parts) < 3:
        raise ValueError("Input cache must be inside root/.build/app/<configuration>")
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink() or (current.exists() and not current.is_dir()):
            raise ValueError("Input cache cannot traverse symlinks or non-directories")
    return path


def input_path(root, name):
    """Return a lexical checkout path without following any source symlink."""
    if not isinstance(name, str) or not name or "\0" in name:
        raise ValueError("Invalid cached input path")
    relative = Path(name)
    if relative.is_absolute() or any(part in ("", ".", "..") for part in name.split("/")):
        raise ValueError("Invalid cached input path")
    return root / relative


def regular_input(root, path):
    current = root
    for part in path.relative_to(root).parts:
        current /= part
        if current.is_symlink():
            return None
    try:
        info = path.stat()
    except (FileNotFoundError, NotADirectoryError):
        return None
    return info if stat.S_ISREG(info.st_mode) else None


def cached_input_records(metadata, root, metadata_path):
    if not isinstance(metadata, dict) or type(metadata.get("schemaVersion")) is not int or metadata["schemaVersion"] != 1:
        raise ValueError("Unsupported input metadata")
    if metadata.get("root") != str(root) or not isinstance(metadata.get("files"), list):
        raise ValueError("Input metadata does not match this checkout")
    seen = set()
    for record in metadata["files"]:
        if not isinstance(record, dict):
            raise ValueError("Invalid input record")
        path = input_path(root, record.get("path"))
        if path == metadata_path or path in seen:
            raise ValueError("Duplicate or reserved input path")
        seen.add(path)
        if (not isinstance(record.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"])
                or type(record.get("mtimeNs")) is not int or not 0 <= record["mtimeNs"] <= 2**63 - 1
                or type(record.get("mode")) is not int or not 0 <= record["mode"] <= 0o7777):
            raise ValueError("Invalid input fingerprint")
    return metadata["files"]


def cache_inputs(action, requested_cache):
    """Keep only tracked-input fingerprints beside a checkout's compiled cache."""
    root = Path.cwd().resolve()
    cache = input_cache_directory(root, requested_cache)
    metadata_path = cache / INPUT_METADATA
    summary = {"action": action, "status": "saved" if action == "save" else "restored",
               "saved": 0, "restored": 0, "skipped": 0}
    if metadata_path.is_symlink() or (metadata_path.exists() and not metadata_path.is_file()):
        return dict(summary, status="rejected")
    if action == "restore":
        try:
            metadata = json.loads(metadata_path.read_text())
        except FileNotFoundError:
            return dict(summary, status="missing")
        except (ValueError, UnicodeError, OSError, RecursionError):
            return dict(summary, status="rejected")
        try:
            records = cached_input_records(metadata, root, metadata_path)
        except ValueError:
            return dict(summary, status="rejected")
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
    names = {os.fsdecode(name) for name in tracked if name}
    if action == "restore":
        for record in records:
            path = input_path(root, record["path"])
            info = regular_input(root, path) if record["path"] in names else None
            if info is None or stat.S_IMODE(info.st_mode) != record["mode"] or contract.digest(path) != record["sha256"]:
                summary["skipped"] += 1
                continue
            os.utime(path, ns=(info.st_atime_ns, record["mtimeNs"]), follow_symlinks=False)
            summary["restored"] += 1
        return summary
    records = []
    for name in sorted(names):
        path = input_path(root, name)
        info = regular_input(root, path) if path != metadata_path else None
        if info is None:
            summary["skipped"] += 1
            continue
        records.append({"path": name, "sha256": contract.digest(path), "mtimeNs": info.st_mtime_ns,
                        "mode": stat.S_IMODE(info.st_mode)})
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=cache, prefix=".source-inputs-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump({"schemaVersion": 1, "root": str(root), "files": records}, stream, sort_keys=True)
            stream.write("\n")
            stream.close()
            temporary.replace(metadata_path)
        finally:
            temporary.unlink(missing_ok=True)
    summary["saved"] = len(records)
    return summary


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
    if argv[:1] == ["cache-inputs"]:
        parser = argparse.ArgumentParser(description="Restore or save tracked build-input timestamps")
        parser.add_argument("action", choices=("restore", "save"))
        parser.add_argument("--cache-dir", type=Path, required=True)
        args = parser.parse_args(argv[1:])
        result = cache_inputs(args.action, args.cache_dir)
        print(json.dumps(result, sort_keys=True))
        return result
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
