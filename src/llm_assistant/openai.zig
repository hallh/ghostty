const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");
const provider_base = @import("provider_base.zig");
const test_utils = @import("test_utils.zig");

const log = std.log.scoped(.openai_provider);

/// OpenAI GPT API provider
pub const OpenAIProvider = struct {
    const Self = @This();

    base: provider_base.BaseProvider,

    /// Default OpenAI API endpoint
    const API_BASE_URL = "https://api.openai.com/v1";

    /// Provider-specific defaults
    const DEFAULTS = provider_base.Defaults{
        .model = "gpt-4.1",
    };

    /// OpenAI request structure
    const OpenAIRequest = struct {
        model: []const u8,
        messages: []const Message,
        max_tokens: u32,
        temperature: f32,

        const Message = struct {
            role: []const u8,
            content: []const u8,
        };
    };

    /// OpenAI response structure
    const OpenAIResponse = struct {
        id: ?[]const u8 = null,
        object: ?[]const u8 = null,
        created: ?u64 = null,
        model: ?[]const u8 = null,
        choices: []const Choice = &.{},
        usage: ?Usage = null,
        @"error": ?ErrorDetail = null,

        const Choice = struct {
            index: ?u32 = null,
            message: ?Message = null,
            finish_reason: ?[]const u8 = null,

            const Message = struct {
                role: []const u8,
                content: ?[]const u8 = null,
            };
        };

        const Usage = struct {
            prompt_tokens: ?u32 = null,
            completion_tokens: ?u32 = null,
            total_tokens: ?u32 = null,
        };

        const ErrorDetail = struct {
            message: []const u8,
            type: []const u8,
            param: ?[]const u8 = null,
            code: ?[]const u8 = null,
        };
    };

    /// Provider vtable implementation
    pub const vtable = llm.LLMProvider.Vtable{
        .request = request,
        .deinit = deinitProvider,
    };

    /// Initialize OpenAI provider
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        cfg: *const config.Config,
    ) llm.LLMError!*OpenAIProvider {
        const provider = try allocator.create(OpenAIProvider);
        errdefer allocator.destroy(provider);

        // Get provider-specific model or use default
        const model = cfg.@"ext-llm-openai-model" orelse DEFAULTS.model;

        provider.* = OpenAIProvider{
            .base = try provider_base.BaseProvider.init(allocator, api_key, model, cfg, DEFAULTS),
        };

        return provider;
    }

    /// Clean up provider resources
    fn deinitProvider(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
    }

    /// Clean up provider resources
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        allocator.destroy(self);
    }

    /// Make a blocking request
    fn request(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
    ) llm.LLMError!llm.LLMResponse {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));

        const request_json = try self.buildRequestJSON(allocator, req);
        defer allocator.free(request_json);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.base.api_key}) },
        };
        defer allocator.free(headers[0].value);

        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        const url = API_BASE_URL ++ "/chat/completions";

        const status = try self.base.http_client.postJSON(url, &headers, request_json, &response_buffer);

        return self.parseResponse(allocator, response_buffer.items, status);
    }

    /// Build JSON request payload
    pub fn buildRequestJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
    ) llm.LLMError![]u8 {
        const messages = [_]OpenAIRequest.Message{
            .{ .role = "system", .content = req.system_prompt orelse self.base.system_prompt },
            .{ .role = "user", .content = req.prompt },
        };

        const api_request = OpenAIRequest{
            .model = req.model orelse self.base.model,
            .max_tokens = req.max_tokens orelse self.base.max_tokens,
            .temperature = req.temperature orelse self.base.temperature,
            .messages = &messages,
        };

        return std.json.stringifyAlloc(allocator, api_request, .{}) catch |err| {
            log.err("Failed to serialize OpenAI request: {}", .{err});
            return llm.LLMError.JSONParseError;
        };
    }

    /// Parse API response into LLMResponse
    pub fn parseResponse(
        _: *Self,
        allocator: std.mem.Allocator,
        response_json: []const u8,
        status: std.http.Status,
    ) llm.LLMError!llm.LLMResponse {
        // Log the raw JSON response for debugging
        log.debug("OpenAI raw JSON response (status {d}): {s}", .{ @intFromEnum(status), response_json });

        if (status.class() != .success) {
            // Try to parse error response
            if (std.json.parseFromSlice(OpenAIResponse, allocator, response_json, .{
                .ignore_unknown_fields = true,
            })) |parsed| {
                defer parsed.deinit();
                if (parsed.value.@"error") |err| {
                    const error_msg = try allocator.dupe(u8, err.message);
                    return llm.LLMResponse{
                        .command = "",
                        .error_message = error_msg,
                    };
                }
            } else |_| {}

            return llm.LLMError.APIError;
        }

        // Parse successful response
        const parsed = std.json.parseFromSlice(OpenAIResponse, allocator, response_json, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Failed to parse OpenAI response: {}", .{err});
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        // Extract command text from the first choice
        if (response.choices.len > 0) {
            const choice = response.choices[0];
            if (choice.message) |message| {
                if (message.content) |content| {
                    // Clean up the command text using base provider method
                    const cleaned_command = try provider_base.BaseProvider.cleanCommandText(allocator, content);

                    return llm.LLMResponse{
                        .command = cleaned_command,
                        .is_final = true,
                    };
                }
            }
        }

        const error_msg = try allocator.dupe(u8, "No command text received from API");
        return llm.LLMResponse{
            .command = "",
            .error_message = error_msg,
        };
    }
};

