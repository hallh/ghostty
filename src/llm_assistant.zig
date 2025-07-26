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
    /// Configuration is missing or invalid
    InvalidConfiguration,
    /// Network request failed
    NetworkError,
    /// API returned an error response
    APIError,
    /// JSON parsing failed
    JSONParseError,
    /// Unsupported provider
    UnsupportedProvider,
    /// Authentication failed
    AuthenticationError,
    /// Rate limit exceeded
    RateLimitExceeded,
    /// Request timeout
    Timeout,
    /// Invalid request payload
    InvalidRequest,
    /// Out of memory
    OutOfMemory,
} || std.http.Client.RequestError || std.json.ParseError(std.json.Scanner);

/// Streaming response callback function
pub const StreamCallback = *const fn (chunk: []const u8, user_data: ?*anyopaque) void;

/// LLM Response data
pub const LLMResponse = struct {
    /// The suggested command text
    command: []const u8,
    /// Whether this is the final response (for streaming)
    is_final: bool = true,
    /// Error message if the request failed
    error_message: ?[]const u8 = null,

    /// Free resources allocated for this response
    pub fn deinit(self: *LLMResponse, allocator: std.mem.Allocator) void {
        if (self.command.len > 0) allocator.free(self.command);
        if (self.error_message) |err| allocator.free(err);
    }
};

/// LLM Request parameters
pub const LLMRequest = struct {
    /// The user's natural language prompt
    prompt: []const u8,
    /// Provider-specific model to use
    model: ?[]const u8 = null,
    /// Temperature for response generation (0.0 to 1.0)
    temperature: ?f32 = null,
    /// Maximum tokens to generate
    max_tokens: ?u32 = null,
    /// System prompt override
    system_prompt: ?[]const u8 = null,
};

/// Provider interface for different LLM APIs
pub const LLMProvider = struct {
    const Self = @This();

    /// Provider implementation function pointers
    pub const Vtable = struct {
        request: *const fn (
            self: *anyopaque,
            allocator: std.mem.Allocator,
            request: LLMRequest,
        ) LLMError!LLMResponse,

        requestStream: *const fn (
            self: *anyopaque,
            allocator: std.mem.Allocator,
            request: LLMRequest,
            callback: StreamCallback,
            user_data: ?*anyopaque,
        ) LLMError!void,

        deinit: *const fn (self: *anyopaque, allocator: std.mem.Allocator) void,
    };

    ptr: *anyopaque,
    vtable: *const Vtable,

    /// Make a blocking request to the LLM
    pub fn request(
        self: Self,
        allocator: std.mem.Allocator,
        req: LLMRequest,
    ) LLMError!LLMResponse {
        return self.vtable.request(self.ptr, allocator, req);
    }

    /// Make a streaming request to the LLM
    pub fn requestStream(
        self: Self,
        allocator: std.mem.Allocator,
        req: LLMRequest,
        callback: StreamCallback,
        user_data: ?*anyopaque,
    ) LLMError!void {
        return self.vtable.requestStream(self.ptr, allocator, req, callback, user_data);
    }

    /// Clean up resources
    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
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

    /// Make a POST request with JSON payload
    pub fn postJSON(
        self: *Self,
        url: []const u8,
        headers: []const std.http.Header,
        json_payload: []const u8,
        response_buffer: *std.ArrayList(u8),
    ) LLMError!std.http.Status {
        const uri = std.Uri.parse(url) catch return LLMError.InvalidRequest;

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

    /// Make a streaming POST request for Server-Sent Events
    pub fn postJSONStream(
        self: *Self,
        url: []const u8,
        headers: []const std.http.Header,
        json_payload: []const u8,
        callback: StreamCallback,
        user_data: ?*anyopaque,
    ) LLMError!void {
        const uri = std.Uri.parse(url) catch return LLMError.InvalidRequest;

        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = self.client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = headers,
        }) catch |err| switch (err) {
            error.ConnectionRefused,
            error.NetworkUnreachable,
            error.ConnectionTimedOut,
            error.UnknownHostName,
            error.TemporaryNameServerFailure,
            => return LLMError.NetworkError,

            error.OutOfMemory => return LLMError.OutOfMemory,

            else => {
                log.err("HTTP stream request failed: {}", .{err});
                return LLMError.NetworkError;
            },
        };
        defer req.deinit();

        // Set request payload
        req.transfer_encoding = .{ .content_length = json_payload.len };

        // Send request
        req.send() catch return LLMError.NetworkError;
        req.writeAll(json_payload) catch return LLMError.NetworkError;
        req.finish() catch return LLMError.NetworkError;
        req.wait() catch return LLMError.NetworkError;

        // Check response status
        if (req.response.status.class() != .success) {
            log.err("HTTP stream request failed with status: {}", .{req.response.status});
            return LLMError.APIError;
        }

        // Read streaming response
        var line_buffer: [8192]u8 = undefined;
        var reader = req.reader();

        while (true) {
            if (reader.readUntilDelimiterOrEof(line_buffer[0..], '\n') catch null) |line| {
                if (line.len == 0) continue; // Skip empty lines

                // Handle Server-Sent Events format
                if (std.mem.startsWith(u8, line, "data: ")) {
                    const data = line[6..]; // Skip "data: " prefix
                    if (std.mem.eql(u8, data, "[DONE]")) break; // End of stream

                    callback(data, user_data);
                }
            } else {
                break; // End of stream
            }
        }
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

    // Reference provider tests to ensure they're included
    _ = @import("llm_assistant/openai.zig");
    _ = @import("llm_assistant/anthropic.zig");
    _ = @import("llm_assistant/gemini.zig");
}
