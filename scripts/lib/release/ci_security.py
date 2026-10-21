#!/usr/bin/env python3
"""Temporary CI keychain and notarization wrappers; no local credential mutation."""
from __future__ import annotations
import argparse
import base64
import contextlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import threading

import release_contract as contract


def secret_file(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
        stream.write(data)


def security(*arguments):
    return contract.run(["security", *arguments], capture_output=True, text=True)


@contextlib.contextmanager
def terminate_with_cleanup():
    """Translate catchable CI SIGTERM into normal stack unwinding on the main thread."""
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    original = signal.getsignal(signal.SIGTERM)
    def terminated(signum, frame):
        # A second SIGTERM must not interrupt restoration already in progress.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminated)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, original)


@contextlib.contextmanager
def temporary_keychain(environment=None):
    env = os.environ if environment is None else environment
    required = ("RUNNER_TEMP", "MACOS_CERTIFICATE", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY", "MACOS_TEAM_ID")
    missing = [name for name in required if not env.get(name)]
    if missing:
        raise ValueError("Missing CI signing configuration: " + ", ".join(missing))
    original_search = shlex.split(security("list-keychains", "-d", "user").stdout)
    original_default = shlex.split(security("default-keychain", "-d", "user").stdout)
    if len(original_default) != 1:
        raise ValueError("Cannot safely restore user default keychain")
    password = env.get("MACOS_KEYCHAIN_PASSWORD") or os.urandom(32).hex()
    with terminate_with_cleanup(), tempfile.TemporaryDirectory(prefix="release-signing-", dir=env["RUNNER_TEMP"]) as temporary:
        keychain = Path(temporary) / "build.keychain-db"
        p12 = Path(temporary) / "certificate.p12"
        secret_file(p12, base64.b64decode(env["MACOS_CERTIFICATE"], validate=True))
        created = False
        body_error = None
        try:
            # Creation may succeed before a signal interrupts the parent wait.
            # Delete this private path even after an uncertain command exit.
            created = True
            security("create-keychain", "-p", password, keychain)
            security("set-keychain-settings", "-lut", "21600", keychain)
            security("unlock-keychain", "-p", password, keychain)
            security("import", p12, "-P", env["MACOS_CERTIFICATE_PASSWORD"], "-t", "cert", "-f", "pkcs12", "-k", keychain, "-T", "/usr/bin/codesign")
            security("set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain)
            security("list-keychains", "-d", "user", "-s", keychain, *original_search)
            security("default-keychain", "-d", "user", "-s", keychain)
            yield dict(env, CODE_SIGN_KEYCHAIN=str(keychain), KEYCHAIN_PATH=str(keychain))
        except BaseException as error:
            body_error = error
            raise
        finally:
            if threading.current_thread() is threading.main_thread():
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            cleanup_errors = []
            # Try every restoration action even when an earlier action fails.
            for arguments in [("list-keychains", "-d", "user", "-s", *original_search),
                              ("default-keychain", "-d", "user", "-s", original_default[0]),
                              *(([("delete-keychain", keychain)]) if created else [])]:
                try:
                    security(*arguments)
                except (OSError, subprocess.SubprocessError):
                    cleanup_errors.append(arguments[0])
            if cleanup_errors:
                print("CI keychain cleanup failed: " + ", ".join(cleanup_errors), file=sys.stderr)
                if body_error is None:
                    raise RuntimeError("CI keychain state could not be completely restored")


def notarize(dmg, receipt, environment=None):
    env = os.environ if environment is None else environment
    required = ("RUNNER_TEMP", "APPLE_NOTARIZATION_PRIVATE_KEY", "APPLE_NOTARIZATION_KEY_ID", "APPLE_NOTARIZATION_ISSUER_ID")
    missing = [name for name in required if not env.get(name)]
    if missing:
        raise ValueError("Missing CI notarization configuration: " + ", ".join(missing))
    dmg, receipt = Path(dmg), Path(receipt)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    if receipt.exists():
        raise ValueError("Refusing to overwrite a notarization receipt")
    contract.signature_details(dmg, env.get("MACOS_TEAM_ID"), require_developer_id=True)
    contract.run(["hdiutil", "verify", dmg], capture_output=True)
    with terminate_with_cleanup(), tempfile.TemporaryDirectory(prefix="release-notary-", dir=env["RUNNER_TEMP"]) as temporary:
        key = Path(temporary) / "AuthKey.p8"
        value = env["APPLE_NOTARIZATION_PRIVATE_KEY"]
        data = value.encode() if "BEGIN PRIVATE KEY" in value else base64.b64decode(value, validate=True)
        secret_file(key, data.rstrip() + b"\n")
        credentials = ["--key", key, "--key-id", env["APPLE_NOTARIZATION_KEY_ID"], "--issuer", env["APPLE_NOTARIZATION_ISSUER_ID"]]
        result = subprocess.run(list(map(str, ["xcrun", "notarytool", "submit", dmg, *credentials, "--wait", "--timeout", "30m", "--output-format", "json"])), capture_output=True, text=True)
        # Retain Apple's exact JSON, including failures. No private key/credential file is retained.
        receipt.write_text(result.stdout or "{}\n")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError:
            payload = None
        valid_json = isinstance(payload, dict)
        submission_id = payload.get("id") if valid_json else None
        has_submission_id = isinstance(submission_id, str) and bool(submission_id)
        if has_submission_id:
            subprocess.run(list(map(str, ["xcrun", "notarytool", "log", payload["id"], *credentials, receipt.with_suffix(".log.json")])), capture_output=True, text=True)
        if result.returncode or not valid_json:
            reason = "submission failed" if result.returncode else "invalid submission response"
            # Only classify known status markers; never echo arbitrary tool output or credentials.
            if result.returncode and "HTTP status code 401" in result.stderr:
                reason = "authentication rejected"
            elif result.returncode and "HTTP status code 403" in result.stderr:
                reason = "authorization rejected"
            evidence = ("JSON receipt retained with submission ID; log retrieval attempted" if has_submission_id else
                        "JSON receipt retained; no submission ID was returned" if valid_json else
                        "No valid JSON receipt or submission ID was returned")
            raise RuntimeError(f"Notarization {reason} (exit code {result.returncode}). {evidence}")
        contract.require_accepted_notarization(payload)
    contract.run(["xcrun", "stapler", "staple", dmg], capture_output=True)
    contract.run(["xcrun", "stapler", "validate", dmg], capture_output=True)
    return payload


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("run-with-keychain", "notarize"))
    parser.add_argument("--ci", action="store_true")
    parser.add_argument("--allow-remote", action="store_true")
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--receipt", type=Path)
    args, command = parser.parse_known_args(argv)
    contract.require_ci_remote(args.ci, args.allow_remote, token_name="MACOS_CERTIFICATE" if args.command == "run-with-keychain" else "APPLE_NOTARIZATION_PRIVATE_KEY")
    if args.command == "run-with-keychain":
        if command and command[0] == "--":
            command = command[1:]
        if not command:
            parser.error("run-with-keychain requires -- followed by the existing owner command")
        with temporary_keychain() as env:
            contract.run(command, env=env)
    else:
        if command:
            parser.error("Unexpected notarization arguments")
        if not args.dmg or not args.receipt:
            parser.error("notarize requires --dmg and --receipt")
        notarize(args.dmg, args.receipt)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print("CI security error: " + ("external command failed" if isinstance(error, subprocess.CalledProcessError) else str(error)), file=sys.stderr)
        sys.exit(1)
