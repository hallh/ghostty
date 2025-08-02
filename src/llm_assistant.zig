const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const input = @import("input.zig");
const i18n = @import("os/i18n.zig");

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
};

/// Response structure for LLM responses
pub const LLMResponse = struct {
    status: enum { ok, err },
    text: []u8,
    allocator: std.mem.Allocator,
    is_final: bool = false,

    pub fn deinit(self: *LLMResponse) void {
        self.allocator.free(self.text);
    }
};

/// Helper function to create a successful LLM response
pub fn makeSuccessResponse(allocator: std.mem.Allocator, command: []const u8) LLMResponse {
    return LLMResponse{
        .status = .ok,
        .text = allocator.dupe(u8, command) catch return makeErrorResponse(allocator, std.mem.span(i18n._("Failed to allocate memory for command"))),
        .allocator = allocator,
        .is_final = true,
    };
}

/// Helper function to create an error LLM response
pub fn makeErrorResponse(allocator: std.mem.Allocator, error_text: []const u8) LLMResponse {
    return LLMResponse{
        .status = .err,
        .text = allocator.dupe(u8, error_text) catch @panic("Out of memory creating error response"),
        .allocator = allocator,
        .is_final = false,
    };
}

/// Unified HTTP response structure
pub const HTTPResponse = struct {
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HTTPResponse) void {
        self.allocator.free(self.body);
    }
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

    /// Helper function to handle HTTP fetch errors
    fn tryFetch(
        client: *std.http.Client,
        method: std.http.Method,
        uri: std.Uri,
        headers: []const std.http.Header,
        payload: []const u8,
        response_buffer: *std.ArrayList(u8),
        header_buffer: []u8,
    ) LLMError!std.http.Client.FetchResult {
        return client.fetch(.{
            .method = method,
            .location = .{ .uri = uri },
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = headers,
            .payload = payload,
            .response_storage = .{ .dynamic = response_buffer },
            .server_header_buffer = header_buffer,
        }) catch |err| switch (err) {
            error.ConnectionRefused,
            error.NetworkUnreachable,
            error.ConnectionTimedOut,
            error.UnknownHostName,
            error.TemporaryNameServerFailure,
            => return LLMError.NetworkError,

            error.OutOfMemory => return LLMError.OutOfMemory,

            else => {
                log.err("{s}: {}", .{ i18n._("HTTP request failed"), err });
                return LLMError.NetworkError;
            },
        };
    }

    /// Make a POST request with JSON payload - returns unified response
    pub fn postJSON(
        self: *Self,
        url: []const u8,
        headers: []const std.http.Header,
        json_payload: []const u8,
    ) LLMError!HTTPResponse {
        const uri = std.Uri.parse(url) catch {
            return LLMError.NetworkError;
        };

        var response_buffer = std.ArrayList(u8).init(self.allocator);
        var header_buffer: [16 * 1024]u8 = undefined;

        const result = tryFetch(
            &self.client,
            .POST,
            uri,
            headers,
            json_payload,
            &response_buffer,
            &header_buffer,
        ) catch |err| {
            response_buffer.deinit();
            return err;
        };

        // Check HTTP status for errors
        if (@intFromEnum(result.status) >= 400) {
            const body = response_buffer.toOwnedSlice() catch {
                response_buffer.deinit();
                return LLMError.OutOfMemory;
            };

            // Return error with the HTTP error body for debugging
            defer self.allocator.free(body);
            return LLMError.APIError;
        }

        // Success case
        const body = response_buffer.toOwnedSlice() catch {
            response_buffer.deinit();
            return LLMError.OutOfMemory;
        };

        return HTTPResponse{
            .body = body,
            .allocator = self.allocator,
        };
    }
};

/// Check if LLM is properly configured
pub fn isConfigured(cfg: *const config.Config) bool {
    return getApiKeyForProvider(cfg, cfg.@"ext-llm-provider") != null;
}

/// Get the appropriate API key for the given provider
fn getApiKeyForProvider(cfg: *const config.Config, provider: config.Config.LLMProvider) ?[]const u8 {
    return switch (provider) {
        .anthropic => cfg.@"ext-llm-anthropic-api-key",
        .openai => cfg.@"ext-llm-openai-api-key",
        .gemini => cfg.@"ext-llm-gemini-api-key",
    };
}

/// Get a user-friendly configuration error message
pub fn getConfigurationError(cfg: *const config.Config) [*:0]const u8 {
    const provider = cfg.@"ext-llm-provider";
    const api_key = getApiKeyForProvider(cfg, provider);

    if (api_key == null) {
        return switch (provider) {
            .anthropic => i18n._("LLM assistant requires an Anthropic API key. Please set 'ext-llm-anthropic-api-key' in your configuration."),
            .openai => i18n._("LLM assistant requires an OpenAI API key. Please set 'ext-llm-openai-api-key' in your configuration."),
            .gemini => i18n._("LLM assistant requires a Gemini API key. Please set 'ext-llm-gemini-api-key' in your configuration."),
        };
    }
    return i18n._("LLM configuration is incomplete. Please check your settings.");
}