// =====================================================
// COMPREHENSIVE TESTS
// =====================================================

const testing = std.testing;

/// Mock HTTP client for testing - replaces llm.HTTPClient interface
const MockHTTPClient = struct {
    response_chunks: []const []const u8 = &[_][]const u8{},
    error_to_return: ?anyerror = null,
    status_code: std.http.Status = .ok,
    should_fail_open: bool = false,
    should_fail_write: bool = false,
    should_fail_read: bool = false,

    const Self = @This();

    pub fn init(_: std.mem.Allocator) Self {
        return Self{};
    }

    pub fn deinit(_: *Self) void {}

    /// Mock postJSONStream - simulates streaming HTTP response
    pub fn postJSONStream(
        self: *Self,
        _: []const u8, // url
        _: []const std.http.Header, // headers
        _: []const u8, // json_payload
        callback: llm.StreamCallback,
        user_data: ?*anyopaque,
    ) llm.LLMError!void {
        // Test network and connection errors from zig-docs
        if (self.error_to_return) |err| {
            return switch (err) {
                error.ConnectionRefused => llm.LLMError.NetworkError,
                error.NetworkUnreachable => llm.LLMError.NetworkError,
                error.ConnectionTimedOut => llm.LLMError.NetworkError,
                error.UnknownHostName => llm.LLMError.NetworkError,
                error.TemporaryNameServerFailure => llm.LLMError.NetworkError,
                error.OutOfMemory => llm.LLMError.OutOfMemory,
                error.TlsInitializationFailed => llm.LLMError.NetworkError,
                error.UnsupportedTransferEncoding => llm.LLMError.NetworkError,
                else => llm.LLMError.APIError,
            };
        }

        // Simulate HTTP status code errors
        if (self.status_code != .ok) {
            switch (self.status_code) {
                .unauthorized => return llm.LLMError.AuthenticationError,
                .too_many_requests => return llm.LLMError.RateLimitExceeded,
                .bad_request, .forbidden, .not_found => return llm.LLMError.APIError,
                .internal_server_error, .bad_gateway, .service_unavailable => return llm.LLMError.APIError,
                else => return llm.LLMError.APIError,
            }
        }

        // Simulate successful streaming response
        for (self.response_chunks) |chunk| {
            callback(chunk, user_data);
        }
    }
};

/// Test context for accumulating streaming responses
const TestStreamContext = struct {
    accumulated_text: std.ArrayList(u8),
    callback_count: u32 = 0,
    error_received: bool = false,
    completion_received: bool = false,

    fn init(allocator: std.mem.Allocator) TestStreamContext {
        return TestStreamContext{
            .accumulated_text = std.ArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: *TestStreamContext) void {
        self.accumulated_text.deinit();
    }

    fn streamCallback(chunk: []const u8, user_data: ?*anyopaque) void {
        const context: *TestStreamContext = @ptrCast(@alignCast(user_data.?));
        context.callback_count += 1;

        if (std.mem.startsWith(u8, chunk, "__ERROR__")) {
            context.error_received = true;
            return;
        }

        if (std.mem.eql(u8, chunk, "__COMPLETE__")) {
            context.completion_received = true;
            return;
        }

        context.accumulated_text.appendSlice(chunk) catch {
            context.error_received = true;
        };
    }
};

/// Test-specific OpenAI provider that uses MockHTTPClient
const TestOpenAIProvider = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,
    mock_client: MockHTTPClient,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    /// Test version of requestStream that uses MockHTTPClient
    pub fn requestStream(
        _: *Self,
        _: std.mem.Allocator,
        _: llm.LLMRequest,
        _: llm.StreamCallback,
        _: ?*anyopaque,
    ) llm.LLMError!void {
        // Streaming removed for simplicity - use blocking request instead
        return llm.LLMError.UnsupportedProvider;
    }
};

/// Create a test provider with mock HTTP client
fn createTestProvider(allocator: std.mem.Allocator, mock_client: MockHTTPClient) TestOpenAIProvider {
    return TestOpenAIProvider{
        .allocator = allocator,
        .api_key = "test-api-key",
        .model = "gpt-4o-mini",
        .temperature = 0.1,
        .max_tokens = 1024,
        .system_prompt = provider_base.DEFAULT_SYSTEM_PROMPT,
        .mock_client = mock_client,
    };
}

// =====================================================
// ERROR HANDLING TESTS (from zig-docs)
// =====================================================
