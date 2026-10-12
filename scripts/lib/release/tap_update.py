#!/usr/bin/env python3
"""Preview or explicitly update one cask; remote push is a separate CI-only operation."""
from __future__ import annotations
import argparse
import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import release_contract as contract
import release


def git(tap, *arguments):
    return contract.output(["git", "-C", tap, *arguments])


def cask_identity(text, token):
    if not text.startswith(f'cask "{token}" do\n'):
        raise ValueError("Candidate/target cask token mismatch")
    versions = re.findall(r'^  version "([^"\n]+)"$', text, re.MULTILINE)
    hashes = re.findall(r'^  sha256 "([a-f0-9]{64})"$', text, re.MULTILINE)
    if len(versions) != 1 or len(hashes) != 1:
        raise ValueError("Cask must contain exactly one stable version and SHA-256")
    contract.version_order(versions[0])
    return versions[0], hashes[0]


def validate_candidate(config, text, version):
    actual, sha = cask_identity(text, config["caskToken"])
    if actual != version or text != contract.cask_text(config, actual, sha):
        raise ValueError("Candidate must exactly match the generated cask contract")
    return sha


def check_checkout(tap, relative, push=False):
    tap = Path(tap).resolve()
    if Path(git(tap, "rev-parse", "--show-toplevel").strip()).resolve() != tap:
        raise ValueError("--tap must be the checkout root")
    target = tap / relative
    if target.is_symlink() or target.parent.is_symlink() or not target.resolve().is_relative_to(tap):
        raise ValueError("Cask target must stay inside the tap checkout")
    if git(tap, "status", "--porcelain=v1", "-z", "--", relative):
        raise ValueError("Target cask is dirty; preserve its existing work")
    if git(tap, "diff", "--cached", "--name-only", "-z"):
        raise ValueError("Tap has staged changes; refusing to mix commit scope")
    if push and git(tap, "status", "--porcelain=v1", "--untracked-files=normal"):
        raise ValueError("CI push requires a clean isolated tap checkout")
    return target


def update(tap, config, candidate, version, write=False, commit=False):
    contract.version_order(version)
    candidate_text = Path(candidate).read_text()
    sha = validate_candidate(config, candidate_text, version)
    relative = f"Casks/{config['caskToken']}.rb"
    target = check_checkout(tap, relative)
    old_text = target.read_text() if target.exists() else ""
    if old_text:
        old_version, old_sha = cask_identity(old_text, config["caskToken"])
        if contract.version_order(version) < contract.version_order(old_version):
            raise ValueError("Refusing a stable cask downgrade")
        if version == old_version:
            if sha != old_sha:
                raise ValueError("Immutable same-version SHA-256 drift")
            return {"changed": False, "committed": False, "path": relative, "mode": "write" if write else "preview"}
    preview = "".join(difflib.unified_diff(old_text.splitlines(keepends=True), candidate_text.splitlines(keepends=True), fromfile=relative, tofile=relative))
    result = {"changed": old_text != candidate_text, "committed": False, "path": relative, "mode": "write" if write else "preview", "diff": preview}
    if write and result["changed"]:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(candidate_text)
        if commit:
            git(tap, "add", "--", relative)
            staged = git(tap, "diff", "--cached", "--name-only", "-z").split("\x00")
            if [name for name in staged if name] != [relative]:
                raise ValueError("Staged scope changed during the cask update")
            # Identity belongs to this command; never modify persistent Git config.
            git(tap, "-c", "user.name=github-actions[bot]", "-c", "user.email=github-actions[bot]@users.noreply.github.com",
                "commit", "--only", "-m", f"chore(cask): update {config['caskToken']} to {version}", "--", relative)
            result["committed"] = True
            result["commit"] = git(tap, "rev-parse", "HEAD").strip()
            if git(tap, "status", "--porcelain=v1", "-z", "--", relative):
                raise ValueError("Cask commit did not leave the target clean")
    return result


