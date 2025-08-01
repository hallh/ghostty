const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");
const provider_base = @import("provider_base.zig");
const test_utils = @import("test_utils.zig");

const log = std.log.scoped(.gemini_provider);

/// Google Gemini API provider
pub const GeminiProvider = struct {
    const Self = @This();

    base: provider_base.BaseProvider,

    /// Default Gemini API endpoint
    const API_BASE_URL = "https://generativelanguage.googleapis.com/v1beta";

    /// Provider-specific defaults (model comes from config)
    const DEFAULTS = provider_base.Defaults{
        // Note: max_tokens intentionally omitted due to Gemini API bug with token limiting
    };

    /// Gemini request structure
    const GeminiRequest = struct {
        contents: []const Content,
        generationConfig: ?GenerationConfig = null,
        systemInstruction: ?SystemInstruction = null,

        const Content = struct {
            role: []const u8,
            parts: []const Part,

            const Part = struct {
                text: []const u8,
            };
        };

        const GenerationConfig = struct {
            temperature: ?f32 = null,
            maxOutputTokens: ?u32 = null,
        };

        const SystemInstruction = struct {
            parts: []const Part,

            const Part = struct {
                text: []const u8,
            };
        };
    };

    /// Gemini response structure
    const GeminiResponse = struct {
        candidates: []const Candidate = &.{},
        promptFeedback: ?PromptFeedback = null,
        usageMetadata: ?UsageMetadata = null,
        @"error": ?ErrorDetail = null,

        const Candidate = struct {
            content: ?Content = null,
            finishReason: ?[]const u8 = null,
            index: ?u32 = null,
            safetyRatings: []const SafetyRating = &.{},

            const Content = struct {
                parts: []const Part = &.{},
                role: ?[]const u8 = null,

                const Part = struct {
                    text: ?[]const u8 = null,
                };
            };

            const SafetyRating = struct {
                category: []const u8,
                probability: []const u8,
            };
        };

        const PromptFeedback = struct {
            safetyRatings: []const SafetyRating = &.{},

            const SafetyRating = struct {
                category: []const u8,
                probability: []const u8,
            };
        };

        const UsageMetadata = struct {
            promptTokenCount: ?u32 = null,
            candidatesTokenCount: ?u32 = null,
            totalTokenCount: ?u32 = null,
        };

        const ErrorDetail = struct {
            code: ?u32 = null,
            message: []const u8,
            status: ?[]const u8 = null,
        };
    };

    /// Provider vtable implementation
    pub const vtable = llm.LLMProvider.Vtable{
        .request = request,
        .deinit = deinitProvider,
    };

    /// Initialize Gemini provider
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        cfg: *const config.Config,
    ) llm.LLMError!*GeminiProvider {
        const provider = try allocator.create(GeminiProvider);
        errdefer allocator.destroy(provider);

        provider.* = GeminiProvider{
            .base = try provider_base.BaseProvider.init(allocator, api_key, .gemini, cfg, DEFAULTS),
        };

        return provider;
    }

    /// Clean up provider resources
    fn deinitProvider(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
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
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));

        const request_json = try self.buildRequestJSON(allocator, req);
        defer allocator.free(request_json);

        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/models/{s}:generateContent?key={s}",
            .{ API_BASE_URL, req.model orelse self.base.model, self.base.api_key },
        );
        defer allocator.free(url);

        const status = try self.base.http_client.postJSON(url, &[_]std.http.Header{}, request_json, &response_buffer);

        return self.parseResponse(allocator, response_buffer.items, status);
    }

    /// Build JSON request payload
    pub fn buildRequestJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
    ) llm.LLMError![]u8 {
        // Build the main prompt (combines system prompt and user prompt for Gemini)
        const prompt_text = try std.fmt.allocPrint(allocator, "{s}\n\nUser request: {s}", .{ req.system_prompt orelse self.base.system_prompt, req.prompt });
        defer allocator.free(prompt_text);

        const content_part = GeminiRequest.Content.Part{ .text = prompt_text };
        const content = GeminiRequest.Content{ .role = "user", .parts = &[_]GeminiRequest.Content.Part{content_part} };

        var generation_config = GeminiRequest.GenerationConfig{};
        // Note: maxOutputTokens intentionally omitted due to Gemini API bug with token limiting
        // that causes empty responses when combined with internal reasoning tokens
        if (req.temperature) |temp| {
            generation_config.temperature = temp;
        } else {
            generation_config.temperature = self.base.temperature;
        }

        const api_request = GeminiRequest{
            .contents = &[_]GeminiRequest.Content{content},
            .systemInstruction = GeminiRequest.SystemInstruction{ .parts = &[_]GeminiRequest.SystemInstruction.Part{.{ .text = req.system_prompt orelse self.base.system_prompt }} },
            .generationConfig = generation_config,
        };

        return std.json.stringifyAlloc(allocator, api_request, .{}) catch |err| {
            log.err("Failed to serialize Gemini request: {}", .{err});
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
            if (std.json.parseFromSlice(GeminiResponse, allocator, response_json, .{
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
        const parsed = std.json.parseFromSlice(GeminiResponse, allocator, response_json, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.err("Failed to parse Gemini response: {}", .{err});
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        // Extract command text from the first candidate
        if (response.candidates.len == 0) {
            const error_msg = try allocator.dupe(u8, "No candidates in API response");
            return llm.LLMResponse{
                .command = "",
                .error_message = error_msg,
            };
        }

        const candidate = response.candidates[0];

        // Check for MAX_TOKENS finish reason with empty/minimal text
        if (candidate.finishReason) |finish_reason| {
            if (std.mem.eql(u8, finish_reason, "MAX_TOKENS")) {
                const error_msg = try allocator.dupe(u8, "Response truncated due to token limit. Try increasing max_tokens or simplifying the request.");
                return llm.LLMResponse{
                    .command = "",
                    .error_message = error_msg,
                };
            }
        }

        const content = candidate.content orelse {
            const error_msg = try allocator.dupe(u8, "No content in API response");
            return llm.LLMResponse{
                .command = "",
                .error_message = error_msg,
            };
        };

        if (content.parts.len == 0) {
            const error_msg = try allocator.dupe(u8, "No parts in API response content");
            return llm.LLMResponse{
                .command = "",
                .error_message = error_msg,
            };
        }

        const text = content.parts[0].text orelse {
            const error_msg = try allocator.dupe(u8, "No text in API response part");
            return llm.LLMResponse{
                .command = "",
                .error_message = error_msg,
            };
        };

        // Clean up the command text using base provider method
        const cleaned_command = try provider_base.BaseProvider.cleanCommandText(allocator, text);

        return llm.LLMResponse{
            .command = cleaned_command,
            .is_final = true,
        };
    }

    /// Clean up command text to ensure it's a valid shell command
    fn cleanCommandText(self: *Self, allocator: std.mem.Allocator, text: []const u8) llm.LLMError![]u8 {
        _ = self; // no instance-specific behavior
        return provider_base.BaseProvider.cleanCommandText(allocator, text);
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
    return provider_base.BaseProvider.cleanCommandText(allocator, text);
}

/// Test-specific Gemini provider that uses MockHTTPClient
const TestGeminiProvider = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,
    mock_client: MockHTTPClient,

    pub fn init(allocator: std.mem.Allocator, mock_client: MockHTTPClient) !*TestGeminiProvider {
        const provider = try allocator.create(TestGeminiProvider);
        provider.* = TestGeminiProvider{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, "test-key"),
            .model = try allocator.dupe(u8, "gemini-2.5-flash"),
            .temperature = 0.7,
            .max_tokens = 1024,
            .system_prompt = try allocator.dupe(u8, "test prompt"),
            .mock_client = mock_client,
        };
        return provider;
    }

    pub fn deinit(self: *TestGeminiProvider) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.system_prompt);
        self.allocator.destroy(self);
    }

    // Implement the provider interface methods for testing
    pub fn request(self: *TestGeminiProvider, allocator: std.mem.Allocator, req: llm.LLMRequest) !llm.LLMResponse {
        const request_json = try self.buildRequestJSON(allocator, req);
        defer allocator.free(request_json);

        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        const status = try self.mock_client.postJSON("", &[_]std.http.Header{}, request_json, &response_buffer);
        return self.parseResponse(allocator, response_buffer.items, status);
    }

    // Use GeminiProvider methods for parsing
    fn buildRequestJSON(self: *TestGeminiProvider, allocator: std.mem.Allocator, req: llm.LLMRequest) ![]u8 {
        const prompt_text = try std.fmt.allocPrint(allocator, "{s}\n\nUser request: {s}", .{ req.system_prompt orelse self.system_prompt, req.prompt });
        defer allocator.free(prompt_text);

        const content_part = GeminiProvider.GeminiRequest.Content.Part{ .text = prompt_text };
        const content = GeminiProvider.GeminiRequest.Content{
            .role = "user",
            .parts = &[_]GeminiProvider.GeminiRequest.Content.Part{content_part},
        };

        const generation_config = GeminiProvider.GeminiRequest.GenerationConfig{
            .temperature = req.temperature orelse self.temperature,
            .maxOutputTokens = req.max_tokens orelse self.max_tokens,
        };

        const api_request = GeminiProvider.GeminiRequest{
            .contents = &[_]GeminiProvider.GeminiRequest.Content{content},
            .generationConfig = generation_config,
        };

        return std.json.stringifyAlloc(allocator, api_request, .{}) catch return llm.LLMError.JSONParseError;
    }

    fn parseResponse(self: *TestGeminiProvider, allocator: std.mem.Allocator, response_json: []const u8, status: std.http.Status) !llm.LLMResponse {
        _ = self;

        if (status.class() != .success) {
            const error_msg = try allocator.dupe(u8, "HTTP error");
            return llm.LLMResponse{
                .command = "",
                .error_message = error_msg,
            };
        }

        const parsed = std.json.parseFromSlice(GeminiProvider.GeminiResponse, allocator, response_json, .{}) catch {
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        if (response.candidates.len > 0) {
            const candidate = response.candidates[0];
            if (candidate.content) |content| {
                if (content.parts.len > 0) {
                    if (content.parts[0].text) |text| {
                        const cleaned_command = try cleanTestCommandText(allocator, text);
                        return llm.LLMResponse{
                            .command = cleaned_command,
                            .is_final = true,
                        };
                    }
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

fn createTestProvider(allocator: std.mem.Allocator, mock_client: MockHTTPClient) *TestGeminiProvider {
    return TestGeminiProvider.init(allocator, mock_client) catch unreachable;
}

// =====================================================
// BASIC FUNCTIONALITY TESTS
// =====================================================

test "Gemini basic response parsing" {
    const allocator = testing.allocator;

    const response_json =
        \\{
        \\    "candidates": [
        \\        {
        \\            "content": {
        \\                "parts": [{ "text": "ls -la" }]
        \\            }
        \\        }
        \\    ]
        \\}
    ;

    const mock_client = MockHTTPClient{ .response_chunks = &[_][]const u8{response_json} };
    var provider = createTestProvider(allocator, mock_client);
    defer provider.deinit();

    const request = llm.LLMRequest{ .prompt = "list files" };
    const response = try provider.request(allocator, request);

    try testing.expectEqualStrings("ls -la", response.command);
    try testing.expect(response.is_final);

    if (response.error_message) |msg| {
        allocator.free(msg);
    }
    allocator.free(response.command);
}

test "Gemini error response" {
    const allocator = testing.allocator;

    const error_response =
        \\{
        \\    "error": {
        \\        "code": 400,
        \\        "message": "Invalid API key",
        \\        "status": "INVALID_ARGUMENT"
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

    try testing.expect(response.error_message != null);
    try testing.expectEqualStrings("", response.command);

    if (response.error_message) |msg| {
        allocator.free(msg);
    }
    allocator.free(response.command);
}

// All Gemini streaming tests removed - functionality intentionally disabled
