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
const configpkg = @import("../../config.zig");
const i18n = @import("../../os/main.zig").i18n;
const Builder = @import("Builder.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const terminal = @import("../../terminal/main.zig");
const Screen = terminal.Screen;
const PageList = terminal.PageList;
const Pin = terminal.Pin;

// LLM helper modules
const llm_terminal_context = @import("llm/terminal_context.zig");
const llm_prompt_builder = @import("llm/prompt_builder.zig");
const llm_history = @import("llm/history.zig");
const llm_worker = @import("llm/worker.zig");
const LLMTerminalContext = llm_terminal_context.TerminalContext;
const HistoryManager = llm_history.History;

const log = std.log.scoped(.llm_assistant_dialog);

const UIState = enum {
    input,
    loading,
    success,
    err,
};

window: *Window,
arena: std.heap.ArenaAllocator,

// UI elements
dialog: *adw.Dialog,
input_box: *gtk.Box,
prompt_entry: *gtk.Entry,
context_checkbox: *gtk.CheckButton,
submit_button: *gtk.Button,
cancel_button: *gtk.Button,
suggestion_box: *gtk.Box,
suggestion_title_label: *gtk.Label,
suggestion_text: *gtk.TextView,
suggestion_buffer: *gtk.TextBuffer,
progress_bar: *gtk.ProgressBar,
error_label: *gtk.Label,
clear_button: *gtk.Button,
accept_button: *gtk.Button,
input_spacer: *gtk.Box,
shortcuts_hint: *gtk.Label,

// State
llm_provider: ?llm.LLMProvider = null,
pulse_timer: ?c_uint = null,
history_manager: HistoryManager,
current_response: ?[]u8 = null,
current_state: UIState = .input,

fn transitionToState(self: *LLMAssistantDialog, state: UIState) void {
    self.current_state = state;

    switch (state) {
        .input => {
            gtk.Widget.setVisible(self.input_box.as(gtk.Widget), 1);
            gtk.Widget.setVisible(self.input_spacer.as(gtk.Widget), 1);
            gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 0);
            self.stopPulseTimer();
        },
        .loading => {
            gtk.Widget.setVisible(self.input_box.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.input_spacer.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 1);
            gtk.Widget.setVisible(self.progress_bar.as(gtk.Widget), 1);
            gtk.Widget.setVisible(self.error_label.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.clear_button.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.accept_button.as(gtk.Widget), 0);
            self.pulse_timer = glib.timeoutAdd(100, pulsProgressBar, self);
        },
        .success => {
            gtk.Widget.setVisible(self.input_box.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.input_spacer.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 1);
            gtk.Widget.setVisible(self.progress_bar.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.clear_button.as(gtk.Widget), 1);
            gtk.Widget.setVisible(self.accept_button.as(gtk.Widget), 1);
            self.stopPulseTimer();
        },
        .err => {
            gtk.Widget.setVisible(self.input_spacer.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.suggestion_box.as(gtk.Widget), 1);
            gtk.Widget.setVisible(self.progress_bar.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.error_label.as(gtk.Widget), 0);
            gtk.Widget.setVisible(self.clear_button.as(gtk.Widget), 1);
            gtk.Widget.setVisible(self.accept_button.as(gtk.Widget), 0);
            self.stopPulseTimer();
        },
    }

    self.updateShortcutsHint();
}

pub fn init(self: *LLMAssistantDialog, window: *Window) !void {
    var builder = Builder.init("llm-assistant-dialog", 1, 5);
    defer builder.deinit();

    self.* = .{
        .window = window,
        .arena = .init(window.app.core_app.alloc),
        .dialog = builder.getObject(adw.Dialog, "llm-assistant-dialog").?,
        .input_box = builder.getObject(gtk.Box, "input-box").?,
        .prompt_entry = builder.getObject(gtk.Entry, "prompt-entry").?,
        .context_checkbox = builder.getObject(gtk.CheckButton, "context-checkbox").?,
        .submit_button = builder.getObject(gtk.Button, "submit-button").?,
        .cancel_button = builder.getObject(gtk.Button, "cancel-button").?,
        .suggestion_box = builder.getObject(gtk.Box, "suggestion-box").?,
        .suggestion_title_label = builder.getObject(gtk.Label, "suggestion-title-label").?,
        .suggestion_text = builder.getObject(gtk.TextView, "suggestion-text").?,
        .suggestion_buffer = undefined, // Will be set below
        .progress_bar = builder.getObject(gtk.ProgressBar, "progress-bar").?,
        .error_label = builder.getObject(gtk.Label, "error-label").?,
        .clear_button = builder.getObject(gtk.Button, "clear-button").?,
        .accept_button = builder.getObject(gtk.Button, "accept-button").?,
        .input_spacer = builder.getObject(gtk.Box, "input-spacer").?,
        .shortcuts_hint = builder.getObject(gtk.Label, "shortcuts-hint").?,
        .history_manager = HistoryManager.init(window.app.core_app.alloc),
    };

    // Get the text buffer for the suggestion text view
    self.suggestion_buffer = self.suggestion_text.getBuffer();

    // Set the initial checkbox state from configuration
    gtk.CheckButton.setActive(
        self.context_checkbox,
        @intFromBool(window.app.config.@"ext-llm-default-terminal-context"),
    );

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
    self.stopPulseTimer();

    if (self.llm_provider) |provider| {
        provider.deinit(self.arena.allocator());
    }

    if (self.current_response) |response| {
        self.arena.allocator().free(response);
    }

    self.history_manager.deinit();
    self.arena.deinit();
    self.dialog.unref();
}

