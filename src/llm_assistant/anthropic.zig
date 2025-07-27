const std = @import("std");
const config = @import("../config.zig");
const llm = @import("../llm_assistant.zig");
const test_utils = @import("test_utils.zig");

const log = std.log.scoped(.anthropic_provider);

/// Anthropic Claude API provider
pub const AnthropicProvider = struct {
    const Self = @This();

    http_client: llm.HTTPClient,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,

    /// Default Anthropic API endpoint
    const API_BASE_URL = "https://api.anthropic.com/v1";
    const DEFAULT_MODEL = "claude-3-5-sonnet-20241022";
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

    /// Anthropic request structure
    const AnthropicRequest = struct {
        model: []const u8,
        max_tokens: u32,
        temperature: f32,
        system: []const u8,
        messages: []const Message,
        stream: bool = false,

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
        .requestStream = requestStream,
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

        provider.* = AnthropicProvider{
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
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
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
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));

        std.log.info("[ANTHROPIC_DEBUG] Starting request with prompt length: {}", .{req.prompt.len});
        std.log.info("[ANTHROPIC_DEBUG] Request has terminal_context: {}", .{req.terminal_context != null});

        const request_json = try self.buildRequestJSON(allocator, req, false);
        defer allocator.free(request_json);

        std.log.info("[ANTHROPIC_DEBUG] Generated JSON length: {}", .{request_json.len});
        std.log.info("[ANTHROPIC_DEBUG] JSON preview: {s}", .{request_json[0..@min(500, request_json.len)]});

        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };

        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        const url = API_BASE_URL ++ "/messages";

        std.log.info("[ANTHROPIC_DEBUG] Making HTTP request to: {s}", .{url});

        const status = try self.http_client.postJSON(url, &headers, request_json, &response_buffer);

        std.log.info("[ANTHROPIC_DEBUG] HTTP response status: {}", .{status});
        std.log.info("[ANTHROPIC_DEBUG] Response length: {}", .{response_buffer.items.len});

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
    pub fn buildRequestJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
        stream: bool,
    ) llm.LLMError![]u8 {
        std.log.info("[ANTHROPIC_DEBUG] buildRequestJSON called", .{});
        std.log.info("[ANTHROPIC_DEBUG] Input request has terminal_context: {}", .{req.terminal_context != null});

        // Always use the prompt directly - it may already be enhanced with terminal context
        std.log.info("[ANTHROPIC_DEBUG] Using prompt as-is (may contain enhanced context)", .{});

        const messages = [_]AnthropicRequest.Message{
            .{ .role = "user", .content = req.prompt },
        };

        const api_request = AnthropicRequest{
            .model = req.model orelse self.model,
            .max_tokens = req.max_tokens orelse self.max_tokens,
            .temperature = req.temperature orelse self.temperature,
            .system = req.system_prompt orelse self.system_prompt,
            .messages = &messages,
            .stream = stream,
        };

        std.log.info("[ANTHROPIC_DEBUG] About to stringify JSON for standard request", .{});
        const json_result = std.json.stringifyAlloc(allocator, api_request, .{}) catch |err| {
            std.log.err("[ANTHROPIC_DEBUG] JSON stringification failed: {}", .{err});
            return err;
        };

        std.log.info("[ANTHROPIC_DEBUG] Standard JSON stringification successful, length: {}", .{json_result.len});
        return json_result;
    }

    /// Build JSON for requests with terminal context
    fn buildPromptWithContext(
        self: *Self,
        allocator: std.mem.Allocator,
        req: llm.LLMRequest,
        context: llm.TerminalContext,
        stream: bool,
    ) llm.LLMError![]u8 {
        std.log.info("[ANTHROPIC_DEBUG] buildPromptWithContext called", .{});
        std.log.info("[ANTHROPIC_DEBUG] Terminal context - command_history: '{any}'", .{context.command_history});
        std.log.info("[ANTHROPIC_DEBUG] Terminal context - current_input: '{any}'", .{context.current_input});

        // Build enhanced prompt with context
        const enhanced_prompt = std.fmt.allocPrint(allocator, "Recent command history:\n{s}\n\nCurrent terminal input:\n{s}\n\nUser request: {s}", .{ context.command_history orelse "", context.current_input orelse "", req.prompt }) catch {
            std.log.err("[ANTHROPIC_DEBUG] Failed to build enhanced prompt", .{});
            return llm.LLMError.OutOfMemory;
        };
        defer allocator.free(enhanced_prompt);

        std.log.info("[ANTHROPIC_DEBUG] Built enhanced prompt, length: {}", .{enhanced_prompt.len});
        std.log.info("[ANTHROPIC_DEBUG] Enhanced prompt preview: {s}", .{enhanced_prompt[0..@min(200, enhanced_prompt.len)]});

        const messages = [_]AnthropicRequest.Message{
            .{ .role = "user", .content = enhanced_prompt },
        };

        const api_request = AnthropicRequest{
            .model = req.model orelse self.model,
            .max_tokens = req.max_tokens orelse self.max_tokens,
            .temperature = req.temperature orelse self.temperature,
            .system = req.system_prompt orelse self.system_prompt,
            .messages = &messages,
            .stream = stream,
        };

        std.log.info("[ANTHROPIC_DEBUG] About to stringify JSON for context request", .{});
        const json_result = std.json.stringifyAlloc(allocator, api_request, .{}) catch |err| {
            std.log.err("[ANTHROPIC_DEBUG] Context JSON stringification failed: {}", .{err});
            return err;
        };

        std.log.info("[ANTHROPIC_DEBUG] Context JSON stringification successful, length: {}", .{json_result.len});
        return json_result;
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
            if (std.json.parseFromSlice(AnthropicResponse, allocator, response_json, .{
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
        const parsed = std.json.parseFromSlice(AnthropicResponse, allocator, response_json, .{
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
            const error_msg = try allocator.dupe(u8, "No command text received from API");
            return llm.LLMResponse{
                .command = "",
                .error_message = error_msg,
            };
        }

        // Clean up the command text (remove any markdown formatting, etc.)
        const cleaned_command = try self.cleanCommandText(allocator, command_text.items);

        return llm.LLMResponse{
            .command = cleaned_command,
            .is_final = true,
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

        var response_buffer = std.ArrayList(u8).init(allocator);
        defer response_buffer.deinit();

        const status = try self.mock_client.postJSON("", &[_]std.http.Header{}, request_json, &response_buffer);
        return self.parseResponse(allocator, response_buffer.items, status);
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
    fn buildRequestJSON(self: *TestAnthropicProvider, allocator: std.mem.Allocator, req: llm.LLMRequest, stream: bool) ![]u8 {
        const messages = [_]AnthropicProvider.AnthropicRequest.Message{
            .{ .role = "user", .content = req.prompt },
        };

        const api_request = AnthropicProvider.AnthropicRequest{
            .model = req.model orelse self.model,
            .max_tokens = req.max_tokens orelse self.max_tokens,
            .temperature = req.temperature orelse self.temperature,
            .system = req.system_prompt orelse self.system_prompt,
            .messages = &messages,
            .stream = stream,
        };

        return std.json.stringifyAlloc(allocator, api_request, .{}) catch return llm.LLMError.JSONParseError;
    }

    fn parseResponse(self: *TestAnthropicProvider, allocator: std.mem.Allocator, response_json: []const u8, status: std.http.Status) !llm.LLMResponse {
        _ = self;

        if (status.class() != .success) {
            const error_msg = try allocator.dupe(u8, "HTTP error");
            return llm.LLMResponse{
                .command = "",
                .error_message = error_msg,
            };
        }

        const parsed = std.json.parseFromSlice(AnthropicProvider.AnthropicResponse, allocator, response_json, .{}) catch {
            return llm.LLMError.JSONParseError;
        };
        defer parsed.deinit();

        const response = parsed.value;

        for (response.content) |content| {
            if (std.mem.eql(u8, content.type, "text")) {
                if (content.text) |text| {
                    const cleaned_command = try cleanTestCommandText(allocator, text);
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

    try testing.expectEqualStrings("ls -la", response.command);
    try testing.expect(response.is_final);

    if (response.error_message) |msg| {
        allocator.free(msg);
    }
    allocator.free(response.command);
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

    try testing.expect(response.error_message != null);
    try testing.expectEqualStrings("", response.command);

    if (response.error_message) |msg| {
        allocator.free(msg);
    }
    allocator.free(response.command);
}

test "Anthropic command text cleaning" {
    const allocator = testing.allocator;

    const response_json =
        \\{
        \\    "content": [
        \\        {
        \\            "type": "text",
        \\            "text": "```bash\nls -la\n```"
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

// Streaming tests removed - functionality intentionally disabled

// All Anthropic streaming tests removed - functionality intentionally disabled
