// Scroll motion: one-shot reveals (IntersectionObserver), and a few scroll-linked values
// (hero depth, background parallax, SkylandBar reveal) written from a single rAF.
// No scroll-jacking: nothing here prevents or delays native scrolling.
(() => {
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const root = document.documentElement;

  // ---------- Reveals ----------
  const revealables = document.querySelectorAll('.reveal, .depth-reveal, .stagger');
  const markDone = (el) => {
    el.addEventListener('transitionend', () => el.classList.add('is-done'), { once: true });
    el.classList.add('is-in');
  };
  if (reduced || !('IntersectionObserver' in window)) {
    revealables.forEach((el) => el.classList.add('is-in', 'is-done'));
  } else {
    const io = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        markDone(entry.target);
        io.unobserve(entry.target);
      }
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    revealables.forEach((el) => io.observe(el));
  }

  // ---------- Window manager layout demo: steps drive the schematic ----------
  const demo = document.querySelector('[data-layout-demo]');
  const steps = [...document.querySelectorAll('[data-steps] .step')];
  const buttons = [...document.querySelectorAll('[data-layout-go]')];
  const windows = demo ? [...demo.querySelectorAll('.w')] : [];
  const activeFor = { 0: 'w2', 1: 'w2', 2: 'w5' };

  const setLayout = (state) => {
    if (!demo) return;
    demo.dataset.state = String(state);
    windows.forEach((w) => w.classList.toggle('is-active', w.classList.contains(activeFor[state])));
    buttons.forEach((b) => b.setAttribute('aria-pressed', String(Number(b.dataset.layoutGo) === state)));
    steps.forEach((s) => s.classList.toggle('is-current', Number(s.dataset.step) === state));
  };
  buttons.forEach((b) => b.addEventListener('click', () => setLayout(Number(b.dataset.layoutGo))));

  if (demo) {
    if (reduced || !('IntersectionObserver' in window)) {
      setLayout(0);
    } else {
      // Floating windows settle into the dwindle layout when the demo comes into view.
      const settle = new IntersectionObserver(([entry]) => {
        if (!entry.isIntersecting) return;
        settle.disconnect();
        setTimeout(() => { if (demo.dataset.state === '-1') setLayout(0); }, 350);
      }, { threshold: 0.45 });
      settle.observe(demo);

      // On wide screens the demo is sticky: the step crossing the middle of the viewport wins.
      const wide = window.matchMedia('(min-width: 1200px)');
      const stepSpy = new IntersectionObserver((entries) => {
        if (!wide.matches) return;
        for (const entry of entries) {
          if (entry.isIntersecting) setLayout(Number(entry.target.dataset.step));
        }
      }, { rootMargin: '-48% 0px -48% 0px' });
      steps.forEach((s) => stepSpy.observe(s));
    }
  }

  if (reduced) {
    const popup = document.querySelector('[data-bar-popup]');
    if (popup) popup.classList.add('is-open');
    document.querySelectorAll('.bar-stage').forEach((el) => el.style.setProperty('--p', '1'));
    return;
  }

  // ---------- Scroll-linked values ----------
  const atmos = document.querySelector('.atmos');
  const hero = document.querySelector('[data-hero]');
  const heroCopy = document.querySelector('[data-hero-copy]');
  const desk = document.querySelector('[data-hero-stage] .desk');
  const barStage = document.querySelector('.bar-stage');
  const popup = document.querySelector('[data-bar-popup]');
  const mobile = window.matchMedia('(max-width: 767px)');

  // Layout reads happen only on resize, never per frame.
  let heroH = 1;
  let barTop = 0;
  let viewH = window.innerHeight;
  const measure = () => {
    viewH = window.innerHeight;
    heroH = hero ? hero.offsetHeight : 1;
    barTop = barStage ? barStage.getBoundingClientRect().top + window.scrollY : 0;
  };
  measure();
  if ('ResizeObserver' in window) new ResizeObserver(measure).observe(document.body);
  else window.addEventListener('resize', measure);

  const clamp01 = (v) => Math.min(1, Math.max(0, v));
  let popupShown = false;
  let ticking = false;

  const update = () => {
    ticking = false;
    const y = window.scrollY;

    if (y < heroH * 1.2) {
      const p = clamp01(y / (heroH * 0.85));
      if (desk) desk.style.setProperty('--p', p.toFixed(4));
      if (heroCopy) {
        heroCopy.style.opacity = String(1 - p * 1.1);
        heroCopy.style.transform = `translate3d(0, ${(-p * 60).toFixed(1)}px, 0)`;
      }
    }

    if (atmos && !mobile.matches) atmos.style.setProperty('--scroll', (y / viewH).toFixed(3));

    if (barStage) {
      // 0 when the bar enters the lower part of the viewport, 1 by the time it reaches the middle.
      const start = barTop - viewH * 0.9;
      const end = barTop - viewH * 0.45;
      const p = clamp01((y - start) / (end - start));
      barStage.style.setProperty('--p', p.toFixed(4));
      if (!popupShown && p >= 1 && popup) {
        popupShown = true;
        setTimeout(() => popup.classList.add('is-open'), 200);
      }
    }
  };

  window.addEventListener('scroll', () => {
    if (!ticking) {
      ticking = true;
      requestAnimationFrame(update);
    }
  }, { passive: true });
  update();
})();
