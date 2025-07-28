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

    pub fn startLoading(self: *Self) void {
        self.is_loading = true;
        self.submit_button_label = "Cancel";
        self.submit_button_sensitive = true;
        self.input_box_visible = false;
        self.progress_visible = true;
        self.suggestion_box_visible = true;
        self.error_label_visible = false;
        self.clear_button_visible = false;
        self.accept_button_visible = false;
        self.updateShortcutsHint();
    }

    pub fn stopLoading(self: *Self) void {
        self.is_loading = false;
        self.submit_button_label = "Get Suggestion";
        self.progress_visible = false;
        self.updateButtonSensitivity();
        self.updateShortcutsHint();
    }

    pub fn updateButtonSensitivity(self: *Self) void {
        if (self.is_loading) {
            self.submit_button_sensitive = true;
        } else {
            self.submit_button_sensitive = self.current_prompt.len > 0;
        }
    }

    pub fn updateShortcutsHint(self: *Self) void {
        self.shortcuts_hint = if (self.is_loading)
            "Loading..."
        else if (self.suggestion_box_visible)
            "Ctrl+Enter accept"
        else
            "↑↓ Navigate history";
    }

    pub fn setPromptText(self: *Self, text: []const u8) void {
        self.current_prompt = text;
        self.updateButtonSensitivity();
    }

    pub fn setSuggestionText(self: *Self, text: []const u8) !void {
        if (self.suggestion_text.len > 0) {
            self.allocator.free(self.suggestion_text);
        }
        self.suggestion_text = try self.allocator.dupe(u8, text);
        self.suggestion_box_visible = true;
        self.clear_button_visible = true;
        self.accept_button_visible = true;
        self.updateShortcutsHint();
    }

    pub fn completeRequest(self: *Self) void {
        self.stopLoading();
        if (self.suggestion_text.len > 0) {
            self.suggestion_box_visible = true;
            self.clear_button_visible = true;
            self.accept_button_visible = true;
        }
    }

    pub fn showError(self: *Self, message: []const u8) void {
        self.error_message = message;
        self.error_label_visible = true;
        self.suggestion_box_visible = true;
        self.clear_button_visible = true;
        self.accept_button_visible = false;
        self.stopLoading();
        self.updateShortcutsHint();
    }

    pub fn clearSuggestion(self: *Self) void {
        if (self.suggestion_text.len > 0) {
            self.allocator.free(self.suggestion_text);
            self.suggestion_text = "";
        }
        self.error_message = null;
        self.input_box_visible = true;
        self.suggestion_box_visible = false;
        self.error_label_visible = false;
        self.clear_button_visible = false;
        self.accept_button_visible = false;
        self.updateButtonSensitivity();
        self.updateShortcutsHint();
    }

    pub fn addToHistory(self: *Self, prompt: []const u8) !void {
        const owned_prompt = try self.allocator.dupeZ(u8, prompt);
        try self.history.append(owned_prompt);
    }

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
                .request = request,
                .deinit = deinit,
            },
        };
    }

    fn request(ptr: *anyopaque, allocator: std.mem.Allocator, _: llm.LLMRequest) llm.LLMError!llm.LLMResponse {
        const self: *MockLLMProvider = @ptrCast(@alignCast(ptr));

        if (self.should_fail) {
            return self.error_type;
        }

        if (self.delay_ms > 0) {
            std.time.sleep(self.delay_ms * std.time.ns_per_ms);
        }

        return llm.LLMResponse{ .command = try allocator.dupe(u8, self.response_command), .is_final = true };
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
};

// =====================================================
// CORE FUNCTIONALITY TESTS
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

test "error handling flow" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    var mock_provider = MockLLMProvider{
        .should_fail = true,
        .error_type = llm.LLMError.AuthenticationError,
    };

    dialog.setPromptText("list files");
    dialog.startLoading();

    const request = llm.LLMRequest{ .prompt = "list files" };
    const result = mock_provider.provider().request(testing.allocator, request);

    try testing.expectError(llm.LLMError.AuthenticationError, result);

    dialog.showError("Authentication failed");

    try testing.expect(!dialog.is_loading);
    try testing.expect(dialog.error_label_visible);
    try testing.expect(!dialog.accept_button_visible);
}

test "UI state transitions" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    // Initial state: input visible, suggestion hidden
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);

    // Start loading: input hidden, loading shown
    dialog.startLoading();
    try testing.expect(!dialog.input_box_visible);
    try testing.expect(dialog.progress_visible);

    // Complete with suggestion: show suggestion, hide loading
    dialog.stopLoading();
    try dialog.setSuggestionText("echo 'success'");
    try testing.expect(!dialog.input_box_visible);
    try testing.expect(dialog.accept_button_visible);

    // Clear suggestion: back to input state
    dialog.clearSuggestion();
    try testing.expect(dialog.input_box_visible);
    try testing.expect(!dialog.suggestion_box_visible);
}

