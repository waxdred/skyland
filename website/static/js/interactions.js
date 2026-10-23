// Interactive scenes: workspaces, site theme, motion demos, cyberdeck HUD, copy button,
// GitHub stats (served cached by the backend, fetched once per page view).
(() => {
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const hasIO = 'IntersectionObserver' in window;
  const onceVisible = (el, fn, threshold = 0.35) => {
    if (!hasIO) return fn();
    const io = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting) return;
      io.disconnect();
      fn();
    }, { threshold });
    io.observe(el);
  };

  // ---------- Workspaces (WAI-ARIA tabs, roving tabindex) ----------
  const ws = document.querySelector('[data-ws]');
  if (ws) {
    const tabs = [...ws.querySelectorAll('[data-ws-tab]')];
    const panels = tabs.map((t) => document.getElementById(t.getAttribute('aria-controls')));
    const track = ws.querySelector('[data-ws-track]');
    const indicator = ws.querySelector('[data-ws-indicator]');

    // With JS all panels sit side by side in the track; inactive ones are inert.
    panels.forEach((p) => { p.hidden = false; });

    const select = (i, focus) => {
      tabs.forEach((t, j) => {
        const on = i === j;
        t.setAttribute('aria-selected', String(on));
        t.tabIndex = on ? 0 : -1;
        panels[j].setAttribute('aria-hidden', String(!on));
        panels[j].inert = !on;
      });
      track.style.transform = `translate3d(${-100 * i}%, 0, 0)`;
      indicator.style.setProperty('--i', i);
      if (focus) tabs[i].focus();
      tabs[i].scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: reduced ? 'auto' : 'smooth' });
    };

    tabs.forEach((t, i) => {
      t.addEventListener('click', () => select(i, false));
      t.addEventListener('keydown', (e) => {
        const last = tabs.length - 1;
        const next = { ArrowRight: i === last ? 0 : i + 1, ArrowLeft: i === 0 ? last : i - 1, Home: 0, End: last }[e.key];
        if (next === undefined) return;
        e.preventDefault();
        select(next, true);
      });
    });
    tabs.forEach((t, i) => panels[i].setAttribute('aria-hidden', String(i !== 0)));
    panels.forEach((p, i) => { p.inert = i !== 0; });
  }

  // ---------- Site theme (an aesthetic choice of this site, remembered per viewer) ----------
  const themeInputs = document.querySelectorAll('[data-theme-input]');
  const current = document.documentElement.dataset.theme || 'midnight';
  themeInputs.forEach((input) => {
    input.checked = input.value === current;
    input.addEventListener('change', () => {
      document.documentElement.dataset.theme = input.value;
      try { localStorage.setItem('skyland-site-theme', input.value); } catch (e) { /* storage unavailable */ }
      document.querySelectorAll('[data-demo]').forEach(play);
    });
  });

  // ---------- Motion demos: play once when visible, replay on demand ----------
  function play(demo) {
    if (reduced) return;
    demo.classList.remove('is-playing');
    void demo.offsetWidth; // restart CSS animations
    demo.classList.add('is-playing');
  }
  document.querySelectorAll('[data-demo]').forEach((demo) => {
    onceVisible(demo, () => setTimeout(() => play(demo), 250), 0.5);
    demo.querySelector('[data-demo-replay]').addEventListener('click', () => play(demo));
  });

  // ---------- Cyberdeck HUD: materialises from the orb ----------
  const hud = document.querySelector('[data-hud]');
  if (hud) {
    const orb = hud.querySelector('[data-hud-toggle]');
    const setOpen = (open) => {
      hud.classList.toggle('is-open', open);
      orb.setAttribute('aria-expanded', String(open));
    };
    if (reduced) setOpen(true);
    else {
      setOpen(false);
      onceVisible(hud, () => setTimeout(() => setOpen(true), 200), 0.3);
    }
    orb.addEventListener('click', () => setOpen(!hud.classList.contains('is-open')));
  }

  // Screenshots hosted in the cyberdeck repo: hide a figure if its image cannot load.
  document.querySelectorAll('[data-remote-shot] img').forEach((img) => {
    const hide = () => {
      const fig = img.closest('figure');
      fig.hidden = true;
      const group = fig.parentElement;
      if (![...group.children].some((c) => !c.hidden)) group.hidden = true;
    };
    if (img.complete && img.naturalWidth === 0 && img.currentSrc) hide();
    img.addEventListener('error', hide);
  });

  // ---------- Copy install command ----------
  const copyBtn = document.querySelector('[data-copy]');
  if (copyBtn && navigator.clipboard) {
    const source = document.querySelector('[data-copy-source]');
    const status = document.querySelector('[data-copy-status]');
    copyBtn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(source.textContent.trim());
        copyBtn.textContent = 'Copied';
        status.textContent = 'Install command copied to the clipboard';
        setTimeout(() => { copyBtn.textContent = 'Copy'; status.textContent = ''; }, 1800);
      } catch (e) { /* clipboard denied: the command stays selectable */ }
    });
  } else if (copyBtn) {
    copyBtn.hidden = true;
  }

  // ---------- GitHub stats ----------
  const fmt = new Intl.NumberFormat('en', { notation: 'compact' });
  // relative: the Flask app at / and the static export in a sub-path both answer it
  fetch('api/github', { headers: { Accept: 'application/json' } })
    .then((r) => (r.ok ? r.json() : null))
    .then((data) => {
      if (!data) return;
      for (const [key, repo] of Object.entries(data.repos || {})) {
        if (typeof repo.stars !== 'number') continue;
        document.querySelectorAll(`[data-stars="${key}"]`).forEach((el) => {
          el.querySelector('.stars__n').textContent = fmt.format(repo.stars);
          el.hidden = false;
        });
      }
      const rel = document.querySelector('[data-release]');
      if (rel && data.release && data.release.tag) {
        const a = document.createElement('a');
        a.href = data.release.url;
        a.rel = 'noopener';
        a.textContent = `Latest release ${data.release.tag}`;
        rel.replaceChildren(a);
        rel.hidden = false;
      }
    })
    .catch(() => { /* stats are optional */ });
})();
