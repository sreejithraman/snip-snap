# Liquid Glass app icon research

Date: 2026-08-30

This report checks how Snip Snap can keep its current Mac icon identity while adding native Liquid Glass appearances for iPhone, iPad, and Mac. Apple documentation and Apple sessions are the sources for platform claims. Repo and tool checks are marked as local findings.

## Short answer

Yes. The best path is to rebuild the current icon as a small set of clean layers, finish it in Apple's Icon Composer, and add one `AppIcon.icon` file to the Mac and iOS targets. That file can produce the default, dark, clear light, clear dark, tinted light, and tinted dark results across iOS, iPadOS, and macOS. It also supplies the App Store icon. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)

Snip Snap's current 1024-pixel icon is a useful visual reference, but it is not suitable source art for a native Liquid Glass icon. It has the background, rounded enclosure, highlights, shadows, and scissors merged into one RGB PNG. Apple tells designers to export separate, plain layers and add blur, shadow, specular highlights, translucency, backgrounds, and the final mask in Icon Composer. [Create icons with Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/), [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

Codex can do this work with the tools available on this Mac. It can reconstruct the scissors as vector art, make and revise the layer files, operate Icon Composer, add the result to Xcode, build the app, and inspect every appearance in Simulator. The main limit is that Apple documents Icon Composer as the authoring tool, not a command-line authoring format. The final glass tuning should therefore happen in the app, with user review of the visual result.

## What Apple now supports

Apple's current icon layout for iOS, iPadOS, and macOS is a layered 1024 by 1024 pixel square. The system applies the rounded-rectangle mask and makes the smaller sizes it needs. The six rendered appearances are default, dark, clear light, clear dark, tinted light, and tinted dark. [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)

Icon Composer stores the work in one multilayer `.icon` file. A single design can cover iPhone, iPad, Mac, and Apple Watch, while the file can hold platform and appearance changes where they are needed. Xcode includes the file in the app and renders the right platform, appearance, and size. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [Create icons with Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/)

Icon Composer labels the editable appearances as Default, Dark, and Mono. Mono drives the clear and tinted results, including their light and dark forms. It lets the designer preview those results over custom backgrounds and with a chosen tint. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

The default design applies to all selected platforms unless the designer changes a setting for one platform or appearance. This means Snip Snap can use one brand design and make only small changes, such as scale or color, for Mac or dark mode. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

## Source art needed for Snip Snap

Apple recommends starting with its current app icon template or a 1024 by 1024 pixel canvas for iPhone, iPad, and Mac. It recommends SVG for scalable shapes and PNG only where an SVG cannot hold the art. Layers should follow back-to-front depth order, and colors or parts that need separate appearance changes should live in separate layers. Text must become outlines. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

The exported layer files should not contain the rounded icon mask. Apple also says to remove baked blur, shadow, specular, opacity, translucency, background colors, and gradients, then set those properties in Icon Composer. This lets the system animate and render the Liquid Glass material instead of displaying a flat picture of glass. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [Create icons with Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/)

