# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build the package
swift build

# Run the deterministic test suite (Apple's Testing framework, not XCTest)
swift test

# Run the opt-in live test (starts a real device authorization against OpenAI)
CHATGPTAUTH_LIVE_TESTS=1 swift test

# Run SwiftLint (strict mode, as CI does)
swiftlint --strict

# Build in release mode
swift build -c release
```

## Architecture

ChatGPTAuth implements the ChatGPT/Codex device-authorization OAuth flow and a refreshing credential
source. It talks to a pinned set of endpoints over an injectable HTTP transport and never verifies a
token signature: the server stays the only party that decides whether a token is valid. It is scoped
to authentication only, so storage, scheduling, and the API calls a token authorizes belong to the
consuming app.

### Core Components

- **ChatGPTDeviceLogin / ChatGPTDeviceAuthorization**: run the device flow. `ChatGPTDeviceAuthorization` owns the login window and every wait; it is generic over `Clock` so a test drives the fifteen-minute window to its end without waiting. `ChatGPTDeviceLogin` composes authorization, token exchange, and credential minting into one call.
- **ChatGPTOAuthClient**: the stateless wire client (`requestDeviceCode`, `pollOnce`, `exchange`, `refresh`). Every value it returns has already cleared the bounds a header and a terminal impose.
- **ChatGPTCredentialSource** (`actor`): the live credential. One owner of the stored pair, one refresh in flight at a time, generation-tracked rejection, and a crash-safe commit point. Its state types live in `ChatGPTCredentialSourceModels.swift`.
- **ChatGPTTokenStore / ChatGPTCredential**: the persistence seam and the stored pair. A single credential per store.
- **ChatGPTTokenMetadata**: reads the unverified `exp` and account claims from an access token's JWT payload. Never authorization.
- **HTTPExecuting / URLSessionHTTPClient**: the transport seam and the bundled default. Auth never streams, so the seam is buffered-only.
- **ChatGPTOAuthConfiguration**: the endpoints and client id, defaulting to `.codex`.

Sources are grouped under `OAuth/`, `Credential/`, `Token/`, `Metadata/`, `Wire/`, `Transport/`, and `Support/`.

### Platform Requirements

- iOS 16.0+, macOS 13.0+, tvOS 16.0+, watchOS 9.0+, visionOS 1.0+, and Linux
- Swift 6.0+ (strict concurrency, typed throws)
- No third-party runtime dependencies (`swift-docc-plugin` is a build-tool plugin for docs only)

### Testing

Tests use Apple's `Testing` framework in two tiers:

- **Deterministic (default):** the whole flow driven through a scripted `HTTPExecuting`, a manual `Clock`, an in-memory `ChatGPTTokenStore`, and scripted refreshers. These run anywhere the package builds and never touch the network.
- **Live (opt-in via `CHATGPTAUTH_LIVE_TESTS=1`):** starts a real device authorization against the vendor endpoint, which needs no credentials and no approval.

Shared test doubles live in `TestHelpers.swift`.

## Code Style

SwiftLint enforced with `--strict` (no swift-format). Key rules:

- 2-space indentation; line length 120 warning / 150 error
- Opt-in rules include `force_unwrapping`, `implicit_return`, `conditional_returns_on_newline`, `trailing_closure` — no trailing commas in collection literals
- Tests follow Given-When-Then (`// given` / `// when` / `// then`)
