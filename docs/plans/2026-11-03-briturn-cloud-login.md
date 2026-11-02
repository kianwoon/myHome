# Briturn Cloud Login Implementation Plan

**Goal:** Add working Briturn Cloud sign-in and sign-out in MyHome Settings.

**Architecture:** A native Swift client reconstructs the verified Briturn email login and query signature. A separate settings section displays account state and saves only the resulting session in macOS Keychain. Existing Tuya and local Briturn control paths remain independent.

**Tech Stack:** SwiftUI, Foundation URLSession, CryptoKit MD5 for protocol compatibility, Security Keychain.

## Design decisions

Prefer native authentication over adding a second Python credential store or a nonfunctional login placeholder. Use US/EU/China region choices, masked saved email, progress/error states and local sign-out. Password is transient and never persisted. Scope is authentication, not device import/control.

## Steps

1. Add a MyHomeCore Briturn client with signed HTTPS requests, response validation and an allowlist for returned regional API hosts. Add Keychain session storage and safe errors.
2. Add offline tests with a mock HTTP transport: password hashing/signing, failed login, session parsing, untrusted regional host, persistence and sign-out. Add a SwiftPM test target.
3. Add the Briturn section to the existing Cloud settings form. Restore cached state; clear password on submission and handle progress, errors and sign-out.
4. Build/test Swift package, run required existing offline Python checks and update RELEASE.md and protocol notes. Produce a runnable local app bundle using the existing packaging workflow if available.

## Validation boundaries

Do not read existing account credential files or perform a real login. Successful account authentication must be verified by the owner in the app. Mock tests establish client behavior; the preceding credential-free configuration probe verified server reachability only.

## Completed validation

- Seven Swift authentication tests pass. Release build and app signing verification pass.
- Python suite passes with an isolated MYHOME_DATA_DIR: 123 tests, one skip. The default local-data run has two configuration-dependent Tuya fallback failures; no Python source was changed. Contrib smoke test passes.
- Installed the new bundle at /Applications/MyHome.app; verified its executable matches the built bundle. Previous bundle backed up in this chat workspace under work/MyHome-before-briturn.app.
- Confirmed live Settings accessibility controls: Briturn email, secure password, US region and disabled empty-form Sign In. macOS Passwords unlock prompt was left to the user. No real login was submitted.
