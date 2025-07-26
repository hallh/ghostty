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
input_box: *gtk.Box,
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
        .input_box = builder.getObject(gtk.Box, "input-box").?,
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
    // Set propagation phase to capture to ensure we get events before child widgets
    ec_key.as(gtk.EventController).setPropagationPhase(.capture);
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

    // Show input section and hide suggestion section
    gtk.Widget.setVisible(self.input_box.as(gtk.Widget), 1);
    gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 0);

    // Reset suggestion display
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
    mods: gdk.ModifierType,
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
        gdk.KEY_Return, gdk.KEY_KP_Enter => {
            // Check for Ctrl+Enter to accept suggestion
            if (mods.control_mask) {
                if (gtk.Widget.getVisible(self.suggestion_box.as(gtk.Widget)) != 0 and
                    gtk.Widget.getVisible(self.accept_button.as(gtk.Widget)) != 0)
                {
                    self.acceptSuggestion();
                    return 1; // TRUE - event handled
                }
            }
            return 0; // FALSE - let normal enter handling proceed
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

    // Submit blocking request in a separate thread to avoid blocking UI
    const RequestContext = struct {
        dialog: *LLMAssistantDialog,
        provider: llm.LLMProvider,
        request: llm.LLMRequest,
        allocator: std.mem.Allocator,
    };

    const context = self.arena.allocator().create(RequestContext) catch |err| {
        self.stopLoading();
        self.showError("Memory allocation failed");
        log.err("Failed to allocate request context: {}", .{err});
        return;
    };

    context.* = RequestContext{
        .dialog = self,
        .provider = provider,
        .request = request,
        .allocator = self.arena.allocator(),
    };

    // Launch request in background thread
    const thread = std.Thread.spawn(.{}, requestInBackground, .{context}) catch |err| {
        self.stopLoading();
        self.arena.allocator().destroy(context);
        self.showError("Failed to start background request");
        log.err("Failed to spawn request thread: {}", .{err});
        return;
    };
    thread.detach(); // Let it run independently
}

fn requestInBackground(context_ptr: *anyopaque) void {
    const RequestContext = struct {
        dialog: *LLMAssistantDialog,
        provider: llm.LLMProvider,
        request: llm.LLMRequest,
        allocator: std.mem.Allocator,
    };

    const context: *RequestContext = @ptrCast(@alignCast(context_ptr));
    defer context.allocator.destroy(context);

    // Make blocking request
    const response = context.provider.request(
        context.allocator,
        context.request,
    ) catch |err| {
        // Schedule error display in main thread
        const error_msg = switch (err) {
            llm.LLMError.InvalidConfiguration => "Configuration error",
            llm.LLMError.NetworkError => "Network error - please check your connection",
            llm.LLMError.AuthenticationError => "Authentication failed - please check your API key",
            llm.LLMError.RateLimitExceeded => "Rate limit exceeded - please wait and try again",
            llm.LLMError.APIError => "API error - the service may be unavailable",
            else => "An unexpected error occurred",
        };

        // Schedule error display in main thread
        const error_context = context.allocator.create(ShowErrorContext) catch {
            log.err("Failed to allocate error context", .{});
            return;
        };
        error_context.* = ShowErrorContext{
            .dialog = context.dialog,
            .message = error_msg,
        };
        _ = glib.idleAdd(showRequestError, error_context);
        return;
    };

    // Schedule success handling in main thread
    const success_context = context.allocator.create(ShowResponseContext) catch |err| {
        log.err("Failed to allocate success context: {}", .{err});
        var mutable_response = response;
        mutable_response.deinit(context.allocator);
        return;
    };

    success_context.* = ShowResponseContext{
        .dialog = context.dialog,
        .response = response,
        .allocator = context.allocator,
    };

    _ = glib.idleAdd(showRequestSuccess, success_context);
}

const ShowErrorContext = struct {
    dialog: *LLMAssistantDialog,
    message: []const u8,
};

