#!/usr/bin/env python3
"""Bundle license texts for modules present in the built Go executable."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


NOTICE_NAME = re.compile(r"^(?:licen[cs]e|copying|copyright|notice|patents|authors)(?:$|[._-])", re.I)
LICENSE_NAME = re.compile(r"^(?:licen[cs]e|copying)(?:$|[._-])", re.I)


def command(arguments, cwd, environment):
    """Read build metadata without changing module files or fetching dependencies."""
    result = subprocess.run(arguments, cwd=cwd, env=environment, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"{' '.join(arguments[:2])} failed: {result.stderr.strip()}")
    return result.stdout


def build_info(binary, module_root):
    """Use the executable, rather than all go.mod requirements, as the inventory."""
    report = command(["go", "version", "-m", str(binary)], module_root, os.environ)
    lines = report.splitlines()
    if not lines or ": " not in lines[0]:
        raise RuntimeError("The core executable has no readable Go build information")
    toolchain = lines[0].rsplit(": ", 1)[1].split()[0]
    if not re.fullmatch(r"go[0-9]+\.[0-9]+(?:\.[0-9]+)?", toolchain):
        raise RuntimeError("A released Go toolchain is required to collect its license")
    modules = {}
    settings = {}
    target = None
    current = None
    main_module = None
    for line in lines[1:]:
        fields = line.strip().split()
        if not fields:
            continue
        if fields[0] == "path":
            target = fields[1]
        elif fields[0] in ("mod", "dep"):
            current = {"path": fields[1], "version": fields[2],
                       "sum": fields[3] if len(fields) > 3 else "", "replacement": None}
            modules[current["path"]] = current
            if fields[0] == "mod":
                main_module = current["path"]
        elif fields[0] == "=>":
            if current is None or len(fields) < 3 or not fields[2].startswith("v"):
                raise RuntimeError("Versioned replacement metadata is required for dependency notices")
            current["replacement"] = {"path": fields[1], "version": fields[2],
                                      "sum": fields[3] if len(fields) > 3 else ""}
        elif fields[0] == "build":
            key, separator, value = line.strip()[len("build"):].strip().partition("=")
            if separator:
                settings[key] = value
    if not target or not main_module or main_module not in modules:
        raise RuntimeError("The core executable is missing its main module or package metadata")
    return toolchain, target, main_module, modules, settings


def json_objects(text):
    decoder = json.JSONDecoder()
    offset = 0
    while offset < len(text):
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset == len(text):
            break
        value, offset = decoder.raw_decode(text, offset)
        yield value


def notice_files(directory):
    return {item for item in directory.iterdir()
            if item.is_file() and NOTICE_NAME.match(item.name)}


def ancestor_notices(directory, root):
    """Include package-specific licenses in addition to the module-wide notices."""
    directory = directory.resolve()
    root = root.resolve()
    if directory != root and root not in directory.parents:
        raise RuntimeError("A linked package is outside its declared source module")
    notices = set()
    while True:
        notices.update(notice_files(directory))
        if directory == root:
            return notices
        directory = directory.parent


def module_sources(packages, modules, main_module, module_root, goroot):
    sources = {name: {"root": None, "files": set()} for name in modules}
    go_notices = notice_files(goroot)
    for package in packages:
        directory = Path(package["Dir"])
        if package.get("Standard"):
            go_notices.update(ancestor_notices(directory, goroot))
            continue
        module = package.get("Module")
        if not module or module["Path"] not in modules:
            continue
        record = modules[module["Path"]]
        replacement = module.get("Replace")
        expected = record["replacement"] or record
        actual = replacement or module
        if actual["Path"] != expected["path"]:
            raise RuntimeError(f"Source replacement differs from the executable: {record['path']}")
        if module["Path"] != main_module and actual.get("Version") != expected["version"]:
            raise RuntimeError(f"Source version differs from the executable: {record['path']}")
        root = Path(actual["Dir"]).resolve()
        if module["Path"] == main_module and root != module_root:
            raise RuntimeError("The executable's main module does not match --module-root")
        source = sources[module["Path"]]
        if source["root"] is not None and source["root"] != root:
            raise RuntimeError(f"Multiple source directories found for {record['path']}")
        source["root"] = root
        source["files"].update(ancestor_notices(directory, root))
    return sources, go_notices


def append_files(parts, label, root, files):
    if not any(LICENSE_NAME.match(path.name) for path in files):
        raise RuntimeError(f"Required LICENSE/LICENCE/COPYING file missing for {label}")
    for path in sorted(files, key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        try:
            content = path.read_bytes().decode("utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise RuntimeError(f"Cannot read notice text: {label}/{relative}") from error
        if not content.strip():
            raise RuntimeError(f"Empty notice text: {label}/{relative}")
        parts.extend([f"\nSource file: {label}/{relative}\n", "-" * 72 + "\n", content])
        if not content.endswith("\n"):
            parts.append("\n")


def go_distribution_root(goroot):
    """Homebrew installs Go's LICENSE beside libexec rather than inside GOROOT."""
    if (goroot / "LICENSE").is_file():
        return goroot
    if goroot.name == "libexec" and (goroot.parent / "LICENSE").is_file():
        return goroot.parent
    raise RuntimeError("The built Go toolchain's own LICENSE file is missing")


