const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");
const provider_base = @import("provider_base.zig");
const test_utils = @import("test_utils.zig");
const i18n = @import("../os/i18n.zig");

const log = std.log.scoped(.openai_provider);

/// OpenAI GPT API provider
pub const OpenAIProvider = struct {
    const Self = @This();

    base: provider_base.BaseProvider,

    /// Default OpenAI API endpoint
    const API_BASE_URL = "https://api.openai.com/v1";

    /// Provider-specific defaults (model comes from config)
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

        provider.* = OpenAIProvider{
            .base = try provider_base.BaseProvider.init(allocator, api_key, .openai, cfg),
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

        const auth_header = try self.base.buildBearerHeader(allocator);
        defer self.base.freeHeaderValue(allocator, auth_header);
        const headers = [_]std.http.Header{auth_header};

        const url = API_BASE_URL ++ "/chat/completions";

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

        return provider_base.BaseProvider.stringifyAllocOrLog("openai", allocator, api_request);
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
        const parsed = std.json.parseFromSlice(OpenAIResponse, allocator, http_response.body, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Failed to parse OpenAI response: {}", .{err});
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        // Check for API error first
        if (response.@"error") |error_detail| {
            return llm.makeErrorResponse(allocator, error_detail.message);
        }

        // Extract command text from the first choice
        if (response.choices.len == 0) {
            return llm.makeErrorResponse(allocator, std.mem.span(i18n._("No choices in API response")));
        }

        const choice = response.choices[0];
        const message = choice.message orelse {
            return llm.makeErrorResponse(allocator, std.mem.span(i18n._("No message in API response")));
        };

        const content = message.content orelse {
            return llm.makeErrorResponse(allocator, std.mem.span(i18n._("No content in API response")));
        };

        // Clean up the command text using base provider method
        const cleaned_command = try provider_base.BaseProvider.cleanCommandText(allocator, content);
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

// =====================================================
// BASIC FUNCTIONALITY TESTS
// =====================================================

test "OpenAI basic response parsing" {
    const allocator = testing.allocator;
    const configpkg = @import("../config.zig");
    var cfg = configpkg.Config{};
    cfg.@"ext-llm-system-prompt" = "test system prompt";

    const real_response =
        \\{
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": "ls -la"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const provider = try OpenAIProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    const mock_http_response = llm.HTTPResponse{
        .body = try allocator.dupe(u8, real_response),
        .allocator = allocator,
    };
    defer {
        var mutable_mock = mock_http_response;
        mutable_mock.deinit();
    }

    const response = try provider.parseResponse(allocator, mock_http_response);
    defer {
        var mutable_response = response;
        mutable_response.deinit();
    }

    try testing.expectEqual(@as(@TypeOf(response.status), .ok), response.status);
    try testing.expectEqualStrings("ls -la", response.text);
    try testing.expect(response.is_final);
}

test "OpenAI JSON request generation" {
    const allocator = testing.allocator;
    const configpkg = @import("../config.zig");
    var cfg = configpkg.Config{};
    cfg.@"ext-llm-system-prompt" = "test system prompt";

    const provider = try OpenAIProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    const request = llm.LLMRequest{
        .prompt = "get the top 3 files by coverage excluding files with 100% coverage",
        .system_prompt = "You are a helpful assistant",
    };

    const json = try provider.buildRequestJSON(allocator, request);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("model"));
    try testing.expect(obj.contains("messages"));

    const messages = obj.get("messages").?.array;
    const user_message = messages.items[1].object;
    const user_content = user_message.get("content").?;

    // Critical test: content should be a string, not an array
    try testing.expect(user_content == .string);
    try testing.expectEqualStrings("get the top 3 files by coverage excluding files with 100% coverage", user_content.string);
    try testing.expect(user_content != .array);
}

test "OpenAI malformed JSON handling" {
    const allocator = testing.allocator;
    const configpkg = @import("../config.zig");
    var cfg = configpkg.Config{};
    cfg.@"ext-llm-system-prompt" = "test system prompt";

    const malformed_json = "{ invalid json ]}";
    const provider = try OpenAIProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    const mock_http_response = llm.HTTPResponse{
        .body = try allocator.dupe(u8, malformed_json),
        .allocator = allocator,
    };
    defer {
        var mutable_mock = mock_http_response;
        mutable_mock.deinit();
    }

    const result = provider.parseResponse(allocator, mock_http_response);
    try testing.expectError(llm.LLMError.JSONParseError, result);
}

test "OpenAI error response handling" {
    const allocator = testing.allocator;
    const configpkg = @import("../config.zig");
    var cfg = configpkg.Config{};
    cfg.@"ext-llm-system-prompt" = "test system prompt";

    const error_response =
        \\{
        \\  "error": {
        \\    "message": "Invalid API key",
        \\    "type": "invalid_request_error"
        \\  }
        \\}
    ;

    const provider = try OpenAIProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    const mock_http_response = llm.HTTPResponse{
        .body = try allocator.dupe(u8, error_response),
        .allocator = allocator,
    };
    defer {
        var mutable_mock = mock_http_response;
        mutable_mock.deinit();
    }

    const response = try provider.parseResponse(allocator, mock_http_response);
    defer {
        var mutable_response = response;
        mutable_response.deinit();
    }

    try testing.expectEqual(@as(@TypeOf(response.status), .err), response.status);
    try testing.expectEqualStrings("Invalid API key", response.text);
}
