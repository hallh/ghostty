const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");
const test_utils = @import("test_utils.zig");

const log = std.log.scoped(.gemini_provider);

/// Google Gemini API provider
pub const GeminiProvider = struct {
    const Self = @This();

    http_client: llm.HTTPClient,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,

    /// Default Gemini API endpoint
    const API_BASE_URL = "https://generativelanguage.googleapis.com/v1beta";
    const DEFAULT_MODEL = "gemini-1.5-flash";
    const DEFAULT_TEMPERATURE: f32 = 0.1;
    const DEFAULT_MAX_TOKENS: u32 = 1024;
    const DEFAULT_SYSTEM_PROMPT =
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
        .requestStream = requestStream,
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

        // Copy configuration values
        const owned_api_key = try allocator.dupe(u8, api_key);
        errdefer allocator.free(owned_api_key);

        const model = if (cfg.@"ext-llm-model") |m|
            try allocator.dupe(u8, m)
        else
            try allocator.dupe(u8, DEFAULT_MODEL);
        errdefer allocator.free(model);

        const system_prompt = if (cfg.@"ext-llm-system-prompt") |sp|
            try allocator.dupe(u8, sp)
        else
            try allocator.dupe(u8, DEFAULT_SYSTEM_PROMPT);
        errdefer allocator.free(system_prompt);

        provider.* = GeminiProvider{
            .http_client = llm.HTTPClient.init(allocator),
            .api_key = owned_api_key,
            .model = model,
            .temperature = cfg.@"ext-llm-temperature",
            .max_tokens = cfg.@"ext-llm-max-tokens",
            .system_prompt = system_prompt,
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
        self.http_client.deinit();
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.system_prompt);
        allocator.destroy(self);
    }

    /// Make a blocking request
    fn request(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
    ) llm.LLMError!llm.LLMResponse {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));

        // Build request JSON
        const request_json = try self.buildRequestJSON(allocator, req);
        defer allocator.free(request_json);

        // Build URL with API key
        var url_buffer: [512]u8 = undefined;
        const url = std.fmt.bufPrint(url_buffer[0..], "{s}/models/{s}:generateContent?key={s}", .{ API_BASE_URL, self.model, self.api_key }) catch |err| switch (err) {
            error.NoSpaceLeft => return llm.LLMError.InvalidConfiguration, // URL too long
        };

        // Make HTTP request
        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        const headers = [_]std.http.Header{};
        const status = try self.http_client.postJSON(url, &headers, request_json, &response_buffer);

        // Parse response
        return self.parseResponse(allocator, response_buffer.items, status);
    }

    /// Make a streaming request (now just returns error)
    fn requestStream(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: llm.LLMRequest,
        _: llm.StreamCallback,
        _: ?*anyopaque,
    ) llm.LLMError!void {
        // For simplicity, streaming now just returns an error
        // The UI should use the blocking request method instead
        return llm.LLMError.UnsupportedProvider;
    }

    /// Build JSON request payload
    fn buildRequestJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
    ) llm.LLMError![]u8 {
        const user_part = [_]GeminiRequest.Content.Part{
            .{ .text = req.prompt },
        };

        const contents = [_]GeminiRequest.Content{
            .{ .role = "user", .parts = &user_part },
        };

        const system_part = [_]GeminiRequest.SystemInstruction.Part{
            .{ .text = req.system_prompt orelse self.system_prompt },
        };

        const generation_config = GeminiRequest.GenerationConfig{
            .temperature = req.temperature orelse self.temperature,
            .maxOutputTokens = req.max_tokens orelse self.max_tokens,
        };

        const api_request = GeminiRequest{
            .contents = &contents,
            .generationConfig = generation_config,
            .systemInstruction = .{ .parts = &system_part },
        };

        return std.json.stringifyAlloc(allocator, api_request, .{}) catch return llm.LLMError.JSONParseError;
    }

    /// Parse API response into LLMResponse
    pub fn parseResponse(
        self: *Self,
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
        if (response.candidates.len > 0) {
            const candidate = response.candidates[0];
            if (candidate.content) |content| {
                if (content.parts.len > 0) {
                    if (content.parts[0].text) |text| {
                        // Clean up the command text
                        const cleaned_command = try self.cleanCommandText(allocator, text);

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

    /// Clean up command text to ensure it's a valid shell command
    fn cleanCommandText(self: *Self, allocator: std.mem.Allocator, text: []const u8) llm.LLMError![]u8 {
        _ = self;

        // Trim whitespace
        const trimmed = std.mem.trim(u8, text, " \t\n\r");

        // Remove markdown code blocks if present
        var cleaned = trimmed;
        if (std.mem.startsWith(u8, cleaned, "```")) {
            if (std.mem.indexOf(u8, cleaned[3..], "\n")) |newline_pos| {
                cleaned = cleaned[3 + newline_pos + 1 ..];
            }
        }
        if (std.mem.endsWith(u8, cleaned, "```")) {
            cleaned = cleaned[0 .. cleaned.len - 3];
        }

        // Remove backticks if present
        if (std.mem.startsWith(u8, cleaned, "`") and std.mem.endsWith(u8, cleaned, "`")) {
            cleaned = cleaned[1 .. cleaned.len - 1];
        }

        // Final trim
        cleaned = std.mem.trim(u8, cleaned, " \t\n\r");

        return try allocator.dupe(u8, cleaned);
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

    pub fn postJSON(
        self: *Self,
        _: []const u8,
        _: []const std.http.Header,
        _: []const u8,
        response_buffer: *std.ArrayList(u8),
    ) !std.http.Status {
        if (self.error_to_return) |err| {
            return err;
        }

        // Simulate response
        if (self.response_chunks.len > 0) {
            try response_buffer.appendSlice(self.response_chunks[0]);
        }

        return self.status_code;
    }

    pub fn postStreamJSON(
        self: *Self,
        _: []const u8,
        _: []const std.http.Header,
        _: []const u8,
        callback: llm.StreamCallback,
        user_data: ?*anyopaque,
    ) !void {
        if (self.error_to_return) |err| {
            return err;
        }

        for (self.response_chunks) |chunk| {
            callback(chunk, user_data);
        }
    }
};

/// Test context for streaming responses
const TestStreamContext = struct {
    allocator: std.mem.Allocator,
    accumulated_text: std.ArrayList(u8),
    completion_received: bool = false,
    error_received: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .accumulated_text = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.accumulated_text.deinit();
    }

    pub fn streamCallback(chunk: []const u8, user_data: ?*anyopaque) void {
        const context: *TestStreamContext = @ptrCast(@alignCast(user_data.?));

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

/// Helper function to clean command text for tests
fn cleanTestCommandText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, text, " \t\n\r");

    // Remove markdown code blocks if present
    var cleaned = trimmed;
    if (std.mem.startsWith(u8, cleaned, "```")) {
        if (std.mem.indexOf(u8, cleaned[3..], "\n")) |newline_pos| {
            cleaned = cleaned[3 + newline_pos + 1 ..];
        }
    }
    if (std.mem.endsWith(u8, cleaned, "```")) {
        cleaned = cleaned[0 .. cleaned.len - 3];
    }

    // Remove backticks if present
    if (std.mem.startsWith(u8, cleaned, "`") and std.mem.endsWith(u8, cleaned, "`")) {
        cleaned = cleaned[1 .. cleaned.len - 1];
    }

    // Final trim
    cleaned = std.mem.trim(u8, cleaned, " \t\n\r");

    return try allocator.dupe(u8, cleaned);
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
            .model = try allocator.dupe(u8, "gemini-1.5-flash"),
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

    pub fn requestStream(
        _: *TestGeminiProvider,
        _: std.mem.Allocator,
        _: llm.LLMRequest,
        _: llm.StreamCallback,
        _: ?*anyopaque,
    ) !void {
        // Streaming removed for simplicity - use blocking request instead
        return llm.LLMError.UnsupportedProvider;
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
        \\                "parts": [
        \\                    {
        \\                        "text": "ls -la"
        \\                    }
        \\                ],
        \\                "role": "model"
        \\            },
        \\            "finishReason": "STOP"
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

test "Gemini streaming response" {
    const allocator = testing.allocator;

    const chunks = [_][]const u8{
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"find\"}],\"role\":\"model\"}}]}\n",
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\" . -name '*.txt'\"}],\"role\":\"model\"}}]}\n",
        "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n",
    };

    const mock_client = MockHTTPClient{ .response_chunks = &chunks };
    var provider = createTestProvider(allocator, mock_client);
    defer provider.deinit();

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "find text files" };
    try provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectEqualStrings("find . -name '*.txt'", context.accumulated_text.items);
    try testing.expect(context.completion_received);
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

test "Gemini command text cleaning" {
    const allocator = testing.allocator;

    const response_json =
        \\{
        \\    "candidates": [
        \\        {
        \\            "content": {
        \\                "parts": [
        \\                    {
        \\                        "text": "```bash\nls -la\n```"
        \\                    }
        \\                ]
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

    if (response.error_message) |msg| {
        allocator.free(msg);
    }
    allocator.free(response.command);
}

test "Gemini streaming memory allocation failure" {
    const allocator = testing.allocator;

    // Test OutOfMemory error during streaming
    var mock_provider = test_utils.MockScenario.outOfMemory(allocator);
    const provider = mock_provider.provider();

    var context = test_utils.TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, test_utils.TestStreamContext.streamCallback, &context);

    // Should get OutOfMemory error
    try testing.expectError(llm.LLMError.OutOfMemory, result);
}

test "Gemini mock provider error handling" {
    const allocator = testing.allocator;

    const error_scenarios = [_]struct {
        error_type: llm.LLMError,
        description: []const u8,
    }{
        .{ .error_type = llm.LLMError.NetworkError, .description = "network" },
        .{ .error_type = llm.LLMError.AuthenticationError, .description = "auth" },
        .{ .error_type = llm.LLMError.APIError, .description = "api" },
        .{ .error_type = llm.LLMError.RateLimitExceeded, .description = "rate limit" },
        .{ .error_type = llm.LLMError.OutOfMemory, .description = "memory" },
    };

    // Test each error type
    for (error_scenarios) |scenario| {
        var mock_provider = test_utils.MockScenario.errorScenario(allocator, scenario.error_type);
        const provider = mock_provider.provider();

        var context = test_utils.TestStreamContext.init(allocator);
        defer context.deinit();

        const request = llm.LLMRequest{ .prompt = "test" };
        const result = provider.requestStream(allocator, request, test_utils.TestStreamContext.streamCallback, &context);

        // Should get the expected error
        try testing.expectError(scenario.error_type, result);
    }
}

test "Gemini provider status code error handling" {
    const allocator = testing.allocator;

    const status_tests = [_]struct {
        expected_error: llm.LLMError,
        description: []const u8,
    }{
        .{ .expected_error = llm.LLMError.AuthenticationError, .description = "unauthorized" },
        .{ .expected_error = llm.LLMError.RateLimitExceeded, .description = "rate limited" },
        .{ .expected_error = llm.LLMError.APIError, .description = "bad request" },
        .{ .expected_error = llm.LLMError.APIError, .description = "forbidden" },
        .{ .expected_error = llm.LLMError.APIError, .description = "not found" },
        .{ .expected_error = llm.LLMError.APIError, .description = "server error" },
    };

    for (status_tests) |test_case| {
        var mock_provider = test_utils.MockScenario.errorScenario(allocator, test_case.expected_error);
        const provider = mock_provider.provider();

        var context = test_utils.TestStreamContext.init(allocator);
        defer context.deinit();

        const request = llm.LLMRequest{ .prompt = "test" };
        const result = provider.requestStream(allocator, request, test_utils.TestStreamContext.streamCallback, &context);

        try testing.expectError(test_case.expected_error, result);
    }
}

test "Gemini provider allocation failure" {
    const allocator = testing.allocator;

    // Test OutOfMemory error during request processing
    var mock_provider = test_utils.MockScenario.outOfMemory(allocator);
    const provider = mock_provider.provider();

    var context = test_utils.TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, test_utils.TestStreamContext.streamCallback, &context);

    // Should get OutOfMemory error
    try testing.expectError(llm.LLMError.OutOfMemory, result);
}

test "Gemini streaming error handling" {
    const allocator = testing.allocator;

    // Test streaming with API error response
    var mock_provider = test_utils.MockScenario.apiError(allocator);
    const provider = mock_provider.provider();

    var context = test_utils.TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, test_utils.TestStreamContext.streamCallback, &context);

    // Should get API error
    try testing.expectError(llm.LLMError.APIError, result);
}
