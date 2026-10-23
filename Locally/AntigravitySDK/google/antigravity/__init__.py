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

"""Google Antigravity SDK for building AI agents.

Vendored in Locally under the loop-only strip: the model layer, the
model connections, and their config classes were removed — models,
tools, and system prompts are Locally's own. What remains exported
here is the agent loop and its boundary types.
"""

from google.antigravity.agent import Agent
from google.antigravity.connections.connection import AgentConfig
from google.antigravity.tools.tool_context import ToolContext
from google.antigravity.types import AgentBehavior
from google.antigravity.types import Audio
from google.antigravity.types import BuiltinTools
from google.antigravity.types import CapabilitiesConfig
from google.antigravity.types import CompactionConfig
from google.antigravity.types import Content
from google.antigravity.types import CustomSystemInstructions
from google.antigravity.types import Document
from google.antigravity.types import from_bytes
from google.antigravity.types import from_file
from google.antigravity.types import Image
from google.antigravity.types import ModelAPIRetryConfig
from google.antigravity.types import ModelOutputRetryConfig
from google.antigravity.types import RetryConfig
from google.antigravity.types import SandboxStatus
from google.antigravity.types import SystemInstructions
from google.antigravity.types import SystemInstructionSection
from google.antigravity.types import TemplatedSystemInstructions
from google.antigravity.types import ToolExecutionError
from google.antigravity.types import ToolOutputTruncationConfig
from google.antigravity.types import UsageMetadata
from google.antigravity.types import Video

__all__ = [
    "Agent",
    "AgentConfig",
                    "ToolContext",
    "AgentBehavior",
    "Audio",
    "BuiltinTools",
    "CapabilitiesConfig",
    "CompactionConfig",
    "Content",
    "CustomSystemInstructions",
    "Document",
            "Image",
    "ModelAPIRetryConfig",
        "ModelOutputRetryConfig",
            "RetryConfig",
    "SandboxStatus",
        "SystemInstructions",
    "SystemInstructionSection",
    "TemplatedSystemInstructions",
        "ToolOutputTruncationConfig",
    "UsageMetadata",
        "Video",
    "ToolExecutionError",
    "from_bytes",
    "from_file",
]
