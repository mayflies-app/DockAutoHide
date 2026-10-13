#!/usr/bin/env python3
"""Vendored macOS release contract. Python 3 standard library, no repository globals."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

ARCHITECTURES = ("arm64", "x86_64", "universal")
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")
SHA = re.compile(r"[a-f0-9]{64}")
COMMIT = re.compile(r"[a-f0-9]{40}")
RELATIVE_PATH = re.compile(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*")
MACOS_CASK_SYMBOLS = {13: "ventura", 14: "sonoma"}


def validate_version(value):
    match = VERSION.fullmatch(value) if isinstance(value, str) else None
    if not match or any(p.isdigit() and len(p) > 1 and p.startswith("0")
                        for p in (match[4] or "").split(".")):
        raise ValueError("Version must be strict SemVer without build metadata")
    return value


def validate_build(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError("Build must be a positive integer string")
    return value


def has_secure_timestamp(value):
    # codesign's absent-timestamp sentinel is text, not an empty/false value.
    # Do not constrain Apple's localized date formatting for actual timestamps.
    return isinstance(value, str) and value.strip().lower() not in ("", "none", "not set", "null", "(null)", "n/a", "missing", "unknown")


def version_order(value):
    validate_version(value)
    if "-" in value:
        raise ValueError("Stable promotion does not accept prereleases")
    return tuple(map(int, value.split(".")))


def minimum_version(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]*(?:\.(?:0|[1-9][0-9]*)){1,2}", value):
        raise ValueError("Invalid macOS minimum version")
    return tuple(map(int, value.split("."))) + (0,) * (3 - len(value.split(".")))


def validate_config(config):
    if type(config.get("schemaVersion")) is not int or config["schemaVersion"] != 1:
        raise ValueError("Unsupported macos-app.json schemaVersion")
    patterns = {"product": r"[A-Za-z][A-Za-z0-9_-]*", "executable": r"[A-Za-z][A-Za-z0-9_.-]*",
                "bundleIdentifier": r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+",
                "repository": r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", "caskToken": r"[a-z0-9]+(?:-[a-z0-9]+)*"}
    for key, pattern in patterns.items():
        if not isinstance(config.get(key), str) or not re.fullmatch(pattern, config[key]):
            raise ValueError(f"Invalid config {key}")
    for key in ("appName", "description"):
        if not isinstance(config.get(key), str) or not config[key] or any(c in config[key] for c in '\n\r\x00"\\/#{}'):
            raise ValueError(f"Unsafe config {key}")
    minimum_version(config.get("minimumSystemVersion"))
    if config.get("buildSystem") not in ("swiftpm", "xcode"):
        raise ValueError("buildSystem must preserve the swiftpm or xcode owner")
    if config.get("releaseAdapter", "scripts/app.py") != "scripts/app.py":
        raise ValueError("releaseAdapter must be scripts/app.py")
    if config.get("architectures") != list(ARCHITECTURES):
        raise ValueError("architectures must be arm64, x86_64, universal in that order")
    if not isinstance(config.get("paths", {}), dict):
        raise ValueError("paths must be an owner path object")
    for key, value in config.get("paths", {}).items():
        if not isinstance(key, str) or not isinstance(value, str) or not RELATIVE_PATH.fullmatch(value) or any(p in (".", "..") for p in Path(value).parts):
            raise ValueError("paths must contain relative owner paths")
    version_file = config.get("versionFile")
    if version_file is not None and (not isinstance(version_file, str) or not RELATIVE_PATH.fullmatch(version_file) or any(p in (".", "..") for p in Path(version_file).parts)):
        raise ValueError("versionFile must be repository relative")
    return config


def load_config(path):
    return validate_config(json.loads(Path(path).read_text()))


def run(arguments, **kwargs):
    return subprocess.run(list(map(str, arguments)), check=True, **kwargs)


def output(arguments, **kwargs):
    return run(arguments, capture_output=True, text=True, **kwargs).stdout


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def bundle_payload_digest(app):
    """Hash relative entry names and payload, without mount path/mtime/ownership."""
    app = Path(app)
    if not stat.S_ISDIR(app.lstat().st_mode):
        raise ValueError("App root must be a real directory, not a symlink")
    root = app.resolve()
    entries = []
    for path in sorted(app.rglob("*")):
        mode = path.lstat().st_mode
        entry = {"path": path.relative_to(app).as_posix()}
        if stat.S_ISLNK(mode):
            try:
                contained = path.resolve().is_relative_to(root)
            except RuntimeError:
                contained = False
            if not contained:
                raise ValueError("App symlink resolves outside its bundle")
            entry.update(kind="symlink", target=os.readlink(path))
        elif stat.S_ISREG(mode):
            entry.update(kind="file", sha256=digest(path), executable=bool(mode & 0o111))
        elif stat.S_ISDIR(mode):
            entry.update(kind="directory")
        else:
            raise ValueError("App payload contains an unsupported special file")
        entries.append(entry)
    return hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def source_state(root, commit=None):
    actual = output(["git", "rev-parse", "HEAD"], cwd=root).strip()
    if not COMMIT.fullmatch(actual) or (commit is not None and actual != commit):
        raise ValueError("Source commit must equal repository HEAD")
    return {"commit": actual, "dirty": bool(output(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=root))}


def artifact_name(config, version, architecture):
    validate_version(version)
    if architecture not in ARCHITECTURES:
        raise ValueError("Unsupported architecture")
    return f"{config['product']}-{version}-{architecture}.dmg"


def signature_details(path, expected_team=None, require_developer_id=False, executable=False):
    run(["codesign", "--verify", "--strict", "--deep", path], capture_output=True)
    details = run(["codesign", "--display", "--verbose=4", path], capture_output=True, text=True).stderr
    def field(name):
        match = re.search(r"^" + name + r"=(.*)$", details, re.MULTILINE)
        return match[1] if match else None
    developer = "Authority=Developer ID Application:" in details
    category = "developer-id" if developer else "adhoc" if "Signature=adhoc" in details else "other"
    # codesign display includes the requested absolute Executable path. It is
    # location evidence, not signature identity; preserve every other line.
    normalized_details = re.sub(r"^Executable=.*$", "Executable=<verified-relative-executable>", details, flags=re.MULTILINE)
    record = {"category": category, "teamIdentifier": field("TeamIdentifier"),
              "runtime": "(runtime)" in details, "timestamp": field("Timestamp"),
              "verification": "codesign --verify --strict --deep", "detailsSha256": hashlib.sha256(normalized_details.encode()).hexdigest()}
    if require_developer_id:
        if not developer or not has_secure_timestamp(record["timestamp"]) or (executable and not record["runtime"]):
            raise ValueError("Developer ID signature requires secure timestamp and executable hardened runtime")
        if not expected_team or record["teamIdentifier"] != expected_team:
            raise ValueError("Developer ID team does not match explicit expected team")
        if executable:
            entitlement_bytes = run(["codesign", "--display", "--entitlements", ":-", path], capture_output=True).stdout
            if entitlement_bytes and plistlib.loads(entitlement_bytes).get("com.apple.security.get-task-allow"):
                raise ValueError("Distribution executable allows debugging")
    elif category != "adhoc":
        raise ValueError("Development artifacts require an ad-hoc signature")
    return record


def verify_app(config, app, version, build, architecture, signed=False, team=None, contained_in=None):
    validate_config(config)
    validate_version(version)
    validate_build(build)
    if architecture not in ARCHITECTURES:
        raise ValueError("Unsupported architecture")
    app = Path(app)
    if not stat.S_ISDIR(app.lstat().st_mode):
        raise ValueError("App root must be a real directory, not a symlink")
    if contained_in is not None and not app.resolve().is_relative_to(Path(contained_in).resolve()):
        raise ValueError("App root resolves outside the mounted artifact")
    if app.name != config["appName"] + ".app":
        raise ValueError("App bundle name does not match configuration")
    payload_sha256 = bundle_payload_digest(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleShortVersionString": version.split("-")[0], "CFBundleVersion": build,
                "CFBundleIdentifier": config["bundleIdentifier"], "CFBundleExecutable": config["executable"]}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Bundle mismatch for {key}")
    if minimum_version(info.get("LSMinimumSystemVersion")) != minimum_version(config["minimumSystemVersion"]):
        raise ValueError("Bundle minimum macOS does not match configuration")
    binary = app / "Contents/MacOS" / config["executable"]
    actual_arches = set(output(["lipo", "-archs", binary]).split())
    expected_arches = {"arm64", "x86_64"} if architecture == "universal" else {architecture}
    if actual_arches != expected_arches:
        raise ValueError("Executable architectures do not match artifact label")
    minimums = {}
    for arch in sorted(actual_arches):
        details = output(["xcrun", "vtool", "-arch", arch, "-show-build", binary])
        found = re.findall(r"\bminos\s+(\d+\.\d+(?:\.\d+)?)", details)
        if len(found) != 1 or minimum_version(found[0]) != minimum_version(config["minimumSystemVersion"]):
            raise ValueError(f"Mach-O minimum macOS does not match for {arch}")
        minimums[arch] = found[0]
    app_signature = signature_details(app, team, signed, executable=True)
    # A bundle signature must not hide an executable with a different team/runtime.
    binary_signature = signature_details(binary, team, signed, executable=True)
    return {"appName": config["appName"], "executable": config["executable"], "info": {**expected, "LSMinimumSystemVersion": info["LSMinimumSystemVersion"]},
            "architectures": sorted(actual_arches), "minimumSystemVersionByArchitecture": minimums,
            "signature": app_signature, "executableSignature": binary_signature, "payloadSha256": payload_sha256}


def require_accepted_notarization(payload):
    if payload.get("status") != "Accepted" or not isinstance(payload.get("id"), str) or not payload["id"]:
        raise ValueError("Notarization receipt must have status Accepted and an id")


def create_manifest(config, root, app, dmg, version, build, architecture, signed=False, team=None, receipt=None):
    """Verify the app INSIDE the final DMG before recording final bytes and receipt."""
    dmg = Path(dmg).resolve()
    if dmg.name != artifact_name(config, version, architecture):
        raise ValueError("DMG name does not match the release contract")
    source = source_state(root)
    bundle = verify_app(config, app, version, build, architecture, signed, team)
    run(["hdiutil", "verify", dmg], capture_output=True)
    with tempfile.TemporaryDirectory(prefix="release-mount-") as temporary:
        mount = Path(temporary) / "volume"
        attached = False
        try:
            run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg], capture_output=True)
            attached = True
            inside = verify_app(config, mount / (config["appName"] + ".app"), version, build, architecture, signed, team, contained_in=mount)
            if inside != bundle:
                raise ValueError("DMG app differs from verified owner bundle")
        finally:
            if attached:
                run(["hdiutil", "detach", mount], capture_output=True)
    dmg_signature = signature_details(dmg, team, signed)
    notarization = {"status": "not-requested", "receipt": None, "stapled": False}
    if receipt:
        if not signed:
            raise ValueError("Notarization requires Developer ID signing")
        receipt_path = Path(receipt).resolve()
        if receipt_path.parent != dmg.parent:
            raise ValueError("Accepted receipt must be next to its final DMG")
        payload = json.loads(receipt_path.read_text())
        require_accepted_notarization(payload)
        run(["xcrun", "stapler", "validate", dmg], capture_output=True)
        notarization = {"status": "accepted", "submissionId": payload["id"], "stapled": True,
                        "receipt": {"path": receipt_path.name, "sha256": digest(receipt_path)}}
    return {"schemaVersion": 1, "product": config["product"], "repository": config["repository"],
            "source": source, "version": version, "build": build, "architecture": architecture,
            "bundle": bundle, "dmgSignature": dmg_signature,
            "verification": {"scope": "owner-bundle-and-readonly-mounted-dmg-app-payload", "payloadIdentity": "relative-paths-file-bytes-symlink-targets-executable-bits"},
            "artifact": {"name": dmg.name, "path": dmg.name, "size": dmg.stat().st_size, "sha256": digest(dmg)},
            "notarization": notarization}


def verify_manifest(config, manifest, dmg, promotion=False):
    validate_config(config)
    version = validate_version(manifest.get("version"))
    validate_build(manifest.get("build"))
    arch = manifest.get("architecture")
    if manifest.get("schemaVersion") != 1 or manifest.get("product") != config["product"] or manifest.get("repository") != config["repository"]:
        raise ValueError("Manifest identity/schema mismatch")
    source = manifest.get("source", {})
    if not COMMIT.fullmatch(str(source.get("commit", ""))) or type(source.get("dirty")) is not bool:
        raise ValueError("Invalid source provenance")
    artifact = manifest.get("artifact", {})
    dmg = Path(dmg)
    if artifact.get("name") != artifact_name(config, version, arch) or dmg.name != artifact["name"] or artifact.get("path") != artifact["name"]:
        raise ValueError("Artifact name/path mismatch")
    if type(artifact.get("size")) is not int or artifact["size"] != dmg.stat().st_size or artifact.get("sha256") != digest(dmg):
        raise ValueError("Artifact size/digest mismatch")
    bundle = manifest.get("bundle", {})
    if not SHA.fullmatch(str(bundle.get("payloadSha256", ""))):
        raise ValueError("Manifest lacks app payload byte identity")
    info = bundle.get("info", {})
    expected = {"CFBundleShortVersionString": version.split("-")[0], "CFBundleVersion": manifest["build"], "CFBundleIdentifier": config["bundleIdentifier"],
                "CFBundleExecutable": config["executable"]}
    if any(info.get(k) != v for k, v in expected.items()) or minimum_version(info.get("LSMinimumSystemVersion")) != minimum_version(config["minimumSystemVersion"]):
        raise ValueError("Manifest bundle metadata mismatch")
    arches = ["arm64", "x86_64"] if arch == "universal" else [arch]
    if bundle.get("architectures") != arches or bundle.get("appName") != config["appName"] or bundle.get("executable") != config["executable"]:
        raise ValueError("Manifest bundle architecture/identity mismatch")
    minimums = bundle.get("minimumSystemVersionByArchitecture", {})
    if set(minimums) != set(arches) or any(minimum_version(v) != minimum_version(config["minimumSystemVersion"]) for v in minimums.values()):
        raise ValueError("Manifest Mach-O minimum macOS mismatch")
    notarization = manifest.get("notarization", {})
    if notarization.get("status") not in ("not-requested", "accepted", "failed"):
        raise ValueError("Unknown notarization status")
    if notarization.get("status") == "accepted":
        receipt = notarization.get("receipt", {})
        if not notarization.get("submissionId") or notarization.get("stapled") is not True or not SHA.fullmatch(str(receipt.get("sha256", ""))) or not isinstance(receipt.get("path"), str) or Path(receipt["path"]).name != receipt["path"]:
            raise ValueError("Accepted notarization requires stapling and receipt evidence")
    if promotion:
        version_order(version)
        if source["dirty"]:
            raise ValueError("Stable release source must be clean")
        signatures = [bundle.get("signature", {}), bundle.get("executableSignature", {}), manifest.get("dmgSignature", {})]
        teams = {s.get("teamIdentifier") for s in signatures}
        if len(teams) != 1 or None in teams or any(s.get("category") != "developer-id" or not has_secure_timestamp(s.get("timestamp")) for s in signatures) or not all(s.get("runtime") is True for s in signatures[:2]):
            raise ValueError("Promotion requires Developer ID, consistent team, timestamp, and executable hardened runtime")
        if notarization.get("status") != "accepted":
            raise ValueError("Promotion requires accepted and stapled notarization")
    return manifest


def collect(config, directory, version, commit=None, promotion=False):
    directory = Path(directory)
    validate_version(version)
    manifests = []
    files = []
    dmgs = list(directory.rglob("*.dmg"))
    names = {arch: artifact_name(config, version, arch) for arch in ARCHITECTURES}
    actual_names = {dmg.name for dmg in dmgs}
    if actual_names - set(names.values()):
        raise ValueError("Unexpected DMG in release directory")
    if actual_names == {names["universal"]}:
        architectures = ("universal",)
    elif actual_names == set(names.values()):
        architectures = ARCHITECTURES
    else:
        raise ValueError("Release requires a Universal-only or complete three-architecture DMG group")
    for arch in architectures:
        matches = [dmg for dmg in dmgs if dmg.name == names[arch]]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one {arch} DMG")
        dmg = matches[0]
        manifest_path = dmg.with_suffix(".json")
        manifest = verify_manifest(config, json.loads(manifest_path.read_text()), dmg, promotion)
        if manifest["version"] != version or manifest["architecture"] != arch or (commit and manifest["source"]["commit"] != commit):
            raise ValueError("Manifest version/architecture/source mismatch")
        if dmg.with_suffix(".dmg.sha256").read_text() != f"{digest(dmg)}  {dmg.name}\n":
            raise ValueError("Artifact checksum sidecar mismatch")
        files.extend([dmg, manifest_path, dmg.with_suffix(".dmg.sha256")])
        if manifest["notarization"]["status"] == "accepted":
            receipt = manifest["notarization"]["receipt"]
            receipt_path = dmg.parent / receipt["path"]
            receipt_payload = json.loads(receipt_path.read_text())
            require_accepted_notarization(receipt_payload)
            if receipt_payload["id"] != manifest["notarization"]["submissionId"]:
                raise ValueError("Notarization submission id differs from retained receipt")
            if digest(receipt_path) != receipt["sha256"]:
                raise ValueError("Notarization receipt bytes differ from manifest")
            files.append(receipt_path)
        manifests.append(manifest)
    if len({m["build"] for m in manifests}) != 1 or len({m["source"]["commit"] for m in manifests}) != 1 or len({m["source"]["dirty"] for m in manifests}) != 1:
        raise ValueError("Architecture builds must share build number and source state")
    def signing_profile(manifest):
        signatures = (manifest["bundle"].get("signature", {}), manifest["bundle"].get("executableSignature", {}), manifest.get("dmgSignature", {}))
        return (tuple((s.get("category"), s.get("teamIdentifier"), s.get("runtime"), has_secure_timestamp(s.get("timestamp"))) for s in signatures),
                manifest["notarization"].get("status"), manifest["notarization"].get("stapled"))
    if len({signing_profile(m) for m in manifests}) != 1:
        raise ValueError("Architecture builds must share the same signing team/mode and notarization readiness")
    if len({p.name for p in files}) != len(files):
        raise ValueError("Release attachment names must be unique (use architecture-specific receipts)")
    return manifests, files


def cask_text(config, version, sha256):
    validate_config(config)
    version_order(version)
    if not SHA.fullmatch(sha256):
        raise ValueError("Invalid cask SHA-256")
    minimum = config["minimumSystemVersion"]
    major, minor, patch = minimum_version(minimum)
    symbol = MACOS_CASK_SYMBOLS.get(major)
    if symbol is None:
        raise ValueError("Unsupported Homebrew macOS major; extend the approved symbol map first")
    preflight = ""
    if minor or patch:
        preflight = f'''  preflight_steps do
    run "/bin/sh", args: ["-c", <<~SH]
      version=$(/usr/bin/sw_vers -productVersion)
      major=${{version%%.*}}
      minor=${{version#*.}}
      [ "$minor" = "$version" ] && minor=0
      patch=${{minor#*.}}
      [ "$patch" = "$minor" ] && patch=0
      minor=${{minor%%.*}}
      if [ "$major" -lt {major} ] || {{ [ "$major" -eq {major} ] && [ "$minor" -lt {minor} ]; }} || {{ [ "$major" -eq {major} ] && [ "$minor" -eq {minor} ] && [ "$patch" -lt {patch} ]; }}; then
        echo "{config['product']} requires macOS {minimum} or later." >&2
        exit 1
      fi
    SH
  end

'''
    bundle = config["bundleIdentifier"]
    return f'''cask "{config['caskToken']}" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/{config['repository']}/releases/download/v#{{version}}/{config['product']}-#{{version}}-universal.dmg"
  name "{config['appName']}"
  desc "{config['description']}"
  homepage "https://github.com/{config['repository']}"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :{symbol}

  app "{config['appName']}.app"

{preflight}  uninstall quit: "{bundle}"

  zap trash: [
    "~/Library/Preferences/{bundle}.plist",
    "~/Library/Saved Application State/{bundle}.savedState",
  ]
end
'''


def prepare_cask(config, manifest, dmg, output_path, promotion=False):
    verify_manifest(config, manifest, dmg, promotion=promotion)
    if manifest["architecture"] != "universal":
        raise ValueError("A cask must use the final universal DMG")
    # Local candidate generation intentionally does not claim that its URL exists.
    text = cask_text(config, manifest["version"], digest(dmg))
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(text)
    return {"candidate": str(output_path), "promotionReady": False, "publicAssetVerified": False,
            "artifactSha256": digest(dmg)}


def require_ci_remote(ci=False, allow_remote=False, token_name="GH_TOKEN", environment=None):
    env = os.environ if environment is None else environment
    if not ci or not allow_remote or env.get("GITHUB_ACTIONS") != "true" or env.get("GITHUB_EVENT_NAME") != "workflow_dispatch" or not env.get(token_name):
        raise ValueError("Remote operation requires explicit --ci --allow-remote and workflow_dispatch with token")