const ShowResponseContext = struct {
    dialog: *LLMAssistantDialog,
    response: llm.LLMResponse,
    allocator: std.mem.Allocator,
};

fn showRequestError(user_data: ?*anyopaque) callconv(.c) c_int {
    const error_context: *ShowErrorContext = @ptrCast(@alignCast(user_data.?));
    const self = error_context.dialog;

    defer {
        // Clean up the allocated error context
        self.arena.allocator().destroy(error_context);
    }

    self.stopLoading();
    self.showError(error_context.message);

    return 0; // Don't repeat
}

fn showRequestSuccess(user_data: ?*anyopaque) callconv(.c) c_int {
    const success_context: *ShowResponseContext = @ptrCast(@alignCast(user_data.?));
    const self = success_context.dialog;

    defer {
        var mutable_response = success_context.response;
        mutable_response.deinit(success_context.allocator);
        success_context.allocator.destroy(success_context);
    }

    self.stopLoading();

    // Check for error in response
    if (success_context.response.error_message) |error_msg| {
        self.showError(error_msg);
        return 0;
    }

    // Show successful response
    if (success_context.response.command.len > 0) {
        // Update current response
        if (self.current_response) |old_response| {
            self.arena.allocator().free(old_response);
        }
        self.current_response = self.arena.allocator().dupe(u8, success_context.response.command) catch {
            self.showError("Failed to save response");
            return 0;
        };

        // Update text buffer
        self.suggestion_buffer.setText(@ptrCast(success_context.response.command.ptr), @intCast(success_context.response.command.len));

        // Show suggestion UI elements
        gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 1);
        gtk.Widget.setVisible(self.clear_button.as(gtk.Widget), 1);
        gtk.Widget.setVisible(self.accept_button.as(gtk.Widget), 1);
    } else {
        self.showError("No command received from LLM service");
    }

    return 0; // Don't repeat
}

fn startLoading(self: *LLMAssistantDialog) void {
    self.is_loading = true;

    // Hide input section and show suggestion area with progress
    gtk.Widget.setVisible(self.input_box.as(gtk.Widget), 0);
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
    // Hide suggestion section and show input section again
    gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 0);
    gtk.Widget.setVisible(self.input_box.as(gtk.Widget), 1);
    self.resetDialog();
}

fn acceptSuggestion(self: *LLMAssistantDialog) void {
    if (self.current_response) |response| {
        // Get the current tab/surface and send the command
        if (self.window.notebook.currentTab()) |tab| {
            // Convert to null-terminated string for the paste operation
            const alloc = self.arena.allocator();
            const command_z = alloc.dupeZ(u8, response) catch {
                log.err("Failed to allocate memory for command insertion", .{});
                return;
            };
            defer alloc.free(command_z);

            // Get the active surface from the tab
            const surface = tab.focus_child orelse switch (tab.elem) {
                .surface => |s| s,
                .split => null, // No focused surface, can't determine which one to send to
            };

            if (surface) |s| {
                // Use the surface's paste mechanism to insert the command
                s.core_surface.completeClipboardRequest(.paste, command_z, false) catch |err| {
                    log.err("Failed to insert command into terminal: {}", .{err});
                    // Fallback: copy to clipboard
                    const display = gdk.Display.getDefault() orelse return;
                    const clipboard = gdk.Display.getClipboard(display);
                    gdk.Clipboard.setText(clipboard, @ptrCast(response.ptr));
                    log.info("Command copied to clipboard as fallback: {s}", .{response});
                    return;
                };

                log.info("Command inserted into terminal: {s}", .{response});
            } else {
                log.warn("No active surface found to insert command", .{});
                // Fallback: copy to clipboard
                const display = gdk.Display.getDefault() orelse return;
                const clipboard = gdk.Display.getClipboard(display);
                gdk.Clipboard.setText(clipboard, @ptrCast(response.ptr));
                log.info("Command copied to clipboard as fallback: {s}", .{response});
            }
        }
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
