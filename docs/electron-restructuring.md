# Possible Electron Restructuring

## Status

This document records a possible architecture, not an accepted migration decision.
Its purpose is to preserve the boundary and safety decisions that should guide any
future Electron implementation.

## Motivation

FoodTruck is growing beyond a collection of native status panes. Its interface is
becoming a combination of:

- an optional-software catalog;
- a desired-state editor;
- a plan reviewer;
- an operation monitor;
- a configuration-history browser;
- and a diagnostics surface.

Those are web-application interaction patterns. A reusable web interface could run
inside a standalone Electron application and also be embedded in a larger Electron
product. The existing Swift implementation, however, already contains the machine
inspection, policy enforcement, and convergence behavior that must not be casually
reimplemented in presentation code.

The proposed restructuring therefore separates presentation, application lifecycle,
and execution authority. It also keeps the frontend independent of the engine
language so that retaining Swift and moving the backend to TypeScript remain
independent decisions.

## Goals

- Ship FoodTruck as a standalone desktop application.
- Allow a larger Electron application to embed the same FoodTruck interface.
- Keep the renderer reusable and independent of Electron APIs.
- Preserve the existing CLI.
- Maintain one implementation of settings, planning, convergence, inventory, and
  safety policy.
- Preserve plan-before-apply behavior and make mutation approval explicit.
- Stream structured operation progress and support reliable cancellation.
- Keep diagnostics available without making them the primary user experience.
- Permit a future backend implementation in either Swift or TypeScript.
- Leave room for platform-specific Linux and Windows implementations.

## Non-goals

- Exposing arbitrary shell execution to a renderer.
- Letting a renderer choose filesystem roots, environment variables, blast ceilings,
  or recipe locations.
- Rewriting the native engine as part of the initial UI migration.
- Installing a global daemon or opening a network listener.
- Downloading native helpers during application startup or npm installation.
- Treating DOM component isolation as a security boundary.
- Making an App Store-style package catalog bypass desired state or plan review.

## Current boundaries

The Swift package already provides a useful starting boundary:

- `FoodTruckKit` contains models, settings, Inventory, recipes, the Kitchen, engines,
  subprocess execution, localization, and self-tests. It does not import SwiftUI or
  AppKit.
- `FoodTruck` combines the command-line interface and SwiftUI application in one
  executable.
- `AppModel` contains both presentation state and consequential application behavior,
  including startup housekeeping, operation selection, Inventory recording, and
  history notices.
- `OperationSettings` is shared application logic but currently lives in the
  executable target.
- Kitchen operations currently return completed results rather than a stream of
  lifecycle events.
- subprocess output is buffered, and timeout or cancellation does not yet guarantee
  termination of an entire descendant process tree.

Before introducing Electron, application behavior should be extracted from the
SwiftUI model so every interface uses the same lifecycle decisions.

The repository also has two divergent application-building paths:

- `scripts/make-app.sh` assembles the current SwiftPM application and resources.
- `.macos-builder/build.sh` still assumes the old flat `src/main.swift` application
  and explicitly assumes there are no nested Electron frameworks or helper apps.

There should be one authoritative production baseline before Electron packaging is
introduced.

## Proposed architecture

```text
@foodtruck/renderer
        |
        v
@foodtruck/client
        |
        v
Electron preload / main adapter
        |
        v
FoodTruck engine protocol
        |
        v
foodtruck-helper
        |
        v
FoodTruck application service
        |
        v
FoodTruckKit and recipe engines
```

The protocol is the durable boundary. Swift can provide the first engine
implementation without becoming part of the renderer's public API. A TypeScript
engine may later implement the same contract if behavioral and safety parity can be
proven.

## Native target structure

An initial Swift-backed implementation could use these targets:

| Target | Responsibility |
| --- | --- |
| `FoodTruckKit` | Existing domain models, settings, Inventory, Kitchen, engines, and subprocess execution. No RPC or Electron knowledge. |
| `FoodTruckApplication` | Operation lifecycle, settings resolution, recipe loading, housekeeping, planning, convergence, Inventory recording, and event emission. |
| `FoodTruckProtocol` | Versioned request, response, event, and error data-transfer objects. It must not expose internal model layout accidentally. |
| `foodtruck-helper` | Foundation-only persistent helper. It owns protocol framing, operation registration, cancellation, and graceful shutdown. |
| `foodtruck` | Independent CLI using `FoodTruckApplication`. |
| SwiftUI application | Temporary adapter during migration; removable after Electron reaches parity. |

`AppModel` should become a thin UI adapter while it exists. Application decisions
must not be reimplemented independently by the CLI, SwiftUI, Electron main process,
or renderer.

## TypeScript and Electron package structure

