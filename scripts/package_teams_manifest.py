"""
Package a Microsoft Teams app manifest with icon assets into a ZIP for upload
to Teams Admin Center.

Usage:
    python scripts/package_teams_manifest.py \
        --app-id <MICROSOFT_APP_ID> \
        --domain <DOMAIN> \
        [--output <path/to/output.zip>]
"""

import argparse
import pathlib
import zipfile

MANIFEST_DIR = pathlib.Path(__file__).parent.parent / "frontend" / "teams-app" / "manifest"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Substitute placeholders in the Teams manifest and bundle it with icons into a ZIP."
    )
    parser.add_argument(
        "--app-id",
        required=True,
        metavar="MICROSOFT_APP_ID",
        help="The Microsoft App ID (GUID) to substitute for ${MICROSOFT_APP_ID}.",
    )
    parser.add_argument(
        "--domain",
        required=True,
        metavar="DOMAIN",
        help="The domain to substitute for ${DOMAIN}.",
    )
    parser.add_argument(
        "--output",
        metavar="OUTPUT_ZIP",
        help="Path for the output ZIP file (default: coreiq-teams-<domain>.zip in the current directory).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    app_id: str = args.app_id
    domain: str = args.domain

    output_path = pathlib.Path(
        args.output if args.output else f"coreiq-teams-{domain}.zip"
    )

    manifest_template = MANIFEST_DIR / "manifest.json"
    color_icon = MANIFEST_DIR / "color.png"
    outline_icon = MANIFEST_DIR / "outline.png"

    for path in (manifest_template, color_icon, outline_icon):
        if not path.exists():
            raise FileNotFoundError(f"Required file not found: {path}")

    manifest_content = manifest_template.read_text(encoding="utf-8")
    manifest_content = manifest_content.replace("${MICROSOFT_APP_ID}", app_id)
    manifest_content = manifest_content.replace("${DOMAIN}", domain)

    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("manifest.json", manifest_content)
        zf.write(color_icon, "color.png")
        zf.write(outline_icon, "outline.png")

    print(f"Created: {output_path}")


if __name__ == "__main__":
    main()
