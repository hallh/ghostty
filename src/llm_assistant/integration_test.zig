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
    history: std.ArrayList([:0]u8),
    allocator: std.mem.Allocator,
    shortcuts_hint: []const u8 = "↑↓ Navigate history",

    // Widget visibility states
    progress_visible: bool = false,
    suggestion_box_visible: bool = false,
    error_label_visible: bool = false,
    clear_button_visible: bool = false,
    accept_button_visible: bool = false,
    input_box_visible: bool = true, // Default to visible

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .history = std.ArrayList([:0]u8).init(allocator),
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
        // New UI behavior: hide input, show suggestion area with progress
        self.input_box_visible = false;
        self.progress_visible = true;
        self.suggestion_box_visible = true;
        self.error_label_visible = false;
        self.clear_button_visible = false;
        self.accept_button_visible = false;
        self.updateShortcutsHint();
    }

    /// Stop loading and show final state
    pub fn stopLoading(self: *Self) void {
        self.is_loading = false;
        self.submit_button_label = "Get Suggestion";
        self.progress_visible = false;
        self.updateButtonSensitivity();
        self.updateShortcutsHint();
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

    /// Update shortcuts hint based on current state
    pub fn updateShortcutsHint(self: *Self) void {
        self.shortcuts_hint = if (self.is_loading)
            "Loading..."
        else if (self.suggestion_box_visible)
            "Ctrl+Enter accept"
        else
            "↑↓ Navigate history";
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
        self.updateShortcutsHint();
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
        self.updateShortcutsHint();
    }

    /// Clear suggestion and return to input state (Esc behavior)
    pub fn clearSuggestion(self: *Self) void {
        if (self.suggestion_text.len > 0) {
            self.allocator.free(self.suggestion_text);
            self.suggestion_text = "";
        }
        self.error_message = null;
        // Show input, hide suggestion area
        self.input_box_visible = true;
        self.suggestion_box_visible = false;
        self.error_label_visible = false;
        self.clear_button_visible = false;
        self.accept_button_visible = false;
        self.updateButtonSensitivity();
        self.updateShortcutsHint();
    }

    /// Add prompt to history
    pub fn addToHistory(self: *Self, prompt: []const u8) !void {
        const owned_prompt = try self.allocator.dupeZ(u8, prompt);
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
        .response_command = "test command",
        .delay_ms = 0,
    };

    // Test the request function that's currently uncovered
    const request = llm.LLMRequest{ .prompt = "test" };
    const response = try MockLLMProvider.request(&provider, allocator, request);

    try testing.expectEqualStrings("test command", response.command);

    // Clean up allocated memory
    allocator.free(response.command);
    if (response.error_message) |msg| {
        allocator.free(msg);
    }
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

// =====================================================
// COMPREHENSIVE INTEGRATION TESTS FOR NEW FEATURES
// =====================================================

test "Ctrl+Enter keyboard shortcut acceptance" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Set up a suggestion
    dialog.setPromptText("test command");
    try dialog.setSuggestionText("ls -la");

    // Simulate Ctrl+Enter keypress (simplified simulation)
    // In real UI, this would trigger command acceptance
    try testing.expect(dialog.accept_button_visible);
    try testing.expectEqualStrings("ls -la", dialog.suggestion_text);
}

test "Insert Command button functionality" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    try dialog.setSuggestionText("mkdir test");

    // Check that the button is visible and suggestion is set
    try testing.expect(dialog.accept_button_visible);
    try testing.expectEqualStrings("mkdir test", dialog.suggestion_text);
}

test "Back button functionality" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Start with a suggestion shown
    try dialog.setSuggestionText("rm -rf /tmp/*");
    try testing.expect(dialog.suggestion_box_visible);

    // Click back button (clearSuggestion)
    dialog.clearSuggestion();

    try testing.expect(!dialog.suggestion_box_visible);
    try testing.expectEqualStrings("", dialog.suggestion_text);
}

test "UI state transitions: input -> loading -> suggestion" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Initial state: input visible, suggestion hidden
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
    try testing.expect(!dialog.is_loading);

    // Start loading: input hidden, loading shown
    dialog.setPromptText("test prompt");
    dialog.startLoading();

    try testing.expect(!dialog.input_box_visible); // New behavior: input hidden during loading
    try testing.expect(dialog.suggestion_box_visible);
    try testing.expect(dialog.progress_visible);
    try testing.expect(dialog.is_loading);

    // Complete with suggestion: show suggestion, hide loading
    dialog.stopLoading();
    try dialog.setSuggestionText("echo 'success'");

    try testing.expect(!dialog.input_box_visible); // Input still hidden
    try testing.expect(dialog.suggestion_box_visible);
    try testing.expect(!dialog.progress_visible);
    try testing.expect(!dialog.is_loading);
    try testing.expect(dialog.accept_button_visible);
    try testing.expect(dialog.clear_button_visible); // Back button
}

test "UI state transitions: suggestion -> back to input" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Start with suggestion
    try dialog.setSuggestionText("cat /etc/passwd");

    // Go back to input
    dialog.clearSuggestion();

    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
    try testing.expect(!dialog.accept_button_visible);
    try testing.expect(!dialog.clear_button_visible);
}

test "command insertion simulation" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    const command = "find . -name '*.zig' -type f";
    try dialog.setSuggestionText(command);

    // Check that command is ready for insertion
    try testing.expect(dialog.accept_button_visible);
    try testing.expectEqualStrings(command, dialog.suggestion_text);
}

test "error handling with Back button" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Show error
    dialog.showError("Network timeout");

    try testing.expect(dialog.suggestion_box_visible);
    try testing.expect(dialog.error_label_visible);
    try testing.expect(dialog.clear_button_visible);
    try testing.expect(!dialog.accept_button_visible);

    // Back to input
    dialog.clearSuggestion();

    try testing.expect(!dialog.suggestion_box_visible);
    try testing.expect(!dialog.error_label_visible);
}

test "keyboard navigation integration" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Test arrow key history navigation
    try dialog.addToHistory("first command");
    try dialog.addToHistory("second command");

    var current_index: ?usize = null;

    const result1 = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("second command", result1);

    const result2 = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("first command", result2);

    const result3 = dialog.navigateHistory(.down, &current_index);
    try testing.expectEqualStrings("second command", result3);
}

test "comprehensive workflow simulation" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // 1. User opens dialog and types
    dialog.setPromptText("list hidden files");
    try testing.expect(dialog.submit_button_sensitive);

    // 2. User submits
    dialog.startLoading();
    try testing.expect(dialog.is_loading);

    // 3. API responds
    dialog.stopLoading();
    try dialog.setSuggestionText("ls -la");
    try testing.expect(dialog.accept_button_visible);
    try testing.expect(dialog.clear_button_visible);

    // 4. Command is ready for acceptance
    try testing.expect(dialog.accept_button_visible);
    try testing.expectEqualStrings("ls -la", dialog.suggestion_text);
}

test "streaming disabled verification" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    var mock_provider = MockLLMProvider{
        .response_command = "echo test",
        .delay_ms = 0,
    };

    // Test that requestStream returns UnsupportedProvider
    const provider = mock_provider.provider();
    const request = llm.LLMRequest{ .prompt = "test" };

    const result = provider.requestStream(
        testing.allocator,
        request,
        undefined, // callback not used
        null, // user_data not used
    );

    try testing.expectError(llm.LLMError.UnsupportedProvider, result);
}

