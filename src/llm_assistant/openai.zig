const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");

const log = std.log.scoped(.openai_provider);

/// OpenAI GPT API provider
pub const OpenAIProvider = struct {
    const Self = @This();

    http_client: llm.HTTPClient,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,

    /// Default OpenAI API endpoint
    const API_BASE_URL = "https://api.openai.com/v1";
    const DEFAULT_MODEL = "gpt-4o-mini";
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

    /// OpenAI request structure
    const OpenAIRequest = struct {
        model: []const u8,
        messages: []const Message,
        max_tokens: u32,
        temperature: f32,
        stream: bool = false,

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

    /// Streaming chunk structure
    const StreamChunk = struct {
        id: ?[]const u8 = null,
        object: ?[]const u8 = null,
        created: ?u64 = null,
        model: ?[]const u8 = null,
        choices: []const StreamChoice = &.{},

        const StreamChoice = struct {
            index: ?u32 = null,
            delta: ?Delta = null,
            finish_reason: ?[]const u8 = null,

            const Delta = struct {
                role: ?[]const u8 = null,
                content: ?[]const u8 = null,
            };
        };
    };

    /// Provider vtable implementation
    pub const vtable = llm.LLMProvider.Vtable{
        .request = request,
        .requestStream = requestStream,
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

        provider.* = OpenAIProvider{
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
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
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
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));

        // Build request JSON
        const request_json = try self.buildRequestJSON(allocator, req, false);
        defer allocator.free(request_json);

        // Prepare headers
        var auth_header_buf: [512]u8 = undefined;
        const auth_value = std.fmt.bufPrint(auth_header_buf[0..], "Bearer {s}", .{self.api_key}) catch |err| switch (err) {
            error.NoSpaceLeft => return llm.LLMError.InvalidConfiguration, // API key too long
        };

        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth_value },
        };

        // Make HTTP request
        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        const url = API_BASE_URL ++ "/chat/completions";
        const status = try self.http_client.postJSON(url, &headers, request_json, &response_buffer);

        // Parse response
        return self.parseResponse(allocator, response_buffer.items, status);
    }

    /// Make a streaming request
    fn requestStream(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
        callback: llm.StreamCallback,
        user_data: ?*anyopaque,
    ) llm.LLMError!void {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));

        // Build streaming request JSON
        const request_json = try self.buildRequestJSON(allocator, req, true);
        defer allocator.free(request_json);

        // Prepare headers
        var auth_header_buf: [512]u8 = undefined;
        const auth_value = std.fmt.bufPrint(auth_header_buf[0..], "Bearer {s}", .{self.api_key}) catch |err| switch (err) {
            error.NoSpaceLeft => return llm.LLMError.InvalidConfiguration, // API key too long
        };

        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth_value },
            .{ .name = "accept", .value = "text/event-stream" },
        };

        // Create streaming context
        var stream_context = StreamContext{
            .allocator = allocator,
            .callback = callback,
            .user_data = user_data,
            .accumulated_text = std.ArrayList(u8).init(allocator),
        };
        defer stream_context.accumulated_text.deinit();

        // Make streaming HTTP request
        const url = API_BASE_URL ++ "/chat/completions";
        try self.http_client.postJSONStream(url, &headers, request_json, streamCallback, &stream_context);
    }

    /// Context for streaming callbacks
    const StreamContext = struct {
        allocator: std.mem.Allocator,
        callback: llm.StreamCallback,
        user_data: ?*anyopaque,
        accumulated_text: std.ArrayList(u8),
        error_occurred: bool = false,
    };

    /// Callback for streaming data
    fn streamCallback(chunk: []const u8, user_data: ?*anyopaque) void {
        const context: *StreamContext = @ptrCast(@alignCast(user_data.?));

        // Skip if we've already had an error
        if (context.error_occurred) return;

        // Debug logging - show raw chunk during development
        log.debug("OpenAI raw streaming chunk: {s}", .{chunk});

        // Handle server-sent events format
        var lines = std.mem.splitScalar(u8, chunk, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");

            // Skip empty lines and metadata
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "event:") or
                std.mem.startsWith(u8, trimmed, "id:") or std.mem.startsWith(u8, trimmed, ":"))
            {
                continue;
            }

            // Handle completion signal
            if (std.mem.eql(u8, trimmed, "data: [DONE]")) {
                log.debug("OpenAI stream completed normally", .{});
                return;
            }

            // Extract JSON data
            if (std.mem.startsWith(u8, trimmed, "data: ")) {
                const json_data = trimmed[6..]; // Skip "data: " prefix

                // Parse JSON chunk with relaxed parsing
                var parsed = std.json.parseFromSlice(StreamChunk, context.allocator, json_data, .{
                    .ignore_unknown_fields = true,
                }) catch |err| {
                    log.warn("Failed to parse OpenAI streaming chunk: {} - Raw data: {s}", .{ err, json_data });

                    // Signal error to UI by sending an error marker
                    context.error_occurred = true;
                    context.callback("__ERROR__Failed to parse streaming response", context.user_data);
                    return;
                };
                defer parsed.deinit();

                const stream_chunk = parsed.value;

                // Extract content from choices
                for (stream_chunk.choices) |choice| {
                    if (choice.delta) |delta| {
                        if (delta.content) |content| {
                            // Accumulate text and send to callback
                            context.accumulated_text.appendSlice(content) catch {
                                log.warn("Failed to accumulate streaming text", .{});
                                context.error_occurred = true;
                                context.callback("__ERROR__Memory allocation failed", context.user_data);
                                return;
                            };
                            context.callback(content, context.user_data);
                        }
                    }

                    // Check for finish reason
                    if (choice.finish_reason) |finish_reason| {
                        log.debug("OpenAI stream finished with reason: {s}", .{finish_reason});
                        if (std.mem.eql(u8, finish_reason, "stop")) {
                            // Send completion signal to UI
                            context.callback("__COMPLETE__", context.user_data);
                            return;
                        }
                    }
                }
            }
        }
    }

    /// Build JSON request payload
    fn buildRequestJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
        stream: bool,
    ) llm.LLMError![]u8 {
        const messages = [_]OpenAIRequest.Message{
            .{ .role = "system", .content = req.system_prompt orelse self.system_prompt },
            .{ .role = "user", .content = req.prompt },
        };

        const api_request = OpenAIRequest{
            .model = req.model orelse self.model,
            .messages = &messages,
            .max_tokens = req.max_tokens orelse self.max_tokens,
            .temperature = req.temperature orelse self.temperature,
            .stream = stream,
        };

        return std.json.stringifyAlloc(allocator, api_request, .{}) catch return llm.LLMError.JSONParseError;
    }

    /// Parse API response into LLMResponse
    fn parseResponse(
        self: *Self,
        allocator: std.mem.Allocator,
        response_json: []const u8,
        status: std.http.Status,
    ) llm.LLMError!llm.LLMResponse {
        if (status.class() != .success) {
            // Try to parse error response
            if (std.json.parseFromSlice(OpenAIResponse, allocator, response_json, .{})) |parsed| {
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
        const parsed = std.json.parseFromSlice(OpenAIResponse, allocator, response_json, .{}) catch |err| {
            log.err("Failed to parse OpenAI response: {}", .{err});
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        // Extract command text from the first choice
        if (response.choices.len > 0) {
            const choice = response.choices[0];
            if (choice.message) |message| {
                if (message.content) |content| {
                    // Clean up the command text
                    const cleaned_command = try self.cleanCommandText(allocator, content);

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

/// Create a test provider with mock HTTP client
fn createTestProvider(allocator: std.mem.Allocator, mock_client: MockHTTPClient) !OpenAIProvider {
    var provider = try OpenAIProvider.init(allocator, "test-api-key", &.{
        .@"ext-llm-api-key" = "test-key",
        .@"ext-llm-provider" = .openai,
        .@"ext-llm-model" = "gpt-4o-mini",
        .@"ext-llm-temperature" = 0.1,
        .@"ext-llm-max-tokens" = 1024,
    });

    // Replace the HTTP client with our mock
    provider.http_client = @bitCast(mock_client);
    return provider;
}

// =====================================================
// STREAMING RESPONSE TESTS
// =====================================================

test "OpenAI streaming with stop finish_reason" {
    const allocator = testing.allocator;

    const chunks = [_][]const u8{
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n",
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ls\"},\"finish_reason\":null}]}\n",
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" -la\"},\"finish_reason\":null}]}\n",
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n",
        "data: [DONE]\n",
    };

    const mock_client = MockHTTPClient{ .response_chunks = &chunks };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "list files" };
    try provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectEqualStrings("ls -la", context.accumulated_text.items);
    try testing.expect(context.completion_received);
    try testing.expect(!context.error_received);
}

test "OpenAI streaming with length finish_reason" {
    const allocator = testing.allocator;

    const chunks = [_][]const u8{
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"very long command that exceeds\"},\"finish_reason\":null}]}\n",
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n",
    };

    const mock_client = MockHTTPClient{ .response_chunks = &chunks };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    try provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectEqualStrings("very long command that exceeds", context.accumulated_text.items);
    try testing.expect(context.completion_received);
}

test "OpenAI streaming with content_filter finish_reason" {
    const allocator = testing.allocator;

    const chunks = [_][]const u8{
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"content_filter\"}]}\n",
    };

    const mock_client = MockHTTPClient{ .response_chunks = &chunks };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    try provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expect(context.completion_received);
    try testing.expectEqualStrings("", context.accumulated_text.items);
}

test "OpenAI streaming with tool_calls finish_reason" {
    const allocator = testing.allocator;

    const chunks = [_][]const u8{
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ls -la\"},\"finish_reason\":null}]}\n",
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n",
    };

    const mock_client = MockHTTPClient{ .response_chunks = &chunks };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    try provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectEqualStrings("ls -la", context.accumulated_text.items);
    try testing.expect(context.completion_received);
}

test "OpenAI streaming with function_call finish_reason" {
    const allocator = testing.allocator;

    const chunks = [_][]const u8{
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"find . -name '*.txt'\"},\"finish_reason\":null}]}\n",
        "data: {\"id\":\"chatcmpl-123\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"function_call\"}]}\n",
    };

    const mock_client = MockHTTPClient{ .response_chunks = &chunks };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    try provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectEqualStrings("find . -name '*.txt'", context.accumulated_text.items);
    try testing.expect(context.completion_received);
}

// =====================================================
// ERROR HANDLING TESTS (from zig-docs)
// =====================================================

test "OpenAI provider handles ConnectionRefused error" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .error_to_return = error.ConnectionRefused };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.NetworkError, result);
}

test "OpenAI provider handles NetworkUnreachable error" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .error_to_return = error.NetworkUnreachable };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.NetworkError, result);
}

