"""Export the site as static files, for GitHub Pages (waxdred/skyland-site).

    python export.py <out_dir> [--base /skyland-site] [--origin https://waxdred.github.io]

The page is rendered by the Flask app itself (same templates and links), under `--base` so
asset URLs work in a project site's sub-path. /api/github is written once, as fetched now:
the page reads it with a relative URL, so the numbers are those of the export.
"""

import argparse
import os
import pathlib
import shutil

parser = argparse.ArgumentParser()
parser.add_argument("out")
parser.add_argument("--base", default="/skyland-site")
parser.add_argument("--origin", default="https://waxdred.github.io")
args = parser.parse_args()

os.environ["SKYLAND_SITE_URL"] = args.origin  # read by app.py at import: canonical, Open Graph, sitemap
import app as site  # noqa: E402

out = pathlib.Path(args.out).resolve()
here = pathlib.Path(__file__).resolve().parent
client = site.app.test_client()
pages = {"index.html": "/", "api/github": "/api/github", "robots.txt": "/robots.txt", "sitemap.xml": "/sitemap.xml"}
for name, route in pages.items():
    resp = client.get(route, environ_overrides={"SCRIPT_NAME": args.base})
    if resp.status_code != 200:
        raise SystemExit(f"{route}: HTTP {resp.status_code}")
    path = out / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(resp.data)
    print("wrote", path.relative_to(out))
shutil.rmtree(out / "static", ignore_errors=True)
shutil.copytree(here / "static", out / "static")
(out / ".nojekyll").touch()  # served as is: no Jekyll
print("copied static/")
