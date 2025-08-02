const std = @import("std");
const llm = @import("../llm_assistant.zig");

/// Mock LLM Provider for testing
/// This replaces HTTP-level mocking with provider-level mocking for simpler, more reliable tests
pub const MockLLMProvider = struct {
    allocator: std.mem.Allocator,

    // Control what the mock returns
    response_command: ?[]const u8 = null,
    response_error: ?[]const u8 = null,
    error_to_return: ?llm.LLMError = null,
    should_fail_deinit: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        if (self.should_fail_deinit) {
            // Could simulate cleanup issues, but usually not needed
        }
        // Note: We don't own the strings passed in, so no cleanup needed
    }

    /// Convert to LLMProvider interface
    pub fn provider(self: *Self) llm.LLMProvider {
        return llm.LLMProvider{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = llm.LLMProvider.Vtable{
        .request = request,
        .deinit = deinitProvider,
    };

    fn request(ptr: *anyopaque, allocator: std.mem.Allocator, req: llm.LLMRequest) llm.LLMError!llm.LLMResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));

        _ = req; // unused

        if (self.error_to_return) |err| {
            return err;
        }

        const command = if (self.response_command) |cmd|
            try allocator.dupe(u8, cmd)
        else
            try allocator.dupe(u8, "echo 'mock response'");

        const error_msg = if (self.response_error) |err|
            try allocator.dupe(u8, err)
        else
            null;

        return llm.LLMResponse{
            .command = command,
            .error_message = error_msg,
            .is_final = true,
        };
    }

    fn deinitProvider(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator; // unused
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Helper function to create common mock scenarios
pub const MockScenario = struct {
    pub fn success(allocator: std.mem.Allocator, command: []const u8) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .response_command = command,
        };
    }

    pub fn errorScenario(allocator: std.mem.Allocator, err: llm.LLMError) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = err,
        };
    }

    pub fn outOfMemory(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.OutOfMemory,
        };
    }

    pub fn networkError(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.NetworkError,
        };
    }

    pub fn authError(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.AuthenticationError,
        };
    }

    pub fn apiError(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.APIError,
        };
    }

    pub fn rateLimitError(allocator: std.mem.Allocator) MockLLMProvider {
        return MockLLMProvider{
            .allocator = allocator,
            .error_to_return = llm.LLMError.RateLimitExceeded,
        };
    }
};

/// Mock HTTP client for testing - replaces llm.HTTPClient interface
/// This consolidates the MockHTTPClient implementations from all provider files
pub const MockHTTPClient = struct {
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
    ) llm.HTTPResponse {
        const allocator = std.heap.page_allocator; // Use page allocator for tests

        if (self.error_to_return != null or @intFromEnum(self.status_code) >= 400) {
            const error_body = if (self.response_chunks.len > 0)
                self.response_chunks[0]
            else
                "HTTP error";

            return llm.HTTPResponse{
                .status = .err,
                .body = allocator.dupe(u8, error_body) catch @panic("Out of memory in mock"),
                .allocator = allocator,
            };
        }

        // Simulate successful response
        const response_body = if (self.response_chunks.len > 0)
            self.response_chunks[0]
        else
            "{}";

        return llm.HTTPResponse{
            .status = .ok,
            .body = allocator.dupe(u8, response_body) catch @panic("Out of memory in mock"),
            .allocator = allocator,
        };
    }
};

/// Generic test provider that works with any real provider implementation
/// This replaces the TestXProvider structs in each provider file
pub const GenericTestProvider = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: []const u8,
    mock_client: MockHTTPClient,

    // Function pointers to real provider methods
    buildRequestJSONFn: *const fn (allocator: std.mem.Allocator, req: llm.LLMRequest, provider: *GenericTestProvider) llm.LLMError![]u8,
    parseResponseFn: *const fn (allocator: std.mem.Allocator, http_response: llm.HTTPResponse) llm.LLMError!llm.LLMResponse,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        mock_client: MockHTTPClient,
        buildRequestJSONFn: *const fn (allocator: std.mem.Allocator, req: llm.LLMRequest, provider: *GenericTestProvider) llm.LLMError![]u8,
        parseResponseFn: *const fn (allocator: std.mem.Allocator, http_response: llm.HTTPResponse) llm.LLMError!llm.LLMResponse,
        model: []const u8,
    ) !*GenericTestProvider {
        const provider = try allocator.create(GenericTestProvider);
        provider.* = GenericTestProvider{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, "test-key"),
            .model = try allocator.dupe(u8, model),
            .temperature = 0.7,
            .max_tokens = 1024,
            .system_prompt = try allocator.dupe(u8, "test prompt"),
            .mock_client = mock_client,
            .buildRequestJSONFn = buildRequestJSONFn,
            .parseResponseFn = parseResponseFn,
        };
        return provider;
    }

    pub fn deinit(self: *GenericTestProvider) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.system_prompt);
        self.allocator.destroy(self);
    }

    pub fn request(self: *GenericTestProvider, allocator: std.mem.Allocator, req: llm.LLMRequest) !llm.LLMResponse {
        const request_json = try self.buildRequestJSONFn(allocator, req, self);
        defer allocator.free(request_json);

        var http_response = self.mock_client.postJSON("", &[_]std.http.Header{}, request_json);
        defer http_response.deinit();

        return self.parseResponseFn(allocator, http_response);
    }
};

// Basic test to ensure MockHTTPClient error handling works
test "MockHTTPClient error handling" {
    const testing = std.testing;

    var mock = MockHTTPClient{
        .error_to_return = error.ConnectionRefused,
    };

    var result = mock.postJSON("", &[_]std.http.Header{}, "");
    defer result.deinit();

    try testing.expectEqual(@as(@TypeOf(result.status), .err), result.status);
}
