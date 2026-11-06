#!/usr/bin/env python3
"""Build an offline license document from the actual package payload."""
import argparse
import fnmatch
import importlib.metadata
import json
from pathlib import Path
import re


def canonical(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def is_notice(path):
    name = path.name.lower()
    return any(word in name for word in ("license", "licence", "copying", "copyright", "notice"))


def read_text(path):
    text = path.read_text(encoding="utf-8-sig")
    if "\x00" in text:
        raise ValueError(f"License is not a text file: {path.name}")
    return text.strip()


def generate(root, resources):
    root, resources = root.resolve(), resources.resolve()
    catalog = json.loads((root / "licenses/catalog.json").read_text())
    sections = []

    def add(title, body):
        sections.append(f"{'=' * 76}\n{title}\n{'=' * 76}\n\n{body.strip()}\n")

    add("SpeekCoding — License / 许可证与开源声明", """
This document contains the project license, model-weight licenses, and licenses
and notices for bundled open-source components, including transitive libraries.
Optional engines and externally installed integrations are identified below.
Models are downloaded separately; users' custom models retain their own terms.
Third-party components retain their original terms; the project MIT license
does not replace third-party GPL, LGPL, MPL, Apache, BSD or other licenses.

本文包含项目许可证、模型权重许可证及开源组件（含传递依赖）的许可全文和声明。
模型权重单独下载；可选组件因平台而异。用户自选模型以其发布者的许可证为准。
“确认”仅关闭此窗口，不代表订立额外协议或改变任何开源许可证。
"""
    )
    add("PROJECT LICENSE / 项目许可证 — SpeekCoding (MIT)", read_text(root / "LICENSE"))
    for item in catalog["external"]:
        add(f"{item['kind'].upper()} / {item['name']} — {item['license']}",
            f"Source: {item['source']}\n{item['scope']}\n\n" + read_text(root / "licenses" / item["file"]))

    node_license = resources / "licenses/Node.js-LICENSE"
    python_license = resources / "runtime/python/lib/python3.12/LICENSE.txt"
    if not node_license.is_file() or not python_license.is_file():
        raise ValueError("Both Node.js and CPython runtime license files are required")
    add("RUNTIME / Node.js (including embedded third-party notices)", read_text(node_license))
    add("RUNTIME / CPython (including historical and bundled notices)", read_text(python_license))

    node_modules = resources / "node_modules"
    packages = sorted(node_modules.rglob("package.json"))
    npm_count = 0
    for package in packages:
        metadata = json.loads(package.read_text())
        name = metadata.get("name")
        version = metadata.get("version")
        if not name or not version:
            continue
        notices = sorted(p for p in package.parent.iterdir() if p.is_file() and is_notice(p))
        if not notices:
            raise ValueError(f"No bundled license found for npm {name}=={version}")
        body = f"Component: npm/{name}=={version}\nLicense: {metadata.get('license', 'See text below')}\n"
        for path in notices:
            body += f"\n--- {path.relative_to(resources).as_posix()} ---\n{read_text(path)}\n"
        add(f"NPM COMPONENT / {name} {version}", body)
        npm_count += 1
    if not npm_count:
        raise ValueError("No npm components were found")

    site = resources / "runtime/python/lib/python3.12/site-packages"
    distributions = sorted(importlib.metadata.distributions(path=[str(site)]), key=lambda d: d.metadata["Name"].lower())
    if not distributions:
        raise ValueError("No Python components were found")
    for distribution in distributions:
        name, version = distribution.metadata["Name"], distribution.version
        notices = []
        for entry in distribution.files or []:
            path = Path(distribution.locate_file(entry))
            if is_notice(path) and path.is_file() and path.resolve().is_relative_to(resources):
                notices.append(path)
        notices = sorted(set(notices))
        fallback = catalog["wheel_fallbacks"].get(canonical(name))
        if not notices:
            if not fallback or fallback["version"] != version:
                raise ValueError(f"No license found for Python {name}=={version}; add a verified upstream license")
            notices = [root / "licenses" / fallback["file"]]
        expression = distribution.metadata.get("License-Expression") or distribution.metadata.get("License") or "See full text below"
        if len(expression) > 160:
            expression = "See full text below"
        body = f"Component: python/{canonical(name)}=={version}\nLicense: {expression}\n"
        if fallback:
            body += f"Upstream license source: {fallback['source']}\n"
        for path in notices:
            origin = path.relative_to(resources).as_posix() if path.is_relative_to(resources) else path.relative_to(root).as_posix()
            body += f"\n--- {origin} ---\n{read_text(path)}\n"
        add(f"PYTHON COMPONENT / {name} {version}", body)
    native_directory = site / "av/.dylibs"
    native_libraries = sorted(p.name for p in native_directory.glob("*.dylib"))
    covered = set()
    for item in json.loads((root / "licenses/native-catalog.json").read_text()):
        matches = [name for name in native_libraries if any(fnmatch.fnmatchcase(name, pattern) for pattern in item["patterns"])]
        if not matches:
            continue
        covered.update(matches)
        body = f"Source and build information: {item['source']}\nBundled by PyAV. Files: {', '.join(matches)}\n"
        for license_file, source in zip(item["files"], item["license_sources"]):
            body += f"\n--- Upstream license: {source} ---\n{read_text(root / 'licenses' / license_file)}\n"
        add(f"NATIVE COMPONENT / {item['name']} (PyAV binary dependencies)", body)
    if set(native_libraries) - covered:
        raise ValueError(f"Missing native library notices: {', '.join(sorted(set(native_libraries) - covered))}")
    add("DISTRIBUTION NOTES / 分发说明", read_text(root / "packaging/THIRD_PARTY_NOTICES.md"))
    return "\n".join(sections)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = generate(args.project_root, args.resources)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(result, encoding="utf-8")
    print(f"Wrote {len(result.encode('utf-8'))} bytes of license notices")


if __name__ == "__main__":
    main()
