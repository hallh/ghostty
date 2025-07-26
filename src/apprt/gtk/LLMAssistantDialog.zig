const LLMAssistantDialog = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const glib = @import("glib");

const llm = @import("../../llm_assistant.zig");
const i18n = @import("../../os/main.zig").i18n;
const Builder = @import("Builder.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.llm_assistant_dialog);

window: *Window,
arena: std.heap.ArenaAllocator,

// UI elements
dialog: *adw.Dialog,
prompt_entry: *gtk.Entry,
submit_button: *gtk.Button,
cancel_button: *gtk.Button,
suggestion_box: *gtk.Box,
suggestion_text: *gtk.TextView,
suggestion_buffer: *gtk.TextBuffer,
progress_bar: *gtk.ProgressBar,
error_label: *gtk.Label,
clear_button: *gtk.Button,
accept_button: *gtk.Button,

// State
llm_provider: ?llm.LLMProvider = null,
is_loading: bool = false,
pulse_timer: ?c_uint = null,
history: std.ArrayList([]u8),
history_index: ?usize = null,
current_response: ?[]u8 = null,

pub fn init(self: *LLMAssistantDialog, window: *Window) !void {
    var builder = Builder.init("llm-assistant-dialog", 1, 5);
    defer builder.deinit();

    self.* = .{
        .window = window,
        .arena = .init(window.app.core_app.alloc),
        .dialog = builder.getObject(adw.Dialog, "llm-assistant-dialog").?,
        .prompt_entry = builder.getObject(gtk.Entry, "prompt-entry").?,
        .submit_button = builder.getObject(gtk.Button, "submit-button").?,
        .cancel_button = builder.getObject(gtk.Button, "cancel-button").?,
        .suggestion_box = builder.getObject(gtk.Box, "suggestion-box").?,
        .suggestion_text = builder.getObject(gtk.TextView, "suggestion-text").?,
        .suggestion_buffer = undefined, // Will be set below
        .progress_bar = builder.getObject(gtk.ProgressBar, "progress-bar").?,
        .error_label = builder.getObject(gtk.Label, "error-label").?,
        .clear_button = builder.getObject(gtk.Button, "clear-button").?,
        .accept_button = builder.getObject(gtk.Button, "accept-button").?,
        .history = std.ArrayList([]u8).init(window.app.core_app.alloc),
    };

    // Get the text buffer for the suggestion text view
    self.suggestion_buffer = self.suggestion_text.getBuffer();

    // Take a reference to keep the dialog in memory
    self.dialog.ref();
    errdefer self.dialog.unref();

    // Add key controller for keyboard shortcuts
    const ec_key = gtk.EventControllerKey.new();
    errdefer ec_key.unref();
    self.dialog.getChild().?.addController(ec_key.as(gtk.EventController));

    // Connect signals
    _ = gtk.Entry.signals.activate.connect(
        self.prompt_entry,
        *LLMAssistantDialog,
        onPromptActivate,
        self,
        .{},
    );

    _ = gtk.Editable.signals.changed.connect(
        self.prompt_entry.as(gtk.Editable),
        *LLMAssistantDialog,
        onPromptChanged,
        self,
        .{},
    );

    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        ec_key,
        *LLMAssistantDialog,
        onKeyPressed,
        self,
        .{},
    );

    _ = gtk.Button.signals.clicked.connect(
        self.submit_button,
        *LLMAssistantDialog,
        onSubmitClicked,
        self,
        .{},
    );

    _ = gtk.Button.signals.clicked.connect(
        self.cancel_button,
        *LLMAssistantDialog,
        onCancelClicked,
        self,
        .{},
    );

    _ = gtk.Button.signals.clicked.connect(
        self.clear_button,
        *LLMAssistantDialog,
        onClearClicked,
        self,
        .{},
    );

    _ = gtk.Button.signals.clicked.connect(
        self.accept_button,
        *LLMAssistantDialog,
        onAcceptClicked,
        self,
        .{},
    );

    // Initialize LLM provider
    self.initLLMProvider() catch |err| {
        log.warn("Failed to initialize LLM provider: {}", .{err});
        // Don't fail initialization, just log the error
        // The dialog will show an appropriate error when the user tries to use it
    };
}

