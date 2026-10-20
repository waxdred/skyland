"""Skyland website: one page served by Flask, plus a cached GitHub stats endpoint.

Run locally:  pip install -r requirements.txt && python app.py
Animations, navigation and the Liquid Glass effects all live in the browser
(static/js, static/css); Python only serves pages and public repository data.
"""

import json
import os
import threading
import time
import urllib.error
import urllib.request

from flask import Flask, Response, jsonify, render_template, request, url_for

app = Flask(__name__)

GITHUB_OWNER = "waxdred"
SITE_URL = os.environ.get("SKYLAND_SITE_URL", "").rstrip("/")

# Single source for every project link on the page.
PROJECTS = {
    "skyland": {
        "name": "Skyland",
        "repo": "skyland",
        "tagline": "The window management experience.",
        "url": f"https://github.com/{GITHUB_OWNER}/skyland",
    },
    "skylandbar": {
        "name": "SkylandBar",
        "repo": "skylandBar",
        "tagline": "A refined system bar.",
        "url": f"https://github.com/{GITHUB_OWNER}/skylandBar",
    },
    "cyberdeck": {
        "name": "Skyland Cyberdeck",
        "repo": "skyland-cyberdeck",
        "tagline": "A personal interface for applications and messages.",
        "url": f"https://github.com/{GITHUB_OWNER}/skyland-cyberdeck",
    },
}

LINKS = {
    "repo": PROJECTS["skyland"]["url"],
    "docs": f"{PROJECTS['skyland']['url']}#readme",
    "install": f"{PROJECTS['skyland']['url']}#install",
    "config": f"{PROJECTS['skyland']['url']}#configuration",
    "keys": f"{PROJECTS['skyland']['url']}#keybindings-hypr-profile",
    "how": f"{PROJECTS['skyland']['url']}#how-it-works",
    "changelog": f"{PROJECTS['skyland']['url']}/blob/main/CHANGELOG.md",
    "releases": f"{PROJECTS['skyland']['url']}/releases",
    "payload": f"{PROJECTS['skyland']['url']}/blob/main/osax/payload.m",
    "animation": f"{PROJECTS['skyland']['url']}/tree/main/Sources/SkylandAnimation",
    "animation_lab": f"{PROJECTS['skyland']['url']}/blob/main/tools/animation-lab/index.html",
    "themes": f"{PROJECTS['skyland']['url']}/tree/main/profiles/hypr/.config/skyland/themes",
    "aerospace": "https://github.com/nikitabobko/AeroSpace",
    "dotfiles": "https://github.com/43PR/dotfiles",
    "hyprland": "https://hyprland.org",
}

# GitHub stats are fetched at most once per CACHE_TTL for all visitors, never per visit.
CACHE_TTL = 60 * 60
_cache = {"at": 0.0, "data": None}
_cache_lock = threading.Lock()


def _github_get(path):
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "skyland-website"},
    )
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=4) as resp:
        return json.load(resp)


def _fetch_stats():
    repos = {}
    for key, project in PROJECTS.items():
        try:
            data = _github_get(f"/repos/{GITHUB_OWNER}/{project['repo']}")
            repos[key] = {"stars": data.get("stargazers_count"), "url": data.get("html_url")}
        except (urllib.error.URLError, TimeoutError, ValueError):
            continue
    release = None
    try:
        data = _github_get(f"/repos/{GITHUB_OWNER}/skyland/releases/latest")
        release = {"tag": data.get("tag_name"), "url": data.get("html_url")}
    except (urllib.error.URLError, TimeoutError, ValueError):
        pass
    return {"repos": repos, "release": release}


def github_stats():
    with _cache_lock:
        fresh = _cache["data"] is not None and time.time() - _cache["at"] < CACHE_TTL
        if not fresh:
            data = _fetch_stats()
            # Keep the last good answer when GitHub is unreachable or rate limited.
            if data["repos"] or _cache["data"] is None:
                _cache["data"] = data
            _cache["at"] = time.time()
        return _cache["data"]


def absolute(endpoint, **values):
    path = url_for(endpoint, **values)
    return f"{SITE_URL}{path}" if SITE_URL else request.url_root.rstrip("/") + path


@app.context_processor
def inject_globals():
    return {"projects": PROJECTS, "links": LINKS, "absolute": absolute}


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/github")
def api_github():
    resp = jsonify(github_stats())
    resp.cache_control.public = True
    resp.cache_control.max_age = 600
    return resp


@app.route("/robots.txt")
def robots():
    body = f"User-agent: *\nAllow: /\nSitemap: {absolute('sitemap')}\n"
    return Response(body, mimetype="text/plain")


@app.route("/sitemap.xml")
def sitemap():
    body = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f"  <url><loc>{absolute('index')}</loc></url>\n"
        "</urlset>\n"
    )
    return Response(body, mimetype="application/xml")


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", 5000)), debug=bool(os.environ.get("DEBUG")))
