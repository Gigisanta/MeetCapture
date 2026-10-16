#!/usr/bin/env python3
"""Bundle a Mach-O executable's non-system libraries, including GGML plugins."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess


def output(*args):
    return subprocess.check_output(args, text=True)


def linked_paths(path):
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in output("otool", "-L", str(path)).splitlines()[1:]
            if line.startswith("\t")]


def rpaths(path):
    lines = output("otool", "-l", str(path)).splitlines()
    return [lines[i + 2].strip().split(" (offset", 1)[0].removeprefix("path ")
            for i, line in enumerate(lines) if line.strip() == "cmd LC_RPATH"]


def dylib_identity(path):
    lines = output("otool", "-D", str(path)).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def bundle(source, destination, frameworks, identity):
    source = source.resolve(strict=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    frameworks.mkdir(parents=True, exist_ok=True)
    copied = {source: destination}
    destinations = {destination: source}
    executable_dir = source.parent
    executable_rpaths = rpaths(source)
    licensed_packages = set()

    def copy_notices(original):
        for parent in original.parents:
            notices = [parent / name for name in
                       ("LICENSE", "LICENSE.txt", "LICENSE.TXT", "COPYING", "NOTICE", "AUTHORS")
                       if (parent / name).is_file()]
            if not notices:
                continue
            if parent not in licensed_packages:
                licensed_packages.add(parent)
                # Homebrew's package root is Cellar/<name>/<version>.
                package_name = parent.parent.name + "-" + parent.name
                notice_dir = destination.parent / "licenses" / package_name
                notice_dir.mkdir(parents=True, exist_ok=True)
                for notice in notices:
                    shutil.copy2(notice, notice_dir / notice.name)
            return

    def expand(value, loader):
        return Path(value.replace("@loader_path", str(loader.parent))
                    .replace("@executable_path", str(executable_dir)))

    def resolve(dependency, loader):
        if dependency.startswith("@rpath/"):
            tail = dependency[len("@rpath/"):]
            candidates = [expand(rp, loader) / tail for rp in rpaths(loader)]
            candidates += [expand(rp, source) / tail for rp in executable_rpaths]
        else:
            candidates = [expand(dependency, loader)]
        for candidate in candidates:
            if candidate.is_file():
                return candidate.resolve(strict=True)
        raise RuntimeError("Cannot resolve %s required by %s" % (dependency, loader))

    def copy_library(original, target):
        original = original.resolve(strict=True)
        if original in copied:
            return copied[original]
        if target in destinations and destinations[target] != original:
            raise RuntimeError("Conflicting libraries named %s" % target.name)
        copied[original] = target
        destinations[target] = original
        rewrite(original, target)
        return target

    def rewrite(original, target):
        copy_notices(original)
        shutil.copy2(original, target)
        target.chmod(target.stat().st_mode | 0o200)
        changes = []
        identity_path = dylib_identity(original)
        for dependency in linked_paths(original):
            if dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if dependency == identity_path:  # LC_ID_DYLIB, not a dependency
                # Keep the original identity: GGML may discover a Homebrew
                # plugin first. Its references must reuse our loaded library,
                # rather than loading a second copy with separate global state.
                continue
            resolved = resolve(dependency, original)
            bundled = copy_library(resolved, frameworks / Path(dependency).name)
            relative = os.path.relpath(bundled, target.parent)
            changes.extend(["-change", dependency, "@loader_path/" + relative])
        if changes:
            subprocess.run(["install_name_tool", *changes, str(target)], check=True)

        # Homebrew builds GGML backends as dlopen plugins, absent from otool -L.
        # GGML searches beside its executable when its original prefix is absent.
        if original.name.startswith("libggml."):
            for plugin in sorted((original.parent.parent / "libexec").glob("libggml-*.so")):
                copy_library(plugin, destination.parent / plugin.name)
        subprocess.run(["codesign", "--force", "--sign", identity, str(target)], check=True)

    rewrite(source, destination)
    print("Bundled executable and %d libraries/plugins" % (len(copied) - 1))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("frameworks", type=Path)
    parser.add_argument("--identity", default="-")
    args = parser.parse_args()
    bundle(args.source, args.destination, args.frameworks, args.identity)
