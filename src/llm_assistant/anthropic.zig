const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");
const provider_base = @import("provider_base.zig");
const test_utils = @import("test_utils.zig");
const i18n = @import("../os/i18n.zig");

const log = std.log.scoped(.anthropic_provider);

/// Anthropic Claude API provider
pub const AnthropicProvider = struct {
    const Self = @This();

    base: provider_base.BaseProvider,

    /// Default Anthropic API endpoint
    const API_BASE_URL = "https://api.anthropic.com/v1";

    /// Provider-specific defaults (model comes from config)
    const DEFAULTS = provider_base.Defaults{};

    /// Anthropic request structure
    const AnthropicRequest = struct {
        model: []const u8,
        max_tokens: u32,
        temperature: f32,
        system: []const u8,
        messages: []const Message,

        const Message = struct {
            role: []const u8,
            content: []const u8,
        };
    };

    /// Anthropic response structure
    const AnthropicResponse = struct {
        id: ?[]const u8 = null,
        type: ?[]const u8 = null,
        role: ?[]const u8 = null,
        content: []const Content = &.{},
        model: ?[]const u8 = null,
        stop_reason: ?[]const u8 = null,
        stop_sequence: ?[]const u8 = null,
        usage: ?Usage = null,
        @"error": ?ErrorDetail = null,

        const Content = struct {
            type: []const u8,
            text: ?[]const u8 = null,
        };

        const Usage = struct {
            input_tokens: ?u32 = null,
            output_tokens: ?u32 = null,
        };

        const ErrorDetail = struct {
            type: []const u8,
            message: []const u8,
        };
    };

    /// Provider vtable implementation
    pub const vtable = llm.LLMProvider.Vtable{
        .request = request,
        .deinit = deinitProvider,
    };

    /// Initialize Anthropic provider
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        cfg: *const config.Config,
    ) llm.LLMError!*AnthropicProvider {
        const provider = try allocator.create(AnthropicProvider);
        errdefer allocator.destroy(provider);

        provider.* = AnthropicProvider{
            .base = try provider_base.BaseProvider.init(allocator, api_key, .anthropic, cfg, DEFAULTS),
        };

        return provider;
    }

    /// Clean up provider resources
    fn deinitProvider(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
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
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));

        const request_json = try self.buildRequestJSON(allocator, req);
        defer allocator.free(request_json);

        const headers = [_]std.http.Header{
            self.base.buildXApiKeyHeader(),
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };

        const url = API_BASE_URL ++ "/messages";

        return self.base.sendJSONRequest(allocator, url, &headers, request_json, parseResponseWrapper);
    }

    /// Wrapper function for parseResponse to match sendJSONRequest signature
    fn parseResponseWrapper(
        allocator: std.mem.Allocator,
        http_response: llm.HTTPResponse,
    ) llm.LLMError!llm.LLMResponse {
        return parseResponseImpl(allocator, http_response);
    }

    /// Build JSON request payload
    pub fn buildRequestJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
    ) llm.LLMError![]u8 {
        const messages = [_]AnthropicRequest.Message{
            .{ .role = "user", .content = req.prompt },
        };

        const api_request = AnthropicRequest{
            .model = req.model orelse self.base.model,
            .max_tokens = req.max_tokens orelse self.base.max_tokens,
            .temperature = req.temperature orelse self.base.temperature,
            .system = req.system_prompt orelse self.base.system_prompt,
            .messages = &messages,
        };

        return provider_base.BaseProvider.stringifyAllocOrLog("anthropic", allocator, api_request);
    }

    /// Parse API response into LLMResponse
    pub fn parseResponse(
        _: *Self,
        allocator: std.mem.Allocator,
        http_response: llm.HTTPResponse,
    ) llm.LLMError!llm.LLMResponse {
        return parseResponseImpl(allocator, http_response);
    }

    /// Internal implementation of response parsing
    fn parseResponseImpl(
        allocator: std.mem.Allocator,
        http_response: llm.HTTPResponse,
    ) llm.LLMError!llm.LLMResponse {
        // Parse successful response
        const parsed = std.json.parseFromSlice(AnthropicResponse, allocator, http_response.body, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.err("Failed to parse Anthropic response: {}", .{err});
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        // Extract command text from content blocks
        var command_text = std.ArrayList(u8).init(allocator);
        defer command_text.deinit();

        for (response.content) |content| {
            if (std.mem.eql(u8, content.type, "text")) {
                if (content.text) |text| {
                    try command_text.appendSlice(text);
                }
            }
        }

        if (command_text.items.len == 0) {
            return llm.makeErrorResponse(allocator, std.mem.span(i18n._("No command text received from API")));
        }

        // Clean up the command text using base provider method
        const cleaned_command = try provider_base.BaseProvider.cleanCommandText(allocator, command_text.items);
        defer allocator.free(cleaned_command);

        return llm.makeSuccessResponse(allocator, cleaned_command);
    }
};

// =====================================================
// COMPREHENSIVE TESTS
// =====================================================

const testing = std.testing;

// Use consolidated mock from test_utils
const MockHTTPClient = test_utils.MockHTTPClient;

/// Helper function to clean command text for tests
fn cleanTestCommandText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    // Forward to shared helper to avoid duplicated logic
    return provider_base.BaseProvider.cleanCommandText(allocator, text);
}