```text
packages/
  protocol/
  client/
  renderer/
  electron-main/
  electron-preload/
  native-darwin-arm64/
  native-darwin-x64/

apps/
  desktop/

fixtures/
  embedder/
```

### `@foodtruck/protocol`

- Canonical TypeScript wire types.
- Runtime validators and JSON Schema where useful.
- Protocol version and golden fixtures.
- No Electron, Node, or UI dependency.

### `@foodtruck/client`

- Framework-independent client interface.
- Operation state machine.
- Transport injection for real, fake, or future transports.
- No global lookup of Electron APIs.

### `@foodtruck/renderer`

- Reusable web UI and styles.
- Receives a `FoodTruckClient` explicitly.
- Contains presentation state only.
- Does not import Electron or Node.
- Can be mounted inside the standalone application, an embedding application, or a
  component-test harness.

React is a practical implementation choice if it is declared as a peer dependency.
A non-React host can mount FoodTruck in an isolated React root.

### `@foodtruck/electron-main`

- Resolves and launches the packaged helper.
- Supervises helper health and shutdown.
- Owns NDJSON transport and Electron IPC registration.
- Binds operations to their initiating `webContents`.
- Enforces host-supplied authorization policy.
- Fails closed if an embedding host does not configure mutation authorization.

### `@foodtruck/electron-preload`

- Exposes a narrow, versioned API through `contextBridge`.
- Validates arguments before forwarding them.
- Removes Electron event objects from callbacks.
- Does not expose `ipcRenderer` or a generic invocation mechanism.
- Can be composed into an embedding application's existing preload.

### `apps/desktop`

The standalone composition root owns BrowserWindow construction, menus, CSP,
updating, appearance, and adapter configuration. It contains no domain policy.

### `fixtures/embedder`

A minimal, unrelated Electron host proves that the renderer, preload, adapter, and
helper do not depend on globals or assumptions belonging to the standalone app.
This fixture should exist before the complete renderer is ported.

## Renderer-facing API

The bridge should expose product operations rather than generic process or RPC
access:

```ts
interface FoodTruckClient {
  initialize(input: { locale: string }): Promise<FoodTruckSnapshot>
  getCatalog(): Promise<Catalog>
  getState(): Promise<MachineState>
  startAudit(): Promise<{ operationId: string }>
  preparePlan(input: { recipeIds: string[] }): Promise<ConvergePlan>
  startConverge(input: {
    recipeIds: string[]
    approvalId: string
  }): Promise<{ operationId: string }>
  cancel(input: { operationId: string }): Promise<{ accepted: boolean }>
  subscribe(listener: (event: OperationEvent) => void): () => void
}
```

It must not expose:

- `runCommand`;
- arbitrary paths;
- raw environment variables;
- recipe creation;
- renderer-controlled execution limits;
- or a generic `invoke(method, parameters)` escape hatch.

Optional-package choices are desired-state edits. Selecting **Add to setup** updates
the draft configuration and plan; it does not directly invoke a package manager.

## Engine protocol

A persistent helper using JSON-RPC 2.0 semantics with one UTF-8 JSON object per line
is a suitable initial transport:

- stdin carries requests and notifications to the helper;
- stdout contains protocol messages only;
- stderr contains bounded native diagnostics;
- both ends enforce line and message-size limits;
- startup negotiates protocol, product, and capability versions;
- operation-start responses are delivered before lifecycle notifications;
- every event includes an operation identifier and monotonic sequence number.

Initial methods can include:

- `initialize`;
- `catalog.get`;
- `state.get`;
- `operation.start` for bootstrap, audit, plan, or converge;
- `operation.cancel`;
- `operation.status`;
- and `shutdown`.

Suggested lifecycle events:

```text
operationQueued
operationStarted
waveStarted
recipeStarted
recipeCompleted
diagnostic
operationCompleted
operationFailed
operationCancelled
```

Every operation emits exactly one terminal event. Diagnostics should be bounded and
coalesced so a noisy recipe cannot block the protocol or exhaust renderer memory.
Large internal Inventory attachments remain native unless a specific view requests a
bounded projection.

## Planning and approval

Planning and execution are separate operations:

1. The engine observes current state.
2. The engine computes a plan against a specific configuration revision.
3. The UI presents exact actions, scope, blockers, and destructive effects.
4. Electron main creates a short-lived approval bound to the plan, caller, and recipe
   set.
5. The backend reloads and validates the plan before execution.
6. Execution produces structured progress and a final verification result.

A renderer-provided blast ceiling or approval flag is never authoritative. Approval
is minted and consumed by the trusted host process. Mutating operations should be
disabled when an embedding host supplies no authorization policy.

## Cancellation and process lifecycle

The current process layer needs explicit cancellation work before it is suitable for
an operation-monitor UI:

1. The application service stores each top-level task.
2. Cancellation is idempotent and calls `Task.cancel()` or the equivalent backend
   primitive.
