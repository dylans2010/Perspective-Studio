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
  `InferenceBackend`. The SDK model-connection *source files* that remain
  are inert Python API definitions — Locally never imports, configures, or
  runs them, and bundles no API keys or endpoints.
- **No tools.** None of the SDK's built-in tools are registered or run.
  Every tool the agent can call is Locally's own, registered in
  `ToolsRegistry`. The SDK `tools/` sources that remain are the loop's
  tool-*running* abstractions for host-provided tools, not tool
  implementations.
- **The loop is what runs.** Turn classification, observation prompts, and
  final-answer handling live in `AntigravityLoopEngine` (Swift), which
  implements the SDK's loop contract natively so Agent mode works with
  zero Python runtime requirements, and the vendored SDK ships alongside
  it for interoperability and inspection.

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
checks the script phase, the exceptions, the manifest integrity, and
the loop-only policy.

## Using the vendored SDK directly

The vendored sources are a standard Python package tree. With Python 3.10+
and the SDK's documented dependencies installed, add this folder to
`PYTHONPATH` and `import google.antigravity`. Inside Locally itself, no
setup is needed or offered: Agent mode already runs on the loop.