def collect(binary, module_root, output):
    toolchain, target, main_module, modules, settings = build_info(binary, module_root)
    environment = dict(os.environ, GOTOOLCHAIN=toolchain, GOPROXY="off", GOSUMDB="off")
    for key in ("GOOS", "GOARCH", "CGO_ENABLED", "GOARM64", "GOAMD64"):
        if key in settings:
            environment[key] = settings[key]
    arguments = ["go", "list", "-mod=readonly", "-deps", "-json=Dir,Module,Standard"]
    if settings.get("-tags"):
        arguments.extend(["-tags", settings["-tags"]])
    arguments.append(target)
    packages = list(json_objects(command(arguments, module_root, environment)))
    goroot = Path(command(["go", "env", "GOROOT"], module_root, environment).strip()).resolve()
    sources, go_notices = module_sources(packages, modules, main_module, module_root, goroot)
    distribution_root = go_distribution_root(goroot)
    go_notices.update(notice_files(distribution_root))
    parts = ["miniEasyConnect — Third-party notices\n",
             "Generated from the Go core executable's build information.\n",
             "License texts and copyright notices are reproduced without modification.\n",
             "Additional icon notices are supplied separately as Tabler-LICENSE.\n"]
    parts.extend(["\n" + "=" * 72 + "\n", f"Go toolchain and standard library: {toolchain}\n",
                  "Source: https://go.dev/\n"])
    append_files(parts, toolchain, distribution_root, go_notices)
    for name in sorted(modules):
        record = modules[name]
        source = sources[name]
        if source["root"] is None:
            raise RuntimeError(f"Linked module source was not located: {name}")
        actual = record["replacement"] or record
        parts.extend(["\n" + "=" * 72 + "\n", f"Module: {name}\n", f"Version: {record['version']}\n"])
        if record["replacement"]:
            parts.append(f"Replacement: {actual['path']} {actual['version']}\n")
        if actual["sum"]:
            parts.append(f"Module checksum: {actual['sum']}\n")
        parts.append(f"Source: https://{actual['path']}\n")
        if name == main_module:
            parts.append("Locally adapted source: Core/upstream\n")
        append_files(parts, f"{actual['path']}@{actual['version']}", source["root"], source["files"])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("".join(parts), encoding="utf-8")
    print(f"Collected Go notices: {len(modules)} modules plus {toolchain}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--module-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        collect(args.binary.resolve(), args.module_root.resolve(), args.output)
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(f"Third-party notice collection failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