3. Kitchen stops scheduling new recipes and waves after cancellation.
4. subprocesses run in process groups or platform equivalents.
5. timeout and cancellation terminate descendants, not only the immediate process.
6. the UI remains in a `cancelling` state until the backend emits
   `operationCancelled`.
7. a helper crash fails every active operation; mutating operations are never retried
   automatically.
8. stdin EOF cancels active work and begins graceful helper shutdown.

A single serialized top-level operation is the safest initial policy. Kitchen may
retain concurrency within one audit or dependency wave.

## Security boundaries

- The renderer is untrusted presentation code.
- Preload is a narrow marshalling boundary.
- Electron main owns authorization and operation ownership.
- The helper or backend process owns execution safety.
- Recipe trust, path containment, environment sealing, scan ceilings, process limits,
  and blast ceilings remain backend concerns.
- The helper runs with the user's privileges; hardened runtime is not an App Sandbox.
- The helper path, resource path, environment, and working directory are supplied by
  trusted host configuration, never renderer input.
- Unknown methods, enum values, duplicate identifiers, unsupported versions,
  oversized messages, and malformed data fail closed.
- Logs are bounded and control characters are stripped before they reach renderer
  state.

The standalone Electron window should enable context isolation and renderer
sandboxing, disable Node integration, use a restrictive CSP and local origin, deny
navigation, deny new windows, and use a deny-by-default permission handler.

A context bridge is visible to every script in its renderer. If a larger application
loads remote or otherwise untrusted content, FoodTruck must run in a dedicated local
`WebContentsView` or BrowserWindow. DOM or component isolation alone is not a
security boundary.

## Localization

Domain localization can remain in the engine initially. Wire messages can carry:

```json
{
  "key": "finding.inventory.shimShadowed",
  "args": {},
  "localized": "The same commands appear through two installations."
}
```

The renderer owns interface chrome such as **Library**, **My Setup**, and **Review
plan**. The engine owns recipe, finding, fault, and remedy language. This preserves
stable diagnostic keys and the current localization validation while the frontend is
migrated.

A future TypeScript engine may move domain localization without changing protocol
semantics.

## Backend language

Swift is not inherently required. Node and TypeScript can implement settings,
planning, filesystem discovery, Git history, process execution, cryptographic
verification, and the engine protocol.

Retaining Swift for the initial migration is a risk decision:

- the current safety behavior and self-tests remain in force;
- the independent native CLI remains small and usable without Node;
- the Electron UI can ship without simultaneously rewriting host mutation behavior.

The protocol must therefore be implementation-neutral. A later TypeScript engine can
replace Swift by passing the same black-box fixtures and mutation tripwires. The
transition should require equivalent behavior for containment, protected-path
refusal, incomplete snapshots, environment isolation, signature verification,
process-tree cancellation, plans, and history.

If a TypeScript engine is selected from the start, it should still run in a separate
backend process rather than in the renderer or directly as application-domain logic
inside Electron main.

## Platform portability

Swift supports Linux and Windows, but the current implementation is macOS-specific.
Portable domain behavior should be separated from platform adapters:

```text
FoodTruckCore
FoodTruckPlatformDarwin
FoodTruckPlatformLinux
FoodTruckPlatformWindows
```

A platform adapter owns canonical path handling, process execution, host inventory,
package-provider discovery, and protected locations. Windows requires a genuine
implementation for drive and UNC paths, reparse points, PATHEXT, registry/package
evidence, and job-object cancellation; it is not a conditional-import variation of
the POSIX implementation.

The same adapter boundary applies if the engine is TypeScript. Native CI workers
should build and test each supported target rather than relying on one macOS host to
cross-compile every release.

## State and concurrency

A standalone FoodTruck and an embedded FoodTruck may run simultaneously against the
same XDG state. The backend needs a cross-process mutation lock around:

- convergence;
- desired-state writes;
- Inventory snapshot recording;
- and Git-backed history.

Read-only audits may remain concurrent where safe. Giving each host an implicit
private state root would fragment FoodTruck's understanding of the machine; a
host-specific root should be an explicit trusted configuration choice.

## Packaging

### Native helper

The helper and immutable Cookbook/localization resources should be copied outside
ASAR through `extraResources`. The helper is resolved from `process.resourcesPath`,
launched by canonical absolute path with `shell: false`, and receives an explicit
resource root. Runtime reliance on `Bundle.main` is unsafe once the executable lives
inside another application's Resources tree.

Recommended distribution options are prebuilt, architecture-specific helper packages
or a universal helper. Avoid postinstall downloads, runtime extraction to mutable
temporary directories, native Node addons, and discovery of an independently
installed FoodTruck application.

### Electron bundle