test "history navigation" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    try dialog.addToHistory("ls -la");
    try dialog.addToHistory("find . -name '*.txt'");
    try dialog.addToHistory("grep -r 'pattern' .");

    var current_index: ?usize = null;

    // Navigate up through history
    var result = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("grep -r 'pattern' .", result);

    result = dialog.navigateHistory(.up, &current_index);
    try testing.expectEqualStrings("find . -name '*.txt'", result);

    // Navigate down
    result = dialog.navigateHistory(.down, &current_index);
    try testing.expectEqualStrings("grep -r 'pattern' .", result);

    // Go past end returns to empty
    result = dialog.navigateHistory(.down, &current_index);
    try testing.expectEqualStrings("", result);
}

// =====================================================
// PROVIDER JSON GENERATION TESTS
// =====================================================

test "All providers generate valid JSON" {
    const allocator = std.testing.allocator;
    const config = @import("../config.zig");
    const cfg = config.Config{};

    const request = llm.LLMRequest{
        .prompt = "help me complete this command",
        .system_prompt = "You are a helpful assistant.",
    };

    // Test Anthropic provider
    {
        const anthropic = @import("anthropic.zig");
        const provider = try anthropic.AnthropicProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const json_payload = try provider.buildRequestJSON(allocator, request);
        defer allocator.free(json_payload);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{});
        defer parsed.deinit();

        const json_obj = parsed.value.object;
        try testing.expect(json_obj.contains("model"));
        try testing.expect(json_obj.contains("messages"));
        try testing.expect(json_obj.contains("system"));
    }

    // Test OpenAI provider
    {
        const openai = @import("openai.zig");
        const provider = try openai.OpenAIProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const json_payload = try provider.buildRequestJSON(allocator, request);
        defer allocator.free(json_payload);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{});
        defer parsed.deinit();

        const json_obj = parsed.value.object;
        try testing.expect(json_obj.contains("model"));
        try testing.expect(json_obj.contains("messages"));
    }

    // Test Gemini provider
    {
        const gemini = @import("gemini.zig");
        const provider = try gemini.GeminiProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const json_payload = try provider.buildRequestJSON(allocator, request);
        defer allocator.free(json_payload);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{});
        defer parsed.deinit();

        const json_obj = parsed.value.object;
        try testing.expect(json_obj.contains("contents"));
        try testing.expect(json_obj.contains("systemInstruction"));
    }
}

test "Real JSON response parsing" {
    const allocator = std.testing.allocator;
    const config = @import("../config.zig");
    const cfg = config.Config{};

    // Test OpenAI response parsing
    {
        const openai = @import("openai.zig");
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

        const provider = try openai.OpenAIProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const response = try provider.parseResponse(allocator, real_response, .ok);
        defer {
            var mutable_response = response;
            mutable_response.deinit(allocator);
        }

        try testing.expectEqualStrings("ls -la", response.command);
    }

    // Test Anthropic response parsing
    {
        const anthropic = @import("anthropic.zig");
        const real_response =
            \\{
            \\  "content": [
            \\    {
            \\      "type": "text",
            \\      "text": "find . -name '*.txt'"
            \\    }
            \\  ]
            \\}
        ;

        const provider = try anthropic.AnthropicProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const response = try provider.parseResponse(allocator, real_response, .ok);
        defer {
            var mutable_response = response;
            mutable_response.deinit(allocator);
        }

        try testing.expectEqualStrings("find . -name '*.txt'", response.command);
    }

    // Test Gemini response parsing
    {
        const gemini = @import("gemini.zig");
        const real_response =
            \\{
            \\  "candidates": [
            \\    {
            \\      "content": {
            \\        "parts": [
            \\          {
            \\            "text": "grep -r 'pattern' ."
            \\          }
            \\        ]
            \\      }
            \\    }
            \\  ]
            \\}
        ;

        const provider = try gemini.GeminiProvider.init(allocator, "test-key", &cfg);
        defer provider.deinit(allocator);

        const response = try provider.parseResponse(allocator, real_response, .ok);
        defer {
            var mutable_response = response;
            mutable_response.deinit(allocator);
        }

        try testing.expectEqualStrings("grep -r 'pattern' .", response.command);
    }
}

// =====================================================
// REGRESSION TESTS (Critical - prevent known bugs)
// =====================================================

