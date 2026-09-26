---
name: play-review-triage
description: Triage recent Google Play reviews for an Android app into themes (crashes, bugs, UX, feature requests, praise), tied to app version and device, with representative quotes and counts. Use when the user asks what users are saying, wants a review digest, or is looking for regressions reported in Play Store reviews.
---

# Play review triage

Read-only. Uses `play_list_reviews` from the `google-play-store` MCP server.

## Steps

1. Call `play_list_reviews` with the app's `packageName` and `maxResults: 500`. The tool pages
   through Play's results for you. If the user reads another language or the reviews are
   multilingual, pass `translationLanguage` (e.g. `en-US`).
2. Classify each review into one primary theme:
   - **Crash / won't open**
   - **Bug**: something specific is broken
   - **Performance**: slow, battery, size
   - **UX / confusion**
   - **Feature request**
   - **Account / billing**
   - **Praise**
3. For each theme, give the count, the average stars, the app versions and devices it shows up on,
   and one or two short verbatim quotes. Order by count × severity. Crashes and bugs on the newest
   version come first.
4. Call out anything that appears **only on the newest app version**. That is the likeliest
   regression.
5. Note which low-star reviews already have a developer reply (`↳ replied:`) and which do not.

## Limits to state

- Google only returns about the **last 7 days** of reviews. This is a recent snapshot, not the
  app's full history.
- Star averages over a handful of reviews are noise. Give the count next to every average.
- Replying to reviews is not supported by this server.
