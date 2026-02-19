# Sustain Monitor

Real-time resource dashboard for **The Elder Scrolls Online** with burn-rate tracking and time-to-empty prediction.

![Analytical Style - Combat Alert](images/UI_Style_Analytisch_Alert.png)

## Features

- **Burn-Rate Tracking** - Shows how fast your Magicka, Stamina and Health are draining per second
- **Time-to-Empty Prediction** - Estimates how many seconds until each resource runs out
- **Casts Remaining** - Shows how many abilities you can still cast based on your equipped skills
- **Potion Cooldown Timer** - Tracks your potion cooldown with a countdown display
- **Heavy Attack Suggestion** - Visual and audio prompt when a Heavy Attack would be beneficial
- **Resource Warnings** - Color-coded warnings (yellow/orange/red) with optional sound and screen flash
- **Configurable Sounds** - Choose from 20 ESO alert sounds for warnings, heavy attack prompts and potion ready notifications
- **Smart Cost Detection** - Learns ability costs from combat usage, including channeled abilities
- **3 Display Styles** - Simple, Analytical and Combat
- **Localization** - English and German

## Display Styles

### Simple
Clean, minimal display showing burn-rate and time-to-empty for each resource.

![Simple Style - Settings](images/UI_Style_einfach.png)

### Analytical
Adds live sparkline graphs for resource history over time.

![Analytical Style - Low Resources Warning](images/UI_Style_Analytisch_NO_Ress.png)

### Combat
Large numbers with screen-center action prompts for Heavy Attack and Potion usage.

![Combat Style - Potion Cooldown](images/UI_Style_Kampf_Potion.png)

![Combat Style - HUD Numbers](images/UI_Style_Kampf_numbers.png)

![Combat Style - Settings](images/UI_Style_Kampf.png)

## Installation

1. Download the latest release ZIP
2. Extract the `SustainMonitor` folder into your ESO AddOns directory:
   ```
   Documents/Elder Scrolls Online/live/AddOns/
   ```
3. Make sure [LibAddonMenu-2.0](https://www.esoui.com/downloads/info7-LibAddonMenu.html) is installed
4. Restart the game or reload the UI with `/reloadui`

## Slash Commands

| Command | Description |
|---------|-------------|
| `/sm` | Show help |
| `/sm toggle` | Toggle the HUD on/off |
| `/sm sounds` | Play test sounds with current configuration |
| `/sm debug` | Toggle debug mode |
| `/sm dump` | Print diagnostics to chat |

## Settings

All settings are accessible via the ESO AddOn Settings menu (`Esc > Settings > AddOns > Sustain Monitor`):

- **General** - Enable/disable, lock position, UI scale
- **Display** - Choose style, toggle resources, bars, time display, compact mode, graphs, casts remaining
- **Calculation** - Smoothing factor for burn-rate responsiveness
- **Heavy Attack Suggestion** - Enable/disable, time and resource thresholds
- **Warnings** - Three warning levels with configurable thresholds, sounds and flash effects
- **Behavior** - Hide out of combat with configurable fade delay

## Dependencies

- **Required:** [LibAddonMenu-2.0](https://www.esoui.com/downloads/info7-LibAddonMenu.html)
- **Optional:** LibMediaProvider

## License

This project is provided as-is for personal use with The Elder Scrolls Online.
