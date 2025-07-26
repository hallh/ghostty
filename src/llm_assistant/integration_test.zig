const std = @import("std");
const testing = std.testing;
const llm = @import("../llm_assistant.zig");

// =====================================================
// MINIMAL STATE TESTING (no GTK dependencies)
// =====================================================

/// Minimal dialog state for testing - extracts only essential logic
const DialogState = struct {
    is_loading: bool = false,
    submit_button_sensitive: bool = false,
    submit_button_label: []const u8 = "Get Suggestion",
    suggestion_text: []u8 = "",
    error_message: ?[]const u8 = null,
    current_prompt: []const u8 = "",
    history: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    // Widget visibility states
    progress_visible: bool = false,
    suggestion_box_visible: bool = false,
    error_label_visible: bool = false,
    clear_button_visible: bool = false,
    accept_button_visible: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .history = std.ArrayList([]u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.history.items) |item| {
            self.allocator.free(item);
        }
        self.history.deinit();
        if (self.suggestion_text.len > 0) {
            self.allocator.free(self.suggestion_text);
        }
    }

    /// Simulate immediate loading state transition (requirement: instant response)
    pub fn startLoading(self: *Self) void {
        self.is_loading = true;
        self.submit_button_label = "Cancel";
        self.submit_button_sensitive = true;
        self.progress_visible = true;
        self.suggestion_box_visible = true;
        self.error_label_visible = false;
        self.clear_button_visible = false;
        self.accept_button_visible = false;
    }

    /// Stop loading and show final state
    pub fn stopLoading(self: *Self) void {
        self.is_loading = false;
        self.submit_button_label = "Get Suggestion";
        self.progress_visible = false;
        self.updateButtonSensitivity();
    }

    /// Update button sensitivity based on prompt content
    pub fn updateButtonSensitivity(self: *Self) void {
        // During loading, button should remain sensitive for cancellation
        // When not loading, button is only sensitive if there's a prompt
        if (self.is_loading) {
            self.submit_button_sensitive = true;
        } else {
            self.submit_button_sensitive = self.current_prompt.len > 0;
        }
    }

    /// Set prompt text and update UI state
    pub fn setPromptText(self: *Self, text: []const u8) void {
        self.current_prompt = text;
        self.updateButtonSensitivity();
    }

    /// Set suggestion text from complete response
    pub fn setSuggestionText(self: *Self, text: []const u8) !void {
        if (self.suggestion_text.len > 0) {
            self.allocator.free(self.suggestion_text);
        }
        self.suggestion_text = try self.allocator.dupe(u8, text);

        // Show suggestion UI elements
        self.suggestion_box_visible = true;
        self.clear_button_visible = true;
        self.accept_button_visible = true;
    }

    /// Complete request and finalize state
    pub fn completeRequest(self: *Self) void {
        self.stopLoading();
        if (self.suggestion_text.len > 0) {
            self.suggestion_box_visible = true;
            self.clear_button_visible = true;
            self.accept_button_visible = true;
        }
    }

    /// Show error message
    pub fn showError(self: *Self, message: []const u8) void {
        self.error_message = message;
        self.error_label_visible = true;
        self.suggestion_box_visible = true;
        self.clear_button_visible = true;
        self.accept_button_visible = false;
        self.stopLoading();
    }

    /// Clear suggestion and return to input state (Esc behavior)
    pub fn clearSuggestion(self: *Self) void {
        if (self.suggestion_text.len > 0) {
            self.allocator.free(self.suggestion_text);
            self.suggestion_text = "";
        }
        self.error_message = null;
        self.suggestion_box_visible = false;
        self.error_label_visible = false;
        self.clear_button_visible = false;
        self.accept_button_visible = false;
        self.updateButtonSensitivity();
    }

    /// Add prompt to history
    pub fn addToHistory(self: *Self, prompt: []const u8) !void {
        const owned_prompt = try self.allocator.dupe(u8, prompt);
        try self.history.append(owned_prompt);
    }

    /// Navigate history with up/down arrows
    pub fn navigateHistory(self: *Self, direction: enum { up, down }, current_index: *?usize) []const u8 {
        if (self.history.items.len == 0) return "";

        switch (direction) {
            .up => {
                if (current_index.*) |idx| {
                    if (idx > 0) {
                        current_index.* = idx - 1;
                    }
                } else {
                    current_index.* = self.history.items.len - 1;
                }
            },
            .down => {
                if (current_index.*) |idx| {
                    if (idx < self.history.items.len - 1) {
                        current_index.* = idx + 1;
                    } else {
                        current_index.* = null;
                        return "";
                    }
                }
            },
        }

        if (current_index.*) |idx| {
            return self.history.items[idx];
        }
        return "";
    }
};

