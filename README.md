# Faster ToME4

Public source mirror of **Faster ToME4 0.0.1**, the Tales of Maj'Eyal addon
originally published by **yutio888** on 20 June 2021.

## Upstream

- [Original addon page](https://te4.org/games/addons/tome/faster)
- [Original downloadable package](https://te4.org/download-addon/7426/tome/faster)
- Upstream author: [yutio888](https://te4.org/users/yutio888)
- Mirror maintainer: [yutio8888](https://github.com/yutio8888)

The five Lua source files were extracted from the original `tome-faster.teaa`
package and imported without modification, including their original line endings,
author metadata, copyright notices, and warranty disclaimer. The initial import
adds repository documentation, the full license text, source provenance, and Git
attributes to preserve those bytes. It does not apply bug fixes.

Package SHA-256:

```text
030d9d4c86c98986e09ac8864991b7948a84263d9c8e23020ddae266b63882ea
```

See [UPSTREAM.json](UPSTREAM.json) for the original download URL, version metadata,
and individual source file hashes. No upstream Git commit is known for this
release; the package hash identifies the imported source.

## Features and compatibility

The addon caches Lua particle/shader definition loading and log-window text
rendering, replaces the recent debug log buffer with a ring buffer, and disables
the `hit_warning` particle effect (the ranged-hit direction indicator).

The source declares game version **1.7.3**. The upstream release page states
compatibility with **1.7.4**. This mirror does not claim complete compatibility or
measured performance improvements on ToME **1.7.6**.

## Installation

Download the original `.teaa` package linked above and place it in the game's
`game/addons/` directory, then enable Faster ToME4 in the Addons menu.

For source development, place this repository's contents in
`game/addons/tome-faster/`, with `init.lua` directly inside that directory. Use
one copy of the addon at a time to avoid loading both the archive and source tree.

## License and attribution

**GNU General Public License, version 3 or (at your option) any later version**
(`GPL-3.0-or-later`), as stated in the upstream [init.lua](init.lua).
The full GPL version 3 text is included in [COPYING](COPYING).

The original source notice credits:

```text
Copyright (C) 2009 - 2019 Nicolas Casalini
```

The addon metadata credits **Yutio888** as its author. This repository preserves
those credits and does not claim authorship of the upstream code.

The program is provided without warranty; see the original notice and COPYING.
