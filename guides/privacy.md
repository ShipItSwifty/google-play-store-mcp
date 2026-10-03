# Privacy policy

Last updated: October 3, 2026

This policy covers the `google-play-store-mcp` server and the Google Play Store plugin for
Claude Code. They are published by ShipItSwifty and owned by Arjang Consulting LLC.

## Summary

The software runs on your machine. We operate no server, receive no data from it, and include
no telemetry, analytics, or crash reporting. We cannot see your credentials, apps, or reviews.

## What the software does with your data

- **Credentials.** It reads the service account key file you select, or the standard credential
  environment variables, only on your machine. It signs a short-lived token locally and exchanges
  it with Google's token endpoint (normally `https://oauth2.googleapis.com/token`, taken from
  the key). The access token is held in process memory and is not written to disk.
- **Google Play data.** It sends authenticated requests to `https://androidpublisher.googleapis.com`
  and returns the results to the Claude session that called the tool. This can include release
  and track state, uploaded artifact metadata, and user reviews, which may contain reviewer
  names and review text.
- **Writes.** Write tools are off unless you enable them. When enabled, they can upload a build
  from a local file, publish a release, change or halt a rollout, or submit a Data safety CSV.
- **Optional federated sign-in.** If you configure GitHub Actions Workload Identity Federation,
  it also contacts GitHub's OIDC endpoint and Google's STS and IAM Credentials endpoints.
- **Storage.** It creates no database and does not persist Play data or credentials. Standard
  error may contain operational logs; they do not include credentials or review text.

## Third parties

- **Google** processes the requests above under your agreement with Google and its
  [privacy policy](https://policies.google.com/privacy).
- **Anthropic.** Tool results are returned to your Claude session. Anthropic's handling of that
  conversation content follows your Claude account's settings and
  [privacy policy](https://www.anthropic.com/legal/privacy).

We do not sell, share, or receive your data.

## Your choices

Remove the key file or disable the plugin to stop all access. Revoke the service account in the
Play Console or Google Cloud to cut off Google's side.

## Changes and contact

Changes are published in this repository with a new date. Questions or requests:
[GitHub issues](https://github.com/ShipItSwifty/google-play-store-mcp/issues).
