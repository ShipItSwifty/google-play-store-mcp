---
name: play-rollout
description: Advance, hold, or halt a Google Play staged rollout safely — read the current track, check recent reviews for the rolling version, confirm with the user, then change the fraction or halt, and verify the result. Use when the user asks to bump, increase, continue, pause, stop, or halt a Play rollout, or asks whether a rollout is safe to advance.
---

# Play staged rollout

Changes production state for real users. Every step below exists because skipping it has caused
a bad rollout before. Follow them in order.

## Preconditions

- The write tools (`play_update_rollout`, `play_halt_rollout`) only exist when the server runs with
  `GOOGLE_PLAY_ENABLE_WRITES=1`. If they are missing, stop and tell the user how to enable them
  (add the variable to the MCP server's `env`, or re-run `scripts/install-mcp.sh --writes`).
  Do not look for another way to change the rollout.
- You need the **packageName** and **track**. The track is almost always `production`, but confirm
  it.

## Steps

1. **Read.** Call `play_get_track` for the track. Find the `inProgress` release, its version codes,
   and its current `rollout=` percentage. If there is no `inProgress` release, say so and stop:
   there is nothing to advance or halt.
2. **Check signal.** Call `play_list_reviews` (`maxResults: 100`) and filter to the rolling
   version. Report the count, the average stars, and any new recurring complaint compared with the
   previous version. With fewer than ~10 reviews, say the signal is weak.
3. **Propose.** State the exact change: `production: 10% → 25%` or `halt at 10%`. Conventional
   ladders are 1% → 5% → 10% → 20% → 50% → full. Recommend holding if step 2 shows a regression.
4. **Confirm.** Get an explicit yes from the user for that exact package, track, and value. Never
   infer approval from an earlier message about a different step.
5. **Act.**
   - Advance: `play_update_rollout` with `userFraction` as a decimal, e.g. `0.25`.
   - Halt: `play_halt_rollout`. The fraction is preserved, so a later resume knows where it stopped.
6. **Verify.** Call `play_get_track` again and report the new state.

## Rules the API enforces

- `userFraction` is **exclusive**: `0 < f < 1`. `1.0` is rejected. A full rollout is a release
  with status `completed`, which these tools do not set. Tell the user to finish in the Play
  Console, or use `play_upload_and_release` with `status: completed` for a new artifact.
- Play **rejects lowering** a fraction. To reduce exposure, halt.
- Every write commits its own edit and cannot be undone through the API.
