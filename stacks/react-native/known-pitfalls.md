# Known pitfalls

Bug classes that have already cost this project an incident. The independent verifier checks every diff
against this list. Add entries with the `incident-to-rule` skill. Each entry: symptom, root cause, how to spot it in a diff.

The entries below are a React Native / Expo seed: keep the ones that match your app's libraries, delete the rest.

## FlashList v2 `onEndReached` guarded by a "has scrolled" ref
- **Symptom:** pagination stops: the next page never loads, often only when the first page is short.
- **Root cause:** FlashList v2 fires `onEndReached` when the end edge is crossed, not on every scroll. If the first call
  is ignored because a "user has scrolled" ref is still false, the edge is never crossed again and nothing retries.
- **Spot it:** an `onEndReached` handler that returns early on a ref or flag set in `onScroll`. Fix: guard only on
  "already loading" and "no more pages".

## FlatList `getItemLayout` with a list header, or `maintainVisibleContentPosition` on Android
- **Symptom:** `scrollToIndex` / `initialScrollIndex` lands a few rows off; on Android the initial scroll position drifts.
- **Root cause:** the offsets from `getItemLayout` do not include the `ListHeaderComponent` height, and
  `maintainVisibleContentPosition` shifts the Android initial scroll as content is laid out.
- **Spot it:** `getItemLayout` that computes `offset: ITEM * index` while the list also has a header; a new
  `maintainVisibleContentPosition` together with `initialScrollIndex`. Fix: add the header height to the offset; avoid the
  combination on Android.

## Android ScrollView keeps a stale offset when content shrinks
- **Symptom:** after a filter or a state change the screen looks empty or cut off until the user scrolls.
- **Root cause:** on Android a `ScrollView` keeps its scroll offset when its content gets shorter than that offset.
- **Spot it:** content of a scroll view that can shrink (filters, tabs, a loading state replacing a long list) with no
  scroll reset. Fix: `scrollTo({ y: 0 })` when the content changes, or a `key` that remounts the scroll view.

## Yoga stretch with `justify-between` / `mt-auto` on Android
- **Symptom:** a footer or button sits in the wrong place on Android (fine on iOS); it moves after a re-render.
- **Root cause:** with `items-stretch` and `justify-between` or `mt-auto`, Android aligns children from the first layout
  pass's height, before the stretched height is known.
- **Spot it:** a column with stretched children and `justify-between` / `mt-auto` whose height comes from its content.
  Fix: give the container a definite height (`flex-1` from a sized parent) or position the footer explicitly.

## `setTimeout` to sequence navigation
- **Symptom:** dismiss-then-push flows work on a fast device and fail (or push onto the wrong stack) on a slow one.
- **Root cause:** a timeout guesses how long the dismiss animation takes; nothing ties the push to the dismiss finishing.
- **Spot it:** `router.back()` / `dismiss()` followed by `setTimeout(() => router.push(...))`. Fix: navigate in one call
  (`router.replace`, `dismissTo`), or push from the transition end event.