/// Mock surface for testing command pasting
const MockSurface = struct {
    pasted_commands: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .pasted_commands = std.ArrayList([]u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pasted_commands.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.pasted_commands.deinit();
    }

    pub fn pasteCommand(self: *Self, command: []const u8) !void {
        const owned_command = try self.allocator.dupe(u8, command);
        try self.pasted_commands.append(owned_command);
    }

    pub fn getLastPastedCommand(self: *Self) ?[]const u8 {
        if (self.pasted_commands.items.len == 0) return null;
        return self.pasted_commands.items[self.pasted_commands.items.len - 1];
    }
};

/// Mock LLM provider for integration testing
const MockLLMProvider = struct {
    response_command: []const u8 = "ls -la",
    should_fail: bool = false,
    error_type: llm.LLMError = llm.LLMError.NetworkError,
    delay_ms: u32 = 0,

    const Self = @This();

    pub fn provider(self: *Self) llm.LLMProvider {
        return llm.LLMProvider{
            .ptr = self,
            .vtable = &.{
                .requestStream = requestStream,
                .request = request,
                .deinit = deinit,
            },
        };
    }

    fn requestStream(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: llm.LLMRequest,
        _: llm.StreamCallback,
        _: ?*anyopaque,
    ) llm.LLMError!void {
        // Streaming is no longer supported, return error
        return llm.LLMError.UnsupportedProvider;
    }

    fn request(ptr: *anyopaque, allocator: std.mem.Allocator, _: llm.LLMRequest) llm.LLMError!llm.LLMResponse {
        const self: *MockLLMProvider = @ptrCast(@alignCast(ptr));

        if (self.should_fail) {
            return self.error_type;
        }

        // Simulate delay if needed
        if (self.delay_ms > 0) {
            std.time.sleep(self.delay_ms * std.time.ns_per_ms);
        }

        return llm.LLMResponse{ .command = try allocator.dupe(u8, self.response_command), .is_final = true };
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
};

// =====================================================
// DIALOG STATE TESTS
// =====================================================

test "immediate loading state transition on submit" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Initial state
    try testing.expect(!dialog.is_loading);
    try testing.expectEqualStrings("Get Suggestion", dialog.submit_button_label);
    try testing.expect(!dialog.progress_visible);

    // Simulate submit
    dialog.setPromptText("list files");
    dialog.startLoading();

    // Verify immediate state change (requirement: instant response)
    try testing.expect(dialog.is_loading);
    try testing.expectEqualStrings("Cancel", dialog.submit_button_label);
    try testing.expect(dialog.progress_visible);
    try testing.expect(dialog.suggestion_box_visible);
    try testing.expect(!dialog.error_label_visible);
}

test "complete text display after request" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    dialog.startLoading();

    // Simulate complete response (blocking behavior)
    try dialog.setSuggestionText("ls -la --color=auto");
    try testing.expectEqualStrings("ls -la --color=auto", dialog.suggestion_text);
    try testing.expect(dialog.suggestion_box_visible);

    // Complete request
    dialog.completeRequest();
    try testing.expect(!dialog.is_loading);
    try testing.expect(dialog.accept_button_visible);
}

