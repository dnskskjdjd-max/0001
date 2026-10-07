// Barra de actualización compartida por todas las pestañas.
// - Botón "Actualizar ahora": recarga la página y sus datos saltándose la caché.
// - Interruptor "Auto": recarga cada 5 min (o los minutos de data-every) y, sobre todo, al volver a la pestaña o al despertar la PC
//   (los navegadores congelan los temporizadores de pestañas inactivas, por eso un simple setTimeout no basta).
(function () {
  // Cada cuanto recargar: data-every="N" (minutos) en la etiqueta script; 5 por defecto
  const EVERY_MIN = +((document.currentScript && document.currentScript.dataset.every) || 5);
  const EVERY_MS = EVERY_MIN * 60 * 1000;
  const KEY = 'fst-autorefresh';
  const loadedAt = Date.now();
  let auto = true;
  try { auto = localStorage.getItem(KEY) !== 'off'; } catch (e) {}

  function reload() {
    const u = new URL(location.href);
    u.searchParams.set('r', Date.now().toString(36)); // URL nueva: evita la caché del HTML
    location.replace(u.toString());
  }

  const css = document.createElement('style');
  css.textContent = `
.fst-refresh { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; margin: -10px 0 16px; font-size: 13px; color: var(--ink-2); }
.fst-refresh button { font: inherit; padding: 5px 12px; border: 1px solid var(--border); border-radius: 6px; background: var(--surface); color: var(--ink); cursor: pointer; }
.fst-refresh button:hover { border-color: var(--accent); }
.fst-refresh label { display: inline-flex; align-items: center; gap: 6px; cursor: pointer; user-select: none; }
.fst-switch { position: relative; width: 34px; height: 18px; border-radius: 9px; background: var(--border); transition: background .15s; flex: none; }
.fst-switch::after { content: ''; position: absolute; top: 2px; left: 2px; width: 14px; height: 14px; border-radius: 50%; background: #fff; transition: left .15s; }
.fst-refresh input { display: none; }
.fst-refresh input:checked + .fst-switch { background: var(--accent); }
.fst-refresh input:checked + .fst-switch::after { left: 18px; }
.fst-refresh .fst-age { color: var(--muted); font-size: 12px; }`;
  document.head.appendChild(css);

  const bar = document.createElement('div');
  bar.className = 'fst-refresh';
  bar.innerHTML = `<button type="button" id="fstNow">🔄 Actualizar ahora</button>
    <label title="Recarga cada ${EVERY_MIN} min y al volver a esta pestaña"><input type="checkbox" id="fstAuto"><span class="fst-switch"></span>Auto-actualizar</label>
    <span class="fst-age" id="fstAge"></span>`;
  const nav = document.getElementById('tabs');
  if (nav) nav.insertAdjacentElement('afterend', bar); else document.body.prepend(bar);

  const chk = bar.querySelector('#fstAuto');
  chk.checked = auto;
  chk.addEventListener('change', () => {
    auto = chk.checked;
    try { localStorage.setItem(KEY, auto ? 'on' : 'off'); } catch (e) {}
    tick();
  });
  bar.querySelector('#fstNow').addEventListener('click', reload);

  const age = bar.querySelector('#fstAge');
  function tick() {
    const min = Math.floor((Date.now() - loadedAt) / 60000);
    age.textContent = 'Página cargada ' + (min < 1 ? 'hace menos de 1 min' : `hace ${min} min`) + (auto ? '' : ' · auto-actualizar apagado');
    // Se compara con el reloj real: tras suspensión o inactividad, el primer tick ya detecta el retraso
    if (auto && document.visibilityState === 'visible' && Date.now() - loadedAt >= EVERY_MS) reload();
  }
  setInterval(tick, 20000);
  document.addEventListener('visibilitychange', tick);
  window.addEventListener('focus', tick);
  window.addEventListener('online', tick);
  // Página restaurada desde la caché del navegador (botón atrás): siempre se recarga
  window.addEventListener('pageshow', e => { if (e.persisted) reload(); });
  tick();
})();
