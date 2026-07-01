#!/usr/bin/env python3
"""Bump Catapult versions and optionally publish a tagged release.

Examples:
  python3 scripts/publish.py --bump patch
  python3 scripts/publish.py 1.2.0 --build 45 --notes "Polish and fixes."
  python3 scripts/publish.py 1.2.0 --build 45 --manifest-only
  python3 scripts/publish.py --bump minor --commit --tag --push-tag

By default this updates the Xcode app target and both static update manifests.
Publishing flags are explicit so a local version bump never talks to GitHub by
surprise.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
from pathlib import Path
from xml.sax.saxutils import escape


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Catapult.xcodeproj" / "project.pbxproj"
BASE_URL = "https://h3nry.xyz/catapult"
SITE_ORIGIN = "https://h3nry.xyz"
MANIFESTS = [
    ROOT / "site" / "catapult" / "update.json",
    ROOT / "site" / "catapult" / "updates" / "update.json",
    ROOT / "site" / "update.json",
]
APPCASTS = [
    ROOT / "site" / "catapult" / "appcast.xml",
    ROOT / "site" / "catapult" / "updates" / "appcast.xml",
]
SITE_ROUTE_FILES = [
    ROOT / "site" / "index.html",
    ROOT / "site" / "robots.txt",
    ROOT / "site" / "sitemap.xml",
    ROOT / "site" / "catapult" / "robots.txt",
    ROOT / "site" / "catapult" / "sitemap.xml",
]
APP_BUNDLE_ID = "h3nry.Catapult"


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def run(cmd: list[str], *, dry_run: bool) -> None:
    print("+", " ".join(cmd))
    if not dry_run:
        subprocess.run(cmd, cwd=ROOT, check=True)


def semver_parts(version: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    if not match:
        fail(f"expected semantic version like 1.2.3, got {version!r}")
    return tuple(int(part) for part in match.groups())


def bump_version(current: str, bump: str) -> str:
    major, minor, patch = semver_parts(current)
    if bump == "major":
        return f"{major + 1}.0.0"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    if bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    fail(f"unknown bump type {bump!r}")


def read_app_build_settings() -> tuple[str, str]:
    text = PROJECT.read_text()
    for block in re.findall(r"buildSettings = \{.*?\n\t\t\t\};", text, flags=re.S):
        if f"PRODUCT_BUNDLE_IDENTIFIER = {APP_BUNDLE_ID};" not in block:
            continue
        version_match = re.search(r"MARKETING_VERSION = ([^;]+);", block)
        build_match = re.search(r"CURRENT_PROJECT_VERSION = ([^;]+);", block)
        if not version_match or not build_match:
            fail("could not read app MARKETING_VERSION/CURRENT_PROJECT_VERSION")
        return clean_pbx_value(version_match.group(1)), clean_pbx_value(build_match.group(1))
    fail(f"could not find app target build settings for {APP_BUNDLE_ID}")


def clean_pbx_value(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1].replace('\\"', '"')
    return value


def quote_pbx_build(value: str) -> str:
    if re.fullmatch(r"\d+", value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def update_project(version: str, build: str, *, dry_run: bool) -> int:
    text = PROJECT.read_text()
    changed = 0

    def replace_block(match: re.Match[str]) -> str:
        nonlocal changed
        block = match.group(0)
        if f"PRODUCT_BUNDLE_IDENTIFIER = {APP_BUNDLE_ID};" not in block:
            return block
        updated = re.sub(r"MARKETING_VERSION = [^;]+;",
                         f"MARKETING_VERSION = {version};", block)
        updated = re.sub(r"CURRENT_PROJECT_VERSION = [^;]+;",
                         f"CURRENT_PROJECT_VERSION = {quote_pbx_build(build)};", updated)
        if updated != block:
            changed += 1
        return updated

    new_text = re.sub(r"buildSettings = \{.*?\n\t\t\t\};",
                      replace_block, text, flags=re.S)
    if changed == 0:
        fail("no app target version settings changed")
    if not dry_run:
        PROJECT.write_text(new_text)
    return changed


def read_manifest_build() -> str | None:
    for path in MANIFESTS:
        if not path.exists():
            continue
        try:
            value = json.loads(path.read_text()).get("build")
        except json.JSONDecodeError:
            continue
        if value is not None:
            return str(value)
    return None


def next_build(current_project_build: str, explicit: str | None) -> str:
    if explicit is not None:
        if not re.fullmatch(r"\d+", explicit):
            fail("--build must be numeric")
        return explicit
    current = read_manifest_build() or current_project_build
    match = re.search(r"\d+", current)
    if not match:
        fail(f"current build {current!r} is not numeric; pass --build")
    return str(int(match.group(0)) + 1)


def update_manifest(path: Path, version: str, build: str, notes: str | None,
                    published_at: str, *, dry_run: bool) -> None:
    data: dict[str, object] = {}
    if path.exists():
        data = json.loads(path.read_text())
    data.update({
        "version": version,
        "build": build,
        "minimumSystemVersion": str(data.get("minimumSystemVersion", "13.0")),
        "publishedAt": published_at,
        "name": f"Catapult {version}",
        "upsweetURL": f"{BASE_URL}/Catapult.upsweet",
        "dmgURL": f"{BASE_URL}/Catapult.dmg",
        "releaseNotesURL": f"{BASE_URL}/",
    })
    if notes is not None:
        data["notes"] = notes
    elif "notes" not in data:
        data["notes"] = "Latest Catapult release for macOS."
    artifact_directory = ROOT / "site" / "catapult"
    attach_artifact_metadata(data, artifact_directory)

    rendered = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if dry_run:
        print(f"would write {path.relative_to(ROOT)}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered)


def update_appcast(path: Path, version: str, build: str, notes: str | None,
                   published_at: str, *, dry_run: bool) -> None:
    release_notes = notes or "Latest Catapult release for macOS."
    package_path = path.parent / "Catapult.upsweet"
    length = package_path.stat().st_size if package_path.exists() else 0
    minimum = "13.0"
    manifest_path = path.with_name("update.json")
    if manifest_path.exists():
        try:
            minimum = str(json.loads(manifest_path.read_text()).get("minimumSystemVersion", minimum))
        except json.JSONDecodeError:
            pass

    rendered = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Catapult Updates</title>
    <link>{BASE_URL}/</link>
    <description>Static Catapult update feed for macOS.</description>
    <item>
      <title>Catapult {escape(version)}</title>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum)}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{BASE_URL}/</sparkle:releaseNotesLink>
      <description>{escape(release_notes)}</description>
      <pubDate>{rfc2822_date(published_at)}</pubDate>
      <enclosure
        url="{BASE_URL}/Catapult.upsweet"
        sparkle:version="{escape(build)}"
        sparkle:shortVersionString="{escape(version)}"
        sparkle:minimumSystemVersion="{escape(minimum)}"
        length="{length}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
"""
    if dry_run:
        print(f"would write {path.relative_to(ROOT)}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered)


def update_site_routes(published_at: str, *, dry_run: bool) -> None:
    lastmod = published_at[:10]
    root_redirect = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="0; url={BASE_URL}/">
  <link rel="canonical" href="{BASE_URL}/">
  <meta name="robots" content="noindex, follow">
  <title>Catapult updates</title>
  <style>
    body {{
      min-height: 100vh;
      margin: 0;
      display: grid;
      place-items: center;
      color: #0b0b10;
      font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      background: linear-gradient(180deg, #f8fdff, #dff6ff);
    }}
    main {{
      width: min(560px, calc(100% - 32px));
      padding: 32px;
      border: 1px solid rgba(0, 116, 224, .14);
      border-radius: 8px;
      background: rgba(255, 255, 255, .82);
      box-shadow: 0 24px 70px rgba(0, 76, 255, .16);
      text-align: center;
    }}
    h1 {{ margin: 0; font-size: clamp(36px, 8vw, 64px); line-height: 1; }}
    p {{ color: rgba(11, 11, 16, .66); font-weight: 700; line-height: 1.45; }}
    a {{
      display: inline-flex;
      margin-top: 14px;
      padding: 12px 16px;
      border-radius: 8px;
      color: white;
      background: #0074e0;
      font-weight: 850;
      text-decoration: none;
    }}
  </style>
</head>
<body>
  <main>
    <h1>catapult moved.</h1>
    <p>The update channel lives at <strong>{BASE_URL}/</strong>.</p>
    <a href="{BASE_URL}/">Open updates</a>
  </main>
</body>
</html>
"""

    robots = f"""User-agent: *
Allow: /catapult/
Sitemap: {SITE_ORIGIN}/sitemap.xml
Sitemap: {BASE_URL}/sitemap.xml
"""

    sitemap_entries = [
        (f"{BASE_URL}/", "daily", "1.0"),
        (f"{BASE_URL}/update.json", "hourly", "0.8"),
        (f"{BASE_URL}/appcast.xml", "hourly", "0.6"),
        (f"{BASE_URL}/updates/", "weekly", "0.5"),
    ]
    sitemap = render_sitemap(sitemap_entries, lastmod)

    writes = {
        ROOT / "site" / "index.html": root_redirect,
        ROOT / "site" / "robots.txt": robots,
        ROOT / "site" / "sitemap.xml": sitemap,
        ROOT / "site" / "catapult" / "robots.txt": robots,
        ROOT / "site" / "catapult" / "sitemap.xml": sitemap,
    }

    for path, contents in writes.items():
        if dry_run:
            print(f"would write {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)


def render_sitemap(entries: list[tuple[str, str, str]], lastmod: str) -> str:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ]
    for loc, changefreq, priority in entries:
        lines.extend([
            "  <url>",
            f"    <loc>{escape(loc)}</loc>",
            f"    <lastmod>{escape(lastmod)}</lastmod>",
            f"    <changefreq>{escape(changefreq)}</changefreq>",
            f"    <priority>{escape(priority)}</priority>",
            "  </url>",
        ])
    lines.append("</urlset>")
    return "\n".join(lines) + "\n"


def rfc2822_date(iso_timestamp: str) -> str:
    try:
        parsed = dt.datetime.fromisoformat(iso_timestamp.replace("Z", "+00:00"))
    except ValueError:
        parsed = dt.datetime.now(dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")


def attach_artifact_metadata(data: dict[str, object], directory: Path) -> None:
    artifacts = [
        ("Catapult.upsweet", "upsweetSHA256", "upsweetSizeBytes"),
        ("Catapult.dmg", "dmgSHA256", "dmgSizeBytes"),
    ]
    for filename, hash_key, size_key in artifacts:
        artifact = directory / filename
        if artifact.exists():
            data[hash_key] = sha256(artifact)
            data[size_key] = artifact.stat().st_size
        else:
            data.pop(hash_key, None)
            data.pop(size_key, None)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def has_changes() -> bool:
    result = subprocess.run(["git", "status", "--short"], cwd=ROOT,
                            check=True, text=True, capture_output=True)
    return bool(result.stdout.strip())


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?", help="exact version, e.g. 1.2.3")
    parser.add_argument("--bump", choices=["major", "minor", "patch"],
                        help="bump from the current app version")
    parser.add_argument("--build", help="exact numeric build number")
    parser.add_argument("--notes", help="release notes for update.json")
    parser.add_argument("--published-at",
                        help="UTC timestamp for update.json (default: now)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print planned changes without writing files or running git")
    parser.add_argument("--manifest-only", action="store_true",
                        help="only update static update manifests, not Xcode build settings")
    parser.add_argument("--commit", action="store_true",
                        help="commit the version/manifest changes")
    parser.add_argument("--tag", action="store_true",
                        help="create an annotated vVERSION git tag")
    parser.add_argument("--push-tag", action="store_true",
                        help="push vVERSION to origin")
    parser.add_argument("--dispatch", action="store_true",
                        help="run the release workflow with gh workflow_dispatch")
    parser.add_argument("--allow-dirty", action="store_true",
                        help="allow commit/tag/publish actions with unrelated dirty files")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    current_version, current_build = read_app_build_settings()
    if args.version and args.bump:
        fail("pass either an exact version or --bump, not both")
    if args.version:
        version = args.version
        semver_parts(version)
    elif args.bump:
        version = bump_version(current_version, args.bump)
    else:
        fail("pass a version or --bump major|minor|patch")

    build = next_build(current_build, args.build)
    published_at = args.published_at or dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    print(f"Catapult {current_version} ({current_build}) -> {version} ({build})")
    if args.manifest_only:
        print("leaving Xcode build settings unchanged")
    else:
        changed_blocks = update_project(version, build, dry_run=args.dry_run)
        print(f"updated {changed_blocks} app target build setting block(s)")
    for manifest in MANIFESTS:
        update_manifest(manifest, version, build, args.notes, published_at,
                        dry_run=args.dry_run)
    for appcast in APPCASTS:
        update_appcast(appcast, version, build, args.notes, published_at,
                       dry_run=args.dry_run)
    update_site_routes(published_at, dry_run=args.dry_run)

    tag = f"v{version}"
    publishing = args.commit or args.tag or args.push_tag or args.dispatch
    if publishing and has_changes() and not args.allow_dirty:
        print("working tree has changes; continuing only with explicit version files")

    if args.commit:
        paths = [str(path.relative_to(ROOT)) for path in MANIFESTS]
        paths.extend(str(path.relative_to(ROOT)) for path in APPCASTS)
        paths.extend(str(path.relative_to(ROOT)) for path in SITE_ROUTE_FILES)
        if not args.manifest_only:
            paths.insert(0, str(PROJECT.relative_to(ROOT)))
        run(["git", "add", *paths], dry_run=args.dry_run)
        run(["git", "commit", "-m", f"Bump Catapult to {version}"], dry_run=args.dry_run)
    if args.tag:
        run(["git", "tag", "-a", tag, "-m", f"Catapult {version}"], dry_run=args.dry_run)
    if args.push_tag:
        run(["git", "push", "origin", tag], dry_run=args.dry_run)
    if args.dispatch:
        run(["gh", "workflow", "run", "release.yml", "-f", f"tag={tag}"], dry_run=args.dry_run)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        raise SystemExit(exc.returncode)