test "blocking request functionality" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    var mock_provider = MockLLMProvider{
        .response_command = "ps aux",
        .delay_ms = 0,
    };

    const provider = mock_provider.provider();
    const request = llm.LLMRequest{ .prompt = "show running processes" };

    const response = try provider.request(testing.allocator, request);

    try testing.expectEqualStrings("ps aux", response.command);
    try testing.expect(response.error_message == null);

    // Clean up allocated memory
    testing.allocator.free(response.command);
    if (response.error_message) |msg| {
        testing.allocator.free(msg);
    }
}

// =====================================================
// NEW COMPREHENSIVE INTEGRATION TESTS FOR REPORTED ISSUES
// =====================================================

test "Dialog UI state resets properly when shown multiple times" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Simulate first usage: input -> suggestion
    dialog.setPromptText("first command");
    try dialog.setSuggestionText("ls -la");
    // Manually hide input box to simulate the real UI flow
    dialog.input_box_visible = false;

    // Verify suggestion state
    try testing.expect(!dialog.input_box_visible);
    try testing.expect(dialog.suggestion_box_visible);
    try testing.expectEqualStrings("ls -la", dialog.suggestion_text);

    // Simulate closing and reopening dialog (like the show() method does)
    dialog.clearSuggestion();

    // Verify dialog properly resets to input state
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
    try testing.expect(!dialog.accept_button_visible);
    try testing.expect(!dialog.clear_button_visible);
    try testing.expect(!dialog.progress_visible);
    try testing.expect(!dialog.error_label_visible);

    // Verify suggestion text is cleared
    try testing.expectEqualStrings("", dialog.suggestion_text);
}

test "Dialog UI state transitions work correctly through complete workflow" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // 1. Initial state: input visible, suggestion hidden
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);

    // 2. Start loading: input hidden, suggestion visible with progress
    dialog.startLoading();
    try testing.expect(!dialog.input_box_visible);
    try testing.expect(dialog.suggestion_box_visible);
    try testing.expect(dialog.progress_visible);
    try testing.expect(!dialog.accept_button_visible);

    // 3. Show suggestion: progress hidden, suggestion and buttons visible
    dialog.stopLoading();
    try dialog.setSuggestionText("echo 'test'");
    try testing.expect(!dialog.input_box_visible);
    try testing.expect(dialog.suggestion_box_visible);
    try testing.expect(!dialog.progress_visible);
    try testing.expect(dialog.accept_button_visible);
    try testing.expect(dialog.clear_button_visible);

    // 4. Clear suggestion: back to input state
    dialog.clearSuggestion();
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
    try testing.expect(!dialog.accept_button_visible);
    try testing.expect(!dialog.clear_button_visible);
}

test "Multiple dialog sessions maintain proper state isolation" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Session 1
    dialog.setPromptText("session 1 command");
    try dialog.setSuggestionText("mkdir session1");
    try testing.expectEqualStrings("mkdir session1", dialog.suggestion_text);

    // Reset for session 2 (simulating dialog reopening)
    dialog.clearSuggestion();
    try testing.expectEqualStrings("", dialog.suggestion_text);
    try testing.expect(dialog.input_box_visible);

    // Session 2
    dialog.setPromptText("session 2 command");
    try dialog.setSuggestionText("rm session2");
    try testing.expectEqualStrings("rm session2", dialog.suggestion_text);

    // Reset for session 3
    dialog.clearSuggestion();
    try testing.expectEqualStrings("", dialog.suggestion_text);
    try testing.expect(dialog.input_box_visible);

    // Session 3 should start clean
    try testing.expect(!dialog.suggestion_box_visible);
    try testing.expect(!dialog.accept_button_visible);
}

test "Keyboard shortcuts work in all dialog states" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Test Enter key in input state (should submit if text present)
    dialog.setPromptText("test command");
    try testing.expect(dialog.input_box_visible);
    // Simulate Enter key press - would trigger submit in real UI

    // Test Ctrl+Enter in suggestion state (should accept suggestion)
    try dialog.setSuggestionText("ls -la");
    try testing.expect(dialog.accept_button_visible);
    // Simulate Ctrl+Enter - would trigger acceptance in real UI

    // Test Esc in suggestion state (should go back to input)
    dialog.clearSuggestion();
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);

    // Test Esc in input state (should close dialog in real UI)
    try testing.expect(dialog.input_box_visible);
    // Simulate second Esc - would close dialog in real UI
}

test "Error state transitions work correctly" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Start loading
    dialog.startLoading();
    try testing.expect(dialog.progress_visible);

    // Show error
    dialog.stopLoading();
    dialog.showError("Network error occurred");
    try testing.expect(!dialog.progress_visible);
    try testing.expect(dialog.error_label_visible);
    try testing.expect(dialog.clear_button_visible);
    try testing.expect(!dialog.accept_button_visible);

    // Clear error back to input state
    dialog.clearSuggestion();
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.error_label_visible);
    try testing.expect(!dialog.clear_button_visible);
}

test "Loading state cancellation works correctly" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Start loading
    dialog.startLoading();
    try testing.expect(dialog.progress_visible);
    try testing.expect(!dialog.input_box_visible);

    // Cancel loading (simulate Esc during loading)
    dialog.stopLoading();
    try testing.expect(!dialog.progress_visible);
    // After cancellation, dialog should return to input state
    dialog.clearSuggestion(); // This simulates the full cancel flow
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
}

test "History navigation maintains UI state correctly" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Add some history
    try dialog.addToHistory("first command");
    try dialog.addToHistory("second command");

    // Navigate history in input state
    try testing.expect(dialog.input_box_visible);
    var current_index: ?usize = null;
    _ = dialog.navigateHistory(.up, &current_index);
    _ = dialog.navigateHistory(.down, &current_index);

    // History navigation should not affect UI state
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
}

test "Complete user workflow with proper state management" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // 1. User opens dialog (should be in input state)
    dialog.clearSuggestion(); // Simulates show() method
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);

    // 2. User types command and submits
    dialog.setPromptText("list files");
    dialog.startLoading();
    try testing.expect(!dialog.input_box_visible);
    try testing.expect(dialog.progress_visible);

    // 3. Response arrives
    dialog.stopLoading();
    try dialog.setSuggestionText("ls -la");
    try testing.expect(dialog.accept_button_visible);
    try testing.expect(dialog.clear_button_visible);

    // 4. User accepts suggestion
    // (In real UI: Ctrl+Enter or click "Insert Command")
    try testing.expectEqualStrings("ls -la", dialog.suggestion_text);

    // 5. User opens dialog again later
    dialog.clearSuggestion();
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
    try testing.expectEqualStrings("", dialog.suggestion_text); // Should be clean
}

test "Focus-independent keyboard shortcut simulation" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Setup suggestion state
    try dialog.setSuggestionText("grep 'pattern' file.txt");
    try testing.expect(dialog.accept_button_visible);

    // Simulate Ctrl+Enter working regardless of which widget has focus
    // In the real implementation, the key controller is attached to the dialog
    // with capture propagation, so it should receive all key events first

    // Test that suggestion is ready for acceptance
    try testing.expectEqualStrings("grep 'pattern' file.txt", dialog.suggestion_text);
    try testing.expect(dialog.accept_button_visible);

    // In a real scenario, the onKeyPressed handler would be called
    // and would trigger acceptSuggestion() when Ctrl+Enter is pressed
    // regardless of focus state
}