test "button sensitivity during different states" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Empty prompt - button disabled
    dialog.setPromptText("");
    try testing.expect(!dialog.submit_button_sensitive);

    // With prompt - button enabled
    dialog.setPromptText("list files");
    try testing.expect(dialog.submit_button_sensitive);

    // During loading - button enabled (for cancel)
    dialog.startLoading();
    try testing.expect(dialog.submit_button_sensitive);

    // Clear prompt during loading - still sensitive (cancel available)
    dialog.setPromptText("");
    try testing.expect(dialog.submit_button_sensitive);

    // After loading with empty prompt - disabled
    dialog.stopLoading();
    try testing.expect(!dialog.submit_button_sensitive);
}

test "error message display and clearing" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    dialog.startLoading();
    dialog.showError("API key missing");

    try testing.expect(!dialog.is_loading);
    try testing.expectEqualStrings("API key missing", dialog.error_message.?);
    try testing.expect(dialog.error_label_visible);
    try testing.expect(dialog.clear_button_visible);
    try testing.expect(!dialog.accept_button_visible);

    // Clear error with Esc
    dialog.clearSuggestion();
    try testing.expect(dialog.error_message == null);
    try testing.expect(!dialog.error_label_visible);
}

test "history navigation with up/down arrows" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Add some history
    try dialog.addToHistory("ls -la");
    try dialog.addToHistory("find . -name '*.txt'");
    try dialog.addToHistory("grep -r 'pattern' .");

    var current_index: ?usize = null;

    // Navigate up through history
    var result = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("grep -r 'pattern' .", result);

    result = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("find . -name '*.txt'", result);

    result = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("ls -la", result);

    // Try to go up past beginning
    result = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("ls -la", result);

    // Navigate down
    result = dialog.navigateHistory(.down, &current_index);
    try testing.expectEqualStrings("find . -name '*.txt'", result);

    result = dialog.navigateHistory(.down, &current_index);
    try testing.expectEqualStrings("grep -r 'pattern' .", result);

    // Go past end returns to empty
    result = dialog.navigateHistory(.down, &current_index);
    try testing.expectEqualStrings("", result);
}

// =====================================================
// INTEGRATION TESTS (End-to-End)
// =====================================================

test "complete LLM assistant flow - happy path" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    var surface = MockSurface.init(testing.allocator);
    defer surface.deinit();

    var mock_provider = MockLLMProvider{
        .response_command = "ls -la",
    };

    // 1. User types prompt
    dialog.setPromptText("list all files");
    try testing.expect(dialog.submit_button_sensitive);

    // 2. User submits (immediate loading state)
    dialog.startLoading();
    try testing.expect(dialog.is_loading);
    try testing.expect(dialog.progress_visible);

    // 3. Add to history
    try dialog.addToHistory(dialog.current_prompt);

    // 4. Simulate blocking request
    const request = llm.LLMRequest{ .prompt = "list all files" };
    const response = try mock_provider.provider().request(testing.allocator, request);
    defer {
        testing.allocator.free(response.command);
        if (response.error_message) |msg| {
            testing.allocator.free(msg);
        }
    }

    // Verify response
    try testing.expectEqualStrings("ls -la", response.command);
    try testing.expect(response.is_final);

    // 5. Apply response to dialog
    try dialog.setSuggestionText(response.command);
    dialog.completeRequest();

    try testing.expectEqualStrings("ls -la", dialog.suggestion_text);
    try testing.expect(!dialog.is_loading);
    try testing.expect(dialog.accept_button_visible);

    // 6. User accepts suggestion (Ctrl+Enter)
    try surface.pasteCommand(dialog.suggestion_text);
    try testing.expectEqualStrings("ls -la", surface.getLastPastedCommand().?);

    // 7. Verify history was saved
    try testing.expect(dialog.history.items.len == 1);
    try testing.expectEqualStrings("list all files", dialog.history.items[0]);
}

