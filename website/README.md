# Skyland website

The presentation site for Skyland, SkylandBar and skyland-cyberdeck: one page, Liquid Glass
surfaces and scroll-driven scenes, served by a small Flask app.

```sh
cd website
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
python app.py            # http://127.0.0.1:5000
```

| Variable | Use |
|---|---|
| `PORT` | port to listen on (default 5000) |
| `SKYLAND_SITE_URL` | public origin for canonical / Open Graph / sitemap URLs, e.g. `https://skyland.example` |
| `GITHUB_TOKEN` | optional, raises the GitHub API rate limit for the stars endpoint |
| `DEBUG` | any value turns on Flask's debug mode |

For production, run it behind a WSGI server, e.g. `gunicorn -w 2 app:app`.

## Layout

```
app.py                 routes: /, /api/github (cached 1 h), /robots.txt, /sitemap.xml; project links
templates/base.html    <head>, SEO / Open Graph, atmosphere layer, assets
templates/index.html   the sections, as semantic HTML (readable without JavaScript)
static/css/
  tokens.css           colors, type, radii, easing (Skyland's own bezier curves), site accents
  base.css             reset, typography, buttons
  glass.css            Liquid Glass levels (ambient, floating, focus, overlay), fallbacks, schematic windows
  layout.css           sections
  animations.css       entrance, reveals, demos; prefers-reduced-motion
  responsive.css       tablet (< 1200px) and mobile (< 768px)
static/js/
  navigation.js        mobile menu, nav glass after the hero, current section
  scroll-effects.js    IntersectionObserver reveals, layout demo steps, one rAF for scroll-linked values
  glass-effects.js     pointer-following highlights (pointer devices only)
  interactions.js      workspaces tabs, site accent picker, demos, cyberdeck HUD, copy, GitHub stats
static/images/         screenshots from docs/screenshots, cropped and converted to WebP (800 / 1600 px)
```

## Content rules

- Screenshots are real (`docs/screenshots`). Every schematic animation is captioned as an
  illustration, and the Midnight / Aurora / Violet accents are labelled as the site's, not
  Skyland themes.
- Star counts come from `/api/github`, fetched from GitHub at most once an hour for all
  visitors and hidden when unavailable; nothing is hard-coded.
- To refresh the images after new screenshots, re-run the crop / WebP conversion
  (Pillow): crop the frame, export 800 and 1600 px wide WebP at quality 80.
