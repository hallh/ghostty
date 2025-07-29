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

// Use consolidated mock from test_utils
const MockHTTPClient = test_utils.MockHTTPClient;

// Use consolidated stream context from test_utils
const TestStreamContext = test_utils.TestStreamContext;

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