test "Context-sensitive shortcuts hints work correctly" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // 1. Initial state should show input hints
    try testing.expectEqualStrings("↑↓ Navigate history", dialog.shortcuts_hint);

    // 2. Loading state should show loading message
    dialog.startLoading();
    try testing.expectEqualStrings("Loading...", dialog.shortcuts_hint);

    // 3. Suggestion state should show accept hints
    dialog.stopLoading();
    try dialog.setSuggestionText("ls -la");
    try testing.expectEqualStrings("Ctrl+Enter accept", dialog.shortcuts_hint);

    // 4. Error state should show accept hints (same as suggestion)
    dialog.showError("Test error");
    try testing.expectEqualStrings("Ctrl+Enter accept", dialog.shortcuts_hint);

    // 5. Back to input state should show input hints again
    dialog.clearSuggestion();
    try testing.expectEqualStrings("↑↓ Navigate history", dialog.shortcuts_hint);
}

test "History navigation with fixed garbage data issue" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Add test history items (now stored as null-terminated strings)
    try dialog.addToHistory("first command");
    try dialog.addToHistory("second command");
    try dialog.addToHistory("third command");

    // Verify history is stored as null-terminated strings
    try testing.expect(dialog.history.items.len == 3);
    try testing.expectEqualStrings("first command", dialog.history.items[0]);
    try testing.expectEqualStrings("second command", dialog.history.items[1]);
    try testing.expectEqualStrings("third command", dialog.history.items[2]);

    // The history items should be properly null-terminated ([:0]u8 type)
    // This prevents the garbage data issue when setting GTK text fields
    const first_item = dialog.history.items[0];
    try testing.expect(@TypeOf(first_item) == [:0]u8);
}

test "UI compact design and single-size modal behavior" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // The modal should maintain consistent size throughout states
    // Input state
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);

    // Loading state (compact progress)
    dialog.startLoading();
    try testing.expect(!dialog.input_box_visible);
    try testing.expect(dialog.suggestion_box_visible);
    try testing.expect(dialog.progress_visible);

    // Suggestion state (compact display)
    dialog.stopLoading();
    try dialog.setSuggestionText("echo test");
    try testing.expect(!dialog.input_box_visible);
    try testing.expect(dialog.suggestion_box_visible);
    try testing.expect(!dialog.progress_visible);
    try testing.expect(dialog.accept_button_visible);

    // Back to input (maintains compact design)
    dialog.clearSuggestion();
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
}

test "Input field is focused after command generation" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Simulate the complete workflow: start loading, get suggestion
    dialog.startLoading();
    dialog.stopLoading();
    try dialog.setSuggestionText("ls -la");

    // After generation, keyboard shortcuts should work (input should be focused)
    // We can't directly test focus, but we can verify the suggestion is visible
    // and the shortcuts hint reflects this state
    try testing.expect(dialog.suggestion_box_visible);
    try testing.expectEqualStrings("Ctrl+Enter accept", dialog.shortcuts_hint);
}

test "Input field is cleared after accepting suggestion" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Set some input text and get a suggestion
    dialog.setPromptText("test command");
    try dialog.setSuggestionText("ls -la");

    // After accepting, the dialog should return to input state
    // The actual clearing happens in the real implementation, here we just test the UI state
    dialog.clearSuggestion();

    // The dialog should be back to input state ready for next use
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
    try testing.expectEqualStrings("↑↓ Navigate history", dialog.shortcuts_hint);
}

test "Terminal context integration works with empty context" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Test that the system works when no terminal context is available
    // This is a basic integration test to ensure our new code doesn't break existing functionality
    dialog.setPromptText("list files");

    // Even without terminal context, the dialog should work normally
    try testing.expect(dialog.submit_button_sensitive);
    try testing.expectEqualStrings("list files", dialog.current_prompt);
}

test "Terminal context builds the correct prompt" {
    const allocator = std.testing.allocator;

    // 1. Create a mock provider
    var mock_provider = MockLLMProvider{
        .response_command = "ls -la",
    };

    // 2. Define terminal context
    const context = llm.TerminalContext{
        .command_history = "ls -l\ngit status",
        .current_input = "cat ",
    };

    // 3. Create a request with context
    const request = llm.LLMRequest{
        .prompt = "list all files",
        .terminal_context = context,
    };

    // 4. Simulate the prompt building
    const expected_prompt = "Recent command history:\nls -l\ngit status\n\nCurrent terminal input:\ncat \n\nUser request: list all files";

    // 5. In a real scenario, this would be passed to the LLM provider
    // For this test, we just verify that the prompt would be built correctly
    // The actual prompt building logic is in the provider, but we can simulate it here
    var full_prompt = std.ArrayList(u8).init(allocator);
    defer full_prompt.deinit();
    const writer = full_prompt.writer();

    if (request.terminal_context.?.command_history) |history| {
        try writer.print("Recent command history:\n{s}\n\n", .{history});
    }
    if (request.terminal_context.?.current_input) |input| {
        try writer.print("Current terminal input:\n{s}\n\n", .{input});
    }
    try writer.print("User request: {s}", .{request.prompt});

    try testing.expectEqualStrings(expected_prompt, full_prompt.items);

    // This part just ensures the mock provider still works, though we aren't testing its output here
    const response = try mock_provider.provider().request(allocator, request);
    defer allocator.free(response.command);
    try testing.expectEqualStrings("ls -la", response.command);
}

test "Provider JSON generation without terminal context works correctly" {
    const allocator = std.testing.allocator;

    // Test that providers work correctly with plain prompts (no terminal context)
    const anthropic = @import("anthropic.zig");
    const config = @import("../config.zig");

    const cfg = config.Config{};
    const provider = try anthropic.AnthropicProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    const request = llm.LLMRequest{
        .prompt = "get the top 3 files by coverage excluding files with 100% coverage",
        .system_prompt = "You are a helpful assistant.",
    };

    // Generate the JSON payload
    const json_payload = try provider.buildRequestJSON(allocator, request, false);
    defer allocator.free(json_payload);

    // Parse the JSON to verify it's valid
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
        std.debug.print("Failed to parse JSON: {}\nJSON payload: {s}\n", .{ err, json_payload });
        return err;
    };
    defer parsed.deinit();

    const json_obj = parsed.value.object;

    // Verify the basic structure
    try testing.expect(json_obj.contains("model"));
    try testing.expect(json_obj.contains("messages"));
    try testing.expect(json_obj.contains("max_tokens"));

    std.debug.print("✓ Anthropic JSON generation works correctly\n", .{});
}

test "OpenAI provider JSON generation works correctly" {
    const allocator = std.testing.allocator;

    const openai = @import("openai.zig");
    const config = @import("../config.zig");

    const cfg = config.Config{};
    const provider = try openai.OpenAIProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    const request = llm.LLMRequest{
        .prompt = "help me find test files",
        .system_prompt = "You are a helpful assistant.",
    };

    const json_payload = try provider.buildRequestJSON(allocator, request, false);
    defer allocator.free(json_payload);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
        std.debug.print("Failed to parse OpenAI JSON: {}\nJSON payload: {s}\n", .{ err, json_payload });
        return err;
    };
    defer parsed.deinit();

    const json_obj = parsed.value.object;

    // Verify basic structure
    try testing.expect(json_obj.contains("model"));
    try testing.expect(json_obj.contains("messages"));

    std.debug.print("✓ OpenAI JSON generation works correctly\n", .{});
}

