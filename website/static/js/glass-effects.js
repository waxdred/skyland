// Liquid Glass highlights: the edge reflection and inner sheen follow the pointer on
// interactive surfaces. Pointer devices only; one rAF write per frame at most.
(() => {
  if (!window.matchMedia('(hover: hover) and (pointer: fine)').matches) return;
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  const surfaces = document.querySelectorAll('a.glass, .ws, .demo, .desk, .hud-card, .more');
  let pending = null;

  const flush = () => {
    const { el, x, y } = pending;
    pending = null;
    const r = el.getBoundingClientRect();
    el.style.setProperty('--mx', ((x - r.left) / r.width).toFixed(3));
    el.style.setProperty('--my', ((y - r.top) / r.height).toFixed(3));
  };

  for (const el of surfaces) {
    el.addEventListener('pointerenter', () => el.classList.add('is-lit'));
    el.addEventListener('pointerleave', () => {
      el.classList.remove('is-lit');
      el.style.removeProperty('--mx');
      el.style.removeProperty('--my');
    });
    el.addEventListener('pointermove', (e) => {
      if (!pending) requestAnimationFrame(flush);
      pending = { el, x: e.clientX, y: e.clientY };
    }, { passive: true });
  }
})();