pub fn deinit(self: *LLMAssistantDialog) void {
    // Stop pulse timer if running
    if (self.pulse_timer) |timer| {
        _ = glib.Source.remove(timer);
        self.pulse_timer = null;
    }

    // Clean up LLM provider
    if (self.llm_provider) |provider| {
        provider.deinit(self.arena.allocator());
    }

    // Clean up current response
    if (self.current_response) |response| {
        self.arena.allocator().free(response);
    }

    // Clean up history
    for (self.history.items) |item| {
        self.arena.allocator().free(item);
    }
    self.history.deinit();

    self.arena.deinit();
    self.dialog.unref();
}

pub fn show(self: *LLMAssistantDialog) void {
    // Reset state
    self.resetDialog();

    // Show dialog and focus the entry
    self.dialog.present(self.window.window.as(gtk.Widget));
    _ = self.prompt_entry.as(gtk.Widget).grabFocus();
}

fn initLLMProvider(self: *LLMAssistantDialog) !void {
    self.llm_provider = llm.createProvider(
        self.arena.allocator(),
        &self.window.app.config,
    ) catch |err| switch (err) {
        llm.LLMError.InvalidConfiguration => {
            // This is expected when API key is missing or invalid
            // We'll handle this gracefully when the user tries to make a request
            log.debug("LLM provider not configured: {}", .{err});
            return;
        },
        llm.LLMError.UnsupportedProvider => {
            log.warn("Unsupported LLM provider configured: {}", .{err});
            return;
        },
        else => {
            log.err("Failed to initialize LLM provider: {}", .{err});
            return err;
        },
    };
}

fn resetDialog(self: *LLMAssistantDialog) void {
    // Clear entry if no current text
    const current_text = std.mem.span(gtk.Editable.getText(self.prompt_entry.as(gtk.Editable)));
    if (current_text.len == 0) {
        gtk.Editable.setText(self.prompt_entry.as(gtk.Editable), "");
    }

    // Reset suggestion display
    gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 0);
    self.suggestion_buffer.setText("", 0);
    gtk.Widget.setVisible(self.progress_bar.as(gtk.Widget), 0);
    gtk.Widget.setVisible(self.error_label.as(gtk.Widget), 0);
    gtk.Widget.setVisible(self.clear_button.as(gtk.Widget), 0);
    gtk.Widget.setVisible(self.accept_button.as(gtk.Widget), 0);

    // Reset submit button
    self.submit_button.setLabel(i18n._("Get Suggestion"));
    const button_text = std.mem.span(gtk.Editable.getText(self.prompt_entry.as(gtk.Editable)));
    gtk.Widget.setSensitive(self.submit_button.as(gtk.Widget), @intFromBool(button_text.len > 0));

    // Reset loading state
    self.is_loading = false;
    if (self.pulse_timer) |timer| {
        _ = glib.Source.remove(timer);
        self.pulse_timer = null;
    }

    // Clean up current response
    if (self.current_response) |response| {
        self.arena.allocator().free(response);
        self.current_response = null;
    }
}

fn onPromptChanged(_: *gtk.Editable, self: *LLMAssistantDialog) callconv(.c) void {
    const text = std.mem.span(gtk.Editable.getText(self.prompt_entry.as(gtk.Editable)));
    gtk.Widget.setSensitive(self.submit_button.as(gtk.Widget), @intFromBool(text.len > 0 and !self.is_loading));
}

fn onPromptActivate(_: *gtk.Entry, self: *LLMAssistantDialog) callconv(.c) void {
    if (gtk.Widget.getSensitive(self.submit_button.as(gtk.Widget)) != 0) {
        self.submitRequest();
    }
}

