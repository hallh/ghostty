const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");

/// Default system prompt shared across all providers
pub const DEFAULT_SYSTEM_PROMPT =
    \\You are a helpful Linux command assistant. Respond with ONLY the command that would accomplish the user's request. 
    \\Do not include explanations, markdown formatting, or additional text. 
    \\Return only the raw command that can be executed directly in a Linux terminal.
    \\
    \\Examples:
    \\User: "list all files including hidden ones"
    \\Assistant: ls -la
    \\
    \\User: "find all PDF files in the current directory"
    \\Assistant: find . -name "*.pdf" -type f
;

/// Provider-specific defaults
pub const Defaults = struct {
    model: []const u8,
    temperature: f32 = 0.1,
    max_tokens: u32 = 1024,
    system_prompt: []const u8 = DEFAULT_SYSTEM_PROMPT,
};

/// Base provider with shared functionality
pub const BaseProvider = struct {
    http_client: llm.HTTPClient,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,

    const Self = @This();

    /// Initialize BaseProvider with configuration and defaults
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        model: []const u8,
        cfg: *const config.Config,
        defaults: Defaults,
    ) !Self {
        // Copy all strings to ensure they remain valid after config reload
        const owned_api_key = try allocator.dupe(u8, api_key);
        errdefer allocator.free(owned_api_key);

        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);

        const owned_system_prompt = try allocator.dupe(u8, cfg.@"ext-llm-system-prompt" orelse defaults.system_prompt);
        errdefer allocator.free(owned_system_prompt);

        return Self{
            .http_client = llm.HTTPClient.init(allocator),
            .api_key = owned_api_key,
            .model = owned_model,
            .temperature = cfg.@"ext-llm-temperature",
            .max_tokens = cfg.@"ext-llm-max-tokens",
            .system_prompt = owned_system_prompt,
        };
    }

    /// Clean up BaseProvider
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Free all owned strings
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.system_prompt);
        self.http_client.deinit();
    }

    /// Clean command text by removing common prefixes and formatting
    pub fn cleanCommandText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        var cleaned = std.mem.trim(u8, text, " \t\n\r");

        // Remove common command prefixes
        const prefixes = [_][]const u8{
            "$ ",
            "# ",
            "> ",
            "```bash\n",
            "```shell\n",
            "```sh\n",
            "```\n",
        };

        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, cleaned, prefix)) {
                cleaned = cleaned[prefix.len..];
                break;
            }
        }

        // Remove trailing code block markers
        const suffixes = [_][]const u8{
            "\n```",
            "```",
        };

        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, cleaned, suffix)) {
                cleaned = cleaned[0 .. cleaned.len - suffix.len];
                break;
            }
        }

        // Remove surrounding backticks if present
        if (cleaned.len >= 2 and cleaned[0] == '`' and cleaned[cleaned.len - 1] == '`') {
            cleaned = cleaned[1 .. cleaned.len - 1];
        }

        return try allocator.dupe(u8, std.mem.trim(u8, cleaned, " \t\n\r"));
    }
};
