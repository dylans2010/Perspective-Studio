# Antigravity SDK — Bundled in Locally

This folder contains the genuine upstream **Google Antigravity SDK**
(`google-antigravity` **0.1.20**, Apache-2.0 — see `LICENSE` and
`google_antigravity-0.1.20.dist-info/METADATA`), vendored from the official
PyPI wheel so that Locally's Agent mode never depends on anything the user
has to install separately. `sdk-manifest.json` records the SHA-256 and size
of every vendored file; the app verifies the bundle against it at runtime
(`AntigravitySDKBundle`).

## The loop-only contract

The SDK is bundled **for its agent loop only**:

- **No models.** The SDK's compiled runtime (`google/antigravity/bin/`,
  the `localharness` binary that executes the SDK's own model backends)
  is **excluded**. Inference in Locally is always the user's local models
  (downloaded MLX models or the built-in Apple model) through
  `InferenceBackend`. On top of that, the vendored hand-written sources
  were **stripped** of Google's model layer, model connections, and
  default system instructions — see "The Locally strip" below. Locally
  bundles no Google API keys, endpoints, or model identifiers.
- **No tools.** None of the SDK's built-in tools are registered or run,
  and their definitions no longer ship (see the strip). Every tool the
  agent can call is Locally's own, registered in `ToolsRegistry`. The
  SDK `tools/` sources that remain are the loop's tool-*running*
  abstractions for host-provided tools, not tool implementations.
- **The loop is what runs.** Turn classification, observation prompts, and
  final-answer handling live in `AntigravityLoopEngine` (Swift), which
  implements the SDK's loop contract natively so Agent mode works with
  zero Python runtime requirements, and the vendored SDK ships alongside
  it for interoperability and inspection.

## The Locally strip

The SDK is used **only for iteration / agentic-loop design**. Models,
tool calling, and system prompts always come from Locally's own context
index (`ContextIndexManager`) — Google's versions of all three are a
"no need" and were removed from the hand-written Python sources that
ship. Files were **gutted in place** (license header + an explanatory
docstring remain) rather than deleted, so the tree layout, the
synchronized-group exceptions, the manifest, and the build's ≥50-file
gate all stay intact. `sdk-manifest.json` was regenerated for the
stripped tree, and `scripts/verify-antigravity-bundle.py` now fails
loudly if a Google model string (`gemini-*`, `DEFAULT_MODEL`) ever
reappears in a hand-written `.py` file.

**Removed (gutted):**

- `google/antigravity/models.py` — Google's model layer: the default
  model identifiers, the image-generation model default, Gemini/Vertex
  endpoint and authentication classes, model options, thinking-level
  and service-tier types. The module now states plainly that the SDK
  defines no models; Locally provides them.
- `google/antigravity/connections/local/` — the entire model-connection
  package (14 files): `local_connection.py` (the localharness wire
  client and its built-in tool wiring), `local_connection_config.py`
  (API-key/model shorthand, default-model defaulting, and the
  `_get_system_instructions` assembly), the OpenAI-compatible
  connection + config, the LiteRT connection + config, `litert_server.py`
  (an inference server), plus the wire/event/struct converters, hook
  router, and test helpers that existed only to serve those
  connections. `connections/local/types.py` held the result types of
  Google's built-in tools (run-command, edit-file, generate-image,
  search-web, …) — built-in tool definitions, also removed.
- `google/antigravity/tools/schema_utils.py` — JSON-schema
  normalization bound to Google's genai types; only the removed model
  connection used it. (`tools/tool_runner.py` and
  `tools/tool_context.py` stay: generic loop plumbing for
  host-provided tools, with no Google content.)

**Edited (kept, with Google wiring cut out):**

- `google/antigravity/types.py` — the loop's boundary types stay. The
  model-layer imports/re-exports (Gemini/Vertex endpoints, model
  targets, thinking levels, service tiers) are gone; `UsageMetadata`'s
  service tier is now a plain string. The `SystemInstructions` types
  stay as generic *field definitions* — they carry no default content.
  The `BuiltinTools` enum stays as the policy machinery's identifier
  vocabulary (names only — no implementations, no schemas), but its
  `default()` / `minimal()` default-bundle definitions were removed.
- `google/antigravity/connections/connection.py` — the loop-facing
  `Connection` / `ConnectionStrategy` / `AgentConfig` interface stays.
  Removed: the `system_instructions` field, the default capabilities
  wiring that pre-enabled a built-in tool set, and the
  `lightweight()` / `eval()` preset factories (default tool bundles +
  Gemini thinking-level presets). `resolve_active_tools` now starts
  from an empty set — the host decides which tools exist.
- `google/antigravity/__init__.py` — exports reduced to the agent loop
  and its boundary types; the model-connection configs and Gemini type
  exports are gone.
- `google/antigravity/hooks/policy.py` — one docstring line naming a
  Gemini safety-evaluation model was neutralized; the policy machinery
  itself is loop infrastructure and stays.

**Left untouched, deliberately:**

- The loop machinery: `agent.py`, `conversation/`, `hooks/`,
  `triggers/`, `utils/`, `policy/` — iteration and step handling with
  no model/tool/prompt content of their own.
- `google/antigravity/proto/*_pb2.py` — *generated* protobuf
  descriptors. They are inert (nothing executes them here) and embed
  genai tool type names by construction; hand-editing generated
  descriptors would corrupt them, so they are excluded from the strip
  and from the verifier's strip check, explicitly.

Nothing in this tree executes inside Locally (Agent mode's loop is the
native Swift `AntigravityLoopEngine`); every remaining `.py` file still
passes `py_compile`, and the package layout stays coherent.

## What was excluded at vendor time

- `google/antigravity/bin/` — the compiled `localharness` model/tool
  runtime (37 MB binary). Excluded per the no-models/no-tools contract.
- `*_test.py` files and `__pycache__/` — tests and bytecode caches.
- The rest of the wheel's dependency tree (`google-genai`, `mcp`,
  `pydantic`, …) — dependencies of the SDK's model connections, which
  Locally does not run.

## How it is bundled (Xcode wiring)

The SDK ships via a dedicated **"Bundle Antigravity SDK" Run Script
build phase** on the Locally target. The script copies this directory
with `ditto` — structure intact — to
`Contents/Resources/AntigravitySDK/` in the built app, where
`AntigravitySDKBundle.bundledDirectory()` finds and verifies it. The
script is gated on `sdk-manifest.json`, refuses to ship the SDK's
compiled `bin/` runtime (loop-only), and **fails the build** if the
copied tree has fewer than 50 files, so a broken bundle can never
silently reach a user again.

The individual files are *also* listed as membership exceptions in the
project's file-system synchronized group. That half matters just as
much: without the exceptions, the synchronized group would try to copy
each file as a loose resource — flattening the tree into the bundle
root and colliding on the many `__init__.py` files (the duplicate-
resource build failure this wiring replaced) — and exceptions alone
(the state between that build fix and this script phase) exclude the
SDK from the app entirely. A folder reference was tried in between and
dropped: references pointing *inside* a synchronized root are not a
reliable copy mechanism. `scripts/verify-antigravity-bundle.py`
checks the script phase, the exceptions, the manifest integrity, the
loop-only policy, and the strip (no Google model content in
hand-written sources).

## Using the vendored SDK directly

The vendored sources remain a standard Python package tree, reduced by
the strip to the agent loop and its boundary types — `import
google.antigravity` exposes `Agent`, `AgentConfig`, and the loop types,
and no longer exposes any model, model-connection, or Gemini types.
Inside Locally itself, no setup is needed or offered: Agent mode
already runs on the loop.
