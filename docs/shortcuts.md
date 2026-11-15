# Global shortcut

Resonance uses the macOS Carbon Events hotkey registration API. macOS delivers events
for the chosen key combination to the app's event target, so configuration does not
use a global event monitor or require Accessibility or Input Monitoring permissions.

The shortcut starts unassigned. In **Settings**, choose a key and modifiers, then
save the shortcut. Letter and number labels follow the current keyboard layout.
The saved binding uses the physical key and modifier combination. An existing
working shortcut stays active if the system rejects a replacement.