Apple advises using simple, front-facing forms, round corners, and bold strokes because thin or sharp details can lose shape at small sizes or under glass highlights. A simple icon may need only one background and one foreground layer. [Say hello to the new look of app icons](https://developer.apple.com/videos/play/wwdc2025/220/)

For Snip Snap, a faithful first structure is:

1. A canvas with a pale neutral background for the default look and a tuned darker or colored background for dark mode.
2. One clean scissors silhouette as an SVG foreground layer, with the two handle holes cut from the shape.
3. No baked outer border, bevel, drop shadow, or gloss. Icon Composer supplies those material effects.

This keeps the current icon's two main features: the dark scissors and the pale glass-like enclosure. It removes only the effects that Apple now wants the system to render. If one foreground layer does not reproduce the present edge weight, a second scissors detail layer can add a controlled inner edge without changing the silhouette.

## Light, dark, clear, and tinted design

Apple says to keep the core visual features the same in every appearance. It advises using the light icon as the base for dark mode, keeping dark colors subdued, and checking that clear and tinted forms remain easy to recognize. The system can make missing variants, but Icon Composer lets the team tune each result. [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)

For Snip Snap, the scissors should not change shape or position between modes. The likely changes are limited to:

- Default: dark charcoal scissors on the current pale neutral background.
- Dark: lighter or midtone scissors on a darker neutral or restrained brand-color background. Apple advises against an overly bright dark icon and notes that a colored background often gives better contrast.
- Clear and tinted: a strong mono scissors silhouette with enough weight to survive transparency and the user's chosen tint.

These are design recommendations based on Apple's rules and the current icon, not platform requirements. Icon Composer previews should decide the exact fills, opacity, blur, refraction, and highlight settings.

## Icon Composer versus an asset catalog

Icon Composer is the right choice for a true Liquid Glass icon shared across Apple platforms. It adds material settings, lighting, platform changes, and all current appearances to one file. Xcode uses an `AppIcon.icon` file in place of an existing asset catalog named `AppIcon` when both names match. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

An asset catalog remains a valid fallback. iOS and iPadOS asset catalogs accept Any, Dark, and Tinted images; the tinted image is grayscale, and the dark image can have transparency for the system background. The system can also apply its own treatment when custom variants are absent. macOS asset catalogs still need the required size entries. This path can preserve the exact current flat Mac image, but it does not give the team Icon Composer's native layered material controls. [Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)

Apple warns that an Icon Composer file replaces the old icon asset catalog and that Xcode generates a similar-looking fallback for older operating systems. A project that must keep its exact old icon on old systems should stay with asset catalogs. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

Snip Snap already requires macOS 26 and plans to require iOS and iPadOS 26, so exact pre-Liquid-Glass output is not a release need. The shared `.icon` path fits those deployment choices. See [ADR 0004](adr/0004-require-macos-26.md) and [ADR 0022](adr/0022-require-ios-and-ipados-26.md).

## Xcode and operating-system fit

Apple introduced Icon Composer support in Xcode 26. Xcode builds fallback icon images from the `.icon` file when an app supports systems without the same Liquid Glass styles. The current standalone Icon Composer download requires macOS Tahoe 26.4 or later. [Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes), [Icon Composer](https://developer.apple.com/icon-composer/), [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

Local check: this Mac has Xcode 26.6 on macOS 26.6.2 and includes Icon Composer 1.6. That meets the current authoring requirement. The installed app also contains an undocumented `ictool` export command. Its help lists PNG output, but local export attempts could not open the valid icon document. Treat it as an optional check, not part of the main workflow.

## Xcode integration

Apple's documented steps are to add the `.icon` file to the Xcode project, include it with the app target, and set the target's App Icon field to the filename without `.icon`. The latest Xcode then chooses that file instead of an asset catalog with the same name. Each Snip Snap app target should point at the same `AppIcon` source so iPhone, iPad, and Mac share one identity. [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)

A sensible repo layout is one tracked `AppIcon.icon` package in a shared resources folder, referenced by both app targets. The plain SVG or PNG input layers should also remain tracked so contributors can inspect and revise the source without needing to extract it from the Icon Composer file. This layout is a project recommendation, not an Apple rule.

## App Store effects

The icon ships in the build. Apple accepts either an Icon Composer file or asset-catalog images, then uses the uploaded build's icon in App Store Connect, TestFlight, and system locations. A published icon change needs a new app version and review. [Add an app icon](https://developer.apple.com/help/app-store-connect/manage-app-information/add-an-app-icon)

Apple says the new rendered icon also appears on the App Store product page. All variants remain subject to App Review. The app must own the artwork rights, and its small, large, Watch, and alternate icons must stay consistent enough not to mislead people. [Say hello to the new look of app icons](https://developer.apple.com/videos/play/wwdc2025/220/), [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons), [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

No separate App Store artwork upload is needed for the main app icon after it is set in Xcode. The normal archive and upload path carries it. This does not change Snip Snap's signing, team, or open-source setup; the `.icon` file and its source art contain no account or team data.
