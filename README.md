# Locally

Your private AI playground on Apple devices.

Locally is a free, open-source macOS app for running open-source AI models locally on your Mac. No cloud. No API keys. No subscriptions. Just you and the model, running on Apple Silicon.

Built with SwiftUI and [MLX Swift](https://github.com/ml-explore/mlx-swift-lm) by [Techopolis](https://github.com/Techopolis).

## Features

- **Stunning Custom UI**: Sleek full-bleed gradient chat interface with custom theme presets and dual-tone color pickers.
- **Provider-Grouped Downloads**: Browse and download models directly from Hugging Face organized by provider (Qwen, Gemma, Mistral, DeepSeek, Llama, Microsoft Phi, Apple).
- **Capability Badges**: Real-time identification of Tools (Function Calling), Vision (VLMs), Thinking (Reasoning / CoT), Code, and Chat specializations.
- **Personalization**: Custom system prompts with built-in role presets, personality style pickers, response length options, and step-by-step thinking toggles.
- **Import From Providers**: Transfer what ChatGPT, Claude, or Gemini knows about you into Locally with a single prompt extraction workflow.
- **Apple Silicon Native**: Runs 100% on-device using MLX Swift.
- **Full Privacy**: Your data, documents, and conversations never leave your device.
- **VoiceOver & Accessibility**: Keyboard shortcuts and full VoiceOver accessibility.

## Requirements

- macOS 15 or later
- Apple Silicon Mac (M1 or later)
- Xcode 16+ (to build from source)

## Getting Started

1. Clone the repository:
   ```
   git clone https://github.com/Techopolis/Perspective-Studio.git
   ```
2. Open `perspective studio.xcodeproj` in Xcode
3. Build and run (Cmd+R)
4. Pick a model from the Downloads tab or use an installed model to start chatting

## Built With

- [MLX Swift](https://github.com/ml-explore/mlx-swift)
- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)
- [Swift Transformers](https://github.com/huggingface/swift-transformers)
- [Hugging Face Hub](https://huggingface.co/mlx-community)

## Accessibility

Locally is fully accessible. VoiceOver, keyboard navigation, and screen reader support are built in from day one.

## License

MIT. See [LICENSE](LICENSE) for details.