/// Helper functions for creating providers
fn createAnthropicProvider(allocator: std.mem.Allocator, api_key: []const u8, cfg: *const config.Config) LLMError!LLMProvider {
    const provider = try anthropic.AnthropicProvider.init(allocator, api_key, cfg);
    return LLMProvider{
        .ptr = provider,
        .vtable = &anthropic.AnthropicProvider.vtable,
    };
}

fn createOpenAIProvider(allocator: std.mem.Allocator, api_key: []const u8, cfg: *const config.Config) LLMError!LLMProvider {
    const provider = try openai.OpenAIProvider.init(allocator, api_key, cfg);
    return LLMProvider{
        .ptr = provider,
        .vtable = &openai.OpenAIProvider.vtable,
    };
}

fn createGeminiProvider(allocator: std.mem.Allocator, api_key: []const u8, cfg: *const config.Config) LLMError!LLMProvider {
    const provider = try gemini.GeminiProvider.init(allocator, api_key, cfg);
    return LLMProvider{
        .ptr = provider,
        .vtable = &gemini.GeminiProvider.vtable,
    };
}

/// Create a provider instance based on configuration
pub fn createProvider(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
) LLMError!LLMProvider {
    const provider_type = cfg.@"ext-llm-provider";
    const api_key = getApiKeyForProvider(cfg, provider_type) orelse return LLMError.InvalidConfiguration;

    return switch (provider_type) {
        .anthropic => createAnthropicProvider(allocator, api_key, cfg),
        .openai => createOpenAIProvider(allocator, api_key, cfg),
        .gemini => createGeminiProvider(allocator, api_key, cfg),
    };
}

// Provider implementations (forward declarations)
const AnthropicProvider = @import("llm_assistant/anthropic.zig");
const OpenAIProvider = @import("llm_assistant/openai.zig");
const GeminiProvider = @import("llm_assistant/gemini.zig");

// Test imports - ensures all tests are discoverable by `zig build test`
test {
    // Reference all modules to ensure their inline tests are included
    _ = @import("llm_assistant/provider_base.zig");
    _ = @import("llm_assistant/openai.zig");
    _ = @import("llm_assistant/anthropic.zig");
    _ = @import("llm_assistant/gemini.zig");
}

test "provider configuration and functionality" {
    const testing = std.testing;

    // Table-driven test for all providers
    const test_cases = [_]struct {
        provider: config.Config.LLMProvider,
        key_field: []const u8,
        model_field: []const u8,
        key_value: []const u8,
        model_value: []const u8,
    }{
        .{ .provider = .anthropic, .key_field = "anthropic-key", .model_field = "anthropic-model", .key_value = "anthropic-key", .model_value = "claude-3-7-sonnet-latest" },
        .{ .provider = .openai, .key_field = "openai-key", .model_field = "openai-model", .key_value = "openai-key", .model_value = "gpt-4.1" },
        .{ .provider = .gemini, .key_field = "gemini-key", .model_field = "gemini-model", .key_value = "gemini-key", .model_value = "gemini-2.5-flash" },
    };

    for (test_cases) |case| {
        // Test API key retrieval and configuration
        var cfg = config.Config{};
        cfg.@"ext-llm-provider" = case.provider;

        switch (case.provider) {
            .anthropic => {
                cfg.@"ext-llm-anthropic-api-key" = case.key_value;
                try testing.expectEqualStrings(case.key_value, getApiKeyForProvider(&cfg, case.provider).?);
                try testing.expectEqualStrings(case.model_value, cfg.@"ext-llm-anthropic-model".?);
            },
            .openai => {
                cfg.@"ext-llm-openai-api-key" = case.key_value;
                try testing.expectEqualStrings(case.key_value, getApiKeyForProvider(&cfg, case.provider).?);
                try testing.expectEqualStrings(case.model_value, cfg.@"ext-llm-openai-model".?);
            },
            .gemini => {
                cfg.@"ext-llm-gemini-api-key" = case.key_value;
                try testing.expectEqualStrings(case.key_value, getApiKeyForProvider(&cfg, case.provider).?);
                try testing.expectEqualStrings(case.model_value, cfg.@"ext-llm-gemini-model".?);
            },
        }

        // Test configuration validation
        try testing.expect(isConfigured(&cfg));

        // Test missing key detection
        var empty_cfg = config.Config{};
        empty_cfg.@"ext-llm-provider" = case.provider;
        try testing.expect(!isConfigured(&empty_cfg));
    }
}

test "HTTPResponse lifecycle" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_cases = [_][]const u8{
        "successful response",
        "error occurred",
        "empty string",
    };

    for (test_cases) |body_text| {
        var response = HTTPResponse{
            .body = try allocator.dupe(u8, body_text),
            .allocator = allocator,
        };

        try testing.expectEqualStrings(body_text, response.body);
        response.deinit();
    }
}

// Import helper modules for test discovery
test {
    _ = @import("llm_assistant/history.zig");
    _ = @import("llm_assistant/prompt_builder.zig");
    _ = @import("llm_assistant/terminal_context.zig");
    _ = @import("llm_assistant/worker_core.zig");
}
