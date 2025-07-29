# LLM Command Assistant

Ghostty includes an **LLM Command Assistant** feature that helps you generate Linux terminal commands using AI. The assistant can understand natural language requests and generate appropriate command-line instructions.

## Overview

The LLM Command Assistant integrates with popular AI providers to help you:
- Generate terminal commands from natural language descriptions
- Learn new command-line tools and options
- Quickly find the right syntax for complex operations
- Get instant command suggestions without leaving your terminal

**Example:** Ask "list all files including hidden ones" and get `ls -la`

## Supported Providers

Ghostty supports three major LLM providers:

### 1. **Anthropic Claude** (Default)
- **Provider ID**: `anthropic`
- **Default Model**: `claude-3-7-sonnet-latest`
- **API Endpoint**: https://api.anthropic.com/v1
- **Get API Key**: [Anthropic Console](https://console.anthropic.com/)

### 2. **OpenAI GPT**
- **Provider ID**: `openai`
- **Default Model**: `gpt-4.1`
- **API Endpoint**: https://api.openai.com/v1
- **Get API Key**: [OpenAI Platform](https://platform.openai.com/api-keys)

### 3. **Google Gemini**
- **Provider ID**: `gemini`
- **Default Model**: `gemini-2.5-flash`
- **API Endpoint**: https://generativelanguage.googleapis.com/v1beta
- **Get API Key**: [Google AI Studio](https://aistudio.google.com/app/apikey)

## Configuration

Add the following settings to your Ghostty configuration file:

### Required Configuration

```ini
# Provider-specific API keys (REQUIRED)
ext-llm-anthropic-api-key = "..."  # for Anthropic Claude
ext-llm-openai-api-key = "..."         # for OpenAI GPT
ext-llm-gemini-api-key = "..."            # for Google Gemini

# Choose your provider (optional - defaults to anthropic)
ext-llm-provider = anthropic  # or openai, gemini
```

### Optional Configuration

```ini
# Provider-specific models (optional - uses provider defaults)
ext-llm-anthropic-model = "claude-3-7-sonnet-latest"  # for Anthropic
ext-llm-openai-model = "gpt-4.1"                     # for OpenAI
ext-llm-gemini-model = "gemini-2.5-flash"            # for Gemini

# Temperature for response generation (default: 1.0)
ext-llm-temperature = 1.0

# Maximum tokens in response (default: 1024)
ext-llm-max-tokens = 1024

# Custom system prompt (optional)
ext-llm-system-prompt = "You are a helpful Linux command assistant..."

# Number of prompts to keep in history (default: 50)
ext-llm-history-size = 50
```

### Multiple Provider Setup

With provider-specific API keys, you can easily switch between providers without changing keys:

```ini
# Configure all three providers
ext-llm-anthropic-api-key = sk-ant-your_anthropic_key_here
ext-llm-openai-api-key = sk-your_openai_key_here
ext-llm-gemini-api-key = your_gemini_key_here

# Switch providers by changing this line
ext-llm-provider = anthropic  # Change to openai or gemini anytime

# Each provider will use its specific API key automatically
```

## Setup Instructions

### 1. Get API Keys

You can set up one or all of the supported providers:

**For Anthropic Claude:**
1. Visit [Anthropic Console](https://console.anthropic.com/)
2. Sign up or log in
3. Navigate to API Keys
4. Create a new API key
5. Copy the key (starts with `sk-ant-`)

**For OpenAI:**
1. Visit [OpenAI Platform](https://platform.openai.com/api-keys)
2. Sign up or log in
3. Create a new API key
4. Copy the key (starts with `sk-`)

**For Google Gemini:**
1. Visit [Google AI Studio](https://aistudio.google.com/app/apikey)
2. Sign up or log in
3. Create a new API key
4. Copy the key

### 2. Configure Ghostty

Add provider-specific API keys to your Ghostty configuration file:

```ini
# Configure your preferred provider(s)
ext-llm-anthropic-api-key = "..."  # your Anthropic API key
ext-llm-openai-api-key = "..."     # your OpenAI API key
ext-llm-gemini-api-key = "..."     # your Google Gemini API key

# Choose your active provider (optional - defaults to anthropic)
ext-llm-provider = anthropic

# Optionally configure provider-specific models
ext-llm-anthropic-model = "claude-3-7-sonnet-latest"
ext-llm-openai-model = "gpt-4.1"
ext-llm-gemini-model = "gemini-2.5-flash"
```

### 3. Switch Providers Easily

Once you have multiple API keys configured, switching providers is simple:

1. **Edit config**: Change `ext-llm-provider = openai` (or gemini)
2. **Reload config**: Use Ghostty's "Reload Configuration" menu option
3. **Done**: Next LLM requests will use the new provider

No need to change API keys when switching!

## Usage

### Accessing the Assistant

The LLM Command Assistant is available through Ghostty's action system. You can trigger it by:

1. **Action Name**: `llm_command_assistant`
2. **Keybinding**: Set a custom keybinding in your configuration:
   ```ini
   keybind = ctrl+alt+l=llm_command_assistant
   ```

### Using the Dialog

1. **Open**: Trigger the `llm_command_assistant` action
2. **Describe**: Type what you want to do in natural language
3. **Submit**: Press Enter or click "Get Suggestion"
4. **Review**: The assistant will provide a command suggestion
5. **Accept**: Click "Accept" to copy the command to your clipboard

### Example Interactions

| **Your Request** | **Generated Command** |
|-----------------|----------------------|
| "list all files including hidden ones" | `ls -la` |
| "find all PDF files in the current directory" | `find . -name "*.pdf" -type f` |
| "show disk usage for each directory" | `du -sh */` |
| "kill all processes named firefox" | `pkill firefox` |
| "create a tar.gz archive of my documents folder" | `tar -czf documents.tar.gz documents/` |

### Command History

The assistant maintains a history of your previous requests. Use the Up/Down arrow keys in the input field to navigate through your request history.

## Troubleshooting

### "LLM assistant requires configuration"

**Problem**: You haven't set up an API key.

**Solution**: Add `ext-llm-api-key = your_api_key_here` to your configuration file.

### "libadwaita 1.5+ is required"

**Problem**: Your system's libadwaita version is too old.

**Solution**: 
- Update your system packages
- The LLM assistant requires libadwaita 1.5 or newer
- Check your distribution's package manager for updates

### "LLM provider failed to initialize"

**Problem**: Invalid API key or network issues.

**Solutions**:
- Verify your API key is correct and active
- Check your internet connection
- Ensure the API key has sufficient credits/quota
- Try a different provider if one is experiencing issues

### High Token Usage

**Problem**: API costs are higher than expected.

**Solutions**:
- Reduce `ext-llm-max-tokens` (default: 1024)
- Use a more cost-effective model
- Consider using shorter, more specific requests

### Slow Responses

**Problem**: The assistant takes too long to respond.

**Solutions**:
- Try a faster model (e.g., `gpt-4o-mini` for OpenAI)
- Check your internet connection
- Consider switching providers if one is experiencing slow response times

## Security Considerations

- **API Keys**: Store your API keys securely and never share them
- **Network**: Requests are sent over HTTPS to the provider's API
- **Privacy**: Your prompts are sent to the chosen AI provider
- **Local Data**: No local terminal data is sent unless explicitly included in your prompt

## Provider Comparison

| **Feature** | **Anthropic** | **OpenAI** | **Google** |
|------------|---------------|------------|------------|
| **Speed** | Fast | Very Fast | Fast |
| **Accuracy** | Excellent | Excellent | Good |
| **Cost** | Moderate | Low-High* | Low |
| **Rate Limits** | Generous | Varies by plan | Generous |

*OpenAI costs vary significantly between models (gpt-4o-mini is very cost-effective)

## Advanced Configuration

### Custom System Prompt

You can customize how the assistant behaves by setting a custom system prompt:

```ini
ext-llm-system-prompt = You are a helpful Linux system administrator. Provide commands that are safe and well-documented. Always include brief explanations for complex commands.
```

### Model Selection

Each provider offers different models with varying capabilities:

**Anthropic Models:**
- `claude-3-7-sonnet-latest` (default) - Latest and best balance
- `claude-3-5-haiku-20241022` - Fastest, most economical

**OpenAI Models:**
- `gpt-4.1` (default) - Latest capability and performance
- `gpt-4o-mini` - Very cost-effective
- `gpt-4o` - Capable but more expensive
- `gpt-3.5-turbo` - Good balance of speed and cost

**Google Models:**
- `gemini-2.5-flash` (default) - Latest fast and efficient model
- `gemini-1.5-pro` - More capable for complex requests

## Architecture

The LLM Command Assistant uses a modular architecture:

- **Provider Base** (`src/llm_assistant/provider_base.zig`): Shared functionality and defaults across all providers
- **Individual Providers**: Anthropic, OpenAI, and Gemini implementations that extend the base
- **Terminal Context**: Smart capture of terminal state to provide relevant context to AI
- **Background Processing**: LLM requests run in separate threads to keep UI responsive

All providers share common configuration defaults and text cleaning logic through the provider base, ensuring consistent behavior while allowing provider-specific optimizations.

## Contributing

The LLM Command Assistant is part of Ghostty's source code. To contribute:

1. **Report Issues**: Use Ghostty's issue tracker for bugs or feature requests
2. **Code Contributions**: Submit pull requests for improvements
3. **Documentation**: Help improve this documentation

## Privacy Policy

Please review the privacy policies of your chosen AI provider:
- [Anthropic Privacy Policy](https://www.anthropic.com/privacy)
- [OpenAI Privacy Policy](https://openai.com/privacy/)
- [Google Privacy Policy](https://policies.google.com/privacy)

Your prompts and generated commands are subject to the privacy policy of your chosen provider. 