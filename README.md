# noctalia-plugins

> Archived. I went back to Dux Shell, so these plugins are no longer maintained. They work on Noctalia 5.4.1.

Plugins for [Noctalia](https://noctalia.dev) that I run on an ASUS ROG laptop with niri. Both target Noctalia 5.4.1 and later.

| Plugin | What it does |
|---|---|
| [music-theme](music-theme) | Themes the shell and your apps from the album art of the playing track, and puts your palette back when playback stops. |
| [amd-gpus](amd-gpus) | Shows one bar widget per AMD GPU, picked by PCI address, without waking a sleeping dGPU. |

## Install

Add this repository as a plugin source, then enable the plugins you want:

```sh
noctalia msg plugins source add felipeadeildo git https://github.com/felipeadeildo/noctalia-plugins
noctalia msg plugins enable felipeadeildo/music-theme
noctalia msg plugins enable felipeadeildo/amd-gpus
```

To declare the source in `config.toml` instead, list the built-in sources too. Once `[[plugins.source]]` appears in your config, Noctalia stops adding `official` and `community` on its own:

```toml
[[plugins.source]]
name     = "official"
kind     = "git"
location = "https://github.com/noctalia-dev/official-plugins"

[[plugins.source]]
name     = "community"
kind     = "git"
location = "https://github.com/noctalia-dev/community-plugins"

[[plugins.source]]
name     = "felipeadeildo"
kind     = "git"
location = "https://github.com/felipeadeildo/noctalia-plugins"
```

## License

MIT