Electron Builder or Electron Packager can assemble an unsigned application. Signing,
notarization, release artifact creation, and publishing should remain in the private
builder so the public repository never receives Apple credentials or arbitrary
entitlement authority.

Electron invalidates the current flat-bundle signing assumption. The private builder
must sign nested code inside-out:

1. Electron Framework and Chromium helper apps;
2. native modules, if introduced;
3. `foodtruck-helper` with ordinary hardened-runtime entitlements;
4. the outer Electron executable and application last.

Electron's JIT entitlements should not be applied to the Swift helper. `codesign
--deep` is useful for verification, not as the signing strategy. The final immutable
bundle is notarized only after all nested signatures are complete.

For embedding, the consuming host owns final signing and notarization. FoodTruck's npm
packages provide native artifacts and integration code but do not independently sign,
notarize, or update the host application.

## Testing

### Native or backend

- Preserve the current sealed self-tests and host-mutation tripwire.
- Add application-service tests covering housekeeping, Inventory recording, operation
  selection, and CLI/GUI/helper parity.
- Test event ordering and exactly one terminal event.
- Test timeout, explicit cancellation, helper death, and descendant-process cleanup.
- Test malformed and oversized protocol messages, unsupported versions, duplicate
  identifiers, and stdout purity.
- Continue relocating the complete test world through `Locations`.

### Protocol and Electron integration

- Share canonical JSON fixtures between backend and TypeScript tests.
- Test arbitrary stream chunking, partial lines, CRLF, invalid UTF-8, stderr, and EOF
  inside a message.
- Use a fake helper to test handshake timeout, crash, stale responses, unknown events,
  backpressure, and cancellation races.
- Test multi-window ownership and cleanup after `webContents` destruction.
- Verify that preload exposes only the documented API.

### Renderer

- Use a fake `FoodTruckClient` for component tests.
- Cover clean, drift, blocked, failed, cancelling, cancelled, helper-crash, and
  protocol-mismatch states.
- Test keyboard operation, focus movement, announcements, busy states, and reduced
  motion.
- Run visual regression tests without a native helper.

### Packaged integration

Maintain two packaged fixtures:

1. the standalone Electron application;
2. a minimal unrelated Electron host embedding FoodTruck.

For each supported architecture, verify relocation away from the checkout, helper and
resource presence outside ASAR, signatures, entitlements, Gatekeeper/notarization,
operation streaming, cancellation, graceful shutdown, and independence from source,
Swift build, and npm workspace directories.

## Migration sequence

### Stage 0: establish one production baseline

- Make the current SwiftPM application path authoritative.
- Retire the old `src/main.swift` producer.
- Align bundle identity, deployment target, architecture, and resources.
- Capture packaged smoke tests before changing the bundle shape.

### Stage 1: extract application behavior

- Add the application-service boundary.
- Move settings resolution, housekeeping, operation selection, Inventory recording,
  and lifecycle behavior out of SwiftUI and the CLI entrypoint.
- Adapt both current interfaces to the service.
- Add structured events and correct process-tree cancellation.

### Stage 2: add the helper and protocol

- Define explicit versioned wire DTOs.
- Implement initialization, catalog, state, audit, plan, converge, cancellation, and
  shutdown.
- Add protocol fixtures and process-level integration tests.

### Stage 3: prove embedding

- Build the TypeScript protocol, client, main adapter, and preload packages.
- Build the minimal embedding fixture before the standalone renderer.
- Verify operation ownership, host authorization, crash handling, and helper
  relocation.

### Stage 4: port the renderer

- Implement Overview, Library, My Setup, Plan, Activity, and Diagnostics.
- Develop first against a fake client, then connect both Electron hosts to the real
  backend.
- Reach behavioral and accessibility parity before changing the default app.

### Stage 5: production packaging

- Assemble the unsigned Electron bundle with native artifacts outside ASAR.
- Add builder-owned Electron signing and entitlement policy.
- Add recursive signature, relocation, helper-launch, Gatekeeper, and notarization
  checks.

### Stage 6: cut over

- Make Electron the standalone composition root.
- Preserve the CLI and engine protocol.
- Keep SwiftUI for one compatibility release if it provides meaningful rollback
  value, then remove only the obsolete UI target.
- Version the engine protocol independently from product releases.

## Open decisions

- Swift or TypeScript for the long-term engine implementation.
- React or another renderer framework.
- architecture-specific native packages or one universal macOS helper.
- exact ownership and persistence format for optional package selections.
- whether the standalone application needs an updater.
- how long the SwiftUI compatibility application should remain.
- which Linux and Windows package providers are in scope.
- protocol compatibility window across embedding-host upgrades.

These decisions do not need to block the first two stages. Establishing one production
build, extracting application behavior, and defining an implementation-neutral
protocol are useful in every outcome.