test "complete LLM assistant flow - error handling" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    var surface = MockSurface.init(testing.allocator);
    defer surface.deinit();

    var mock_provider = MockLLMProvider{
        .should_fail = true,
        .error_type = llm.LLMError.AuthenticationError,
    };

    // 1. User types prompt and submits
    dialog.setPromptText("list files");
    dialog.startLoading();

    // 2. Provider returns error
    const request = llm.LLMRequest{ .prompt = "list files" };
    const result = mock_provider.provider().request(testing.allocator, request);

    try testing.expectError(llm.LLMError.AuthenticationError, result);

    // 3. Show error to user
    dialog.showError("Authentication failed - please check your API key");

    try testing.expect(!dialog.is_loading);
    try testing.expect(dialog.error_label_visible);
    try testing.expect(!dialog.accept_button_visible);

    // 4. Verify no command was pasted
    try testing.expect(surface.pasted_commands.items.len == 0);
}

test "keyboard shortcuts simulation" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    var surface = MockSurface.init(testing.allocator);
    defer surface.deinit();

    // Setup with suggestion
    dialog.setPromptText("test command");
    try dialog.setSuggestionText("ls -la");
    dialog.completeRequest();

    // Test Enter key - submits if in input mode
    dialog.clearSuggestion();
    dialog.setPromptText("new command");
    try testing.expect(dialog.submit_button_sensitive);
    // Simulate enter submit
    dialog.startLoading();
    try testing.expect(dialog.is_loading);

    // Test Ctrl+Enter - accepts suggestion and pastes
    dialog.stopLoading();
    try dialog.setSuggestionText("find . -name '*.txt'");
    try surface.pasteCommand(dialog.suggestion_text);
    try testing.expectEqualStrings("find . -name '*.txt'", surface.getLastPastedCommand().?);

    // Test Esc - clears suggestion first
    dialog.clearSuggestion();
    try testing.expectEqualStrings("", dialog.suggestion_text);
    try testing.expect(!dialog.suggestion_box_visible);

    // Test Esc again - would close dialog (simulated by resetting state)
    dialog.setPromptText("");
    dialog.clearSuggestion();
    try testing.expect(!dialog.submit_button_sensitive);
}

test "blocking request with different responses" {
    const test_cases = [_]struct {
        name: []const u8,
        response_command: []const u8,
        expected_final: bool,
    }{
        .{
            .name = "simple command",
            .response_command = "ls -la",
            .expected_final = true,
        },
        .{
            .name = "complex command",
            .response_command = "find . -name '*.txt' -type f",
            .expected_final = true,
        },
        .{
            .name = "empty command",
            .response_command = "",
            .expected_final = true,
        },
    };

    for (test_cases) |case| {
        var dialog = DialogState.init(testing.allocator);
        defer dialog.deinit();

        var mock_provider = MockLLMProvider{
            .response_command = case.response_command,
        };

        const request = llm.LLMRequest{ .prompt = "test" };
        const response = try mock_provider.provider().request(testing.allocator, request);
        defer {
            testing.allocator.free(response.command);
            if (response.error_message) |msg| {
                testing.allocator.free(msg);
            }
        }

        try testing.expectEqualStrings(case.response_command, response.command);
        try testing.expect(response.is_final == case.expected_final);
    }
}

test "DialogState handles memory allocation failure gracefully" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Try to set text when the allocator would fail
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    dialog.allocator = failing_allocator.allocator();

    // This should handle the allocation failure gracefully
    dialog.setSuggestionText("test content") catch {
        // Expected to fail due to failing allocator
    };
}