test "OpenAI provider handles ConnectionTimedOut error" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .error_to_return = error.ConnectionTimedOut };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.NetworkError, result);
}

test "OpenAI provider handles UnknownHostName error" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .error_to_return = error.UnknownHostName };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.NetworkError, result);
}

test "OpenAI provider handles TemporaryNameServerFailure error" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .error_to_return = error.TemporaryNameServerFailure };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.NetworkError, result);
}

test "OpenAI provider handles OutOfMemory error" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .error_to_return = error.OutOfMemory };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.OutOfMemory, result);
}

test "OpenAI provider handles TlsInitializationFailed error" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .error_to_return = error.TlsInitializationFailed };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.NetworkError, result);
}

// =====================================================
// HTTP STATUS CODE TESTS (from zig-docs)
// =====================================================

test "OpenAI provider handles 401 Unauthorized" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .status_code = .unauthorized };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.AuthenticationError, result);
}

test "OpenAI provider handles 429 Too Many Requests" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .status_code = .too_many_requests };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.RateLimitExceeded, result);
}

test "OpenAI provider handles 400 Bad Request" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .status_code = .bad_request };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.APIError, result);
}

test "OpenAI provider handles 403 Forbidden" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .status_code = .forbidden };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.APIError, result);
}

test "OpenAI provider handles 500 Internal Server Error" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .status_code = .internal_server_error };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.APIError, result);
}

