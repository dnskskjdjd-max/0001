# Fire Score Tracker

Registra cada hora las recomendaciones de [firepolymarket.com](https://firepolymarket.com/) y simula si apostar en ellas da ganancias.

- `tracker.ps1`: descarga los datos, registra señales y grupo de control, y resuelve mercados con la API de Polymarket.
- `.github/workflows/tracker.yml`: lo ejecuta cada hora en GitHub Actions y guarda los datos en `data/`.
- `dashboard.html`: el panel con las simulaciones (publicado con GitHub Pages).
- `data/log.txt`: registro de cada ejecución; si algo falla, el error aparece aquí.

No es asesoría financiera.