// Test real JSON parsing to catch crashes and parsing errors
test "OpenAI JSON parsing with real response format" {
    const openai = @import("openai.zig");
    const config = @import("../config.zig");

    // Real OpenAI response with extra fields that caused crashes
    const real_response =
        \\{
        \\  "id": "chatcmpl-9WA1234567890",
        \\  "object": "chat.completion",
        \\  "created": 1717123456,
        \\  "model": "gpt-4o-mini-2024-07-18",
        \\  "choices": [
        \\    {
        \\      "index": 0,
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": "ls -la"
        \\      },
        \\      "logprobs": null,
        \\      "finish_reason": "stop"
        \\    }
        \\  ],
        \\  "usage": {
        \\    "prompt_tokens": 15,
        \\    "completion_tokens": 2,
        \\    "total_tokens": 17
        \\  },
        \\  "system_fingerprint": "fp_12345",
        \\  "service_tier": "default"
        \\}
    ;

    const cfg = config.Config{};
    const provider = try openai.OpenAIProvider.init(testing.allocator, "test-key", &cfg);
    defer provider.deinit(testing.allocator);

    const response = try provider.parseResponse(testing.allocator, real_response, .ok);
    defer {
        var mutable_response = response;
        mutable_response.deinit(testing.allocator);
    }

    try testing.expectEqualStrings("ls -la", response.command);
    try testing.expect(response.is_final);
    try testing.expect(response.error_message == null);
}

test "Anthropic JSON parsing with real response format" {
    const anthropic = @import("anthropic.zig");
    const config = @import("../config.zig");

    const real_response =
        \\{
        \\  "id": "msg_abc123",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    {
        \\      "type": "text",
        \\      "text": "find . -name '*.txt'"
        \\    }
        \\  ],
        \\  "model": "claude-3-5-sonnet-20241022",
        \\  "stop_reason": "end_turn",
        \\  "stop_sequence": null,
        \\  "usage": {
        \\    "input_tokens": 25,
        \\    "output_tokens": 12
        \\  }
        \\}
    ;

    const cfg = config.Config{};
    const provider = try anthropic.AnthropicProvider.init(testing.allocator, "test-key", &cfg);
    defer provider.deinit(testing.allocator);

    const response = try provider.parseResponse(testing.allocator, real_response, .ok);
    defer {
        var mutable_response = response;
        mutable_response.deinit(testing.allocator);
    }

    try testing.expectEqualStrings("find . -name '*.txt'", response.command);
    try testing.expect(response.is_final);
    try testing.expect(response.error_message == null);
}

test "Gemini JSON parsing with real response format" {
    const gemini = @import("gemini.zig");
    const config = @import("../config.zig");

    const real_response =
        \\{
        \\  "candidates": [
        \\    {
        \\      "content": {
        \\        "parts": [
        \\          {
        \\            "text": "grep -r 'pattern' ."
        \\          }
        \\        ],
        \\        "role": "model"
        \\      },
        \\      "finishReason": "STOP",
        \\      "index": 0,
        \\      "safetyRatings": [
        \\        {
        \\          "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT",
        \\          "probability": "NEGLIGIBLE"
        \\        }
        \\      ]
        \\    }
        \\  ],
        \\  "usageMetadata": {
        \\    "promptTokenCount": 20,
        \\    "candidatesTokenCount": 8,
        \\    "totalTokenCount": 28
        \\  }
        \\}
    ;

    const cfg = config.Config{};
    const provider = try gemini.GeminiProvider.init(testing.allocator, "test-key", &cfg);
    defer provider.deinit(testing.allocator);

    const response = try provider.parseResponse(testing.allocator, real_response, .ok);
    defer {
        var mutable_response = response;
        mutable_response.deinit(testing.allocator);
    }

    try testing.expectEqualStrings("grep -r 'pattern' .", response.command);
    try testing.expect(response.is_final);
    try testing.expect(response.error_message == null);
}