fn onKeyPressed(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint,
    _: gdk.ModifierType,
    self: *LLMAssistantDialog,
) callconv(.c) c_int {
    switch (keyval) {
        gdk.KEY_Up => {
            self.navigateHistory(.previous);
            return 1; // TRUE - event handled
        },
        gdk.KEY_Down => {
            self.navigateHistory(.next);
            return 1; // TRUE - event handled
        },
        gdk.KEY_Escape => {
            if (self.is_loading) {
                self.cancelRequest();
            } else if (gtk.Widget.getVisible(self.suggestion_box.as(gtk.Widget)) != 0) {
                self.clearSuggestion();
            } else {
                _ = self.dialog.close();
            }
            return 1; // TRUE - event handled
        },
        else => return 0, // FALSE - event not handled
    }
}

fn onSubmitClicked(_: *gtk.Button, self: *LLMAssistantDialog) callconv(.c) void {
    self.submitRequest();
}

fn onCancelClicked(_: *gtk.Button, self: *LLMAssistantDialog) callconv(.c) void {
    _ = self.dialog.close();
}

fn onClearClicked(_: *gtk.Button, self: *LLMAssistantDialog) callconv(.c) void {
    self.clearSuggestion();
}

fn onAcceptClicked(_: *gtk.Button, self: *LLMAssistantDialog) callconv(.c) void {
    self.acceptSuggestion();
}

fn submitRequest(self: *LLMAssistantDialog) void {
    const text = std.mem.span(gtk.Editable.getText(self.prompt_entry.as(gtk.Editable)));
    if (text.len == 0) return;

    // Check if LLM provider is available
    const provider = self.llm_provider orelse {
        const config = &self.window.app.config;
        if (config.@"ext-llm-api-key" == null) {
            self.showError(std.mem.span(i18n._("LLM assistant requires configuration. Please set your API key with 'ext-llm-api-key' in your configuration file.")));
        } else {
            self.showError(std.mem.span(i18n._("LLM provider failed to initialize. Please check your configuration and try again.")));
        }
        return;
    };

    // Add to history
    self.addToHistory(text) catch |err| {
        log.warn("Failed to add prompt to history: {}", .{err});
    };

    // Start loading state
    self.startLoading();

    // Create request
    const request = llm.LLMRequest{
        .prompt = text,
    };

    // Submit streaming request
    const stream_context = StreamContext{
        .dialog = self,
        .allocator = self.arena.allocator(),
        .accumulated_text = std.ArrayList(u8).init(self.arena.allocator()),
    };

    provider.requestStream(
        self.arena.allocator(),
        request,
        onStreamChunk,
        @constCast(&stream_context),
    ) catch |err| {
        self.stopLoading();
        const error_msg = switch (err) {
            llm.LLMError.InvalidConfiguration => "Configuration error",
            llm.LLMError.NetworkError => "Network error - please check your connection",
            llm.LLMError.AuthenticationError => "Authentication failed - please check your API key",
            llm.LLMError.RateLimitExceeded => "Rate limit exceeded - please wait and try again",
            llm.LLMError.APIError => "API error - the service may be unavailable",
            else => "An unexpected error occurred",
        };
        self.showError(error_msg);
        log.err("LLM request failed: {}", .{err});
    };
}

fn startLoading(self: *LLMAssistantDialog) void {
    self.is_loading = true;
    self.submit_button.setLabel(i18n._("Cancel"));
    gtk.Widget.setSensitive(self.submit_button.as(gtk.Widget), 1);

    // Show suggestion area with progress
    gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 1);
    gtk.Widget.setVisible(self.progress_bar.as(gtk.Widget), 1);
    gtk.Widget.setVisible(self.error_label.as(gtk.Widget), 0);
    gtk.Widget.setVisible(self.clear_button.as(gtk.Widget), 0);
    gtk.Widget.setVisible(self.accept_button.as(gtk.Widget), 0);

    // Start progress animation
    self.pulse_timer = glib.timeoutAdd(100, pulsProgressBar, self);
}