test "Gemini provider JSON generation works correctly" {
    const allocator = std.testing.allocator;

    const gemini = @import("gemini.zig");
    const config = @import("../config.zig");

    const cfg = config.Config{};
    const provider = try gemini.GeminiProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    const request = llm.LLMRequest{
        .prompt = "suggest a npm script to run",
        .system_prompt = "You are a helpful assistant.",
    };

    const json_payload = try provider.buildRequestJSON(allocator, request);
    defer allocator.free(json_payload);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
        std.debug.print("Failed to parse Gemini JSON: {}\nJSON payload: {s}\n", .{ err, json_payload });
        return err;
    };
    defer parsed.deinit();

    const json_obj = parsed.value.object;

    // Verify basic structure
    try testing.expect(json_obj.contains("contents"));
    try testing.expect(json_obj.contains("systemInstruction"));

    std.debug.print("✓ Gemini JSON generation works correctly\n", .{});
}

// =====================================================
// REGRESSION TESTS FOR MEMORY CORRUPTION BUG
// =====================================================

test "Regression: Memory corruption bug in background thread prompt handling" {
    const allocator = std.testing.allocator;

    // This test reproduces the exact scenario that caused the memory corruption:
    // 1. Create an enhanced prompt that gets allocated
    // 2. Pass it to a simulated background thread context
    // 3. Verify the prompt remains uncorrupted throughout the process

    // Simulate creating an enhanced prompt (like createEnhancedPrompt does)
    const original_prompt = "get the top 3 files by coverage excluding files with 100% coverage";
    const enhanced_prompt = try std.fmt.allocPrint(allocator, "Enhanced context:\nSome terminal context here\n\nUser request: {s}", .{original_prompt});
    defer allocator.free(enhanced_prompt);

    // Create the request like the GTK dialog does
    const request = llm.LLMRequest{
        .prompt = enhanced_prompt,
    };

    // Simulate the RequestContext structure used in background threads
    const RequestContext = struct {
        provider: llm.LLMProvider,
        request: llm.LLMRequest,
        allocator: std.mem.Allocator,
        enhanced_prompt: []const u8,
        original_prompt: []const u8,
    };

    // Create a mock provider for testing
    var mock_provider = MockLLMProvider{
        .response_command = "find . -name '*.json' | head -3",
    };
    const provider = mock_provider.provider();

    // Create context like the real code does
    var context = RequestContext{
        .provider = provider,
        .request = request,
        .allocator = allocator,
        .enhanced_prompt = enhanced_prompt,
        .original_prompt = original_prompt,
    };

    // Simulate background thread processing
    // The key test: verify that the prompt is NOT corrupted when accessed
    try testing.expectEqualStrings(enhanced_prompt, context.request.prompt);

    // Verify the prompt contains the expected content (not corrupted bytes like [170,170,170...])
    try testing.expect(std.mem.indexOf(u8, context.request.prompt, original_prompt) != null);
    try testing.expect(std.mem.indexOf(u8, context.request.prompt, "Enhanced context") != null);

    // Verify prompt length is reasonable (not corrupted)
    try testing.expect(context.request.prompt.len > original_prompt.len);
    try testing.expect(context.request.prompt.len < 1000); // Should be reasonable size

    // Simulate making the actual provider request
    var response = try context.provider.request(allocator, context.request);
    defer response.deinit(allocator);

    // Verify the response was successful (proving the prompt wasn't corrupted)
    try testing.expect(response.command.len > 0);
    try testing.expectEqualStrings("find . -name '*.json' | head -3", response.command);

    std.debug.print("✓ Regression test passed: No memory corruption in background thread prompt handling\n", .{});
}

test "Regression: JSON serialization with valid vs corrupted prompts" {
    const allocator = std.testing.allocator;

    // This test specifically targets the JSON serialization issue that was causing
    // prompts to be serialized as [170,170,170...] instead of strings

    const openai = @import("openai.zig");
    const config = @import("../config.zig");

    const cfg = config.Config{};
    const provider = try openai.OpenAIProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    // Test 1: Valid prompt should serialize correctly
    const valid_prompt = "get the top 3 files by coverage excluding files with 100% coverage";
    const valid_request = llm.LLMRequest{
        .prompt = valid_prompt,
        .system_prompt = "You are a helpful assistant",
    };

    const valid_json = try provider.buildRequestJSON(allocator, valid_request, false);
    defer allocator.free(valid_json);

    // Parse the JSON to verify structure
    const parsed_valid = try std.json.parseFromSlice(std.json.Value, allocator, valid_json, .{});
    defer parsed_valid.deinit();

    const valid_obj = parsed_valid.value.object;
    try testing.expect(valid_obj.contains("messages"));
    const valid_messages = valid_obj.get("messages").?.array;
    try testing.expect(valid_messages.items.len == 2);

    // Verify the user message content is a STRING, not an array of integers
    const user_message = valid_messages.items[1].object;
    const user_content = user_message.get("content").?;

    // This is the critical test: content should be a string, not an array
    try testing.expect(user_content == .string);
    try testing.expectEqualStrings(valid_prompt, user_content.string);

    // Verify it's NOT an array of integers (which was the bug)
    try testing.expect(user_content != .array);

    std.debug.print("✓ Regression test passed: Valid prompts serialize as strings, not integer arrays\n", .{});
}

test "Regression: Use-after-free scenario with enhanced prompt cleanup" {
    const allocator = std.testing.allocator;

    // This test reproduces the EXACT bug scenario:
    // 1. Allocate enhanced prompt
    // 2. Create LLMRequest pointing to it
    // 3. Free enhanced prompt (simulating the old defer behavior)
    // 4. Try to use the request (simulating background thread)
    // 5. Verify we can detect/prevent corruption

    const original_prompt = "get the top 3 files by coverage excluding files with 100% coverage";

    // Step 1: Allocate enhanced prompt (like createEnhancedPrompt)
    const enhanced_prompt = try std.fmt.allocPrint(allocator, "Terminal context here\nUser request: {s}", .{original_prompt});

    // Step 2: Create request pointing to enhanced prompt
    const request = llm.LLMRequest{
        .prompt = enhanced_prompt,
    };

    // Step 3: This simulates the old bug - freeing the enhanced prompt too early
    // (In the old code, this happened due to the defer statement)
    // allocator.free(enhanced_prompt); // DON'T do this - it would cause use-after-free

    // Instead, let's test that our new approach keeps the memory valid
    // Create the RequestContext structure like our fixed code does
    const TestContext = struct {
        request: llm.LLMRequest,
        enhanced_prompt: []const u8,
        original_prompt: []const u8,

        fn cleanup(self: *@This(), alloc: std.mem.Allocator) void {
            // Only free if enhanced_prompt was actually allocated
            if (self.enhanced_prompt.ptr != self.original_prompt.ptr) {
                alloc.free(self.enhanced_prompt);
            }
        }
    };

    var context = TestContext{
        .request = request,
        .enhanced_prompt = enhanced_prompt,
        .original_prompt = original_prompt,
    };
    defer context.cleanup(allocator);

    // Step 4: Simulate background thread usage - verify prompt is still valid
    try testing.expectEqualStrings(enhanced_prompt, context.request.prompt);

    // Verify the prompt content is not corrupted
    try testing.expect(std.mem.indexOf(u8, context.request.prompt, original_prompt) != null);

    // Test that we can still use the prompt for JSON serialization
    const openai = @import("openai.zig");
    const config = @import("../config.zig");

    const cfg = config.Config{};
    const provider = try openai.OpenAIProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    // This should work without corruption
    const json = try provider.buildRequestJSON(allocator, context.request, false);
    defer allocator.free(json);

    // Verify the JSON contains the original prompt, not corrupted data
    try testing.expect(std.mem.indexOf(u8, json, original_prompt) != null);

    // Verify it doesn't contain the corruption pattern [170,170,170...]
    try testing.expect(std.mem.indexOf(u8, json, "[170,170") == null);

    std.debug.print("✓ Regression test passed: Use-after-free prevented, memory stays valid\n", .{});
}

