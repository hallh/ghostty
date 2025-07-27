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
const Surface = @import("Surface.zig");
const terminal = @import("../../terminal/main.zig");
const Screen = terminal.Screen;
const PageList = terminal.PageList;
const Pin = terminal.Pin;

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
shortcuts_hint: *gtk.Label,

// State
llm_provider: ?llm.LLMProvider = null,
is_loading: bool = false,
pulse_timer: ?c_uint = null,
history: std.ArrayList([:0]u8),
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
        .shortcuts_hint = builder.getObject(gtk.Label, "shortcuts-hint").?,
        .history = std.ArrayList([:0]u8).init(window.app.core_app.alloc),
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

    // Update shortcuts hint for initial state
    self.updateShortcutsHint();
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

    // Get terminal context if available
    const terminal_context = self.getTerminalContext() catch |err| blk: {
        log.warn("Failed to get terminal context: {}", .{err});
        break :blk null;
    };

    log.info("[LLM_DEBUG] Terminal context available: {}", .{terminal_context != null});
    if (terminal_context) |ctx| {
        log.info("[LLM_DEBUG] Command history length: {}", .{ctx.commands.items.len});
        log.info("[LLM_DEBUG] Current input: '{any}'", .{ctx.current_input});
        log.info("[LLM_DEBUG] First few commands: {s}", .{if (ctx.commands.items.len > 0) ctx.commands.items[0].command else "none"});
    }

    // Create enhanced prompt with context
    const enhanced_prompt = if (terminal_context) |ctx|
        self.createEnhancedPrompt(text, ctx) catch text
    else
        text;
    // Don't free enhanced_prompt here - it will be used by the background thread

    log.info("[LLM_DEBUG] Original prompt: '{s}'", .{text});
    log.info("[LLM_DEBUG] Enhanced prompt length: {}", .{enhanced_prompt.len});
    log.info("[LLM_DEBUG] Enhanced prompt preview: '{s}'", .{enhanced_prompt[0..@min(100, enhanced_prompt.len)]});

    // Convert local TerminalContext to LLM TerminalContext if available
    const llm_context = if (terminal_context) |ctx| blk: {
        // Convert command history to string format
        var history_builder = std.ArrayList(u8).init(self.arena.allocator());
        defer history_builder.deinit();

        for (ctx.commands.items, 0..) |entry, i| {
            const command_num = ctx.commands.items.len - i;
            history_builder.writer().print("## {}\nCommand: `{s}`\nOutput:\n```\n{s}\n```\n\n", .{ command_num, entry.command, entry.output }) catch {
                log.warn("Failed to format command history", .{});
                break;
            };
        }

        const history_str = if (history_builder.items.len > 0)
            self.arena.allocator().dupe(u8, history_builder.items) catch null
        else
            null;

        break :blk llm.TerminalContext{
            .command_history = history_str,
            .current_input = ctx.current_input,
        };
    } else null;

    // Create request
    const request = llm.LLMRequest{
        .prompt = enhanced_prompt,
        .terminal_context = llm_context,
    };

    log.info("[LLM_DEBUG] Created LLMRequest with prompt length: {}", .{request.prompt.len});
    log.info("[LLM_DEBUG] LLMRequest.terminal_context is: {}", .{request.terminal_context != null});

    // Submit blocking request in a separate thread to avoid blocking UI
    const RequestContext = struct {
        dialog: *LLMAssistantDialog,
        provider: llm.LLMProvider,
        request: llm.LLMRequest,
        allocator: std.mem.Allocator,
        enhanced_prompt: []const u8, // Keep track of enhanced prompt for cleanup
        original_prompt: []const u8, // Keep track of original prompt for comparison
    };

    const context = self.arena.allocator().create(RequestContext) catch |err| {
        // Clean up enhanced_prompt if it was allocated
        if (enhanced_prompt.ptr != text.ptr) self.arena.allocator().free(enhanced_prompt);
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
        .enhanced_prompt = enhanced_prompt,
        .original_prompt = text,
    };

    log.info("[LLM_DEBUG] About to spawn background thread for LLM request", .{});

    // Launch request in background thread
    const thread = std.Thread.spawn(.{}, requestInBackground, .{context}) catch |err| {
        // Clean up enhanced_prompt if it was allocated
        if (enhanced_prompt.ptr != text.ptr) self.arena.allocator().free(enhanced_prompt);
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
        enhanced_prompt: []const u8, // Keep track of enhanced prompt for cleanup
        original_prompt: []const u8, // Keep track of original prompt for comparison
    };

    const context: *RequestContext = @ptrCast(@alignCast(context_ptr));
    defer {
        // Clean up enhanced_prompt if it was allocated
        if (context.enhanced_prompt.ptr != context.original_prompt.ptr) {
            context.allocator.free(context.enhanced_prompt);
        }
        context.allocator.destroy(context);
    }

    log.info("[LLM_DEBUG] Background thread started, about to make provider request", .{});
    log.info("[LLM_DEBUG] Request prompt length: {}", .{context.request.prompt.len});
    log.info("[LLM_DEBUG] Request has terminal_context: {}", .{context.request.terminal_context != null});

    // Make blocking request
    const response = context.provider.request(
        context.allocator,
        context.request,
    ) catch |err| {
        log.err("[LLM_DEBUG] Provider request failed with error: {}", .{err});
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

        // Focus the input field for keyboard shortcuts to work
        _ = self.prompt_entry.as(gtk.Widget).grabFocus();

        // Update shortcuts hint for suggestion state
        self.updateShortcutsHint();
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

    // Update shortcuts hint for loading state
    self.updateShortcutsHint();
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

    // Update shortcuts hint for error state (same as suggestion state)
    self.updateShortcutsHint();
}

