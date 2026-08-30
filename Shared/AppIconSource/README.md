# App icon source

`Scissors.svg` is the plain foreground art used by `AppIcon.icon`.

Keep the source on a 1024 by 1024 canvas. Do not add the app icon mask, background, blur, shadow, shine, or glass effects to this file. Apple Icon Composer owns those parts of the final icon.

When the icon changes:

1. Replace or edit `Scissors.svg`.
2. Open `Shared/AppIcon.icon` in Apple Icon Composer.
3. Replace the foreground image while keeping its canvas position.
4. Check Default, Dark, and Mono for iOS and macOS.
5. Build both app targets and capture Default, Dark, Clear, and Tinted review images in Icon Composer or Simulator.

The current design gives the scissors blur, translucency, a specular edge, and a neutral shadow. Keep the dark fill light enough to stand out from the dark system enclosure.