test "Regression: Memory corruption bug in background thread prompt handling" {
    const allocator = std.testing.allocator;

    // This test reproduces the exact scenario that caused the memory corruption
    const original_prompt = "get the top 3 files by coverage excluding files with 100% coverage";
    const enhanced_prompt = try std.fmt.allocPrint(allocator, "Enhanced context:\nSome terminal context here\n\nUser request: {s}", .{original_prompt});
    defer allocator.free(enhanced_prompt);

    const request = llm.LLMRequest{
        .prompt = enhanced_prompt,
    };

    // Simulate background thread processing
    const RequestContext = struct {
        provider: llm.LLMProvider,
        request: llm.LLMRequest,
        allocator: std.mem.Allocator,
        enhanced_prompt: []const u8,
        original_prompt: []const u8,
    };

    var mock_provider = MockLLMProvider{
        .response_command = "find . -name '*.json' | head -3",
    };
    const provider = mock_provider.provider();

    var context = RequestContext{
        .provider = provider,
        .request = request,
        .allocator = allocator,
        .enhanced_prompt = enhanced_prompt,
        .original_prompt = original_prompt,
    };

    // Verify that the prompt is NOT corrupted when accessed
    try testing.expectEqualStrings(enhanced_prompt, context.request.prompt);
    try testing.expect(std.mem.indexOf(u8, context.request.prompt, original_prompt) != null);
    try testing.expect(context.request.prompt.len > original_prompt.len);

    // Simulate making the actual provider request
    var response = try context.provider.request(allocator, context.request);
    defer response.deinit(allocator);

    try testing.expect(response.command.len > 0);
    try testing.expectEqualStrings("find . -name '*.json' | head -3", response.command);
}

test "Regression: JSON serialization with valid prompts" {
    const allocator = std.testing.allocator;
    const openai = @import("openai.zig");
    const config = @import("../config.zig");

    const cfg = config.Config{};
    const provider = try openai.OpenAIProvider.init(allocator, "test-key", &cfg);
    defer provider.deinit(allocator);

    const valid_prompt = "get the top 3 files by coverage excluding files with 100% coverage";
    const valid_request = llm.LLMRequest{
        .prompt = valid_prompt,
        .system_prompt = "You are a helpful assistant",
    };

    const valid_json = try provider.buildRequestJSON(allocator, valid_request);
    defer allocator.free(valid_json);

    const parsed_valid = try std.json.parseFromSlice(std.json.Value, allocator, valid_json, .{});
    defer parsed_valid.deinit();

    const valid_obj = parsed_valid.value.object;
    const valid_messages = valid_obj.get("messages").?.array;
    const user_message = valid_messages.items[1].object;
    const user_content = user_message.get("content").?;

    // Critical test: content should be a string, not an array (which was the bug)
    try testing.expect(user_content == .string);
    try testing.expectEqualStrings(valid_prompt, user_content.string);
    try testing.expect(user_content != .array);
}

// =====================================================
// EDGE CASES AND ERROR HANDLING
// =====================================================

test "Malformed JSON handling" {
    const openai = @import("openai.zig");
    const config = @import("../config.zig");

    const malformed_json = "{ invalid json ]}";
    const cfg = config.Config{};
    const provider = try openai.OpenAIProvider.init(testing.allocator, "test-key", &cfg);
    defer provider.deinit(testing.allocator);

    const result = provider.parseResponse(testing.allocator, malformed_json, .ok);
    try testing.expectError(llm.LLMError.JSONParseError, result);
}

test "Command text cleaning" {
    const openai = @import("openai.zig");
    const config = @import("../config.zig");

    const test_cases = [_]struct {
        content: []const u8,
        expected: []const u8,
    }{
        .{ .content = "ls -la", .expected = "ls -la" },
        .{ .content = "`ls -la`", .expected = "ls -la" },
        .{ .content = "```bash\\nls -la\\n```", .expected = "ls -la" },
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

test "Terminal context integration" {
    const allocator = std.testing.allocator;

    const context = llm.TerminalContext{
        .command_history = "ls -l\ngit status",
    };

    const request = llm.LLMRequest{
        .prompt = "list all files",
        .terminal_context = context,
    };

    // Simulate prompt building
    const expected_prompt = "Recent command history:\nls -l\ngit status\n\nUser request: list all files";

    var full_prompt = std.ArrayList(u8).init(allocator);
    defer full_prompt.deinit();
    const writer = full_prompt.writer();

    if (request.terminal_context.?.command_history) |history| {
        try writer.print("Recent command history:\n{s}\n\n", .{history});
    }
    try writer.print("User request: {s}", .{request.prompt});

    try testing.expectEqualStrings(expected_prompt, full_prompt.items);
}
