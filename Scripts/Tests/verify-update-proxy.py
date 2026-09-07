#!/usr/bin/env python3
"""Exercise official Sparkle signature validation, extraction, install and relaunch in disposable apps.

Requires an existing debug build with testing enabled; never builds or starts the real app.
All credentials are newly generated fixture keys; sign_update always receives --ed-key-file.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
SIGNER = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"


def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, capture_output=True, text=True, **kwargs)


def compile_fixture(build, work):
    objects = sorted((build / "CodexRunwayCore.build").glob("*.swift.o"))
    if not objects or not (build / "Modules/CodexRunwayCore.swiftmodule").exists():
        raise RuntimeError("Run swift test first to produce the debug Core module and objects")
    executable = work / "UpdateProxyFixture"
    run([
        "swiftc", "-parse-as-library", "-swift-version", "6", "-module-name", "UpdateProxyFixture",
        "-target", f"{os.uname().machine}-apple-macosx12.0",
        "-module-cache-path", work / "module-cache", "-I", build / "Modules", "-F", build,
        "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ROOT / "Scripts/Tests/UpdateProxyFixture.swift", *objects, "-lsqlite3", "-o", executable,
    ])
    return executable


def create_keys(work):
    source = work / "CreateFixtureKey.swift"
    source.write_text('''import CryptoKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let seed = Data(key.rawRepresentation.base64EncodedString().utf8)
guard FileManager.default.createFile(atPath: root.appendingPathComponent("fixture.key").path,
    contents: seed, attributes: [.posixPermissions: 0o600]) else { fatalError("fixture key write failed") }
try key.publicKey.rawRepresentation.base64EncodedString().write(
    to: root.appendingPathComponent("fixture.pub"), atomically: true, encoding: .utf8)
''')
    run(["swift", "-module-cache-path", work / "module-cache", source, work])
    return (work / "fixture.pub").read_text().strip()


def make_app(case, executable, framework, key, version, identifier):
    app = case / ("installed" if version == "1" else "payload") / "UpdateProxyFixture.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    shutil.copy2(executable, contents / "MacOS/UpdateProxyFixture")
    run(["ditto", framework, contents / "Frameworks/Sparkle.framework"])
    info = {
        "CFBundleIdentifier": identifier, "CFBundleName": "UpdateProxyFixture",
        "CFBundleExecutable": "UpdateProxyFixture", "CFBundlePackageType": "APPL",
        "CFBundleVersion": version, "CFBundleShortVersionString": version,
        "LSMinimumSystemVersion": "12.0", "LSUIElement": True,
        "SUPublicEDKey": key, "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
        "SUEnableAutomaticChecks": False,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}, "FixtureRoot": str(case),
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    entitlements = case / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.cs.disable-library-validation": True}))
    run(["codesign", "--force", "--options", "runtime", "--entitlements", entitlements, "--sign", "-", app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    return app


def create_signed_feed(case, key_file, invalid_archive):
    archive = case / "UpdateProxyFixture.zip"
    signature = run([SIGNER, "--ed-key-file", key_file, "-p", archive]).stdout.strip()
    if invalid_archive:
        signature = base64.b64encode(bytes(64)).decode("ascii")
    feed = case / "appcast.xml"
    feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Update proxy fixture</title><item><title>Version 2</title>
<sparkle:version>2</sparkle:version><sparkle:shortVersionString>2</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
<enclosure url="https://github.com/Licoy/codex-runway/releases/download/fixture/UpdateProxyFixture.zip"
sparkle:edSignature="{signature}" length="{archive.stat().st_size}" type="application/octet-stream"/>
</item></channel></rss>
''')
    run([SIGNER, "--ed-key-file", key_file, feed])
    return signature


def verify_signature(file, key_file, signature=None):
    arguments = [str(SIGNER), "--verify", "--ed-key-file", str(key_file), str(file)]
    if signature is not None:
        arguments.append(signature)
    return subprocess.run(arguments, capture_output=True, text=True).returncode == 0


def stop_fixture(case):
    events = case / "events.jsonl"
    if not events.exists():
        return
    for line in events.read_text().splitlines():
        event = json.loads(line)
        if event.get("event") != "launched":
            continue
        pid = int(event["pid"])
        result = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
        expected = str(case / "installed/UpdateProxyFixture.app/Contents/MacOS/UpdateProxyFixture")
        if result.stdout.strip() == expected:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


def exercise(case, app, timeout):
    # Launch a real app, as Sparkle's installer/relauncher expects; all upstream requests
    # are handled by the fixture URLProtocol and unknown URLs fail without networking.
    run(["open", "-g", "-n", app])
    deadline = time.monotonic() + timeout
    previous = None
    try:
        while time.monotonic() < deadline:
            if (case / "result.json").exists():
                return json.loads((case / "result.json").read_text())
            lines = (case / "events.jsonl").read_text().splitlines()
            current = json.loads(lines[-1]).get("event") if lines else "launching"
            if current != previous:
                print(f"{case.name}: {current}", flush=True)
                previous = current
            time.sleep(0.25)
        raise TimeoutError(f"Fixture timed out: {case.name}")
    finally:
        stop_fixture(case)


def test_case(name, work, executable, framework, public_key, timeout):
    case = work / name
    case.mkdir()
    (case / "events.jsonl").touch()
    identifier = f"com.github.codex-runway.proxy-fixture.{uuid.uuid4().hex}"
    app = make_app(case, executable, framework, public_key, "1", identifier)
    payload = make_app(case, executable, framework, public_key, "2", identifier)
    archive = case / "UpdateProxyFixture.zip"
    run(["ditto", "-c", "-k", "--keepParent", payload, archive])
    signature = create_signed_feed(case, work / "fixture.key", name == "bad-archive")
    feed = case / "appcast.xml"
    if name == "bad-feed":
        feed.write_bytes(feed.read_bytes().replace(b"<title>Version 2</title>", b"<title>Version X</title>"))
    feed_valid = verify_signature(feed, work / "fixture.key")
    archive_valid = verify_signature(archive, work / "fixture.key", signature)
    if feed_valid != (name != "bad-feed") or archive_valid != (name != "bad-archive"):
        raise AssertionError("Fixture signature precondition failed")
    before = hashlib.sha256(feed.read_bytes()).hexdigest()
    started = time.monotonic()
    result = exercise(case, app, timeout)
    installed = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
    events = [json.loads(line) for line in (case / "events.jsonl").read_text().splitlines()]
    names = [event["event"] for event in events]
    passed = installed == ("2" if name == "valid" else "1")
    passed &= result.get("outcome") == ("relaunched" if name == "valid" else "error")
    passed &= before == hashlib.sha256(feed.read_bytes()).hexdigest()
    if name == "valid":
        passed &= all(event in names for event in ["archive-routed", "extracting", "ready-to-install", "installing"])
    else:
        passed &= result.get("domain") == "SUSparkleErrorDomain"
        passed &= result.get("event") == "update-error"
        if name == "bad-feed":
            passed &= result.get("code") == "1000" and "archive-routed" not in names
        else:
            # Sparkle's installer wraps SUValidationError inside SUInstallationError.
            chain = [value for key, value in result.items() if key.startswith("underlying-")]
            signature_error = result.get("code") in ["3001", "3002"] or (
                result.get("code") == "4005" and "SUSparkleErrorDomain:3002" in chain)
            passed &= signature_error and "archive-routed" in names
        passed &= "ready-to-install" not in names
    report = {
        "case": name, "passed": bool(passed), "signedFeedValid": feed_valid, "signedArchiveValid": archive_valid,
        "installedVersion": installed, "result": result, "events": names, "directory": str(case),
        "durationSeconds": round(time.monotonic() - started, 2),
    }
    (case / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT / f".build/{os.uname().machine}-apple-macosx/debug")
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="codex-runway-update-fixture-", dir="/tmp"))
    print(f"Fixture artifacts: {work}", flush=True)
    try:
        executable = compile_fixture(args.build_dir, work)
        public_key = create_keys(work)
        reports = [test_case(name, work, executable, args.build_dir / "Sparkle.framework", public_key, args.timeout)
                   for name in ["valid", "bad-feed", "bad-archive"]]
        (work / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
        return 0 if all(report["passed"] for report in reports) else 1
    finally:
        (work / "fixture.key").unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(error.stderr, end="", flush=True)
        raise SystemExit(error.returncode)
