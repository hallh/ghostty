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
- **Default Model**: `claude-3-5-sonnet-20241022`
- **API Endpoint**: https://api.anthropic.com/v1
- **Get API Key**: [Anthropic Console](https://console.anthropic.com/)

### 2. **OpenAI GPT**
- **Provider ID**: `openai`
- **Default Model**: `gpt-4o-mini`
- **API Endpoint**: https://api.openai.com/v1
- **Get API Key**: [OpenAI Platform](https://platform.openai.com/api-keys)

### 3. **Google Gemini**
- **Provider ID**: `gemini`
- **Default Model**: `gemini-1.5-flash`
- **API Endpoint**: https://generativelanguage.googleapis.com/v1beta
- **Get API Key**: [Google AI Studio](https://aistudio.google.com/app/apikey)

## Configuration

Add the following settings to your Ghostty configuration file:

### Required Configuration

```ini
# Set your API key (REQUIRED)
ext-llm-api-key = your_api_key_here

# Choose your provider (optional - defaults to anthropic)
ext-llm-provider = anthropic  # or openai, gemini
```

### Optional Configuration

```ini
# Model to use (optional - uses provider defaults)
ext-llm-model = claude-3-5-sonnet-20241022  # for Anthropic
# ext-llm-model = gpt-4o                     # for OpenAI
# ext-llm-model = gemini-1.5-pro             # for Google

# Temperature for response generation (0.0-1.0, default: 0.1)
ext-llm-temperature = 0.1

# Maximum tokens in response (default: 1024)
ext-llm-max-tokens = 1024

# Custom system prompt (optional)
ext-llm-system-prompt = You are a helpful Linux command assistant...

# Number of prompts to keep in history (default: 50)
ext-llm-history-size = 50
```

## Setup Instructions

### 1. Get an API Key

Choose one of the supported providers and obtain an API key:

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

Add your API key to your Ghostty configuration file:

```ini
# Minimum required configuration
ext-llm-api-key = your_api_key_here
```

### 3. Optional: Choose Provider

If you want to use a provider other than Anthropic (default):

```ini
ext-llm-provider = openai    # or gemini
ext-llm-api-key = your_openai_api_key_here
```

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
- `claude-3-5-sonnet-20241022` (default) - Best balance
- `claude-3-5-haiku-20241022` - Fastest, most economical

**OpenAI Models:**
- `gpt-4o-mini` (default) - Very cost-effective
- `gpt-4o` - Most capable but more expensive
- `gpt-3.5-turbo` - Good balance of speed and cost

**Google Models:**
- `gemini-1.5-flash` (default) - Fast and efficient
- `gemini-1.5-pro` - More capable for complex requests

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