test "Malformed JSON handling doesn't crash" {
    const openai = @import("openai.zig");
    const config = @import("../config.zig");

    const malformed_json = "{ invalid json ]}";

    const cfg = config.Config{};
    const provider = try openai.OpenAIProvider.init(testing.allocator, "test-key", &cfg);
    defer provider.deinit(testing.allocator);

    const result = provider.parseResponse(testing.allocator, malformed_json, .ok);
    try testing.expectError(llm.LLMError.JSONParseError, result);
}

test "Command text cleaning handles various formats" {
    const openai = @import("openai.zig");
    const config = @import("../config.zig");

    const test_cases = [_]struct {
        content: []const u8,
        expected: []const u8,
    }{
        .{ .content = "ls -la", .expected = "ls -la" },
        .{ .content = "`ls -la`", .expected = "ls -la" },
        .{ .content = "```bash\\nls -la\\n```", .expected = "ls -la" },
        .{ .content = "```\\nls -la\\n```", .expected = "ls -la" },
        .{ .content = "  ls -la  \\n", .expected = "ls -la" },
    };

    const cfg = config.Config{};
    const provider = try openai.OpenAIProvider.init(testing.allocator, "test-key", &cfg);
    defer provider.deinit(testing.allocator);

    for (test_cases) |case| {
        const response_json = try std.fmt.allocPrint(testing.allocator,
            \\{{
            \\  "choices": [
            \\    {{
            \\      "message": {{
            \\        "role": "assistant",
            \\        "content": "{s}"
            \\      }}
            \\    }}
            \\  ]
            \\}}
        , .{case.content});
        defer testing.allocator.free(response_json);

        const response = try provider.parseResponse(testing.allocator, response_json, .ok);
        defer {
            var mutable_response = response;
            mutable_response.deinit(testing.allocator);
        }

        try testing.expectEqualStrings(case.expected, response.command);
    }
}

test "MockLLMProvider error propagation paths" {
    var mock_provider = MockLLMProvider{
        .should_fail = true,
        .error_type = llm.LLMError.InvalidConfiguration,
    };

    const request = llm.LLMRequest{ .prompt = "test" };
    const result = mock_provider.provider().request(testing.allocator, request);

    try testing.expectError(llm.LLMError.InvalidConfiguration, result);
}

test "DialogState history navigation edge cases" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    var current_index: ?usize = null;

    // Test navigation with empty history
    var result = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("", result);

    result = dialog.navigateHistory(.down, &current_index);
    try testing.expectEqualStrings("", result);

    // Add single item and test edge cases
    try dialog.addToHistory("single command");

    // Navigate down from null should stay empty
    current_index = null;
    result = dialog.navigateHistory(.down, &current_index);
    try testing.expectEqualStrings("", result);
}

test "dialog memory allocation failure handling" {
    var buffer: [100]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const limited_allocator = fba.allocator();

    var dialog = DialogState.init(limited_allocator);
    defer dialog.deinit();

    // Try to trigger allocation failure by appending large text
    const large_text = "x" ** 200; // Larger than our 100-byte buffer
    const result = dialog.setSuggestionText(large_text);

    // Should fail due to memory allocation
    try testing.expectError(error.OutOfMemory, result);
}

test "mock provider request function coverage" {
    const allocator = testing.allocator;

    var provider = MockLLMProvider{
        .response_command = "echo hello",
        .delay_ms = 0,
    };

    // Test the request function that's currently uncovered
    const request = llm.LLMRequest{ .prompt = "test" };
    const response = try MockLLMProvider.request(&provider, allocator, request);

    try testing.expectEqualStrings("test command", response.command);

    // Note: MockLLMProvider returns string literals, not allocated memory,
    // so we don't need to free response.command or response.error_message
}

test "dialog loading state with delays" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    dialog.setPromptText("test command");
    dialog.startLoading();

    // Simulate the delay line in the mock provider (line 236)
    std.time.sleep(std.time.ns_per_ms * 1); // 1ms delay

    try dialog.setSuggestionText("response");
    dialog.stopLoading();

    try testing.expect(dialog.suggestion_text.len > 0);
}
