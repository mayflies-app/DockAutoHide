#!/usr/bin/env python3
"""Local release preparation and explicitly gated GitHub publication."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

import release_contract as contract


def github_json(endpoint, missing_ok=False, paginate=False):
    command = ["gh", "api", endpoint]
    if paginate:
        command += ["--paginate", "--slurp"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        if missing_ok and "(HTTP 404)" in result.stderr:
            return None
        error = subprocess.CalledProcessError(result.returncode, command, output=result.stdout, stderr=result.stderr)
        contract.report_failure("github-api-read", error)
        raise error
    return json.loads(result.stdout)


def release_metadata(config, version):
    pages = github_json(f"repos/{config['repository']}/releases?per_page=100", paginate=True)
    matches = [item for page in pages for item in page if item["tag_name"] == f"v{version}"]
    if len(matches) > 1:
        raise ValueError("Multiple releases have the same tag")
    return matches[0] if matches else None


def tag_commit(config, version, missing_ok=False):
    reference = github_json(f"repos/{config['repository']}/git/ref/tags/v{version}", missing_ok)
    if reference is None:
        return None
    target = reference["object"]
    for _ in range(8):
        if target["type"] == "commit" and contract.COMMIT.fullmatch(target["sha"]):
            return target["sha"]
        if target["type"] != "tag":
            break
        target = github_json(f"repos/{config['repository']}/git/tags/{target['sha']}")["object"]
    raise ValueError("Release tag does not resolve to a full source commit")


def verify_release_identity(config, metadata, version, source_commit, allow_draft=False):
    contract.version_order(version)
    if not metadata or metadata.get("tag_name") != f"v{version}" or metadata.get("prerelease") is not False:
        raise ValueError("Stable release version/prerelease mismatch")
    if metadata.get("draft") is not False and not allow_draft:
        raise ValueError("Release must already be public, not a draft")
    resolved = tag_commit(config, version, missing_ok=allow_draft)
    if resolved != source_commit and not (allow_draft and resolved is None and metadata.get("target_commitish") == source_commit):
        raise ValueError("Release tag/source commit mismatch")


def download_asset(config, metadata, asset, destination, public=True):
    name = asset.get("name", "")
    if not name or Path(name).name != name or any(c in name for c in "\n\r\x00"):
        raise ValueError("Unsafe release asset name")
    path = Path(destination) / name
    if path.exists():
        raise ValueError("Refusing to overwrite a downloaded asset")
    if public:
        expected_url = f"https://github.com/{config['repository']}/releases/download/{metadata['tag_name']}/{name}"
        if asset.get("browser_download_url") != expected_url:
            raise ValueError("Release asset URL does not match the expected repository/tag")
        with urllib.request.urlopen(expected_url, timeout=120) as incoming, path.open("xb") as stream:
            while chunk := incoming.read(1024 * 1024):
                stream.write(chunk)
    else:
        with path.open("xb") as stream:
            contract.run(["gh", "api", f"repos/{config['repository']}/releases/assets/{asset['id']}", "--header", "Accept: application/octet-stream"], stdout=stream, stderr=subprocess.DEVNULL)
    if path.stat().st_size != asset.get("size"):
        raise ValueError("Downloaded public asset size differs from release metadata")
    if asset.get("digest") and asset["digest"] != "sha256:" + contract.digest(path):
        raise ValueError("Downloaded public asset digest differs from release metadata")
    return path


def fetch_release(config, version, source_commit, destination, metadata=None, public=True):
    metadata = metadata or release_metadata(config, version)
    verify_release_identity(config, metadata, version, source_commit, allow_draft=not public)
    directory = Path(destination)
    if directory.exists() and any(directory.iterdir()):
        raise ValueError("Release downloads require a new/empty directory")
    directory.mkdir(parents=True, exist_ok=True)
    names = set()
    for asset in metadata["assets"]:
        if asset["name"] in names:
            raise ValueError("Duplicate published release asset names")
        names.add(asset["name"])
        download_asset(config, metadata, asset, directory, public)
    manifests, files = contract.collect(config, directory, version, source_commit, promotion=True)
    return manifests, files


def verify_public_release(config, version, source_commit, directory=None):
    with tempfile.TemporaryDirectory(prefix="public-release-") as temporary:
        manifests, files = fetch_release(config, version, source_commit, temporary)
        if directory is not None:
            local_manifests, local_files = contract.collect(config, directory, version, source_commit, promotion=True)
            if {p.name: contract.digest(p) for p in files} != {p.name: contract.digest(p) for p in local_files}:
                raise ValueError("Public release bytes differ from prepared workflow artifacts")
            if manifests != local_manifests:
                raise ValueError("Public release provenance differs from local manifest")
        universal = next(m for m in manifests if m["architecture"] == "universal")
        return {"schemaVersion": 1, "repository": config["repository"], "version": version,
                "sourceCommit": source_commit, "draft": False, "prerelease": False,
                "tag": f"v{version}", "publicAssetVerified": True,
                "artifact": universal["artifact"], "manifest": universal}


def check_publish_state(config, version, source_commit):
    contract.version_order(version)
    existing = release_metadata(config, version)
    if existing:
        verify_release_identity(config, existing, version, source_commit)
        return "reuse"
    latest = github_json(f"repos/{config['repository']}/releases/latest", missing_ok=True)
    if latest and isinstance(latest.get("tag_name"), str):
        latest_version = latest["tag_name"].removeprefix("v")
        if contract.version_order(version) < contract.version_order(latest_version):
            raise ValueError("Refusing a stable release downgrade")
    target = tag_commit(config, version, missing_ok=True)
    if target is not None and target != source_commit:
        raise ValueError("Immutable version tag already points to a different commit")
    return "new"


def publish(config, version, source_commit, directory):
    state = check_publish_state(config, version, source_commit)
    if state == "reuse":
        # Never compare a newly rebuilt artifact against or replace a published version.
        return verify_public_release(config, version, source_commit)
    _, files = contract.collect(config, directory, version, source_commit, promotion=True)
    notes = Path(directory) / "release-notes.md"
    notes.write_text(f"{config['appName']} {version}\n\nmacOS {config['minimumSystemVersion']} or later.\nDeveloper ID signed and Apple notarized.\n")
    contract.run(["gh", "release", "create", f"v{version}", *files, "--repo", config["repository"],
                  "--target", source_commit, "--title", f"{config['appName']} {version}", "--notes-file", notes, "--draft"], capture_output=True)
    metadata = release_metadata(config, version)
    with tempfile.TemporaryDirectory(prefix="draft-release-") as temporary:
        _, downloaded = fetch_release(config, version, source_commit, temporary, metadata, public=False)
        if {p.name: contract.digest(p) for p in downloaded} != {p.name: contract.digest(p) for p in files}:
            raise ValueError("Uploaded draft bytes differ from final prepared artifacts")
    contract.run(["gh", "release", "edit", f"v{version}", "--repo", config["repository"], "--draft=false"], capture_output=True)
    return verify_public_release(config, version, source_commit, directory)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "verify-app", "manifest", "collect", "prepare-cask", "verify-public-release", "fetch-release", "publish", "promote-cask"))
    parser.add_argument("--config", type=Path, default=Path("macos-app.json"))
    parser.add_argument("--root", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--build", default="1")
    parser.add_argument("--arch", choices=contract.ARCHITECTURES, default="universal")
    parser.add_argument("--sign-mode", choices=("ad-hoc", "developer-id"), default="ad-hoc")
    parser.add_argument("--team", default=os.environ.get("MACOS_TEAM_ID"))
    parser.add_argument("--app", type=Path)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--source-commit")
    parser.add_argument("--online", action="store_true")
    parser.add_argument("--request-notarization", action="store_true")
    parser.add_argument("--request-publish", action="store_true")
    parser.add_argument("--request-tap", action="store_true")
    parser.add_argument("--ci", action="store_true")
    parser.add_argument("--allow-remote", action="store_true")
    args = parser.parse_args(argv)
    config = contract.load_config(args.config)
    root = (args.root or args.config.resolve().parent).resolve()
    if args.version is None and config.get("versionFile"):
        args.version = (root / config["versionFile"]).read_text().strip()
    version = contract.validate_version(args.version)
    contract.validate_build(args.build)
    signed = args.sign_mode == "developer-id"
    remote = args.command in ("verify-public-release", "fetch-release", "publish", "promote-cask") or args.online
    if remote:
        contract.require_ci_remote(args.ci, args.allow_remote)
        if not contract.COMMIT.fullmatch(args.source_commit or ""):
            raise ValueError("Remote release commands require an explicit full --source-commit")
    if args.command == "preflight":
        if args.request_notarization and not signed:
            raise ValueError("Notarization requires Developer ID signing")
        eligible = signed and args.request_notarization and "-" not in version
        if args.request_tap and eligible and not args.request_publish:
            raise ValueError("Tap promotion requires public release publication")
        result = {"version": version, "tag": f"v{version}", "source": contract.source_state(root, args.source_commit), "reuse": False,
                  "publishEligible": eligible and args.request_publish,
                  "tapEligible": eligible and args.request_publish and args.request_tap}
        if result["publishEligible"] and result["source"]["dirty"]:
            raise ValueError("Stable publishing requires a clean source checkout")
        if args.online and result["publishEligible"]:
            result["reuse"] = check_publish_state(config, version, args.source_commit) == "reuse"
        if args.ci:
            required = []
            if signed and not result["reuse"]:
                required += ["MACOS_CERTIFICATE", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY", "MACOS_TEAM_ID"]
            if args.request_notarization and not result["reuse"]:
                required += ["APPLE_NOTARIZATION_KEY_ID", "APPLE_NOTARIZATION_ISSUER_ID", "APPLE_NOTARIZATION_PRIVATE_KEY"]
            if result["tapEligible"]:
                required += ["HOMEBREW_TAP_TOKEN"]
            missing = [name for name in required if not os.environ.get(name)]
            if missing:
                raise ValueError("Missing required CI configuration: " + ", ".join(missing))
        if os.environ.get("GITHUB_OUTPUT") and args.ci:
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as stream:
                stream.write(f"version={version}\nreuse={str(result['reuse']).lower()}\npublish_eligible={str(result['publishEligible']).lower()}\ntap_eligible={str(result['tapEligible']).lower()}\n")
    elif args.command == "verify-app":
        if not args.app:
            parser.error("verify-app requires --app")
        result = contract.verify_app(config, args.app, version, args.build, args.arch, signed, args.team)
    elif args.command == "manifest":
        if not args.app or not args.dmg:
            parser.error("manifest requires --app and --dmg")
        result = contract.create_manifest(config, root, args.app, args.dmg, version, args.build, args.arch, signed, args.team, args.receipt)
        target = args.output or args.dmg.with_suffix(".json")
        target.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        args.dmg.with_suffix(".dmg.sha256").write_text(f"{result['artifact']['sha256']}  {args.dmg.name}\n")
    elif args.command == "collect":
        if not args.directory:
            parser.error("collect requires --directory")
        manifests, files = contract.collect(config, args.directory, version, args.source_commit)
        result = {"manifests": manifests, "files": list(map(str, files))}
    elif args.command == "prepare-cask":
        if not args.manifest or not args.dmg or not args.output:
            parser.error("prepare-cask requires --manifest --dmg --output")
        manifest = json.loads(args.manifest.read_text())
        if manifest.get("version") != version:
            raise ValueError("Candidate cask version differs from requested version")
        result = contract.prepare_cask(config, manifest, args.dmg, args.output)
    elif args.command == "fetch-release":
        if not args.directory:
            parser.error("fetch-release requires --directory")
        manifests, files = fetch_release(config, version, args.source_commit, args.directory)
        result = {"manifests": manifests, "files": list(map(str, files))}
    elif args.command == "publish":
        if not args.directory:
            parser.error("publish requires --directory")
        result = publish(config, version, args.source_commit, args.directory)
    else:
        result = verify_public_release(config, version, args.source_commit, args.directory)
        if args.command == "promote-cask":
            if not args.output:
                parser.error("promote-cask requires --output")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(contract.cask_text(config, version, result["artifact"]["sha256"]))
            result["promotionReady"] = True
    if args.output and args.command in ("verify-public-release", "promote-cask"):
        evidence = args.output.with_suffix(args.output.suffix + ".promotion.json")
        evidence.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return result


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError, subprocess.CalledProcessError) as error:
        # subprocess commands may contain credentials; never format their command.
        message = contract.failure_message(error)
        print(f"Release error: {message}", file=sys.stderr)
        sys.exit(1)
