---
name: play-review-triage
description: Triage recent Google Play reviews for an Android app into themes (crashes, bugs, UX, feature requests, praise), tied to app version and device, with representative quotes and counts, and optionally draft replies for approval. Use when the user asks what users are saying, wants a review digest, is looking for regressions reported in Play Store reviews, or wants to reply to reviews.
---

# Play review triage

Read-only. Uses `play_list_reviews` from the `google-play-store` MCP server.

## Steps

1. Call `play_list_reviews` with the app's `packageName` and `maxResults: 500`. The tool pages
   through Play's results for you. If the user reads another language or the reviews are
   multilingual, pass `translationLanguage` (e.g. `en-US`). When the user only cares about a slice,
   filter on the server instead: `maxStars: 2` for complaints, `appVersionCode` for one build,
   `unrepliedOnly: true` for reviews still waiting on a reply.
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
6. **Replies (only if asked).** Draft a reply per review, under 350 characters, specific to what
   the reviewer reported. Show every draft with its review id and get explicit approval for each
   before calling `play_reply_to_review`. Replies are public immediately and replace any earlier
   reply. The tool exists only when writes are enabled.

## Limits to state

- Google only returns about the **last 7 days** of reviews. This is a recent snapshot, not the
  app's full history.
- Star averages over a handful of reviews are noise. Give the count next to every average.
- Reviews show the date they were last edited; a review edited this week may have been written
  earlier.
