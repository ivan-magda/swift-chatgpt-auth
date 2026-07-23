# ChatGPTAuth

[![CI](https://github.com/ivan-magda/swift-chatgpt-auth/actions/workflows/swift.yml/badge.svg)](https://github.com/ivan-magda/swift-chatgpt-auth/actions/workflows/swift.yml)
[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS%20%7C%20Linux-blue.svg)](https://swift.org)
[![SPM Compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

ChatGPTAuth signs a Swift app in to ChatGPT and Codex with the device-authorization OAuth flow, then keeps a fresh bearer token in hand. You show a short code, and once the person approves it in a browser, you get back a credential that renews on its own before it expires.

```swift
import ChatGPTAuth

let client = ChatGPTOAuthClient(http: URLSessionHTTPClient())
let login = ChatGPTDeviceLogin(client: client)

let credential = try await login.run { device in
  print("Open \(ChatGPTOAuthConfiguration.codex.verificationURL) and enter \(device.userCode)")
}
```

## Table of Contents

- [Background](#background)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [How It Works](#how-it-works)
- [Project Structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)

## Background

ChatGPTAuth began as the sign-in layer of a production personal assistant that talks to Codex on a subscription token. That assistant runs as a background daemon, so it cannot lean on a browser redirect or the Keychain: it needs the device flow, and it needs a credential that renews without a human in the loop. This package lifts that layer out and adds seams so any Apple or Linux app can reuse it.

OpenAI publishes no discovery document for this flow, so ChatGPTAuth pins the endpoints and the Codex client id as constants derived from studying the official clients. They ship as `ChatGPTOAuthConfiguration.codex` and stay fixed unless you supply your own, so a subscription token only reaches the host you name.

## Features

- **Device-authorization login.** `ChatGPTDeviceLogin` runs the whole flow, from the first request to a stored credential, and reports the user code before it starts polling.
- **A credential that refreshes itself.** `ChatGPTCredentialSource` is an actor that hands out a fresh bearer per request and commits each rotation before it uses it, collapsing concurrent callers onto one in-flight refresh.
- **Bounded vendor values.** A token that carries whitespace, a control byte, or non-ASCII text never becomes a header, and the library strips terminal escapes and secrets from remote diagnostics before you see them.
- **Your transport, your storage.** The HTTP layer and the token store are protocol seams. A bundled `URLSessionHTTPClient` works out of the box; a test injects a scripted double instead.
- **Typed outcomes.** Login and refresh report a small closed set of errors that tell you what to do next: retry, wait, or log in again.
- **No third-party runtime dependencies.** Foundation and Swift Concurrency only.

## Requirements

- iOS 16.0+, macOS 13.0+, tvOS 16.0+, watchOS 9.0+, visionOS 1.0+, or Linux
- Swift 6.0+ / Xcode 16+

## Installation

### Xcode

In Xcode, open **File -> Add Package Dependencies…**, enter the repository URL, and add the `ChatGPTAuth` library to your target:

```
https://github.com/ivan-magda/swift-chatgpt-auth
```

### Package.swift

Add the package to your dependencies:

```swift
dependencies: [
  .package(url: "https://github.com/ivan-magda/swift-chatgpt-auth", from: "1.0.0")
]
```

Then add `ChatGPTAuth` to your target:

```swift
.target(
  name: "YourTarget",
  dependencies: [
    .product(name: "ChatGPTAuth", package: "swift-chatgpt-auth")
  ]
)
```

## Usage

### Log in with the device flow

```swift
import ChatGPTAuth

let client = ChatGPTOAuthClient(http: URLSessionHTTPClient())
let login = ChatGPTDeviceLogin(client: client)

let credential = try await login.run { device in
  // Show this to the person and send them to the verification page.
  print("Go to \(ChatGPTOAuthConfiguration.codex.verificationURL)")
  print("Enter code: \(device.userCode)")
}

try myStore.save(credential)
```

`run` returns once the person approves the code, or throws `ChatGPTOAuthFailure.deadlineExceeded` once the fifteen-minute window closes.

### Keep a fresh bearer for every request

Wrap the stored credential in a `ChatGPTCredentialSource` and let it authorize each call. It refreshes the token when it is close to expiring and hands the same result to every caller waiting on that one refresh:

```swift
let source = ChatGPTCredentialSource(
  initialCredential: try myStore.load(),
  store: myStore,
  oauth: client
)

var request = URLRequest(url: apiURL)
try await source.authorizeRequest(&request)
```

To let the source own the 401 loop as well — attach, send, and on a clean 401 refresh and retry once — hand it the send step. A second 401, spent against the freshly rotated token, latches the source and throws `ChatGPTCredentialError.authenticationRequired`:

```swift
let data = try await source.withAuthorization { authorization in
  var request = URLRequest(url: apiURL)
  authorization.apply(to: &request)
  let (data, response) = try await URLSession.shared.data(for: request)
  return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
}
```

A transport that does not speak `URLRequest` — a WebSocket handshake, gRPC metadata — reads the bearer and expiry directly instead of parsing headers:

```swift
let authorization = try await source.authorization()
connect(bearer: authorization.accessToken)   // expiry at authorization.expiresAt, informational
```

Driving the loop yourself? Report a 401 back with the generation the authorization carried, so a late failure from an older request can never invalidate a newer token:

```swift
await source.reject(generation: authorization.generation, disposition: .refresh)
```

To sign out, discard the credential through its owner — memory and store together:

```swift
try await source.logout()
```

### Provide a token store

The library never touches disk. Conform your own storage to `ChatGPTTokenStore`:

```swift
struct KeychainTokenStore: ChatGPTTokenStore {
  func load() throws(ChatGPTTokenStoreError) -> ChatGPTCredential? { /* ... */ }
  func save(_ credential: ChatGPTCredential) throws(ChatGPTTokenStoreError) { /* ... */ }
  func delete() throws(ChatGPTTokenStoreError) { /* ... */ }
}
```

### Test without the network

Every network call runs through `HTTPExecuting`, so a test injects scripted responses instead of a live transport:

```swift
struct StubHTTP: HTTPExecuting {
  let result: HTTPResult
  func execute(_ request: HTTPRequest) async throws -> HTTPResult { result }
}

let client = ChatGPTOAuthClient(http: StubHTTP(result: cannedTokenResponse))
```

## How It Works

1. **Start.** `requestDeviceCode` asks the vendor to begin an authorization and returns a user code plus the interval to poll at.
2. **Approve.** The person opens the verification page and enters the code.
3. **Poll.** `ChatGPTDeviceAuthorization` polls on its own clock, honoring the vendor's interval and any throttle, until the code is approved or the window closes.
4. **Exchange.** `ChatGPTDeviceLogin` spends the approved grant once at the token endpoint for an access and refresh token.
5. **Refresh.** `ChatGPTCredentialSource` measures each token against its expiry, redeems the refresh token before the access token lapses, and persists the rotation before spending it.

The wire client never verifies a token signature. It reads the `exp` and account claims to schedule a refresh and address the right account, and leaves the server to decide whether a token is valid.

## Project Structure

```
Sources/ChatGPTAuth/
├── OAuth/          # device flow, wire client, login facade
├── Credential/     # refreshing credential source, token store seam
├── Token/          # JWT claim reader
├── Metadata/       # pinned endpoints, timing, header builder
├── Wire/           # bounds and sanitizers for vendor values
├── Transport/      # HTTP seam and the URLSession default
└── Support/        # JSON, canonical encoding, redaction
```

## Contributing

Issues and pull requests are welcome.

```bash
swift build
swift test                          # deterministic suite
CHATGPTAUTH_LIVE_TESTS=1 swift test # opt-in: starts a real device authorization
swiftlint --strict                  # run before opening a PR
```

Tests use Apple's Testing framework and follow Given-When-Then.

## License

Released under the MIT License. See [LICENSE](LICENSE) for details.
