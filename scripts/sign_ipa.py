#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sign an unsigned ClawTalk ipa with a third-party P12 + two provisioning
profiles (main app + keyboard extension). Runs on macOS (codesign + security).

Usage:
  python3 sign_ipa.py \
    --ipa unsigned.zip --p12 sign.p12 --password 1 \
    --main-profile main.mobileprovision --ext-profile ext.mobileprovision \
    --out signed.ipa
"""
import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


def extract_entitlements(profile_path):
    """Parse the Entitlements dict embedded in a .mobileprovision file."""
    raw = open(profile_path, "rb").read()
    m = re.search(rb"<\?xml.*?</plist>", raw, re.S)
    if not m:
        raise RuntimeError("no plist found in %s" % profile_path)
    pl = plistlib.loads(m.group(0))
    return pl.get("Entitlements", {}) or {}


def find_distribution_identity():
    out = subprocess.check_output(
        ["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    for line in out.splitlines():
        if ("iPhone Distribution" in line) or ("Apple Distribution" in line):
            parts = line.split('"')
            if len(parts) >= 2:
                return parts[1]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True, help="path to unsigned ipa or artifact zip")
    ap.add_argument("--p12", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--main-profile", required=True)
    ap.add_argument("--ext-profile", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    # --- import p12 into an isolated keychain ---
    subprocess.run(["security", "create-keychain", "-p", "ci", "ci.keychain"],
                   capture_output=True, check=False)
    subprocess.run(["security", "default-keychain", "-s", "ci.keychain"], check=True,
                   capture_output=True)
    subprocess.run(["security", "unlock-keychain", "-p", "ci", "ci.keychain"], check=True,
                   capture_output=True)
    subprocess.run(["security", "import", args.p12, "-k", "ci.keychain",
                    "-P", args.password, "-T", "/usr/bin/codesign"], check=True,
                   capture_output=True)
    subprocess.run(["security", "set-key-partition-list", "-S",
                    "apple-tool:,apple:,codesign:", "-s", "-k", "ci", "ci.keychain"],
                   check=True, capture_output=True)

    identity = find_distribution_identity()
    if not identity:
        print("ERROR: no iPhone Distribution identity found in keychain")
        sys.exit(1)
    print("identity:", identity)

    with tempfile.TemporaryDirectory() as tmp:
        # --- locate ipa inside the artifact zip (or use it directly) ---
        if args.ipa.lower().endswith(".zip"):
            art = zipfile.ZipFile(args.ipa)
            ipa_name = next(n for n in art.namelist() if n.endswith(".ipa"))
            ipa_path = os.path.join(tmp, "input.ipa")
            with open(ipa_path, "wb") as f:
                f.write(art.read(ipa_name))
        else:
            ipa_path = args.ipa

        # --- extract ipa ---
        work = os.path.join(tmp, "work")
        with zipfile.ZipFile(ipa_path) as z:
            z.extractall(work)

        payload = os.path.join(work, "Payload")
        app_name = next(d for d in os.listdir(payload) if d.endswith(".app"))
        app_path = os.path.join(payload, app_name)
        plug_ins = os.path.join(app_path, "PlugIns")
        exts = [d for d in os.listdir(plug_ins) if d.endswith(".appex")]
        print("app:", app_name, "| extensions:", exts)

        # --- entitlements ---
        main_ent = extract_entitlements(args.main_profile)
        ext_ent = extract_entitlements(args.ext_profile)
        main_ent_path = os.path.join(tmp, "main_ent.plist")
        ext_ent_path = os.path.join(tmp, "ext_ent.plist")
        with open(main_ent_path, "wb") as f:
            plistlib.dump(main_ent, f)
        with open(ext_ent_path, "wb") as f:
            plistlib.dump(ext_ent, f)

        # --- embed profiles + sign extensions first, then the app ---
        shutil.copy(args.main_profile, os.path.join(app_path, "embedded.mobileprovision"))
        for ext in exts:
            ext_path = os.path.join(plug_ins, ext)
            shutil.copy(args.ext_profile, os.path.join(ext_path, "embedded.mobileprovision"))
            subprocess.run(["codesign", "--force", "--sign", identity,
                            "--entitlements", ext_ent_path,
                            "--timestamp=none", ext_path], check=True)
            print("signed extension:", ext)
        subprocess.run(["codesign", "--force", "--sign", identity,
                        "--entitlements", main_ent_path,
                        "--timestamp=none", app_path], check=True)
        print("signed app:", app_name)

        # --- verify ---
        subprocess.run(["codesign", "--verify", "--deep", "--strict", app_path], check=True)
        print("codesign verify OK")

        # --- repack ipa ---
        out_ipa = os.path.join(tmp, "signed.ipa")
        with zipfile.ZipFile(out_ipa, "w", zipfile.ZIP_DEFLATED) as z:
            for root, dirs, files in os.walk(work):
                for f in files:
                    fp = os.path.join(root, f)
                    z.write(fp, os.path.relpath(fp, work))
        shutil.copy(out_ipa, args.out)
        print("signed ipa ->", args.out)


if __name__ == "__main__":
    main()
