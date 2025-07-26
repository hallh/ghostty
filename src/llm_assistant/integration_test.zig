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
        self.submit_button_sensitive = self.current_prompt.len > 0 and !self.is_loading;
    }

    /// Set prompt text and update UI state
    pub fn setPromptText(self: *Self, text: []const u8) void {
        self.current_prompt = text;
        self.updateButtonSensitivity();
    }

    /// Handle streaming text updates (requirement: gradual population)
    pub fn appendSuggestionText(self: *Self, chunk: []const u8) !void {
        const old_len = self.suggestion_text.len;
        self.suggestion_text = try self.allocator.realloc(self.suggestion_text, old_len + chunk.len);
        @memcpy(self.suggestion_text[old_len..], chunk);

        // Show suggestion UI elements
        self.suggestion_box_visible = true;
        self.clear_button_visible = true;
        self.accept_button_visible = true;
    }

    /// Complete streaming and finalize state
    pub fn completeStreaming(self: *Self) void {
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
    response_chunks: []const []const u8 = &[_][]const u8{},
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
        ptr: *anyopaque,
        _: std.mem.Allocator,
        _: llm.LLMRequest,
        callback: llm.StreamCallback,
        user_data: ?*anyopaque,
    ) llm.LLMError!void {
        const self: *MockLLMProvider = @ptrCast(@alignCast(ptr));

        if (self.should_fail) {
            return self.error_type;
        }

        // Simulate gradual streaming
        for (self.response_chunks) |chunk| {
            if (self.delay_ms > 0) {
                std.time.sleep(self.delay_ms * std.time.ns_per_ms);
            }
            callback(chunk, user_data);
        }

        // Send completion signal
        callback("__COMPLETE__", user_data);
    }

    fn request(_: *anyopaque, _: std.mem.Allocator, _: llm.LLMRequest) llm.LLMError!llm.LLMResponse {
        return llm.LLMResponse{ .command = "test command" };
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

test "progressive text accumulation during streaming" {
    var dialog = DialogState.init(testing.allocator);
    defer dialog.deinit();

    dialog.startLoading();

    // Simulate streaming chunks (requirement: gradual population)
    try dialog.appendSuggestionText("ls");
    try testing.expectEqualStrings("ls", dialog.suggestion_text);
    try testing.expect(dialog.suggestion_box_visible);

    try dialog.appendSuggestionText(" -la");
    try testing.expectEqualStrings("ls -la", dialog.suggestion_text);

    try dialog.appendSuggestionText(" --color=auto");
    try testing.expectEqualStrings("ls -la --color=auto", dialog.suggestion_text);

    // Complete streaming
    dialog.completeStreaming();
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
        .response_chunks = &[_][]const u8{ "ls", " -la" },
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

    // 4. Simulate streaming response
    var stream_context = TestStreamContext.init(testing.allocator);
    defer stream_context.deinit();

    const request = llm.LLMRequest{ .prompt = "list all files" };
    try mock_provider.provider().requestStream(
        testing.allocator,
        request,
        TestStreamContext.streamCallback,
        &stream_context,
    );

    // Verify streaming accumulated text
    try testing.expectEqualStrings("ls -la", stream_context.accumulated_text.items);
    try testing.expect(stream_context.completion_received);

    // 5. Apply streaming updates to dialog
    try dialog.appendSuggestionText(stream_context.accumulated_text.items);
    dialog.completeStreaming();

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
    var stream_context = TestStreamContext.init(testing.allocator);
    defer stream_context.deinit();

    const request = llm.LLMRequest{ .prompt = "list files" };
    const result = mock_provider.provider().requestStream(
        testing.allocator,
        request,
        TestStreamContext.streamCallback,
        &stream_context,
    );

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
    try dialog.appendSuggestionText("ls -la");
    dialog.completeStreaming();

    // Test Enter key - submits if in input mode
    dialog.clearSuggestion();
    dialog.setPromptText("new command");
    try testing.expect(dialog.submit_button_sensitive);
    // Simulate enter submit
    dialog.startLoading();
    try testing.expect(dialog.is_loading);

    // Test Ctrl+Enter - accepts suggestion and pastes
    dialog.stopLoading();
    try dialog.appendSuggestionText("find . -name '*.txt'");
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

test "streaming with all OpenAI finish reasons" {
    const test_cases = [_]struct {
        name: []const u8,
        chunks: []const []const u8,
        expected_text: []const u8,
        should_complete: bool,
    }{
        .{
            .name = "stop finish_reason",
            .chunks = &[_][]const u8{ "ls", " -la", "__COMPLETE__" },
            .expected_text = "ls -la",
            .should_complete = true,
        },
        .{
            .name = "length finish_reason",
            .chunks = &[_][]const u8{ "very long command", "__COMPLETE__" },
            .expected_text = "very long command",
            .should_complete = true,
        },
        .{
            .name = "content_filter finish_reason",
            .chunks = &[_][]const u8{"__COMPLETE__"},
            .expected_text = "",
            .should_complete = true,
        },
    };

    for (test_cases) |case| {
        var dialog = DialogState.init(testing.allocator);
        defer dialog.deinit();

        var mock_provider = MockLLMProvider{
            .response_chunks = case.chunks,
        };

        var stream_context = TestStreamContext.init(testing.allocator);
        defer stream_context.deinit();

        const request = llm.LLMRequest{ .prompt = "test" };
        try mock_provider.provider().requestStream(
            testing.allocator,
            request,
            TestStreamContext.streamCallback,
            &stream_context,
        );

        try testing.expectEqualStrings(case.expected_text, stream_context.accumulated_text.items);
        try testing.expect(stream_context.completion_received == case.should_complete);
    }
}

// Helper struct for streaming tests
const TestStreamContext = struct {
    accumulated_text: std.ArrayList(u8),
    completion_received: bool = false,
    error_received: bool = false,

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

        if (std.mem.eql(u8, chunk, "__COMPLETE__")) {
            context.completion_received = true;
            return;
        }

        if (std.mem.startsWith(u8, chunk, "__ERROR__")) {
            context.error_received = true;
            return;
        }

        context.accumulated_text.appendSlice(chunk) catch {
            context.error_received = true;
        };
    }
};
