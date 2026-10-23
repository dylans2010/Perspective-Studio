# Perspective Studio — Expansion Execution Plan

Base: `main` @ `c248adf` (verified live against origin, fast-forwarded 2026-10-22).
Status: implemented on top of that base; statically verified only — see the final section.
Project facts that shape everything below: Xcode 26 project, `PBXFileSystemSynchronizedRootGroup`
(new Swift files under `perspective studio/` are auto-registered — no pbxproj edits),
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, macOS deployment target 15.0, Swift 6.0,
app sandbox OFF, only package dependency is `mlx-swift-lm` (MLXLLM / MLXVLM / MLXLMCommon).

## Critical bug — Hugging Face downloads (root cause, confirmed by inspection)

There was **no downloader**. `ChatViewModel.downloadHFModel()` called
`LLMService.loadModelByID()`, i.e. "download" meant "ask MLX to load the model and
treat load progress as download progress, then unload". Consequences:

- No repo manifest was ever fetched, so nothing enumerated **all** required files
  (weight shards from `model.safetensors.index.json`, tokenizer, config, …).
- `HFModel.isDownloaded` / `scanInstalledModels()` treated a model as installed if a
  `blobs/` *or* `snapshots/` folder merely **existed** — any partial/interrupted
  download counted as installed, and `downloadHFModel()`'s error path marked a failed
  load as "downloaded successfully" on that same check.
- No resume, no retry, no per-file validation, no size/hash checks.
- Vision models were forced through the LLM (not VLM) factory on this path.

HF API facts verified live against `mlx-community/Qwen2.5-0.5B-Instruct-4bit`:
`/api/models/{id}` siblings carry **only** `rfilename`; sizes/etags require
`/api/models/{id}/tree/main?recursive=true` (`size`, `oid` = git blob SHA-1,
`lfs.oid` = SHA-256 + `lfs.size`). `/resolve/main/<file>` answers 307 redirects.

Fix: `Services/ModelDownloadService.swift` (manifest → per-file resumable download
into the standard HF hub cache layout `blobs/<etag>` + `snapshots/<sha>/` symlinks +
`refs/main`, SHA-256 verification for LFS files, size verification for all files,
3 retries with persisted resume data) + `Services/ModelArtifactValidator.swift`
(structural + manifest completeness; the only definition of "installed").
`isDownloaded`, `scanInstalledModels()`, and the Downloads UI all use the validator.
A model is never marked installed until validation passes.

## Feature map (existing → action)

| Area | Existing | Action |
|---|---|---|
| A Comparison | View+VM, sequential, latency/tok-s | Add TTFT + load time, route through unified backend, record benchmarks |
| B API server | `/v1/models`, `/v1/chat/completions`, SSE, logs, loopback default | Optional bearer-token auth, 404 for unknown model, keep loopback/opt-in model |
| C HF Explorer | mlx-community catalog list only | Model details: file list + sizes, license, total size, repo link (Model Detail) |
| D Library/Downloads | Fragmented scans in 3 places, weak `isDownloaded` | Central states in `DownloadsManager` via download service + validator; completeness badges + storage in Downloads UI |
| E Benchmarks | None | `BenchmarkService` + `BenchmarkStore` (measured load/TTFT/tok-s/memory), Studio UI |
| F Prompts/Profiles | System-prompt presets in Settings only | `PromptLibraryStore` (CRUD/search/import/export) + per-model `GenerationProfile`s, Studio UI |
| G Chat | Streaming, editing surface varies | Conversation archive/rename/branch (SwiftData fields), conversation search, branch-from-message, edit-and-resend, image attachments |
| H Vision | VLM load path, video attach | Image attach/preview/paste, images passed to the engine, hard gate + clear error for non-vision models |
| I Knowledge/RAG | None | `KnowledgeBaseStore`: PDF/MD/TXT/code import, chunking, local index, scored retrieval with citations, optional chat injection |
| J Routing | None | `ModelRouter`: capability-evidence scoring vs RAM, explained decision, manual override, Studio UI |
| K Tools | Skills (prompt text) only | `ToolRegistry` + bounded tools (calculator, authorized-folder file search, date/time, hardware, library), argument validation, confirmation for file search, tool-call round-trip service |
| L Unified backend | UI calls `LLMService` directly | `InferenceBackend` protocol + `MLXInferenceBackend` wrapping `LLMService`; comparison/benchmarks/tools/routing use it |
| M macOS integration | Commands, shortcuts, multi-window Settings | Menu-bar extra with compact Quick Chat window + Carbon global hotkey (⇧⌘L) that opens it |

## Persistence

New app-level libraries (prompts, profiles, benchmarks, knowledge bases) persist as
versioned JSON under Application Support via `Services/JSONFileStore.swift`
(`schemaVersion` envelope field = migration hook). Conversations stay in SwiftData;
`Conversation` gains defaulted `isArchived` / `parentConversationID` and `Message`
gains defaulted `imageFileNames` (lightweight migration).

## Verification honestly available in the build environment

No macOS/Xcode/MLX in the agent environment: implementation is statically verified
(symbol cross-reference, brace/paren balance, pbxproj synchronized-group check) and the
HF manifest logic is verified live against the HF API. Building, running the test
suite, and the download→load→generate proof with
`mlx-community/Qwen2.5-0.5B-Instruct-4bit` must run on Dylan's Mac — see the completion
report checklist. Nothing is claimed as compiled or run until that happens.

## Addendum (2026-10-22, later): the deeper root cause — wrong cache location

The first fix enumerated and validated the right files but wrote them to the
Python-style hub cache (`~/.cache/huggingface/hub/models--…/blobs + snapshots`).
Verifying against the *pinned library sources* (mlx-swift-lm 2.30.6,
swift-transformers 1.1.9) showed the engine never reads that location:

- `MLXLMCommon.defaultHubApi` = `HubApi(downloadBase: ~/Library/Caches)`, and
  `HubApi.localRepoLocation` = `<base>/models/<org>/<name>` — real files, side
  by side, no blobs/symlinks.
- Each file needs a `.cache/huggingface/download/<path>.metadata` record
  (commit hash / etag / timestamp). `HubApi.snapshot` in offline mode throws
  unless every (non-hidden) file has one and every LFS file's SHA-256 matches
  its recorded etag; online, a file whose recorded commit hash matches is
  reused without re-downloading.

So the downloader, validator, manifests, and every cache scan/delete in the
app were moved to that layout: files download as real files into
`~/Library/Caches/models/<org>/<name>/`, a `.metadata` record is written or
refreshed for every file, the app manifest lives outside the model directory
(Application Support), and "installed" validation mirrors the engine's offline
rules. Models MLX itself downloaded earlier are in this location already and
are now detected correctly.
