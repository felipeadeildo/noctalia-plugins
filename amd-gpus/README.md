# AMD GPUs

A bar widget for one AMD GPU, picked by PCI address. Add one instance per card.

Noctalia's built-in `sysmon` widget shows a single GPU. On a laptop with an AMD iGPU and an AMD dGPU, it reports usage and temperature from whichever card it finds first, and adds both cards' VRAM into one number. This widget keeps the cards apart.

It reads `power/runtime_status` before anything else. While the card is suspended, it reads no other file, because reading `gpu_busy_percent` or the hwmon sensors wakes a sleeping dGPU and costs battery.

## Setup

Find each card's PCI address:

```sh
for c in /sys/class/drm/card[0-9]; do echo "$c $(basename "$(readlink -f "$c/device")")"; done
```

Then add one widget instance per card to `config.toml` and place them on a bar:

```toml
[widget.gpu-igpu]
type  = "felipeadeildo/amd-gpus:gpu"
pci   = "0000:37:00.0"
label = "680M"

[widget.gpu-dgpu]
type             = "felipeadeildo/amd-gpus:gpu"
pci              = "0000:03:00.0"
label            = "6700S"
hide_when_asleep = true
```

## Settings

| Setting | Default | What it does |
|---|---|---|
| `pci` | empty | The card's PCI address. |
| `label` | `GPU` | Text shown before the usage. |
| `hide_when_asleep` | `false` | Removes the widget while the card is suspended, so a dGPU only shows up when it wakes. |
| `interval` | `2000` | Milliseconds between reads, from 1000 to 10000. |

The tooltip shows usage, VRAM and temperature. Clicking the widget opens `amdgpu_top` in your terminal when it is installed.
