# Global shortcut

Resonance uses the macOS Carbon Events hotkey registration API. macOS delivers events
for the chosen key combination to the app's event target, so configuration does not
use a global event monitor or require Accessibility or Input Monitoring permissions.

The shortcut starts unassigned. In **Settings**, choose a key and modifiers, then
save the shortcut. Settings asks for confirmation before saving a binding that
overlaps a common app command such as Copy or Quit. An existing working shortcut
stays active while you review the warning or if the system rejects a replacement.
[Mac keyboard shortcuts](https://support.apple.com/en-us/102650)

The saved binding uses the physical key and modifier combination. Letter and
number labels follow the current keyboard layout, including its Command mapping
for shortcuts that include Command. [Dvorak layouts on Mac](https://support.apple.com/guide/mac-help/use-dvorak-keyboard-layouts-mh27976/mac)
