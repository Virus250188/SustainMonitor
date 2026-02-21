# Changelog - Sustain Monitor

## v1.3.3 (2026-02-21)

### Bugfix
- **Minion Kompatibilitaet:** ZIP-Paket wird jetzt mit standardkonformen Forward-Slashes und Directory-Eintraegen erstellt. Behebt das Problem, dass Minion das Addon nicht automatisch entpacken konnte.

---

## v1.3.2 (2026-02-20)

### ESOUI Compliance Fixes
- **DependsOn Versionscheck:** `LibAddonMenu-2.0>=41` hinzugefuegt (ESOUI Pflicht-Regel)
- **SavedVariables Server-Trennung:** `GetWorldName()` als Namespace-Parameter hinzugefuegt, damit Settings pro Server (EU/NA/PTS) getrennt gespeichert werden
- **Hinweis:** Bestehende Einstellungen werden einmalig zurueckgesetzt (neuer Speicherpfad pro Server)

---

## v1.3.1 (2026-02-20)

### Bugfix
- **Tod-Erkennung:** Warnungen, Sounds, Blink-Effekte und Heavy-Attack-Vorschlaege werden jetzt unterdrueckt wenn der Spieler tot ist
- HUD wird beim Tod automatisch ausgeblendet und nach dem Revive zurueckgesetzt
- `EVENT_PLAYER_DEAD` wird jetzt registriert und verarbeitet

---

## v1.3.0 (2026-02-19)

### Neue Features
- **Anpassbare Warnfarben:** Alle drei Warnstufen (Gelb/Orange/Rot) lassen sich jetzt per Colorpicker im Settings-Panel individuell einfaerben
- **Alert-Schriftgroesse:** Die Schriftgroesse der Bildschirmmitte-Aktionshinweise (Heavy Attack / Trank nutzen) ist jetzt per Slider konfigurierbar (16-40pt)
- **Trank-Farbe anpassbar:** Die Farbe des Trank-Labels und des Cooldown-Highlights kann frei gewaehlt werden (Standard: Cyan)
- **Trank-Bereit Farbe:** Separate Farbe fuer den "Bereit"-Zustand des Tranks (Standard: Gruen)
- **Trank-Schriftgroesse:** Die Schriftgroesse der Trank-Zeile im HUD ist jetzt konfigurierbar (14-36pt)

### Settings-Panel
- Neuer Bereich "Alert-Darstellung" mit 3 Colorpickern und 1 Slider
- Neuer Bereich "Trank-Darstellung" mit 2 Colorpickern und 1 Slider
- Alle neuen Settings haben "Auf Standard zuruecksetzen" Unterstuetzung

### Technisch
- Hardcodierte Farbwerte in UI.lua und Warnings.lua durch Saved Variables ersetzt
- Neue Defaults in SM.defaults fuer alle Farb- und Groessen-Optionen
- Lokalisierung fuer EN und DE komplett

---

## v1.2.0

### Features
- Drei Display-Styles: Einfach, Analytisch, Kampf
- Heavy Attack Vorschlag mit konfigurierbaren Schwellwerten
- Potion-Cooldown Tracking (Event-Driven + Polling-Fallback)
- Dreistufiges Warnsystem (Gelb/Orange/Rot) mit Blinken und Sound
- Live-Sparkline-Graphen (Analytisch-Stil)
- Verbleibende Casts Anzeige basierend auf ausgeruesteten Skills
- Kompakter Modus (Einfach-Stil)
- 20 konfigurierbare Sound-Optionen fuer Warnungen
- Debug-Modus mit Combat-Log
- Vollstaendige DE/EN Lokalisierung

---

## v1.1.0

### Features
- Grundlegende Burn-Rate Berechnung mit EMA-Glaettung
- Time-to-Empty Vorhersage
- Konfigurierbares HUD mit Drag-and-Drop Positionierung
- LibAddonMenu-2.0 Settings-Panel

---

## v1.0.0

### Erstveroeffentlichung
- Initiale Version mit Magicka/Stamina/Health Monitoring
- Einfache Ressourcen-Anzeige