fn stopLoading(self: *LLMAssistantDialog) void {
    self.is_loading = false;
    self.submit_button.setLabel(i18n._("Get Suggestion"));
    const entry_text = std.mem.span(gtk.Editable.getText(self.prompt_entry.as(gtk.Editable)));
    gtk.Widget.setSensitive(self.submit_button.as(gtk.Widget), @intFromBool(entry_text.len > 0));

    // Stop progress animation
    gtk.Widget.setVisible(self.progress_bar.as(gtk.Widget), 0);
    if (self.pulse_timer) |timer| {
        _ = glib.Source.remove(timer);
        self.pulse_timer = null;
    }
}

fn cancelRequest(self: *LLMAssistantDialog) void {
    self.stopLoading();
    // Note: We can't actually cancel the HTTP request once started
    // TODO: Implement request cancellation if needed
}

fn showError(self: *LLMAssistantDialog, message: []const u8) void {
    gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 1);
    self.error_label.setText(@ptrCast(message.ptr));
    gtk.Widget.setVisible(self.error_label.as(gtk.Widget), 1);
    gtk.Widget.setVisible(self.clear_button.as(gtk.Widget), 1);
    gtk.Widget.setVisible(self.accept_button.as(gtk.Widget), 0);
}

fn clearSuggestion(self: *LLMAssistantDialog) void {
    gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 0);
    self.resetDialog();
}

fn acceptSuggestion(self: *LLMAssistantDialog) void {
    if (self.current_response) |response| {
        // Send the command to the terminal
        _ = self.window.notebook.currentTab() orelse return;
        // TODO: Implement command insertion into terminal
        // For now, just copy to clipboard as fallback
        const display = gdk.Display.getDefault() orelse return;
        const clipboard = gdk.Display.getClipboard(display);
        gdk.Clipboard.setText(clipboard, @ptrCast(response.ptr));

        log.info("Command copied to clipboard: {s}", .{response});
    }

    _ = self.dialog.close();
}

fn addToHistory(self: *LLMAssistantDialog, text: []const u8) !void {
    // Don't add duplicates
    if (self.history.items.len > 0) {
        const last = self.history.items[self.history.items.len - 1];
        if (std.mem.eql(u8, last, text)) return;
    }

    // Add to history
    const owned_text = try self.arena.allocator().dupe(u8, text);
    try self.history.append(owned_text);

    // Limit history size
    const max_history = 50; // TODO: Make configurable
    if (self.history.items.len > max_history) {
        self.arena.allocator().free(self.history.orderedRemove(0));
    }

    // Reset history index
    self.history_index = null;
}

fn navigateHistory(self: *LLMAssistantDialog, direction: enum { previous, next }) void {
    if (self.history.items.len == 0) return;

    switch (direction) {
        .previous => {
            if (self.history_index) |index| {
                if (index > 0) {
                    self.history_index = index - 1;
                }
            } else {
                self.history_index = self.history.items.len - 1;
            }
        },
        .next => {
            if (self.history_index) |index| {
                if (index < self.history.items.len - 1) {
                    self.history_index = index + 1;
                } else {
                    self.history_index = null;
                }
            }
        },
    }

    // Update entry text
    if (self.history_index) |index| {
        const text = self.history.items[index];
        gtk.Editable.setText(self.prompt_entry.as(gtk.Editable), @ptrCast(text.ptr));
    } else {
        gtk.Editable.setText(self.prompt_entry.as(gtk.Editable), "");
    }
}

fn pulsProgressBar(user_data: ?*anyopaque) callconv(.c) c_int {
    const self: *LLMAssistantDialog = @ptrCast(@alignCast(user_data.?));
    self.progress_bar.pulse();
    return @intFromBool(self.is_loading); // Continue if still loading
}

const StreamContext = struct {
    dialog: *LLMAssistantDialog,
    allocator: Allocator,
    accumulated_text: std.ArrayList(u8),
};

