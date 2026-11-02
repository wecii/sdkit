# React Native idioms

Rules that hold for any React Native app (bare or Expo, TypeScript or JavaScript). Navigation structure, state library and
design system belong in the project's own rules.

## Rendering and lists

- Long or unbounded lists use `FlatList` or `FlashList`, never `ScrollView` + `map`. Always give a stable `keyExtractor`
  (a domain id, never the index).
- Keep hot render paths cheap: extract the row into its own component and pass it no inline functions. No new style
  object/array literal per render in list rows; use your styling system's stable form (`StyleSheet.create` when the app
  uses StyleSheet; with utility classes such as NativeWind, static `className` strings, and only the *dynamic* values in
  `style`).
- Memoize (`memo`, `useCallback`, `useMemo`) where a profile shows a cost, not by default.
- Heavy work (parsing, sorting big arrays, crypto) stays off the JS thread: defer with `InteractionManager`, move to a
  native module or worklet.
- Remote images in lists get a fixed size (and on Expo, `expo-image`), so rows do not jump when the image loads.
- No `{count && <X />}` with a number: `0` renders as a bare string outside `<Text>` and crashes. Use `count > 0 &&` or a
  ternary. Every string sits inside `<Text>`.

## Styling and layout

- One styling system per app, used the same way everywhere. Colors, spacing and fonts come from the design tokens, never
  hard-coded values.
- `gap` for the space between siblings, padding for the space inside a container; a scroll view's padding goes in
  `contentContainerStyle`, not `style`.
- On the New Architecture use `boxShadow` instead of the legacy `shadow*` / `elevation` props.
- Screen size comes from `useWindowDimensions` (it updates on rotation and resize), not `Dimensions.get`.

## Animation and performance

- Animate only `transform` and `opacity`, on the UI thread (Reanimated or the native driver). Respect the system's
  reduce-motion setting.
- Judge performance only in a release build on a device, never in a debug build (or Expo Go).

## Screens and navigation

- Every screen that loads data handles all four states: loading, error (with a retry), empty, and content.
- Prefer the native stack and native tab navigators over JS reimplementations; they give native gestures and transitions.

## Platform

- Platform differences: on Expo, `process.env.EXPO_OS` (inlined at build time, so the other platform's branch is removed
  from the bundle); on bare React Native, `Platform.select` or `.ios.tsx` / `.android.tsx` files. Not scattered
  `Platform.OS` checks.
- Respect safe areas (`react-native-safe-area-context`). For the keyboard prefer a keyboard-aware scroll view over
  `KeyboardAvoidingView`.
- Ask for permissions at the point of use, with a rationale, and handle denial and "never ask again".

## Security and data

- The bundle is client code: no secrets, API keys with write power or private URLs in it. Tokens go in the secure store
  (Keychain/Keystore), not `AsyncStorage`.
- Never log tokens or personal data; strip `console.*` from release builds.

## Accessibility and navigation

- Interactive elements carry `accessibilityRole` and an `accessibilityLabel` when the visible text is not enough.
  Touch targets are at least 44x44 pt.
- Type the navigation params (route param list) and use the typed hooks; no `any` routes.

## Native and runtime

- A change to a native module, `ios/`, `android/` or app config needs a rebuild and a manual check on a device or
  simulator; `verify` does not cover it.
- New `react-native-*` dependencies with native code need a dev client rebuild (Expo) or `pod install` / Gradle sync (bare).
- Check Hermes and New Architecture (Fabric/TurboModules) compatibility before adding a native library.
