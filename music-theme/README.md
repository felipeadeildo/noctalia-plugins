# Music Theme

Themes Noctalia from the album art of the track that is playing. The shell and every template you have enabled (GTK, Ghostty, niri, Zed and the rest) follow the cover, and your wallpaper stays as it is. When playback stops, your previous palette comes back.

This is the Noctalia port of [dms-music-theme](https://github.com/felipeadeildo/dms-music-theme).

## Requirements

- Noctalia 5.4.1 or newer
- [`playerctl`](https://github.com/altdesktop/playerctl)
- A media player that exposes MPRIS with album art: Spotify, Chromium-based browsers, mpv with the MPRIS script, and most others

## How it works

1. `playerctl --follow status` reports the player whose status changed last. When that player closes, it reports the next one.
2. While a player is playing, the plugin reads its `mpris:artUrl` every 2 seconds, so a new track with a new cover is picked up. Covers on `http(s)` URLs are downloaded once and cached.
3. `noctalia theme <cover> --both` generates a dark and a light palette from the cover. The plugin writes them to `~/.config/noctalia/palettes/MusicTheme.json`.
4. The first time it themes, the plugin saves the palette you had (for example `wallpaper vibrant`), then runs `noctalia msg color-scheme-set custom MusicTheme`.
5. When playback stops, it waits for the hold time and runs `color-scheme-set` with the palette it saved.

A black and white or washed out cover would come out as a strong color with a random hue under most schemes. When the cover's source color has a saturation below 0.2, the plugin uses `m3-content`, which keeps it neutral.

If you pick another palette yourself while an album palette is showing, the plugin leaves your choice alone when playback stops.

## Settings

Open them from Settings, Plugins, then the gear on Music Theme.

| Setting | Default | What it does |
|---|---|---|
| Palette | System | The scheme that turns the cover into a palette. System uses your `[theme] wallpaper_scheme`. |
| When playback stops | After 30 seconds | How long the album palette stays after a pause: right away, 10 s, 30 s, 1 min, 5 min, or until the player closes. |
| Update delay | 500 ms | How long the track has to settle before the palette changes. |
| Ignored players | none | `playerctl` player names that never theme the desktop, for example `chromium` if you don't want YouTube videos to recolor everything. |

## Limitations

- `color-scheme-set` saves the palette in `settings.toml`. If Noctalia is killed mid-track, the album palette stays until the next start, when the plugin restores the saved one.
- Noctalia Greeter's auto-sync runs on every palette change, which means once per track with this plugin. Leave `[shell.greeter_sync] auto_sync` off and sync the greeter by hand.
- Palettes from a custom file set 16 colors, and Noctalia derives the remaining roles from them. They are close to a wallpaper palette but not identical.
