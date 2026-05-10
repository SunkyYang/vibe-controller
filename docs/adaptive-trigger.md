# Adaptive trigger (USB only)

When the controller is plugged in via USB-C, the app sends a `0x02` HID output report to put R2 into "weapon mode": resistance ramps up between positions 2 and 6 of the trigger pull, then snaps loose past position 6. Pull R2 slowly to feel it.

Bluetooth uses a different report ID (`0x31`) that requires a CRC32 trailer (poly `0xEDB88320`); the app currently no-ops the trigger effect over Bluetooth and the trigger feels stock.

Constants live in `DualSenseTriggerEffect.setWeaponMode(...)` — change start/end positions or strength as you like.
