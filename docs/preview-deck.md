# Preview deck (0.2)

The existing Shibumi-inspired fan remains the selector. The focused card is also
shown full-screen behind it. Selecting a card centers and expands it into the
screen over 700 ms. The overlay fades only after the native Omarchy setter
succeeds; a failed setter restores the hand with a retry message. Escape closes
the picker but does not undo an already-started native setter.

## Controls

| Action | Keyboard / pointer |
|---|---|
| Move | Arrow keys, wheel, click another card |
| Apply | Enter, Space, click the focused card |
| Search | Type; all letters, including H and L, remain searchable |
| Mark/unmark favourite | Ctrl+F |
| All / favourites | Tab, or the corresponding chip |
| Sort by name / colour / newest | Ctrl+S, or Sort chip |
| Live preview | Ctrl+P, or Live preview chip (wallpapers) |
| Clear search / close | Escape; outside click closes |

Name preserves Omarchy's filename order, including numbered theme defaults.
Colour follows a dominant-hue wheel, then greys from light to dark. Unknown
colours sort last. Newest uses file modification time (theme folder modification
time for themes). Sorting preserves the focused card.

Live preview defaults off. Video is muted and loops; GIF/animated WebP uses
Qt's animated-image decoder. Changing video source restarts playback. Leaving
video, closing the picker or enabling Reduced Motion releases the player.
Reduced Motion also removes the growing-card animation. Static WebP remains a
valid preview, even when it has only one frame.

## Persistence and scope

`~/.local/state/nerdibeard.card-picker/state.json` stores sort mode, favourites,
live-preview preference and a small thumbnail colour cache. Writes are atomic.
Invalid JSON is left untouched and reported; preferences remain session-local
until that file is repaired. Wallpaper favourites are scoped to the theme, with
user-added files disambiguated from the theme's own files.

Read-only lists and writes still use Omarchy's native commands. No background
renderer, matugen, network access, Wallhaven integration or package installation
is added. Paths are passed as argv, and displayed text is plain text. Async
requests carry an open-generation token so stale results cannot replace a newly
opened deck. Histogram work has per-image and overall time/resource bounds.

## Install and rollback

`./dev-install.sh` validates the plugin and stages a complete immutable QML
generation outside the watched plugin tree. It atomically switches only this
plugin's manifest. It never changes shell.json, menu routing, the active theme,
background, or preferences. Original root files and old generations remain.
Backed-up manifests are under `~/.config/omarchy/card-picker-manifest-backups/`.
Restore the desired previous manifest atomically to roll back. Verify the running
`omarchy-shell card-picker state` revision, not only the installed manifest.

## Verification

- `node tests/logic.cjs`: seven grouped logic checks, including duplicate names.
- `python3 tests/native.py OUTPUT`: production Picker/Deck QML in a private Xvfb
  window, real Qt key events, fixture media and native subprocess fixtures. Checks
  search, favourites, sorting, video-to-video switching, animated-image lifecycle,
  Reduced Motion, failed/slow/successful setters, rapid reopening, on-disk
  preferences and exact setter call count. It never calls the host's setters.
- `python3 tests/render.py --output OUTPUT [--video]`: native visual walkthrough
  against the installed read-only Omarchy lists. Setters are dry-run only.

Fixture checks complement, not replace, a live Wayland route/focus check. The
preview animation is real QML, not a design mockup. Shell restarts are unnecessary.
