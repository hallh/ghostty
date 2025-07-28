const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const input = @import("input.zig");

const log = std.log.scoped(.llm_assistant);

// LLM Provider implementations
const anthropic = @import("llm_assistant/anthropic.zig");
const openai = @import("llm_assistant/openai.zig");
const gemini = @import("llm_assistant/gemini.zig");

/// Errors that can occur during LLM operations
pub const LLMError = error{
    APIError,
    AuthenticationError,
    InvalidConfiguration,
    JSONParseError,
    NetworkError,
    OutOfMemory,
    RateLimitExceeded,
    UnsupportedProvider,
};

/// Base interface for all LLM providers
pub const LLMProvider = struct {
    ptr: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        request: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, req: LLMRequest) LLMError!LLMResponse,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn deinit(self: LLMProvider, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn request(self: LLMProvider, allocator: std.mem.Allocator, req: LLMRequest) !LLMResponse {
        return self.vtable.request(self.ptr, allocator, req);
    }
};

/// Request structure for making LLM requests
pub const LLMRequest = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    system_prompt: ?[]const u8 = null,
    terminal_context: ?TerminalContext = null,
};

/// Response structure for LLM responses
pub const LLMResponse = struct {
    command: []const u8,
    error_message: ?[]const u8 = null,
    is_final: bool = false,

    pub fn deinit(self: *LLMResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

/// Terminal context for richer prompts
pub const TerminalContext = struct {
    command_history: ?[]const u8 = null,
};

/// HTTP client wrapper for LLM API calls
pub const HTTPClient = struct {
    client: std.http.Client,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize HTTP client
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .client = std.http.Client{ .allocator = allocator },
            .allocator = allocator,
        };
    }

    /// Clean up HTTP client
    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }

    /// Make a POST request with JSON payload
    pub fn postJSON(
        self: *Self,
        url: []const u8,
        headers: []const std.http.Header,
        json_payload: []const u8,
        response_buffer: *std.ArrayList(u8),
    ) LLMError!std.http.Status {
        const uri = std.Uri.parse(url) catch return LLMError.InvalidConfiguration;

        var header_buffer: [16 * 1024]u8 = undefined;
        const result = self.client.fetch(.{
            .method = .POST,
            .location = .{ .uri = uri },
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = headers,
            .payload = json_payload,
            .response_storage = .{ .dynamic = response_buffer },
            .server_header_buffer = &header_buffer,
        }) catch |err| switch (err) {
            error.ConnectionRefused,
            error.NetworkUnreachable,
            error.ConnectionTimedOut,
            error.UnknownHostName,
            error.TemporaryNameServerFailure,
            => return LLMError.NetworkError,

            error.OutOfMemory => return LLMError.OutOfMemory,

            else => {
                log.err("HTTP request failed: {}", .{err});
                return LLMError.NetworkError;
            },
        };

        return result.status;
    }
};

/// Check if LLM is properly configured
pub fn isConfigured(cfg: *const config.Config) bool {
    return cfg.@"ext-llm-api-key" != null;
}

/// Get a user-friendly configuration error message
pub fn getConfigurationError(cfg: *const config.Config) [*:0]const u8 {
    if (cfg.@"ext-llm-api-key" == null) {
        return "LLM assistant requires an API key. Please set 'ext-llm-api-key' in your configuration.";
    }
    return "LLM configuration is incomplete. Please check your settings.";
}

/// Create a provider instance based on configuration
pub fn createProvider(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
) LLMError!LLMProvider {
    const provider_type = cfg.@"ext-llm-provider";
    const api_key = cfg.@"ext-llm-api-key" orelse return LLMError.InvalidConfiguration;

    switch (provider_type) {
        .anthropic => {
            const provider = try anthropic.AnthropicProvider.init(allocator, api_key, cfg);
            return LLMProvider{
                .ptr = provider,
                .vtable = &anthropic.AnthropicProvider.vtable,
            };
        },
        .openai => {
            const provider = try openai.OpenAIProvider.init(allocator, api_key, cfg);
            return LLMProvider{
                .ptr = provider,
                .vtable = &openai.OpenAIProvider.vtable,
            };
        },
        .gemini => {
            const provider = try gemini.GeminiProvider.init(allocator, api_key, cfg);
            return LLMProvider{
                .ptr = provider,
                .vtable = &gemini.GeminiProvider.vtable,
            };
        },
    }
}

// Provider implementations (forward declarations)
const AnthropicProvider = @import("llm_assistant/anthropic.zig");
const OpenAIProvider = @import("llm_assistant/openai.zig");
const GeminiProvider = @import("llm_assistant/gemini.zig");

// Test imports - ensures all tests are discoverable by `zig build test`
test {
    _ = @import("llm_assistant/integration_test.zig");
    _ = @import("llm_assistant/provider_base_test.zig");

    // Reference provider tests to ensure they're included
    _ = @import("llm_assistant/openai.zig");
    _ = @import("llm_assistant/anthropic.zig");
    _ = @import("llm_assistant/gemini.zig");
}
