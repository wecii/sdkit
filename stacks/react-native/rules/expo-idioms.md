# Expo idioms

Rules for apps that depend on `expo` (Expo Router, prebuild or a dev client). A bare React Native app can delete this
file. The generic React Native rules are in `rn-idioms.md`; which screens, sheets and native modules the app has belong
in the project's own rules.

## Navigation and headers

- Configure native Stack headers in the layout (`_layout.tsx`, `<Stack.Screen options={...}>`), not by rendering a
  custom header inside each screen.
- A title that depends on loaded data is set with `navigation.setOptions` inside `useLayoutEffect`, so it is applied
  before the first paint instead of flashing the static title.

## Sheets (`presentation: 'formSheet'`)

- Mount the sheet's single scroll container from the first render and keep it for the sheet's lifetime. Never swap the
  root between a `View` (loading) and a `ScrollView` (loaded): iOS binds the sheet's drag gesture to the scroll view
  that exists when the sheet is presented, so a later one does not scroll or dismiss properly. Show the loading state
  inside the scroll container.
- A short sheet sized with `sheetAllowedDetents: 'fitToContents'` uses a non-scrolling body. A scroll view there can keep
  a stale offset and leave buttons visually in place but untappable.

## Edge-to-edge Android

- With edge-to-edge on Android, the bottom-most scroll container adds the bottom safe-area inset (in
  `contentContainerStyle`), on Android only. On iOS `contentInsetAdjustmentBehavior="automatic"` already pads it;
  adding the inset there too doubles the space.

## Hermes and Intl

- Hermes does not implement every `Intl` API (for example `Intl.DisplayNames`). Before using one, either add a polyfill
  (the formatjs packages, imported first in the entry file) or use a static lookup table. Check it in a release build.

## NativeWind

- Do not toggle `transform`, shadow, `transition` or `ring` classes on re-render (`className={cond ? 'scale-95' : ''}`):
  the class change can crash the app (expo/expo#38423). Put those values in `style`, or animate them with Reanimated.
  Static classes are fine.

## Images (`expo-image`)

- On Android keep the `Image` node mounted in every state (loading, error, loaded). Render a placeholder as an absolute
  overlay on top of it instead of swapping the image for another element, and set `recyclingKey` when the image sits in
  a recycled list row, so a reused row does not show the previous item's image.

## Native changes and builds

- A change to `app.json` / `app.config.*` plugins, native `ios` / `android` keys, or a dependency with native code needs
  `npx expo prebuild` and a run on a device or simulator. `verify` does not cover it.
- Keep native-pinned dependencies on the versions `npx expo install --check` expects for the SDK; compile a Release build
  before merging a change to them, debug builds hide some failures.
