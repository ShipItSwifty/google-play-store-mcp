---
name: play-release-check
description: Report what is live on Google Play for an Android app — every track, its release status and rollout percentage, the latest uploaded version code, and how the newest version is being received in recent reviews. Use when the user asks "what's live", "where is the rollout", "is the release healthy", or wants a pre/post-release status check for an Android package.
---

# Play release check

A read-only status report built from the `google-play-store` MCP tools. Nothing here changes Play
state.

## Inputs

- **packageName** (required), e.g. `com.example.app`. If the user did not give one, look for
  `applicationId` in `app/build.gradle(.kts)` or `package` in `AndroidManifest.xml` before asking.

## Steps

1. Call `play_release_overview` once. It returns tracks, bundles, and APKs from a single
   throwaway edit. Do not call `play_list_tracks`, `play_list_bundles`, and `play_list_apks`
   separately. Each of those opens its own edit.
2. Call `play_list_reviews` with `maxResults: 100`.
3. Build the report:
   - **Per track:** status (`completed`, `inProgress`, `halted`, `draft`), version codes, and
     rollout percentage. Flag any `halted` release, and any `inProgress` release on
     `production`.
   - **Artifacts:** the highest uploaded version code, and whether it is assigned to a track yet.
     An uploaded version code on no track usually means an unfinished release.
   - **Reviews:** group by app version. For the version that is rolling out, give the review count,
     average stars, and the two or three most repeated complaints with a short quote each. Compare
     it with the previous version when both have reviews.

## Caveats to state, not hide

- Reviews only cover roughly the **last 7 days**. A quiet week is not the same as no problems.
- Review counts during a small staged rollout are low. Say how many reviews a conclusion rests on.
- The Play API has no crash or ANR data (that lives in Android vitals / Play Console). Do not
  imply that stability was checked.
- Data safety cannot be read through the API. Point to the Play Console if it comes up.

## Output shape

Lead with one sentence: what is live on production and at what percentage. Then a short per-track
list, then the review summary. Keep it scannable.
