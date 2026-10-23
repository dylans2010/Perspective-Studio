# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Removed in Locally's loop-only strip.

Upstream, this module contained the result types of Google's built-in tools (run-command, edit-file, generate-image, search-web, read-url and friends) — built-in tool definitions Locally does not ship; Locally's tools are its own, in ToolsRegistry.

Locally bundles the Antigravity SDK for its agent-loop design only:
models, tool calling, and system prompts always come from Locally's own
context index, never from Google — so this content was removed. The
file remains (empty of code) so the vendored tree layout, the bundle
manifest, and the build's file-count gate stay intact. See BUNDLED.md.
"""
