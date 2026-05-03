# third-party licenses

catapult is built on the shoulders of several open-source projects. their
licenses and copyright notices are reproduced (or pointed at) below.
copies of the full license texts are bundled inside `Catapult.app` for
in-app access via Settings → About → "open-source licenses".

last refreshed: 2026-05-03 — for catapult 1.0.

---

## runtime dependencies (downloaded by catapult on first launch)

these aren't shipped inside the .app. catapult downloads release builds
of yt-dlp and ffmpeg into `~/Library/Application Support/Catapult/bin/`
on first run.

### yt-dlp

- upstream: https://github.com/yt-dlp/yt-dlp
- license: **The Unlicense** (public domain dedication)
- copyright (c) yt-dlp contributors

> This is free and unencumbered software released into the public domain.
>
> Anyone is free to copy, modify, publish, use, compile, sell, or distribute
> this software, either in source code form or as a compiled binary, for
> any purpose, commercial or non-commercial, and by any means.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

### ffmpeg

- upstream: https://ffmpeg.org/
- license: **LGPL v2.1 or later** (default build); some configurations are
  redistributed under **GPL v2 or later**. catapult downloads the
  evermeet.cx static-build distribution: https://evermeet.cx/ffmpeg/
- copyright (c) FFmpeg developers

ffmpeg's components are individually licensed; `--enable-gpl`,
`--enable-nonfree`, `x264`, `libfdk-aac` etc. each carry their own terms.
the evermeet.cx build catapult downloads is a stock GPL build —
see https://evermeet.cx/ffmpeg/#legal for the canonical statement.

per LGPL/GPL: source is available from the upstream project at
https://git.ffmpeg.org/ffmpeg.git. catapult does not modify ffmpeg.

---

## swift packages linked into Catapult.app

### Sparkle

- upstream: https://sparkle-project.org / https://github.com/sparkle-project/Sparkle
- license: **MIT**
- copyright (c) 2006-2024 Andy Matuschak and the Sparkle Project

> Permission is hereby granted, free of charge, to any person obtaining
> a copy of this software and associated documentation files (the
> "Software"), to deal in the Software without restriction, including
> without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software …
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

Sparkle bundles a few sublibraries internally, each MIT-compatible:
bsdiff (BSD-2-Clause), Sparkle's own auto-updater, Ed25519 reference
implementation (public domain). their notices ship inside
`Sparkle.framework/Resources` once the framework is linked.

---

## fonts bundled inside Catapult.app

### Lora

- upstream: https://fonts.google.com/specimen/Lora
- license: **SIL Open Font License v1.1**
- copyright (c) 2011 The Lora Project Authors

> Copyright 2011 The Lora Project Authors (https://github.com/cyrealtype/Lora-Cyrillic),
> with Reserved Font Name "Lora".
>
> This Font Software is licensed under the SIL Open Font License, Version 1.1.
> You may obtain a copy of the License at:
> https://openfontlicense.org

### Google Sans Flex

- upstream: https://fonts.google.com (variable variant of Google Sans Text)
- license: **SIL Open Font License v1.1**
- copyright (c) Google LLC

> This Font Software is licensed under the SIL Open Font License, Version 1.1.
> https://openfontlicense.org

per OFL v1.1, the bundled font binaries are not sold standalone, may be
embedded in catapult, and the reserved font name is preserved. the full
OFL text ships in the .app under `Resources/licenses/OFL.txt`.

---

## design / graphics

- the **h3 design system** (Frutiger Aero / Wii channel inspired tokens
  in `H3Design.swift`) is original work © 2026 henry perzinski, released
  under the same MIT terms as catapult itself.
- the **app icon** (`Catapult.icon`) is original work © 2026 henry
  perzinski, all rights reserved (not OSS-licensed).
- SF Symbols glyphs displayed in-app are © Apple Inc. and used under the
  SF Symbols license — they are NOT redistributed as standalone art.

---

## catapult itself

catapult is © 2026 henry perzinski. the source code in this repository
is provided under the **MIT License** (see `LICENSE` in the repo root).

---

## reporting issues with this list

if you spot a missing attribution, an outdated version, or a license
mismatch, file an issue at
https://github.com/HenryTheAddict/Catapult/issues — or open a PR amending this
file directly.