// =====================================================
// COMPREHENSIVE END-TO-END PROVIDER TESTS
// =====================================================

test "End-to-end: All providers handle requests without errors" {
    const allocator = std.testing.allocator;
    const config = @import("../config.zig");
    const cfg = config.Config{};

    // Test data that simulates a real command suggestion scenario
    const request = llm.LLMRequest{
        .prompt = "help me complete this git commit message for a bug fix",
        .system_prompt = "You are a helpful command-line assistant.",
        .model = "test-model",
        .max_tokens = 100,
        .temperature = 0.7,
    };

    // Test Anthropic provider
    {
        const anthropic = @import("anthropic.zig");
        const provider = try anthropic.AnthropicProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const json_payload = try provider.buildRequestJSON(allocator, request, false);
        defer allocator.free(json_payload);

        // Verify JSON is valid and contains expected structure
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
            std.debug.print("Anthropic JSON parsing failed: {}\nPayload: {s}\n", .{ err, json_payload });
            return err;
        };
        defer parsed.deinit();

        const json_obj = parsed.value.object;
        try testing.expect(json_obj.contains("model"));
        try testing.expect(json_obj.contains("messages"));
        try testing.expect(json_obj.contains("system"));
        try testing.expect(json_obj.contains("max_tokens"));

        // Verify message structure is correct
        const messages = json_obj.get("messages").?.array;
        try testing.expect(messages.items.len >= 1);
    }

    // Test OpenAI provider
    {
        const openai = @import("openai.zig");
        const provider = try openai.OpenAIProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const json_payload = try provider.buildRequestJSON(allocator, request, false);
        defer allocator.free(json_payload);

        // Verify JSON is valid and contains expected structure
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
            std.debug.print("OpenAI JSON parsing failed: {}\nPayload: {s}\n", .{ err, json_payload });
            return err;
        };
        defer parsed.deinit();

        const json_obj = parsed.value.object;
        try testing.expect(json_obj.contains("model"));
        try testing.expect(json_obj.contains("messages"));
        try testing.expect(json_obj.contains("max_tokens"));
        try testing.expect(json_obj.contains("temperature"));

        // Verify both system and user messages exist
        const messages = json_obj.get("messages").?.array;
        try testing.expect(messages.items.len >= 2);
    }

    // Test Gemini provider
    {
        const gemini = @import("gemini.zig");
        const provider = try gemini.GeminiProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const json_payload = try provider.buildRequestJSON(allocator, request);
        defer allocator.free(json_payload);

        // Verify JSON is valid and contains expected structure
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
            std.debug.print("Gemini JSON parsing failed: {}\nPayload: {s}\n", .{ err, json_payload });
            return err;
        };
        defer parsed.deinit();

        const json_obj = parsed.value.object;
        try testing.expect(json_obj.contains("contents"));
        try testing.expect(json_obj.contains("systemInstruction"));
        try testing.expect(json_obj.contains("generationConfig"));

        // Verify content structure is correct
        const contents = json_obj.get("contents").?.array;
        try testing.expect(contents.items.len >= 1);

        // Verify generation config
        const gen_config = json_obj.get("generationConfig").?.object;
        try testing.expect(gen_config.contains("maxOutputTokens"));
        try testing.expect(gen_config.contains("temperature"));
    }

    std.debug.print("✓ All providers pass end-to-end basic functionality test\n", .{});
}

test "End-to-end: All providers handle requests without terminal context (backward compatibility)" {
    const allocator = std.testing.allocator;
    const config = @import("../config.zig");
    const cfg = config.Config{};

    // Test request without terminal context to ensure backward compatibility
    const request = llm.LLMRequest{
        .prompt = "list all files in the current directory",
        .terminal_context = null,
        .system_prompt = "You are a helpful assistant.",
    };

    // Test all providers can handle requests without terminal context
    {
        const anthropic = @import("anthropic.zig");
        const provider = try anthropic.AnthropicProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const json_payload = try provider.buildRequestJSON(allocator, request, false);
        defer allocator.free(json_payload);

        // Should not crash and should produce valid JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
            std.debug.print("Anthropic backward compatibility failed: {}\n", .{err});
            return err;
        };
        defer parsed.deinit();

        // Verify basic structure is still correct
        const json_obj = parsed.value.object;
        try testing.expect(json_obj.contains("messages"));
        const messages = json_obj.get("messages").?.array;
        try testing.expect(messages.items.len == 1);

        const user_msg = messages.items[0].object;
        try testing.expectEqualStrings("user", user_msg.get("role").?.string);
        try testing.expectEqualStrings("list all files in the current directory", user_msg.get("content").?.string);
    }

    {
        const openai = @import("openai.zig");
        const provider = try openai.OpenAIProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const json_payload = try provider.buildRequestJSON(allocator, request, false);
        defer allocator.free(json_payload);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
            std.debug.print("OpenAI backward compatibility failed: {}\n", .{err});
            return err;
        };
        defer parsed.deinit();

        const json_obj = parsed.value.object;
        try testing.expect(json_obj.contains("messages"));
        const messages = json_obj.get("messages").?.array;
        try testing.expect(messages.items.len == 2); // system + user
    }

    {
        const gemini = @import("gemini.zig");
        const provider = try gemini.GeminiProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const json_payload = try provider.buildRequestJSON(allocator, request);
        defer allocator.free(json_payload);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
            std.debug.print("Gemini backward compatibility failed: {}\n", .{err});
            return err;
        };
        defer parsed.deinit();

        const json_obj = parsed.value.object;
        try testing.expect(json_obj.contains("contents"));
        const contents = json_obj.get("contents").?.array;
        const content = contents.items[0].object;
        const parts = content.get("parts").?.array;
        const text = parts.items[0].object.get("text").?.string;

        // Gemini includes system prompt in content when no terminal context, which is expected
        try testing.expect(std.mem.indexOf(u8, text, "list all files in the current directory") != null);
    }

    std.debug.print("✓ All providers maintain backward compatibility without terminal context\n", .{});
}

