# Changelog

## Watt Bank for Mac 8.0 — first public release

- **Cards:**
  - Watt, Debit (₽) and Credit (₽ loans that level up).
  - Calories, fed by Apple Health.
  - Trainer and Mom, read live from the loaded game save.
  - Arrange them in a 2-column grid: drag a card onto another to swap, or right-click → Move.
- **IR head (ESP32):**
  - Deposit and withdraw watts with the Pokémon Pikachu 2 GS.
  - Mystery Gift for Gold, Silver and Crystal.
- **One-click firmware install** from the app, with progress. The board's blue light blinks to show it was found and
  that the install finished. Arduino IDE steps are kept as a backup.
- **Guides with pictures** in the app: building the IR head (8 steps) and setting up the iPhone Shortcut (4 steps).
- **Game saves of every generation** through PKHeX.Core:
  - Drop a save anywhere on the window.
  - The same trainer name and ID opens the same account.
  - Every save is backed up before Watt Bank writes to it.
- **Exchange:** 0.83 W = ₽1. Buy Watts with Debit or Credit; sell Watts for Debit.
- **Tips bar** with NANO and BAN addresses, QR codes, and a suggested tip of about $5 that follows the live price.
- **Custom card art** goes in `~/Library/Application Support/Watt Bank/Card Art/`.
- **Everything works from the keyboard.**

## IR head firmware 4.8

- **Install signals:** 3 blue blinks on start-up. The `f` command blinks the blue light, which the installer uses to show
  which board it found.
- **Requests:** answers a burst of `?` requests only once.
