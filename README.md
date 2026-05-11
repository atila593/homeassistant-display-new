# Home Assistant Display — Kiosk HAOS (Chromium)

Afficher des dashboards Home Assistant en mode “kiosk” directement sur **Home Assistant OS (HAOS)** via HDMI/DP, en utilisant **Chromium** (support WebRTC/caméras).

## Pourquoi ce dépôt ?
Le projet original basé sur Luakit a des limites (WebRTC/caméras). Cette variante utilise Chromium pour une compatibilité moderne.

---

## Installation (HAOS)

1. **Paramètres → Modules complémentaires → Boutique**
2. **⋮ → Dépôts**
3. Ajouter ce dépôt GitHub (URL de ton futur dépôt)
4. Installer l’add-on `homeassistant-display`
5. Configurer (ci-dessous) puis démarrer

---

## Configuration recommandée (sans auto-login)

### Option A — Trusted Networks (recommandé)
Si ton Home Assistant est configuré avec `trusted_networks` + `allow_bypass_login: true`, **ne configure pas** `ha_username` / `ha_password`.
Cela évite l’envoi de frappes clavier au démarrage (qui peut ouvrir la recherche HA).

Exemple `configuration.yaml` (remplace `<YOUR_USER_ID>` — ne publie pas ton ID réel) :

```yaml
homeassistant:
  auth_providers:
    - type: trusted_networks
      trusted_networks:
        - 192.168.1.0/24
        - 127.0.0.1
      trusted_users:
        192.168.1.0/24:
          - <YOUR_USER_ID>
        127.0.0.1:
          - <YOUR_USER_ID>
      allow_bypass_login: true
    - type: homeassistant
```

Dans l’add-on :
- `ha_url: "http://127.0.0.1:8123"`
- laisser `ha_username` / `ha_password` vides

---

## Clavier à l’écran (écrans tactiles)

Sur HAOS (X11 + Chromium), un clavier à l’écran ne “pop” pas automatiquement partout.
Cet add-on propose un mode universel :

- `onscreen_keyboard_mode: "off" | "manual" | "always"`
  - **off**: désactivé
  - **manual**: activable via API REST `/keyboard/toggle`
  - **always**: toujours visible (le plus simple pour “tout le monde”)

---

## Paramètres

| Clé | Défaut | Description |
|---|---:|---|
| `ha_url` | `http://127.0.0.1:8123` | URL de base Home Assistant |
| `ha_dashboard` | `""` | Chemin dashboard (ex: `lovelace/kiosk`) |
| `login_delay` | `8.0` | (si auto-login activé) délai avant tentatives |
| `zoom_level` | `100` | Zoom Chromium |
| `browser_refresh` | `600` | Auto refresh (0=off) |
| `screen_timeout` | `0` | Veille écran (0=jamais) |
| `output_number` | `1` | Écran sélectionné |
| `rotate_display` | `normal` | `normal|left|right|inverted` |
| `map_touch_inputs` | `true` | Mapper tactile vers l’écran |
| `keyboard_layout` | `us` | `fr`, `de`, etc. |
| `onscreen_keyboard_mode` | `off` | `off|manual|always` |
| `rest_port` | `8080` | Port API |
| `rest_bearer_token` | `""` | Token Bearer optionnel |
| `debug_mode` | `false` | X/Openbox sans Chromium |

### Auto-login (optionnel)
Si tu actives `ha_username` / `ha_password`, l’add-on **peut** tenter un auto-login clavier.
Selon le timing, ça peut ouvrir la recherche HA. La solution “propre” est **Trusted Networks**.

---

## API REST (local)

Par sécurité, l’API écoute sur `127.0.0.1`.

Endpoints :
- `GET /health`
- `POST /display_on`
- `POST /display_off`
- `POST /keyboard/toggle`
- `POST /browser/refresh`
- `POST /browser/navigate` (JSON: `{"url":"http://..."}`)

Si `rest_bearer_token` est défini, ajouter :
- Header `Authorization: Bearer <TOKEN>`