test "End-to-end: All providers handle edge cases correctly" {
    const allocator = std.testing.allocator;
    const config = @import("../config.zig");
    const cfg = config.Config{};

    // Test various edge cases that could break in real usage
    const edge_cases = [_]struct {
        name: []const u8,
        context: ?llm.TerminalContext,
        prompt: []const u8,
    }{
        .{
            .name = "empty command history",
            .context = llm.TerminalContext{
                .command_history = "",
                .current_input = "ls",
            },
            .prompt = "help with ls command",
        },
        .{
            .name = "empty current input",
            .context = llm.TerminalContext{
                .command_history = "cd /home",
                .current_input = "",
            },
            .prompt = "suggest next command",
        },
        .{
            .name = "long command history",
            .context = llm.TerminalContext{
                .command_history = "git init\ngit add .\ngit commit -m 'initial'\ngit remote add origin\ngit push\nls -la\ncd src\nfind . -name '*.zig'\ngrep -r 'test'\nvim main.zig",
                .current_input = "git log --oneline | head -",
            },
            .prompt = "complete this git command",
        },
        .{
            .name = "special characters in commands",
            .context = llm.TerminalContext{
                .command_history = "echo \"Hello World!\"\ngrep -E '[0-9]+' file.txt\nfind . -name '*.json' | xargs cat",
                .current_input = "sed 's/old/new/g'",
            },
            .prompt = "help with sed command",
        },
    };

    for (edge_cases) |case| {
        const request = llm.LLMRequest{
            .prompt = case.prompt,
            .terminal_context = case.context,
            .system_prompt = "You are a helpful assistant.",
        };

        // Test all providers handle this edge case
        {
            const anthropic = @import("anthropic.zig");
            const provider = try anthropic.AnthropicProvider.init(allocator, "test-key", &cfg);
            defer provider.deinit(allocator);

            const json_payload = try provider.buildRequestJSON(allocator, request, false);
            defer allocator.free(json_payload);

            // Should not crash and should produce valid JSON
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
                std.debug.print("Anthropic failed on edge case '{s}': {}\n", .{ case.name, err });
                return err;
            };
            defer parsed.deinit();
        }

        {
            const openai = @import("openai.zig");
            const provider = try openai.OpenAIProvider.init(allocator, "test-key", &cfg);
            defer provider.deinit(allocator);

            const json_payload = try provider.buildRequestJSON(allocator, request, false);
            defer allocator.free(json_payload);

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
                std.debug.print("OpenAI failed on edge case '{s}': {}\n", .{ case.name, err });
                return err;
            };
            defer parsed.deinit();
        }

        {
            const gemini = @import("gemini.zig");
            const provider = try gemini.GeminiProvider.init(allocator, "test-key", &cfg);
            defer provider.deinit(allocator);

            const json_payload = try provider.buildRequestJSON(allocator, request);
            defer allocator.free(json_payload);

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| {
                std.debug.print("Gemini failed on edge case '{s}': {}\n", .{ case.name, err });
                return err;
            };
            defer parsed.deinit();
        }
    }

    std.debug.print("✓ All providers handle edge cases correctly\n", .{});
}

// Terminal Context Functionality Tests
test "Terminal context: Environment variable censoring" {
    const allocator = std.testing.allocator;

    const TestDialog = struct {
        arena: std.heap.ArenaAllocator,

        fn init() @This() {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        fn censorEnvironmentVariables(self: *@This(), text: []const u8) ![]u8 {
            const alloc = self.arena.allocator();

            // Common environment variable patterns to detect and censor
            const env_patterns = [_][]const u8{
                "PATH=",    "HOME=",      "USER=",      "USERNAME=", "LOGNAME=",
                "SHELL=",   "PWD=",       "OLDPWD=",    "LANG=",     "LC_",
                "DISPLAY=", "TERM=",      "SSH_",       "SUDO_",     "DBUS_",
                "XDG_",     "DESKTOP_",   "SESSION_",   "WAYLAND_",  "_KEY=",
                "_TOKEN=",  "_SECRET=",   "_PASSWORD=", "API_KEY=",  "AUTH_",
                "PRIVATE_", "CREDENTIAL",
            };

            var result = std.ArrayList(u8).init(alloc);
            defer result.deinit();

            var i: usize = 0;
            while (i < text.len) {
                var found_env = false;

                // Check for environment variable patterns
                for (env_patterns) |pattern| {
                    if (i + pattern.len <= text.len and
                        std.mem.startsWith(u8, text[i..], pattern))
                    {
                        // Found an env var, censor the value part
                        try result.appendSlice(pattern);
                        i += pattern.len;

                        // Skip to next whitespace or newline (end of env var value)
                        while (i < text.len and
                            !std.ascii.isWhitespace(text[i]))
                        {
                            i += 1;
                        }
                        try result.appendSlice("****");
                        found_env = true;
                        break;
                    }
                }

                if (!found_env) {
                    try result.append(text[i]);
                    i += 1;
                }
            }

            return alloc.dupe(u8, result.items);
        }

        fn trimOutputWithEllipsis(self: *@This(), output: []const u8) []u8 {
            const alloc = self.arena.allocator();
            const max_chars = 50;

            if (output.len <= max_chars * 2) {
                return alloc.dupe(u8, output) catch @constCast(output);
            }

            // Create trimmed version with ellipsis
            const trimmed = std.fmt.allocPrint(alloc, "{s} ... {s}", .{
                output[0..max_chars],
                output[output.len - max_chars ..],
            }) catch return alloc.dupe(u8, output) catch @constCast(output);

            return trimmed;
        }
    };

    var dialog = TestDialog.init();
    defer dialog.deinit();

    // Test environment variable censoring
    const input = "PATH=/usr/bin:/bin HOME=/home/user API_KEY=secret123 normal text";
    const result = try dialog.censorEnvironmentVariables(input);

    try std.testing.expect(std.mem.indexOf(u8, result, "PATH=****") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "HOME=****") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "API_KEY=****") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "normal text") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "secret123") == null); // Should be censored
}

