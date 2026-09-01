# foodtruck

A hello-world macOS app that exists to prove one thing end to end: **a public
GitHub repo can ship a signed, notarized `.dmg` without ever touching a macOS
runner, a self-hosted runner, or an Apple credential.**

Push a `release/vX.Y.Z` branch, and a signed `.dmg` appears on a draft release a
few minutes later. That's the whole product.

```
git switch -c release/v0.1.0 main
git push -u origin release/v0.1.0
```

## Why it's built this way

GitHub's guidance on self-hosted runners is blunt: they
[*"should almost never be used for public repositories"*](https://docs.github.com/en/actions/reference/security/secure-use),
because anyone can open a pull request and a self-hosted runner "can be
persistently compromised by untrusted code in a workflow." Signing a macOS app
needs a Mac, and Apple's Developer ID keys have to live somewhere. Putting both
on a public repo is the exact thing that warning is about.

So the Mac and the Apple secrets live in **`stuffbucket/macos-builder`**, a
private repo. This repo sends a dispatch and gets artifacts back. Every job here
runs on `ubuntu-latest` and builds nothing.

```
  foodtruck (PUBLIC)                      macos-builder (PRIVATE)
  ┌────────────────────────────┐          ┌──────────────────────────────────┐
  │ push release/v0.1.0        │          │ self-hosted Mac + Apple keychain │
  │        │                   │          │                                  │
  │        ▼                   │          │                                  │
  │ release-cut.yml            │          │ build.yml                        │
  │  ubuntu-latest             │          │  ├─ sanitize repo/ref            │
  │  ├─ assert commit is on main          │  ├─ check allowlist + policy     │
  │  ├─ create tag v0.1.0      │          │  ├─ mint app-repoman token       │
  │  ├─ create DRAFT release   │          │  │    (1 hour, foodtruck only)   │
  │  └─ dispatch ──────────────┼─────────►│  ├─ checkout foodtruck @ v0.1.0  │
  │       MACOS_BUILDER_PAT    │          │  ├─ run .macos-builder/build.sh  │
  │                            │          │  ├─ sign → dmg → notarize →      │
  │                            │          │  │   staple → sha256            │
  │  draft release assets  ◄───┼──────────┼──┘ upload via app token          │
  │   foodtruck-0.1.0-…dmg     │          │                                  │
  └────────────────────────────┘          └──────────────────────────────────┘
```

The release is left as a **draft** on purpose. GitHub's immutable releases reject
asset uploads after publish (HTTP 422), so the `.dmg` has to land while the
release is still mutable. Publishing stays a deliberate human step.

## The two auth hops

They are deliberately different, and the difference is the interesting part.

**builder → foodtruck** (clone at the tag, upload the `.dmg`). No credential is
stored here at all. The builder signs a JWT with the `app-repoman` GitHub App's
private key — which never leaves the private repo — and mints an installation
token scoped to `foodtruck` alone, valid for one hour. This repo only needs the
App *installed* on it with Contents: read+write.

**foodtruck → builder** (start the build). This one needs a stored credential,
because a workflow's built-in `GITHUB_TOKEN` only works on its own repo and
GitHub's API doesn't accept OIDC tokens as auth. So `MACOS_BUILDER_PAT` is a
fine-grained PAT whose entire power is *Actions: write on
`stuffbucket/macos-builder`*. It cannot read this repo's secrets, cannot reach
any other repo, and cannot touch the Apple credentials.

A GitHub App would be **worse** here, not better: minting an App token requires
the App's private key, and a private key on a public repo can mint tokens for
every repo that App is installed on. A deploy key can't do it at all — deploy
keys are git transport only and cannot call the Actions API.

To mint or rotate the PAT: **github.com/settings/personal-access-tokens/new**,
signed in as `stuffbucket` → Resource owner `stuffbucket` → Only select
repositories → `stuffbucket/macos-builder` → Repository permissions → **Actions:
Read and write**. Nothing else.

If the secret is absent or expired, `release-cut.yml` still creates the tag and
draft release, then prints the manual dispatch command instead of failing.

## Why a fork can't steal the token

> "With the exception of `GITHUB_TOKEN`, secrets are not passed to the runner when
> a workflow is triggered from a forked repository."
> — [Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)

Fork a repo, edit a workflow to print the secret, open a PR — the secret isn't
there. This is platform behaviour, not configuration.

The protection has exactly two escape hatches, `pull_request_target` and
`workflow_run`, which run in the *base* repo's context *with* secrets. CI fails
the build if either ever appears in `.github/workflows/`. Same for a `macos` or
`self-hosted` runner, and for any reference to Apple credentials.

## Layout

| Path | What it is |
| --- | --- |
| `src/main.swift` | The app. AppKit window, no dependencies. |
| `src/Info.plist` | Bundle metadata. `CFBundleIdentifier` must equal the builder-side policy. |
| `.macos-builder/config` | Declarative build config the builder reads. |
| `.macos-builder/build.sh` | The **producer**: builds `dist/FoodTruck.app` and stops. |
| `.github/workflows/release-cut.yml` | Push `release/v*` → tag, draft release, signed dmg. |
| `.github/workflows/macos-build.yml` | Manual rebuild of an existing tag. |
| `.github/workflows/ci.yml` | The guardrails above, plus shellcheck/zizmor/config validation. |

## The producer contract

`.macos-builder/build.sh` builds the `.app` at `app_path` and **stops**. It does
not sign the top-level bundle, build a `.dmg`, notarize, or staple — the builder
owns that entire tail, and never hands the producer `APPLE_*` or
`KEYCHAIN_PASSWORD`.

It runs standalone, so the code path proven on a laptop is the one the signing
Mac runs:

```bash
TAG=v0.0.0-local ./.macos-builder/build.sh
open dist/FoodTruck.app
```

## Building on the builder side

The builder refuses to build a repo with no approved policy. `foodtruck`'s lives
at `clients/stuffbucket/foodtruck.policy` in `macos-builder` and is written only
by an approved `build-config` issue — never hand-edited:

```
bundle_id_allowed    = co.stuffbucket.foodtruck
entitlements_allowed = default
artifact_allowed     = dmg
```

`entitlements = default` means hardened runtime with no added capabilities.
Clients pick a profile **by name** from a builder-owned menu and can never supply
an arbitrary entitlements file.

## Verifying a build

```bash
gh release download v0.1.0 --repo stuffbucket/foodtruck --pattern '*.dmg*'
shasum -a 256 -c foodtruck-0.1.0-darwin-arm64.dmg.sha256
codesign --verify --deep --strict --verbose=2 /Volumes/FoodTruck/FoodTruck.app
spctl -a -t open --context context:primary-signature foodtruck-0.1.0-darwin-arm64.dmg
xcrun stapler validate foodtruck-0.1.0-darwin-arm64.dmg
```