pub fn show(self: *LLMAssistantDialog) void {
    self.resetDialog();
    self.dialog.present(self.window.window.as(gtk.Widget));
    _ = self.prompt_entry.as(gtk.Widget).grabFocus();
}

pub fn updateConfig(self: *LLMAssistantDialog, config: *const configpkg.Config) !void {
    if (self.llm_provider) |provider| {
        provider.deinit(self.arena.allocator());
        self.llm_provider = null;
    }

    gtk.CheckButton.setActive(
        self.context_checkbox,
        @intFromBool(config.@"ext-llm-default-terminal-context"),
    );

    try self.initLLMProvider();
}

fn initLLMProvider(self: *LLMAssistantDialog) !void {
    self.llm_provider = llm.createProvider(
        self.arena.allocator(),
        &self.window.app.config,
    ) catch |err| switch (err) {
        llm.LLMError.InvalidConfiguration => {
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
    const current_text = std.mem.span(gtk.Editable.getText(self.prompt_entry.as(gtk.Editable)));
    if (current_text.len == 0) {
        gtk.Editable.setText(self.prompt_entry.as(gtk.Editable), "");
    }

    self.transitionToState(.input);

    self.suggestion_buffer.setText("", 0);
    self.suggestion_title_label.setText(@ptrCast(i18n._("Suggested Command:")));

    self.submit_button.setLabel(i18n._("Get Suggestion"));
    const button_text = std.mem.span(gtk.Editable.getText(self.prompt_entry.as(gtk.Editable)));
    gtk.Widget.setSensitive(self.submit_button.as(gtk.Widget), @intFromBool(button_text.len > 0));

    if (self.current_response) |response| {
        self.arena.allocator().free(response);
        self.current_response = null;
    }
}

fn onPromptChanged(_: *gtk.Editable, self: *LLMAssistantDialog) callconv(.c) void {
    const text = std.mem.span(gtk.Editable.getText(self.prompt_entry.as(gtk.Editable)));
    const can_submit = text.len > 0 and self.current_state != .loading;
    gtk.Widget.setSensitive(self.submit_button.as(gtk.Widget), @intFromBool(can_submit));
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
            self.history_manager.navigate(.previous, self.prompt_entry);
            return 1;
        },
        gdk.KEY_Down => {
            self.history_manager.navigate(.next, self.prompt_entry);
            return 1;
        },
        gdk.KEY_Return, gdk.KEY_KP_Enter => {
            if (!mods.control_mask) return 0;
            if (self.current_state != .success) return 0;

            self.acceptSuggestion();
            return 1;
        },
        gdk.KEY_Escape => {
            switch (self.current_state) {
                .loading => self.cancelRequest(),
                .success, .err => self.clearSuggestion(),
                .input => _ = self.dialog.close(),
            }
            return 1;
        },
        else => return 0,
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

    const provider = self.llm_provider orelse {
        self.transitionToErrorWithMessage(self.getProviderErrorMessage());
        return;
    };

    self.history_manager.addEntry(text) catch |err| {
        log.warn("Failed to add prompt to history: {}", .{err});
    };

    self.transitionToState(.loading);

    const include_context = gtk.CheckButton.getActive(self.context_checkbox) != 0;
    const active_surface = self.getActiveSurface();
    const terminal_context = if (include_context)
        llm_terminal_context.getTerminalContext(self.arena.allocator(), active_surface) catch |err| blk: {
            log.warn("Failed to get terminal context: {}", .{err});
            break :blk null;
        }
    else
        null;

    const enhanced_prompt = if (include_context and terminal_context != null)
        llm_prompt_builder.createEnhancedPrompt(self.arena.allocator(), text, terminal_context.?) catch text
    else
        text;

    const worker_request = llm_worker.WorkerRequest{
        .prompt = self.arena.allocator().dupe(u8, enhanced_prompt) catch {
            self.transitionToErrorWithMessage("Memory allocation failed");
            return;
        },
        .terminal_context = if (include_context) terminal_context else null,
        .allocator = self.arena.allocator(),
    };

    log.debug("Querying LLM provider: {}", .{self.window.app.config.@"ext-llm-provider"});

    llm_worker.processRequest(
        provider,
        worker_request,
        onWorkerResponse,
        self,
    );
}

fn onWorkerResponse(response: llm_worker.WorkerResponse, user_data: ?*anyopaque) void {
    const self: *LLMAssistantDialog = @ptrCast(@alignCast(user_data.?));

    if (!response.success) {
        const error_msg = response.error_message orelse "Unknown error occurred";
        self.transitionToErrorWithMessage(error_msg);
        return;
    }

    const text = response.response orelse {
        self.transitionToErrorWithMessage("Received empty response from LLM");
        return;
    };

    self.transitionToSuccessWithResponse(text);
}

fn transitionToSuccessWithResponse(self: *LLMAssistantDialog, command_text: []const u8) void {
    if (command_text.len == 0) {
        self.transitionToErrorWithMessage("No command received from LLM service");
        return;
    }

    if (self.current_response) |old_response| {
        self.arena.allocator().free(old_response);
    }

    self.current_response = self.arena.allocator().dupe(u8, command_text) catch {
        self.transitionToErrorWithMessage("Failed to save response");
        return;
    };

    self.suggestion_title_label.setText(@ptrCast(i18n._("Suggested Command:")));
    self.suggestion_buffer.setText(@ptrCast(command_text.ptr), @intCast(command_text.len));

    self.transitionToState(.success);
    _ = self.prompt_entry.as(gtk.Widget).grabFocus();
}

fn stopPulseTimer(self: *LLMAssistantDialog) void {
    if (self.pulse_timer) |timer| {
        _ = glib.Source.remove(timer);
        self.pulse_timer = null;
    }
}

fn cancelRequest(self: *LLMAssistantDialog) void {
    self.transitionToState(.input);
    // Note: We can't actually cancel the HTTP request once started
}

fn transitionToErrorWithMessage(self: *LLMAssistantDialog, message: []const u8) void {
    self.suggestion_title_label.setText(@ptrCast(i18n._("An error occurred:")));
    self.suggestion_buffer.setText(@ptrCast(message.ptr), @intCast(message.len));
    self.transitionToState(.err);
}

fn clearSuggestion(self: *LLMAssistantDialog) void {
    self.resetDialog();
}

fn acceptSuggestion(self: *LLMAssistantDialog) void {
    const response = self.current_response orelse return;

    const tab = self.window.notebook.currentTab() orelse {
        self.copyToClipboard(response);
        self.closeAndClearInput();
        return;
    };

    const alloc = self.arena.allocator();
    const command_z = alloc.dupeZ(u8, response) catch {
        log.err("Failed to allocate memory for command insertion", .{});
        return;
    };
    defer alloc.free(command_z);

    const surface = self.getTabSurface(tab) orelse {
        log.warn("No active surface found to insert command", .{});
        self.copyToClipboard(response);
        self.closeAndClearInput();
        return;
    };

    surface.core_surface.completeClipboardRequest(.paste, command_z, false) catch |err| {
        log.err("Failed to insert command into terminal: {}", .{err});
        self.copyToClipboard(response);
        self.closeAndClearInput();
        return;
    };

    self.closeAndClearInput();
}

fn updateShortcutsHint(self: *LLMAssistantDialog) void {
    const hint_text = switch (self.current_state) {
        .loading => i18n._("Loading..."),
        .err => "",
        .success => i18n._("Ctrl+Enter accept"),
        .input => i18n._("↑↓ Navigate history"),
    };

    self.shortcuts_hint.setText(@ptrCast(hint_text));
}

fn getActiveSurface(self: *LLMAssistantDialog) ?*Surface {
    // Get the active surface
    const tab = self.window.notebook.currentTab() orelse return null;
    return tab.focus_child orelse switch (tab.elem) {
        .surface => |s| s,
        .split => null,
    };
}

fn pulsProgressBar(user_data: ?*anyopaque) callconv(.c) c_int {
    const self: *LLMAssistantDialog = @ptrCast(@alignCast(user_data.?));
    self.progress_bar.pulse();
    return @intFromBool(self.current_state == .loading);
}

fn getProviderErrorMessage(self: *LLMAssistantDialog) []const u8 {
    const config = &self.window.app.config;
    return if (!llm.isConfigured(config))
        std.mem.span(llm.getConfigurationError(config))
    else
        std.mem.span(i18n._("LLM provider failed to initialize. Please check your configuration and try again."));
}

fn getTabSurface(self: *LLMAssistantDialog, tab: anytype) ?*Surface {
    _ = self;
    return tab.focus_child orelse switch (tab.elem) {
        .surface => |s| s,
        .split => null,
    };
}

fn copyToClipboard(self: *LLMAssistantDialog, text: []const u8) void {
    _ = self;
    const display = gdk.Display.getDefault() orelse return;
    const clipboard = gdk.Display.getClipboard(display);
    gdk.Clipboard.setText(clipboard, @ptrCast(text.ptr));
}

fn closeAndClearInput(self: *LLMAssistantDialog) void {
    // Retain previous prompt in history
    gtk.Editable.setText(self.prompt_entry.as(gtk.Editable), "");
    _ = self.dialog.close();
}