fn clearSuggestion(self: *LLMAssistantDialog) void {
    // Hide suggestion section and show input section again
    gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 0);
    gtk.Widget.setVisible(self.input_box.as(gtk.Widget), 1);
    self.resetDialog();

    // Update shortcuts hint for input state
    self.updateShortcutsHint();
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

    // Clear the input field so it's empty when dialog reopens
    // (the previous prompt will be available in history)
    gtk.Editable.setText(self.prompt_entry.as(gtk.Editable), "");

    _ = self.dialog.close();
}

fn addToHistory(self: *LLMAssistantDialog, text: []const u8) !void {
    // Don't add duplicates
    if (self.history.items.len > 0) {
        const last = self.history.items[self.history.items.len - 1];
        if (std.mem.eql(u8, last, text)) return;
    }

    // Add to history (null-terminated for GTK compatibility)
    const owned_text = try self.arena.allocator().dupeZ(u8, text);
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

fn updateShortcutsHint(self: *LLMAssistantDialog) void {
    const hint_text = if (self.is_loading)
        i18n._("Loading...")
    else if (gtk.Widget.getVisible(self.suggestion_box.as(gtk.Widget)) != 0)
        i18n._("Ctrl+Enter accept")
    else
        i18n._("↑↓ Navigate history");

    self.shortcuts_hint.setText(@ptrCast(hint_text));
}

const TerminalContext = struct {
    commands: std.ArrayList(CommandEntry),
    current_input: ?[]u8 = null,
    current_input_full_line: ?[]u8 = null, // Full line with decorations and cursor marker
    allocator: std.mem.Allocator,

    const CommandEntry = struct {
        command: []u8,
        output: []u8,
    };

    pub fn deinit(self: *TerminalContext) void {
        for (self.commands.items) |entry| {
            self.allocator.free(entry.command);
            self.allocator.free(entry.output);
        }
        self.commands.deinit();
        if (self.current_input) |input| {
            self.allocator.free(input);
        }
        if (self.current_input_full_line) |full_line| {
            self.allocator.free(full_line);
        }
    }
};

fn getTerminalContext(self: *LLMAssistantDialog) !?TerminalContext {
    // Get the active surface
    const tab = self.window.notebook.currentTab() orelse return null;
    const surface = tab.focus_child orelse switch (tab.elem) {
        .surface => |s| s,
        .split => null,
    };

    if (surface == null) return null;

    var context = TerminalContext{
        .commands = std.ArrayList(TerminalContext.CommandEntry).init(self.arena.allocator()),
        .allocator = self.arena.allocator(),
    };

    // Extract terminal context using actual terminal data
    try self.extractCommandHistory(surface.?, &context);
    try self.extractCurrentInput(surface.?, &context);

    return context;
}

/// Extract command history from terminal using semantic prompts
fn extractCommandHistory(self: *LLMAssistantDialog, surface: *Surface, context: *TerminalContext) !void {
    const allocator = context.allocator;

    // Access terminal state with proper mutex locking
    surface.core_surface.renderer_state.mutex.lock();
    defer surface.core_surface.renderer_state.mutex.unlock();

    const screen = &surface.core_surface.io.terminal.screen;

    // Start from cursor position and scan backwards through terminal history
    var current_pin = screen.cursor.page_pin.*;
    const max_commands = 10; // Limit to prevent too much context
    var commands_found: usize = 0;

    // Scan backwards looking for command/output patterns
    var it = current_pin.rowIterator(.left_up, null);
    var current_state: enum { seeking_command, in_command_output, seeking_prompt } = .seeking_command;
    var command_input: ?[]u8 = null;
    var output_start_pin: ?Pin = null;
    var output_end_pin: ?Pin = null;

    while (it.next()) |pin| {
        if (commands_found >= max_commands) break;

        const row = pin.rowAndCell().row;
        const semantic_state = row.semantic_prompt;

        switch (current_state) {
            .seeking_command => {
                switch (semantic_state) {
                    .command => {
                        // Found command output, mark the end and start collecting
                        if (output_end_pin == null) {
                            output_end_pin = pin;
                            output_end_pin.?.x = pin.node.data.size.cols - 1;
                        }
                        output_start_pin = pin;
                        output_start_pin.?.x = 0;
                        current_state = .in_command_output;
                    },
                    .input => {
                        // Found input line, extract the command
                        if (extractCommandFromInput(screen, pin, allocator)) |cmd| {
                            command_input = cmd;
                            current_state = .seeking_prompt;
                        }
                    },
                    else => {},
                }
            },

            .in_command_output => {
                switch (semantic_state) {
                    .command => {
                        // Still in command output, update start
                        output_start_pin = pin;
                        output_start_pin.?.x = 0;
                    },
                    .input => {
                        // Found the command input, extract it
                        if (extractCommandFromInput(screen, pin, allocator)) |cmd| {
                            command_input = cmd;
                            current_state = .seeking_prompt;
                        }
                    },
                    .prompt, .prompt_continuation => {
                        // Hit a prompt, we have a complete command/output pair
                        try self.saveCommandEntry(
                            context,
                            command_input,
                            output_start_pin,
                            output_end_pin,
                            surface,
                            allocator,
                        );
                        commands_found += 1;

                        // Reset for next command
                        command_input = null;
                        output_start_pin = null;
                        output_end_pin = null;
                        current_state = .seeking_command;
                    },
                    else => {},
                }
            },

            .seeking_prompt => {
                switch (semantic_state) {
                    .prompt, .prompt_continuation => {
                        // Found the prompt, save the command/output pair
                        try self.saveCommandEntry(
                            context,
                            command_input,
                            output_start_pin,
                            output_end_pin,
                            surface,
                            allocator,
                        );
                        commands_found += 1;

                        // Reset for next command
                        command_input = null;
                        output_start_pin = null;
                        output_end_pin = null;
                        current_state = .seeking_command;
                    },
                    else => {},
                }
            },
        }
    }

    // Handle any remaining command/output pair
    if (command_input != null or output_start_pin != null) {
        try self.saveCommandEntry(
            context,
            command_input,
            output_start_pin,
            output_end_pin,
            surface,
            allocator,
        );
    }
}

/// Extract command text from an input line
fn extractCommandFromInput(screen: *Screen, pin: Pin, allocator: std.mem.Allocator) ?[]u8 {
    // Create a selection for the input line
    if (screen.selectLine(.{
        .pin = pin,
        .whitespace = &.{ 0, ' ', '\t' },
        .semantic_prompt_boundary = true,
    })) |line_selection| {
        // This is a simplified approach - in reality you'd need to extract just the command part
        // For now, we'll return null to indicate we couldn't extract the command
        // A more sophisticated implementation would parse the line to separate prompt from command
        _ = line_selection;
        _ = allocator;
        return null;
    }
    return null;
}

/// Save a command entry to the context
fn saveCommandEntry(
    self: *LLMAssistantDialog,
    context: *TerminalContext,
    command_input: ?[]u8,
    output_start_pin: ?Pin,
    output_end_pin: ?Pin,
    surface: *Surface,
    allocator: std.mem.Allocator,
) !void {
    // Extract output text if we have output bounds
    const output_text = if (output_start_pin != null and output_end_pin != null) blk: {
        const selection = terminal.Selection.init(output_start_pin.?, output_end_pin.?, false);
        var output_result = surface.core_surface.dumpTextLocked(allocator, selection) catch {
            log.warn("Failed to extract command output", .{});
            break :blk try allocator.dupe(u8, "(output extraction failed)");
        };
        defer output_result.deinit(allocator);

        // Censor and trim the output
        const censored = self.censorEnvironmentVariables(output_result.text) catch output_result.text;
        const trimmed = self.trimOutput(censored);

        break :blk try allocator.dupe(u8, trimmed);
    } else try allocator.dupe(u8, "(no output)");

    // Use command input if available, otherwise use placeholder
    const command_text = if (command_input) |cmd|
        try allocator.dupe(u8, cmd)
    else
        try allocator.dupe(u8, "(command extraction failed)");

    const entry = TerminalContext.CommandEntry{
        .command = command_text,
        .output = output_text,
    };
    try context.commands.append(entry);
}

/// Extract current terminal input with cursor position
fn extractCurrentInput(self: *LLMAssistantDialog, surface: *Surface, context: *TerminalContext) !void {
    _ = self;
    const allocator = context.allocator;

    // Access terminal state with proper mutex locking (following Ghostty's thread architecture)
    surface.core_surface.renderer_state.mutex.lock();
    defer surface.core_surface.renderer_state.mutex.unlock();

    const term = &surface.core_surface.io.terminal;
    const screen = &term.screen;

    // Check if we're at a prompt/input area using Ghostty's shell integration
    if (!term.cursorIsAtPrompt()) {
        // Not at a prompt, no current input to extract
        return;
    }

    const cursor_pin = screen.cursor.page_pin.*;

    // Extract only the input portion using semantic prompt boundaries
    if (extractInputSelection(cursor_pin)) |input_selection| {
        // Extract the text using Surface's dumpTextLocked (already under mutex)
        var input_text = surface.core_surface.dumpTextLocked(allocator, input_selection) catch |err| {
            log.warn("Failed to extract current input: {}", .{err});
            return;
        };
        defer input_text.deinit(allocator);

        // Calculate cursor position within the input (not the entire line)
        const input_start_pin = input_selection.start();
        const cursor_offset = calculateCursorOffsetInLine(input_start_pin, cursor_pin);

        // Create input with cursor marker at the correct position
        var input_with_cursor = std.ArrayList(u8).init(allocator);
        defer input_with_cursor.deinit();

        const text = input_text.text;
        if (cursor_offset <= text.len) {
            try input_with_cursor.appendSlice(text[0..cursor_offset]);
            try input_with_cursor.appendSlice("!!CURSOR!!");
            try input_with_cursor.appendSlice(text[cursor_offset..]);
        } else {
            // Cursor beyond text, append at end
            try input_with_cursor.appendSlice(text);
            try input_with_cursor.appendSlice("!!CURSOR!!");
        }

        context.current_input = try allocator.dupe(u8, input_with_cursor.items);
    }

    // Always capture the full line with decorations for LLM context
    if (screen.selectLine(.{
        .pin = cursor_pin,
        .whitespace = null, // Don't trim anything - keep all decorations
        .semantic_prompt_boundary = false, // Include prompt decorations
    })) |full_line_selection| {
        var full_line_text = surface.core_surface.dumpTextLocked(allocator, full_line_selection) catch |err| {
            log.warn("Failed to extract full current line: {}", .{err});
            return;
        };
        defer full_line_text.deinit(allocator);

        const full_line_start_pin = full_line_selection.start();
        const full_cursor_offset = calculateCursorOffsetInLine(full_line_start_pin, cursor_pin);

        // Create full line with cursor marker
        var full_line_with_cursor = std.ArrayList(u8).init(allocator);
        defer full_line_with_cursor.deinit();

        const full_text = full_line_text.text;
        if (full_cursor_offset <= full_text.len) {
            try full_line_with_cursor.appendSlice(full_text[0..full_cursor_offset]);
            try full_line_with_cursor.appendSlice("!!CURSOR!!");
            try full_line_with_cursor.appendSlice(full_text[full_cursor_offset..]);
        } else {
            try full_line_with_cursor.appendSlice(full_text);
            try full_line_with_cursor.appendSlice("!!CURSOR!!");
        }

        context.current_input_full_line = try allocator.dupe(u8, full_line_with_cursor.items);
    }
}

/// Extract selection for only the input portion using semantic prompt boundaries
fn extractInputSelection(cursor_pin: Pin) ?terminal.Selection {
    // Check if we're on an input line
    const row = cursor_pin.rowAndCell().row;
    if (row.semantic_prompt != .input) {
        return null;
    }

    // Find the start of the input region on this line
    var input_start_pin = cursor_pin;
    input_start_pin.x = 0;

    // Scan right to find where the actual input starts (after prompt decorations)
    var it = input_start_pin.cellIterator(.right_down, null);
    while (it.next()) |pin| {
        // Stop at the same row, different rows would be continuation
        if (pin.y != cursor_pin.y) break;

        const pin_row = pin.rowAndCell().row;
        if (pin_row.semantic_prompt == .input) {
            input_start_pin = pin;
            break;
        }
    }

    // Find the end of the input region
    var input_end_pin = cursor_pin;
    input_end_pin.x = cursor_pin.node.data.size.cols - 1;

    // Scan left from end of line to find last input character
    it = input_end_pin.cellIterator(.left_up, null);
    while (it.next()) |pin| {
        // Stop at the same row
        if (pin.y != cursor_pin.y) break;

        const cell = pin.rowAndCell().cell;
        if (cell.hasText()) {
            input_end_pin = pin;
            break;
        }
    }

    return terminal.Selection.init(input_start_pin, input_end_pin, false);
}

/// Calculate the cursor offset within a line selection
fn calculateCursorOffsetInLine(line_start_pin: Pin, cursor_pin: Pin) usize {
    // Simple case: same row
    if (line_start_pin.y == cursor_pin.y) {
        return if (cursor_pin.x >= line_start_pin.x)
            cursor_pin.x - line_start_pin.x
        else
            0;
    }

    // Multi-row case: would need to account for line wrapping
    // For now, return a reasonable approximation
    const row_diff = cursor_pin.y - line_start_pin.y;
    const cols_per_row = cursor_pin.node.data.size.cols;
    return row_diff * cols_per_row + cursor_pin.x - line_start_pin.x;
}

/// Censor environment variables by replacing them with ****
fn censorEnvironmentVariables(self: *LLMAssistantDialog, text: []const u8) ![]u8 {
    const allocator = self.arena.allocator();

    // Common environment variable patterns to detect and censor
    const env_patterns = [_][]const u8{
        "PATH=",    "HOME=",      "USER=",      "USERNAME=", "LOGNAME=",
        "SHELL=",   "PWD=",       "OLDPWD=",    "LANG=",     "LC_",
        "DISPLAY=", "TERM=",      "SSH_",       "SUDO_",     "DBUS_",
        "XDG_",     "DESKTOP_",   "SESSION_",   "WAYLAND_",  "_KEY=",
        "_TOKEN=",  "_SECRET=",   "_PASSWORD=", "API_KEY=",  "AUTH_",
        "PRIVATE_", "CREDENTIAL",
    };

    var result = std.ArrayList(u8).init(allocator);
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

    return allocator.dupe(u8, result.items);
}

/// Trim output to first 50 + last 50 characters with ellipsis
fn trimOutputWithEllipsis(self: *LLMAssistantDialog, output: []const u8) []u8 {
    const allocator = self.arena.allocator();
    const max_chars = 50;

    if (output.len <= max_chars * 2) {
        return allocator.dupe(u8, output) catch &[_]u8{}; // Return empty string on allocation failure
    }

    // Create trimmed version with ellipsis
    const trimmed = std.fmt.allocPrint(allocator, "{s} ... {s}", .{
        output[0..max_chars],
        output[output.len - max_chars ..],
    }) catch return allocator.dupe(u8, output) catch &[_]u8{}; // Return empty string on allocation failure

    return trimmed;
}

fn createEnhancedPrompt(self: *LLMAssistantDialog, user_prompt: []const u8, context: TerminalContext) ![]u8 {
    var prompt_builder = std.ArrayList(u8).init(self.arena.allocator());
    defer prompt_builder.deinit();

    // Use the new format requested by user
    try prompt_builder.appendSlice("## The user is asking about how to perform certain steps or actions via their CLI.");

    // Add command history if available
    if (context.commands.items.len > 0) {
        try prompt_builder.appendSlice("  Their ");
        const num_commands = @min(context.commands.items.len, 3); // Show up to 3 commands
        try prompt_builder.writer().print("{} latest run command{s} {s} (from oldest to newest):\n\n", .{ num_commands, if (num_commands == 1) @as([]const u8, "") else "s", if (num_commands == 1) @as([]const u8, "is") else "are" });

        // Show commands in reverse order (oldest to newest as requested)
        var i = num_commands;
        while (i > 0) {
            i -= 1;
            const entry = context.commands.items[context.commands.items.len - 1 - i];
            try prompt_builder.writer().print("{}) {s}\n", .{ num_commands - i, entry.command });
        }
    } else {
        try prompt_builder.appendSlice("\n");
    }

    // Add current terminal state if available
    if (context.current_input_full_line) |full_line| {
        try prompt_builder.appendSlice("\n## The current state of the active line is below. Ignore any decorations that may be present. When returning the suggested CLI command, return only the part of the command that is missing and assume that it will be inserted at the end of the current line:\n\n");
        try prompt_builder.appendSlice(full_line);
        try prompt_builder.appendSlice("\n");
    }

    // Add the user's request
    try prompt_builder.appendSlice("\n## They wish to:\n\n");
    try prompt_builder.appendSlice(user_prompt);
    try prompt_builder.appendSlice("\n");

    return self.arena.allocator().dupe(u8, prompt_builder.items);
}

fn trimOutput(self: *LLMAssistantDialog, output: []const u8) []const u8 {
    // Use the new implementation
    return self.trimOutputWithEllipsis(output);
}

fn pulsProgressBar(user_data: ?*anyopaque) callconv(.c) c_int {
    const self: *LLMAssistantDialog = @ptrCast(@alignCast(user_data.?));
    self.progress_bar.pulse();
    return @intFromBool(self.is_loading); // Continue if still loading
}