test "OpenAI provider handles 502 Bad Gateway" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .status_code = .bad_gateway };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.APIError, result);
}

test "OpenAI provider handles 503 Service Unavailable" {
    const allocator = testing.allocator;

    const mock_client = MockHTTPClient{ .status_code = .service_unavailable };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectError(llm.LLMError.APIError, result);
}

// =====================================================
// MALFORMED RESPONSE TESTS
// =====================================================

test "OpenAI provider handles malformed JSON" {
    const allocator = testing.allocator;

    const chunks = [_][]const u8{
        "data: {invalid json syntax}\n",
    };

    const mock_client = MockHTTPClient{ .response_chunks = &chunks };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    try provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expect(context.error_received);
    try testing.expect(!context.completion_received);
}

test "OpenAI provider handles empty response" {
    const allocator = testing.allocator;

    const chunks = [_][]const u8{};

    const mock_client = MockHTTPClient{ .response_chunks = &chunks };
    var provider = try createTestProvider(allocator, mock_client);
    defer provider.deinit(allocator);

    var context = TestStreamContext.init(allocator);
    defer context.deinit();

    const request = llm.LLMRequest{ .prompt = "test" };
    try provider.requestStream(allocator, request, TestStreamContext.streamCallback, &context);

    try testing.expectEqualStrings("", context.accumulated_text.items);
    try testing.expect(!context.completion_received);
    try testing.expect(!context.error_received);
    try testing.expect(context.callback_count == 0);
}