fn onStreamChunk(chunk: []const u8, user_data: ?*anyopaque) void {
    const context: *StreamContext = @ptrCast(@alignCast(user_data.?));

    // Handle special signals from providers
    if (std.mem.startsWith(u8, chunk, "__ERROR__")) {
        const error_msg = chunk[9..]; // Skip "__ERROR__" prefix
        log.err("Streaming error received: {s}", .{error_msg});

        // Schedule error display in main thread
        const error_context = context.allocator.create(ErrorContext) catch {
            log.err("Failed to allocate error context", .{});
            return;
        };
        error_context.* = ErrorContext{
            .dialog = context.dialog,
            .message = context.allocator.dupe(u8, error_msg) catch "Unknown streaming error",
        };
        _ = glib.idleAdd(showStreamingError, error_context);
        return;
    }

    if (std.mem.eql(u8, chunk, "__COMPLETE__")) {
        log.debug("Stream completed successfully", .{});
        // Schedule completion handling in main thread
        _ = glib.idleAdd(completeStreaming, @constCast(context));
        return;
    }

    // Accumulate regular text content
    context.accumulated_text.appendSlice(chunk) catch |err| {
        log.warn("Failed to accumulate stream chunk: {}", .{err});
        return;
    };

    // Update UI in main thread
    _ = glib.idleAdd(updateSuggestionText, @constCast(context));
}

const ErrorContext = struct {
    dialog: *LLMAssistantDialog,
    message: []const u8,
};

fn showStreamingError(user_data: ?*anyopaque) callconv(.c) c_int {
    const error_context: *ErrorContext = @ptrCast(@alignCast(user_data.?));
    const self = error_context.dialog;

    // Stop loading and show error
    self.stopLoading();
    self.showError(error_context.message);

    // Clean up
    self.arena.allocator().free(error_context.message);
    self.arena.allocator().destroy(error_context);

    return 0; // Don't repeat
}

fn completeStreaming(user_data: ?*anyopaque) callconv(.c) c_int {
    const context: *StreamContext = @ptrCast(@alignCast(user_data.?));
    const self = context.dialog;

    // Ensure we stop loading
    self.stopLoading();

    // Show final suggestion if we have content
    if (context.accumulated_text.items.len > 0) {
        // Update current response
        if (self.current_response) |old_response| {
            self.arena.allocator().free(old_response);
        }
        self.current_response = self.arena.allocator().dupe(u8, context.accumulated_text.items) catch {
            log.warn("Failed to save final response", .{});
            return 0;
        };

        // Update text buffer
        self.suggestion_buffer.setText(@ptrCast(context.accumulated_text.items.ptr), @intCast(context.accumulated_text.items.len));

        // Show suggestion UI elements
        gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 1);
        gtk.Widget.setVisible(self.clear_button.as(gtk.Widget), 1);
        gtk.Widget.setVisible(self.accept_button.as(gtk.Widget), 1);
    } else {
        self.showError("No response received from LLM service");
    }

    return 0; // Don't repeat
}

fn updateSuggestionText(user_data: ?*anyopaque) callconv(.c) c_int {
    const context: *StreamContext = @ptrCast(@alignCast(user_data.?));
    const self = context.dialog;

    // Update current response
    if (self.current_response) |old_response| {
        self.arena.allocator().free(old_response);
    }
    self.current_response = self.arena.allocator().dupe(u8, context.accumulated_text.items) catch |err| {
        log.warn("Failed to update current response: {}", .{err});
        return 0;
    };

    // Update text buffer with incremental content
    self.suggestion_buffer.setText(@ptrCast(context.accumulated_text.items.ptr), @intCast(context.accumulated_text.items.len));

    // Show suggestion UI elements (but keep loading until explicit completion)
    gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 1);
    gtk.Widget.setVisible(self.clear_button.as(gtk.Widget), 1);
    gtk.Widget.setVisible(self.accept_button.as(gtk.Widget), 1);

    return 0; // Don't repeat
}