def remote_update(tap, config, candidate, version, source_commit, branch, tap_repository):
    """Called only after the CLI's explicit CI/remote/token gate."""
    relative = f"Casks/{config['caskToken']}.rb"
    check_checkout(tap, relative, push=True)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", tap_repository) or not re.fullmatch(r"[A-Za-z0-9_.-]+", branch):
        raise ValueError("Invalid tap repository or branch")
    remote = git(tap, "remote", "get-url", "origin").strip()
    allowed = {f"https://github.com/{tap_repository}", f"https://github.com/{tap_repository}.git", f"git@github.com:{tap_repository}.git"}
    if remote not in allowed or git(tap, "branch", "--show-current").strip() != branch:
        raise ValueError("Tap origin/branch does not match the explicit promotion target")
    proof = release.verify_public_release(config, version, source_commit)
    candidate_sha = validate_candidate(config, Path(candidate).read_text(), version)
    if candidate_sha != proof["artifact"]["sha256"]:
        raise ValueError("Cask SHA-256 differs from the actual public universal DMG")
    git(tap, "fetch", "origin", branch)
    if git(tap, "rev-list", f"origin/{branch}..HEAD").strip():
        raise ValueError("Isolated tap checkout has unpublished local commits")
    git(tap, "merge", "--ff-only", f"origin/{branch}")
    result = update(tap, config, candidate, version, write=True, commit=True)
    if not result["changed"]:
        return result
    for attempt in range(3):
        pushed = subprocess.run(["git", "-C", str(tap), "push", "origin", f"HEAD:refs/heads/{branch}"], capture_output=True, text=True)
        if pushed.returncode == 0:
            result["pushed"] = True
            return result
        if attempt == 2:
            raise RuntimeError("Tap push failed after bounded concurrency retries; local commit retained")
        git(tap, "fetch", "origin", branch)
        # If another run updated this same cask, stop instead of silently overwriting it.
        changed = git(tap, "diff", "--name-only", "HEAD^", f"origin/{branch}", "--", relative).strip()
        if changed:
            raise ValueError("Concurrent update touched the same cask; inspect the retained local commit")
        try:
            git(tap, "rebase", f"origin/{branch}")
        except subprocess.CalledProcessError:
            git(tap, "rebase", "--abort")
            raise RuntimeError("Concurrent tap changes could not be rebased safely") from None
        changed_paths = git(tap, "diff", "--name-only", f"origin/{branch}", "HEAD").splitlines()
        if changed_paths != [relative]:
            raise ValueError("Rebased promotion would modify more than its target cask")
    raise RuntimeError("Unreachable push state")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("macos-app.json"))
    parser.add_argument("--tap", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--commit", action="store_true")
    parser.add_argument("--push", action="store_true")
    parser.add_argument("--ci", action="store_true")
    parser.add_argument("--allow-remote", action="store_true")
    parser.add_argument("--source-commit")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--tap-repository", default="mayflies-app/homebrew-tap")
    args = parser.parse_args(argv)
    config = contract.load_config(args.config)
    if args.push:
        contract.require_ci_remote(args.ci, args.allow_remote, token_name="HOMEBREW_TAP_TOKEN")
        contract.require_ci_remote(args.ci, args.allow_remote, token_name="GH_TOKEN")
        if not args.write or not args.commit or not contract.COMMIT.fullmatch(args.source_commit or ""):
            parser.error("--push requires --write --commit and an explicit full --source-commit")
        result = remote_update(args.tap, config, args.candidate, args.version, args.source_commit, args.branch, args.tap_repository)
    else:
        if args.commit and not args.write:
            parser.error("--commit requires explicit --write")
        result = update(args.tap, config, args.candidate, args.version, args.write, args.commit)
    print(json.dumps(result, indent=2, sort_keys=True))
    return result


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print("Tap update error: " + ("external command failed" if isinstance(error, subprocess.CalledProcessError) else str(error)), file=sys.stderr)
        sys.exit(1)