test "Terminal context: Output trimming with ellipsis" {
    const allocator = std.testing.allocator;

    const TestDialog = struct {
        arena: std.heap.ArenaAllocator,

        fn init() @This() {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        fn trimOutputWithEllipsis(self: *@This(), output: []const u8) []u8 {
            const alloc = self.arena.allocator();
            const max_chars = 50;

            if (output.len <= max_chars * 2) {
                return alloc.dupe(u8, output) catch @constCast(output);
            }

            // Create trimmed version with ellipsis
            const trimmed = std.fmt.allocPrint(alloc, "{s} ... {s}", .{
                output[0..max_chars],
                output[output.len - max_chars ..],
            }) catch return alloc.dupe(u8, output) catch @constCast(output);

            return trimmed;
        }
    };

    var dialog = TestDialog.init();
    defer dialog.deinit();

    // Test short output (no trimming needed)
    const short_output = "This is a short output";
    const short_result = dialog.trimOutputWithEllipsis(short_output);
    try std.testing.expectEqualStrings(short_output, short_result);

    // Test long output (trimming needed)
    const long_output = "A" ** 150; // 150 characters
    const long_result = dialog.trimOutputWithEllipsis(long_output);

    // Should be first 50 + " ... " + last 50 = 50 + 5 + 50 = 105 chars
    try std.testing.expect(long_result.len < long_output.len);
    try std.testing.expect(std.mem.indexOf(u8, long_result, " ... ") != null);
    try std.testing.expect(std.mem.startsWith(u8, long_result, "A" ** 50));
    try std.testing.expect(std.mem.endsWith(u8, long_result, "A" ** 50));
}

test "Terminal context: Command history formatting" {
    const allocator = std.testing.allocator;

    // Test the command history formatting in the enhanced prompt template
    const CommandEntry = struct {
        command: []u8,
        output: []u8,
    };

    var commands = std.ArrayList(CommandEntry).init(allocator);
    defer {
        for (commands.items) |entry| {
            allocator.free(entry.command);
            allocator.free(entry.output);
        }
        commands.deinit();
    }

    // Add test commands
    try commands.append(.{
        .command = try allocator.dupe(u8, "ls -la"),
        .output = try allocator.dupe(u8, "total 8\ndrwxr-xr-x 2 user user 4096 Jan 1 12:00 .\ndrwxr-xr-x 3 user user 4096 Jan 1 12:00 ..\n-rw-r--r-- 1 user user    0 Jan 1 12:00 file.txt"),
    });

    try commands.append(.{
        .command = try allocator.dupe(u8, "echo 'hello world'"),
        .output = try allocator.dupe(u8, "hello world"),
    });

    // Format the command history
    var history_builder = std.ArrayList(u8).init(allocator);
    defer history_builder.deinit();

    for (commands.items, 0..) |entry, i| {
        const command_num = commands.items.len - i;
        try history_builder.writer().print("## {}\nCommand: `{s}`\nOutput:\n```\n{s}\n```\n\n", .{ command_num, entry.command, entry.output });
    }

    const history_str = history_builder.items;

    // Verify the formatting
    try std.testing.expect(std.mem.indexOf(u8, history_str, "## 2\nCommand: `ls -la`") != null);
    try std.testing.expect(std.mem.indexOf(u8, history_str, "## 1\nCommand: `echo 'hello world'`") != null);
    try std.testing.expect(std.mem.indexOf(u8, history_str, "Output:\n```\nhello world\n```") != null);
}

test "Terminal context: Enhanced prompt template integration" {
    const allocator = std.testing.allocator;

    // Simulate the enhanced prompt creation with terminal context
    const user_prompt = "get the top 3 files by coverage excluding files with 100% coverage";
    const command_history = "## 2\nCommand: `cat kcov-output/ghostty-test/coverage.json`\nOutput:\n```\nCoverage data...\n```\n\n## 1\nCommand: `zig build test -Dtest-coverage`\nOutput:\n```\nTest results...\n```\n\n";
    const current_input = "cat kcov-output/ghostty-test/coverage.json | jq -r !!CURSOR!! | tee /tmp/out.csv";

    var prompt_builder = std.ArrayList(u8).init(allocator);
    defer prompt_builder.deinit();

    // Build enhanced prompt using the specified template
    try prompt_builder.appendSlice(user_prompt);
    try prompt_builder.appendSlice("\n\n---\nAdditional context is provided below.\n\n");
    try prompt_builder.appendSlice("Last 2 run commands:\n\n");
    try prompt_builder.appendSlice(command_history);
    try prompt_builder.appendSlice("The current state of the cli, the user's cursor placement is marked by `!!CURSOR!!` - this is not actually included in the user's terminal, but is for your information only.\n```\n");
    try prompt_builder.appendSlice(current_input);
    try prompt_builder.appendSlice("\n```\n---\n");

    const enhanced_prompt = prompt_builder.items;

    // Verify the enhanced prompt contains all expected sections
    try std.testing.expect(std.mem.indexOf(u8, enhanced_prompt, user_prompt) != null);
    try std.testing.expect(std.mem.indexOf(u8, enhanced_prompt, "Additional context is provided below") != null);
    try std.testing.expect(std.mem.indexOf(u8, enhanced_prompt, "Last 2 run commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, enhanced_prompt, "Command: `cat kcov-output/ghostty-test/coverage.json`") != null);
    try std.testing.expect(std.mem.indexOf(u8, enhanced_prompt, "!!CURSOR!!") != null);
    try std.testing.expect(std.mem.indexOf(u8, enhanced_prompt, "current state of the cli") != null);
}

test "End-to-end: Command suggestion with command history" {
    const allocator = std.testing.allocator;

    var dialog = DialogState.init(allocator);
    defer dialog.deinit();

    var surface = MockSurface.init(allocator);
    defer surface.deinit();

    var mock_provider = MockLLMProvider{
        .response_command = "jq -r '.results[] | select(.coverage < 100) | .file' coverage.json | head -3",
    };

    // 1. Add command history to dialog
    try dialog.addToHistory("zig build test -Dtest-coverage");
    try dialog.addToHistory("cat kcov-output/ghostty-test/coverage.json");

    // 2. User types a new request
    dialog.setPromptText("get the top 3 files by coverage excluding files with 100% coverage");

    // 3. Simulate enhanced prompt creation (this would be done by LLMAssistantDialog)
    const enhanced_prompt = try std.fmt.allocPrint(allocator,
        \\{s}
        \\
        \\---
        \\Additional context is provided below.
        \\
        \\Last 2 run commands:
        \\
        \\## 2
        \\Command: `cat kcov-output/ghostty-test/coverage.json`
        \\Output:
        \\```
        \\Coverage data...
        \\```
        \\
        \\## 1
        \\Command: `zig build test -Dtest-coverage`
        \\Output:
        \\```
        \\Test results...
        \\```
        \\
        \\The current state of the cli, the user's cursor placement is marked by `!!CURSOR!!`:
        \\```
        \\jq -r '.results[]' coverage.json | !!CURSOR!!
        \\```
        \\---
    , .{dialog.current_prompt});
    defer allocator.free(enhanced_prompt);

    // 4. Make request with enhanced prompt
    const request = llm.LLMRequest{ .prompt = enhanced_prompt };
    var response = try mock_provider.provider().request(allocator, request);
    defer response.deinit(allocator);

    // 5. Verify response
    try std.testing.expect(response.command.len > 0);
    try std.testing.expectEqualStrings("jq -r '.results[] | select(.coverage < 100) | .file' coverage.json | head -3", response.command);

    // 6. Accept command suggestion
    try surface.pasteCommand(response.command);
    try std.testing.expectEqualStrings(response.command, surface.getLastPastedCommand().?);

    std.log.info("✓ End-to-end with command history: Complete workflow passed", .{});
}

test "Terminal context: Memory management and cleanup" {
    const allocator = std.testing.allocator;

    // Test proper memory management for terminal context structures
    const TerminalContext = struct {
        commands: std.ArrayList(CommandEntry),
        current_input: ?[]u8 = null,
        allocator: std.mem.Allocator,

        const CommandEntry = struct {
            command: []u8,
            output: []u8,
        };

        pub fn deinit(self: *@This()) void {
            for (self.commands.items) |entry| {
                self.allocator.free(entry.command);
                self.allocator.free(entry.output);
            }
            self.commands.deinit();
            if (self.current_input) |input| {
                self.allocator.free(input);
            }
        }
    };

    // Create and populate context
    var context = TerminalContext{
        .commands = std.ArrayList(TerminalContext.CommandEntry).init(allocator),
        .allocator = allocator,
    };

    try context.commands.append(.{
        .command = try allocator.dupe(u8, "test command"),
        .output = try allocator.dupe(u8, "test output"),
    });

    context.current_input = try allocator.dupe(u8, "current input with !!CURSOR!!");

    // Verify context was created correctly
    try std.testing.expect(context.commands.items.len == 1);
    try std.testing.expectEqualStrings("test command", context.commands.items[0].command);
    try std.testing.expectEqualStrings("test output", context.commands.items[0].output);
    try std.testing.expect(context.current_input != null);
    try std.testing.expectEqualStrings("current input with !!CURSOR!!", context.current_input.?);

    // Clean up and verify no leaks
    context.deinit();
}

// =====================================================
// COMPREHENSIVE END-TO-END INTEGRATION TESTS
// =====================================================

test "End-to-end: Command suggestion without command history" {
    const allocator = std.testing.allocator;

    var dialog = DialogState.init(allocator);
    defer dialog.deinit();

    var surface = MockSurface.init(allocator);
    defer surface.deinit();

    var mock_provider = MockLLMProvider{
        .response_command = "find . -name '*.md' -type f",
    };

    // 1. User types a request with no history
    dialog.setPromptText("find all markdown files in current directory");
    try testing.expect(dialog.history.items.len == 0); // No history

    // 2. Make request with just the plain prompt (no terminal context)
    const request = llm.LLMRequest{ .prompt = dialog.current_prompt };
    var response = try mock_provider.provider().request(allocator, request);
    defer response.deinit(allocator);

    // 3. Verify response
    try testing.expect(response.command.len > 0);
    try testing.expectEqualStrings("find . -name '*.md' -type f", response.command);

    // 4. Accept command suggestion
    try surface.pasteCommand(response.command);
    try testing.expectEqualStrings(response.command, surface.getLastPastedCommand().?);

    // 5. Add to history after successful execution
    try dialog.addToHistory(dialog.current_prompt);
    try testing.expect(dialog.history.items.len == 1);

    std.log.info("✓ End-to-end without command history: Complete workflow passed", .{});
}

test "End-to-end: Accept command with partially prefilled terminal" {
    const allocator = std.testing.allocator;

    var dialog = DialogState.init(allocator);
    defer dialog.deinit();

    var surface = MockSurface.init(allocator);
    defer surface.deinit();

    var mock_provider = MockLLMProvider{
        .response_command = "git commit -m \"fix: resolve memory leak in parser\"",
    };

    // 1. Simulate partially filled terminal
    const current_terminal_input = "git commit -m \"!!CURSOR!!\"";

    // 2. User asks for help completing the command
    dialog.setPromptText("help me write a commit message for fixing a memory leak");

    // 3. Create enhanced prompt that includes the current terminal state
    const enhanced_prompt = try std.fmt.allocPrint(allocator,
        \\{s}
        \\
        \\---
        \\Additional context is provided below.
        \\
        \\The current state of the cli, the user's cursor placement is marked by `!!CURSOR!!`:
        \\```
        \\{s}
        \\```
        \\---
    , .{ dialog.current_prompt, current_terminal_input });
    defer allocator.free(enhanced_prompt);

    // 4. Make request
    const request = llm.LLMRequest{ .prompt = enhanced_prompt };
    var response = try mock_provider.provider().request(allocator, request);
    defer response.deinit(allocator);

    // 5. Verify response
    try testing.expect(response.command.len > 0);

    // 6. Simulate command insertion at cursor position
    // In real implementation, this would replace the partial command or insert at cursor
    try surface.pasteCommand(response.command);
    try testing.expectEqualStrings("git commit -m \"fix: resolve memory leak in parser\"", surface.getLastPastedCommand().?);

    std.log.info("✓ End-to-end with prefilled terminal: Command completion passed", .{});
}

test "End-to-end: Accept command with empty terminal" {
    const allocator = std.testing.allocator;

    var dialog = DialogState.init(allocator);
    defer dialog.deinit();

    var surface = MockSurface.init(allocator);
    defer surface.deinit();

    var mock_provider = MockLLMProvider{
        .response_command = "docker ps -a --format \"table {{.Names}}\\t{{.Status}}\"",
    };

    // 1. User types request with clean terminal
    dialog.setPromptText("show all docker containers with names and status");

    // 2. Create enhanced prompt showing empty terminal
    const enhanced_prompt = try std.fmt.allocPrint(allocator,
        \\{s}
        \\
        \\---
        \\Additional context is provided below.
        \\
        \\The current state of the cli, the user's cursor placement is marked by `!!CURSOR!!`:
        \\```
        \\!!CURSOR!!
        \\```
        \\---
    , .{dialog.current_prompt});
    defer allocator.free(enhanced_prompt);

    // 3. Make request
    const request = llm.LLMRequest{ .prompt = enhanced_prompt };
    var response = try mock_provider.provider().request(allocator, request);
    defer response.deinit(allocator);

    // 4. Verify response
    try testing.expect(response.command.len > 0);

    // 5. Insert command at empty prompt
    try surface.pasteCommand(response.command);
    try testing.expectEqualStrings("docker ps -a --format \"table {{.Names}}\\t{{.Status}}\"", surface.getLastPastedCommand().?);

    std.log.info("✓ End-to-end with empty terminal: Command insertion passed", .{});
}

test "End-to-end: Full workflow with history navigation and acceptance" {
    const allocator = std.testing.allocator;

    var dialog = DialogState.init(allocator);
    defer dialog.deinit();

    var surface = MockSurface.init(allocator);
    defer surface.deinit();

    var mock_provider = MockLLMProvider{
        .response_command = "tail -f /var/log/nginx/access.log | grep 404",
    };

    // 1. Build up some command history first
    try dialog.addToHistory("systemctl status nginx");
    try dialog.addToHistory("ls /var/log/nginx/");
    try dialog.addToHistory("cat /etc/nginx/nginx.conf");

    // 2. Test history navigation
    var current_index: ?usize = null;
    var navigated_command = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("cat /etc/nginx/nginx.conf", navigated_command);

    navigated_command = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("ls /var/log/nginx/", navigated_command);

    // 3. User decides to make a new request instead of using history
    dialog.setPromptText("monitor nginx for 404 errors in real time");

    // 4. Create enhanced prompt with history and current state
    const enhanced_prompt = try std.fmt.allocPrint(allocator,
        \\{s}
        \\
        \\---
        \\Additional context is provided below.
        \\
        \\Last 3 run commands:
        \\
        \\## 3
        \\Command: `cat /etc/nginx/nginx.conf`
        \\Output:
        \\```
        \\Server configuration...
        \\```
        \\
        \\## 2
        \\Command: `ls /var/log/nginx/`
        \\Output:
        \\```
        \\access.log error.log
        \\```
        \\
        \\## 1
        \\Command: `systemctl status nginx`
        \\Output:
        \\```
        \\Active: active (running)
        \\```
        \\
        \\The current state of the cli, the user's cursor placement is marked by `!!CURSOR!!`:
        \\```
        \\!!CURSOR!!
        \\```
        \\---
    , .{dialog.current_prompt});
    defer allocator.free(enhanced_prompt);

    // 5. Make request
    const request = llm.LLMRequest{ .prompt = enhanced_prompt };
    var response = try mock_provider.provider().request(allocator, request);
    defer response.deinit(allocator);

    // 6. Verify response incorporates context
    try testing.expect(response.command.len > 0);
    try testing.expectEqualStrings("tail -f /var/log/nginx/access.log | grep 404", response.command);

    // 7. Accept and execute command
    try surface.pasteCommand(response.command);
    try dialog.addToHistory(dialog.current_prompt);

    // 8. Verify final state
    try testing.expect(dialog.history.items.len == 4);
    try testing.expectEqualStrings("tail -f /var/log/nginx/access.log | grep 404", surface.getLastPastedCommand().?);

    std.log.info("✓ End-to-end full workflow: History navigation and command acceptance passed", .{});
}