/// Test-specific Anthropic provider that uses MockHTTPClient
const TestAnthropicProvider = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,
    mock_client: MockHTTPClient,

    pub fn init(allocator: std.mem.Allocator, mock_client: MockHTTPClient) !*TestAnthropicProvider {
        const provider = try allocator.create(TestAnthropicProvider);
        provider.* = TestAnthropicProvider{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, "test-key"),
            .model = try allocator.dupe(u8, "claude-3-5-sonnet-20241022"),
            .temperature = 0.7,
            .max_tokens = 1024,
            .system_prompt = try allocator.dupe(u8, "test prompt"),
            .mock_client = mock_client,
        };
        return provider;
    }

    pub fn deinit(self: *TestAnthropicProvider) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.system_prompt);
        self.allocator.destroy(self);
    }

    // Implement the provider interface methods for testing
    pub fn request(self: *TestAnthropicProvider, allocator: std.mem.Allocator, req: llm.LLMRequest) !llm.LLMResponse {
        const request_json = try self.buildRequestJSON(allocator, req, false);
        defer allocator.free(request_json);

        var http_response = self.mock_client.postJSON("", &[_]std.http.Header{}, request_json) catch |err| {
            const error_msg = switch (err) {
                llm.LLMError.APIError => std.mem.span(i18n._("API Error")),
                llm.LLMError.NetworkError => std.mem.span(i18n._("Network Error")),
                else => std.mem.span(i18n._("HTTP Error")),
            };
            return llm.makeErrorResponse(allocator, error_msg);
        };
        defer http_response.deinit();

        return self.parseResponse(allocator, http_response);
    }

    pub fn requestStream(
        _: *TestAnthropicProvider,
        _: std.mem.Allocator,
        _: llm.LLMRequest,
        _: llm.StreamCallback,
        _: ?*anyopaque,
    ) !void {
        // Streaming removed for simplicity - use blocking request instead
        return llm.LLMError.UnsupportedProvider;
    }

    // Use AnthropicProvider methods for parsing
    fn buildRequestJSON(self: *TestAnthropicProvider, allocator: std.mem.Allocator, req: llm.LLMRequest, _: bool) ![]u8 {
        const messages = [_]AnthropicProvider.AnthropicRequest.Message{
            .{ .role = "user", .content = req.prompt },
        };

        const api_request = AnthropicProvider.AnthropicRequest{
            .model = req.model orelse self.model,
            .max_tokens = req.max_tokens orelse self.max_tokens,
            .temperature = req.temperature orelse self.temperature,
            .system = req.system_prompt orelse self.system_prompt,
            .messages = &messages,
        };

        return std.json.stringifyAlloc(allocator, api_request, .{}) catch return llm.LLMError.JSONParseError;
    }

    fn parseResponse(self: *TestAnthropicProvider, allocator: std.mem.Allocator, http_response: llm.HTTPResponse) !llm.LLMResponse {
        _ = self;

        const parsed = std.json.parseFromSlice(AnthropicProvider.AnthropicResponse, allocator, http_response.body, .{}) catch {
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        for (response.content) |content| {
            if (std.mem.eql(u8, content.type, "text")) {
                if (content.text) |text| {
                    const cleaned_command = try cleanTestCommandText(allocator, text);
                    defer allocator.free(cleaned_command);
                    return llm.makeSuccessResponse(allocator, cleaned_command);
                }
            }
        }

        return llm.makeErrorResponse(allocator, std.mem.span(i18n._("No command text received from API")));
    }
};

fn createTestProvider(allocator: std.mem.Allocator, mock_client: MockHTTPClient) *TestAnthropicProvider {
    return TestAnthropicProvider.init(allocator, mock_client) catch unreachable;
}

// =====================================================
// BASIC FUNCTIONALITY TESTS
// =====================================================

test "Anthropic basic response parsing" {
    const allocator = testing.allocator;

    const response_json =
        \\{
        \\    "id": "msg_123",
        \\    "type": "message",
        \\    "role": "assistant",
        \\    "content": [
        \\        {
        \\            "type": "text",
        \\            "text": "ls -la"
        \\        }
        \\    ],
        \\    "model": "claude-3-5-sonnet-20241022",
        \\    "stop_reason": "end_turn",
        \\    "stop_sequence": null,
        \\    "usage": {
        \\        "input_tokens": 20,
        \\        "output_tokens": 6
        \\    }
        \\}
    ;

    const mock_client = MockHTTPClient{ .response_chunks = &[_][]const u8{response_json} };
    var provider = createTestProvider(allocator, mock_client);
    defer provider.deinit();

    const request = llm.LLMRequest{ .prompt = "list files" };
    const response = try provider.request(allocator, request);

    try testing.expectEqual(@as(@TypeOf(response.status), .ok), response.status);
    try testing.expectEqualStrings("ls -la", response.text);
    try testing.expect(response.is_final);

    var mutable_response = response;
    mutable_response.deinit();
}

// Anthropic streaming tests removed - streaming functionality intentionally disabled

test "Anthropic error response" {
    const allocator = testing.allocator;

    const error_response =
        \\{
        \\    "type": "error",
        \\    "error": {
        \\        "type": "invalid_request_error",
        \\        "message": "Invalid API key"
        \\    }
        \\}
    ;

    const mock_client = MockHTTPClient{
        .response_chunks = &[_][]const u8{error_response},
        .status_code = .bad_request,
    };
    var provider = createTestProvider(allocator, mock_client);
    defer provider.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const response = try provider.request(allocator, request);

    try testing.expectEqual(@as(@TypeOf(response.status), .err), response.status);

    var mutable_response = response;
    mutable_response.deinit();
}

// Streaming tests removed - functionality intentionally disabled

// All Anthropic streaming tests removed - functionality intentionally disabled
