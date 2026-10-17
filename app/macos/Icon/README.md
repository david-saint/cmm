# The app icon

`AppIcon.icon` is an Icon Composer document: a serif "c" and a green full stop, in three looks.

| Look | Tile | The c | The dot |
|---|---|---|---|
| Light (default) | warm paper `#FBFBF9` | ink `#0D0D0F` | green `#14975A` |
| Dark | near-black `#0B0B0C` | off-white `#F5F5F7` | brighter green `#30C477` |
| Tinted | dark grey | the dark look's glyphs | the dark look's dot |

The "c." concept was picked from five generated options; the c is a vector trace of that design (`Assets/c.svg`),
the dot a plain circle (`Assets/dot.svg`), and the `-dark` files are the same shapes in the dark colours.

`build-app.sh` compiles the document with `actool` into `Assets.car` (what macOS 26 and later draw, with the system's
glass finish and its own dark, tinted and clear looks) and `AppIcon.icns` (older systems), and `Info.plist` names it.

Render a look to a PNG to check a change:

```bash
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Icon/AppIcon.icon \
  --export-image --output-file /tmp/icon.png --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1
```

Renditions: `Default`, `Dark`, `TintedDark`, `TintedLight`, `ClearDark`, `ClearLight`.

One format detail worth knowing when editing `icon.json`: the tile colour and each layer's image are given only as
`fill-specializations` and `image-name-specializations` (an entry without `appearance` is the light look). With a plain
`fill` or `image-name` next to them, Icon Composer ignores the dark and tinted entries.
