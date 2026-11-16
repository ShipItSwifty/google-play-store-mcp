# MCP tools

## Tool catalog

Read tools are always advertised. Write tools appear only when `GOOGLE_PLAY_ENABLE_WRITES=1` —
an agent exploring release state should not be one malformed argument away from changing a
production rollout.

"Kind" is whether it reads or changes Play state. "Live-verified" is how far it has been
exercised against a real Play Console account (see [Verification status](#verification-status)).

On connect, the server also sends the host a short set of **instructions**: start with
`play_release_overview`, the 7-day review window, the Data safety limitation, and whether writes
are enabled. Most hosts fold these into the agent's context, so the agent does not have to learn
them by failing a call.

Every tool returns a readable text summary **and** the same data as MCP `structuredContent`
(a JSON object such as `{"packageName": …, "tracks": [...]}`, using the Play API's own field
names). Models read the compact text; hosts and scripts that support structured output get exact
values without parsing it.

| Tool | Kind | Live-verified | What it answers |
|---|---|---|---|
| `play_release_overview` | read | built from verified reads | Tracks, rollout percentages, bundles, and APKs in one call (one edit); `limit` keeps the newest artifacts |
| `play_list_tracks` | read | yes | What is live on every track, and at what rollout percentage |
| `play_get_track` | read | yes | The same, for one track |
| `play_list_bundles` | read | yes | Which AABs have been uploaded (`limit` for the newest N) |
| `play_list_apks` | read | yes | Which APKs have been uploaded (`limit` for the newest N) |
| `play_list_reviews` | read | yes (filters and new fields mocked only) | Recent reviews with rating, date, device, OS, app version, and review id; filter by `minStars`, `maxStars`, `appVersionCode`, `unrepliedOnly` |
| `play_validate_edit` | read | yes | Would the app's current state pass Play's pre-commit checks |
| `play_update_rollout` | write | encoding only | Change the staged-rollout fraction |
| `play_halt_rollout` | write | encoding only | Halt an in-progress rollout, keeping its fraction |
| `play_resume_rollout` | write | mocked only | Resume a halted rollout at its fraction, or a new one |
| `play_complete_rollout` | write | mocked only | Take an in-progress or halted rollout to 100% |
| `play_promote_release` | write | mocked only | Release version codes from one track to another without re-uploading |
| `play_upload_and_release` | write | mocked only | Upload an AAB/APK and release it to a track |
| `play_reply_to_review` | write | mocked only | Publicly reply to a review, or replace the reply |
| `play_upload_data_safety_labels` | write | mocked only | Upload a Safety Labels CSV |

### Changes already in review

Every write that commits an edit (all of the above except `play_reply_to_review` and
`play_upload_data_safety_labels`) takes two optional arguments:

- `changesInReviewBehavior`: Play's own default **cancels changes already in review** and
  resubmits them with yours, which could quietly restart a teammate's store-listing review. These
  tools default to `errorIfInReview` instead, so the call fails and nothing changes. Pass
  `cancelInReviewAndSubmit` only once the user has agreed to cancel that review.
- `changesNotSentForReview`: set `true` when Play rejects a commit asking for it. The change is
  then held until someone sends it for review from the Play Console.

The libraries keep Play's default; see [Libraries](library.md).

### Reliability

Reads, track updates, and edit deletions are retried up to three times on a dropped connection,
`408`, `429`, and retryable `5xx` responses. Edit creation, commits, uploads, and replies are
never retried, since repeating them is not safe.

### Verification status

**built from verified reads**: `play_release_overview` makes the same `tracks`, `bundles`, and
`apks` requests as the list tools, just concurrently inside one edit. Rerun the live suite to
confirm it against your account.

**yes** — verified against a live Play Console account: authentication, tracks, bundles, APKs,
reviews, and a throwaway edit created and confirmed deleted.

**encoding only** — `play_update_rollout` and `play_halt_rollout` have their request encoding
verified live (a track `PUT` plus Play's pre-commit validation, inside an edit that is deleted
rather than committed), and their refusal path checked against a real track. Advancing or halting
a *real* staged rollout is still unproven — it needs an app with a live rollout to act on.

**mocked only** — `play_upload_and_release` end to end, `play_promote_release`,
`play_resume_rollout`, `play_complete_rollout`, `play_reply_to_review`, and
`play_upload_data_safety_labels` are proven only against mocked HTTP. The rollout and promotion
tools follow the request shapes in Google's
[track documentation](https://developers.google.com/android-publisher/tracks), but most of them need
an app with a staged rollout or a build to promote before they can be exercised live. Treat them
accordingly.

Run the live suite yourself — see [Live tests](development.md#live-tests).

### What the Play API cannot do

`applications.dataSafety` is **write-only**. There is no endpoint that reads back the current
published Data safety declaration, and none that distinguishes a published declaration from an
unpublished draft — verifying what is live has to happen in the Play Console UI. No MCP server
built on this API can answer that question.

Google also only returns reviews from roughly the last week. `play_list_reviews` follows Play's page
tokens for you, up to 500 reviews per call. With a filter it keeps paging past non-matching reviews,
scanning at most 2,000.

The Play Developer API has no crash or ANR data; that lives in Android vitals and the separate Play
Developer Reporting API, which this server does not call yet.

## Example prompts

- "What's live on every track for com.example.app?"
- "Is the 4.2.0 rollout healthy enough to go from 10% to 25%?" (read-only unless writes are enabled)
- "Summarize this week's 1- and 2-star reviews by theme and app version."
- "Which version codes are uploaded but not assigned to any track?"
- "Halt the production rollout." (needs `GOOGLE_PLAY_ENABLE_WRITES=1`; the agent should confirm first)
- "Promote what's on internal to production at 5%."
- "Draft replies to this week's unreplied 1-star reviews on version 412, and post the ones I approve."
