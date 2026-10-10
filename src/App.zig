// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The gtty application: owns the OS window, the job windows and the
//! prompt; decides layout and routes input. Job windows render and manage
//! their own processes (see ui/JobWindow.zig).

const std = @import("std");
const trace = @import("core/trace.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const c = @import("c.zig").c;
const color = @import("core/color.zig");
const Theme = color.Theme;
const Rgb = color.Rgb;
const Process = @import("core/Process.zig");
const Screen = @import("core/Screen.zig");
const Tee = @import("core/Tee.zig");
const Gfx = @import("render/Gfx.zig");
const Rect = Gfx.Rect;
const JobWindow = @import("ui/JobWindow.zig");
const Prompt = @import("ui/Prompt.zig");
const StatusBar = @import("ui/StatusBar.zig");
const Peek = @import("ui/Peek.zig");
const Menu = @import("ui/Menu.zig");
const SettingsWindow = @import("ui/SettingsWindow.zig");
const Config = @import("core/Config.zig");
const FileOpener = @import("ui/FileOpener.zig");
const FileFx = @import("ui/FileFx.zig");
const Modal = @import("ui/Modal.zig");
const RemoteLink = @import("core/RemoteLink.zig");
const ids_mod = @import("ui/ids.zig");
const oscmd = @import("core/oscmd.zig");
const beep = @import("ui/beep.zig");
const ShellNames = @import("core/ShellNames.zig");
const shell_hooks = @import("core/shell_hooks.zig");
const commands = @import("ui/commands.zig");
const tiling = @import("ui/tiling.zig");
const Ai = @import("ai/Ai.zig");
const Memory = @import("ai/Memory.zig");

const App = @This();

pub const Options = struct {
    script: ?[]const u8 = null,
    /// Typed into the prompt once at start (`-c` / `--command`); null: none.
    command: ?[]const u8 = "s",
    font_pt: f32 = 13,
    /// Rows of output each job window keeps in memory (--scrollback).
    scrollback: usize = Screen.default_max_lines,
    /// The settings file's values (what the settings window edits).
    cfg: Config = .{},
    /// Write settings changes to the file (not in a test script without
    /// GTTY_CONFIG).
    save_config: bool = false,
};

gpa: std.mem.Allocator,
window: *c.SDL_Window,
renderer: *c.SDL_Renderer,
gfx: Gfx,
theme: Theme = .{},
prompt: Prompt,
jobs: std.ArrayList(*JobWindow) = .empty,
/// The current job window, shown in the windows area (or maximized over
/// the whole screen). Every other job is minimized into the job grid.
main: ?usize = null,
/// Other job windows selected (checkbox in the job grid) to show next to
/// the current one in the windows area, in display order (set when the
/// selection changes, then kept while they are shown). Empty: the current
/// window alone.
extras: std.ArrayList(*JobWindow) = .empty,
/// Keyboard focus: a job window in the windows area (run mode), or null
/// for the prompt (compose mode).
focus: ?usize = null,
/// Sync typing (gtty menu, a title bar's sync pill): what this window
/// (the source) gets typed is typed into every other running window in
/// the windows area too; those are read-only while it lasts (no focus, no
/// paste). Null: off. See updateSync.
sync_src: ?ids_mod.Id = null,
/// Serial number for the next job window (#1, #2, …).
next_serial: u32 = 1,
/// Unique window ids (ids.zig).
ids: ids_mod.Gen = .init(0),
reaper: Process.Reaper,
/// Aliases, functions, builtins the user's shell knows (asked at startup).
shell_names: ShellNames,

font_pt: f32,
scrollback: usize,
/// Temp folder of this gtty instance: every job's full output (null if it
/// could not be made: then only the memory window is kept).
tmp: ?Tee.Dir = null,
/// The shell hook files are in `tmp` (core/shell_hooks.zig).
hooks: bool = false,
scale: JobWindow.Scale = .{},
density: f32 = 1,
width_px: f32 = 0,
height_px: f32 = 0,
desktop_r: Rect = .{},
/// Job grid: a column on the right with every job window but the current
/// one, running or finished (empty when no job is in it).
grid_r: Rect = .{},
/// Scroll of the job grid, in pixels (down).
grid_scroll: f32 = 0,
/// The job grid's header (fixed above the scrolling windows): its title
/// and the sort button.
grid_head_r: Rect = .{},
grid_sort_r: Rect = .{},
/// The header's checkbox: select as many windows as fit / clear the
/// selection; shows red until `head_err_until` when nothing more fits.
grid_check_r: Rect = .{},
head_err_until: u64 = 0,
/// Job grid order inside each group: last activity oldest first (true) or
/// newest first (false, the default).
grid_oldest_first: bool = false,
/// The mouse is over the sort button (drawn lighter).
over_grid_sort: bool = false,
/// Tooltip of the title-bar action under the mouse (JobWindow.tip): which
/// window, which action, since when; drawn once the mouse has rested
/// there for `tip_delay_ms`.
tip: ?Tip = null,
tip_drawn: bool = false,
/// The symbolic link name under the mouse (`JobWindow.linkAt`): after
/// `tip_delay_ms` a box over it shows where it points (`drawLinkHover`);
/// a click on the box cd's to the folder the target is in.
link_hover: ?LinkHover = null,
/// Height of everything in the job grid (to scroll through).
grid_content_h: f32 = 0,
/// The job grid's scroll bar: a strip down its right edge.
grid_bar_r: Rect = .{},
/// Dragging the scroll bar's thumb (`grid_grab` = where on it it was
/// taken); the mouse is over the bar (drawn wider).
grid_drag: bool = false,
grid_grab: f32 = 0,
over_grid_bar: bool = false,
/// The next relayout animates windows that change place (set by
/// `relayoutAnimated`: swaps, minimize, close, maximize, a job finishing).
animate: bool = false,
/// Screen-size offscreen canvas for window transitions: a moving window is
/// drawn there at its new place, then stretched along the way.
anim_canvas: ?*c.SDL_Texture = null,
/// The job window that was in the windows area at the last relayout:
/// when another takes its place, its last-action time is set (only
/// compared, never followed: it may be closed by then).
shown: ?*JobWindow = null,
/// Where the job grid's group labels ("running", "history") are drawn
/// (top of the label row; null while the group is empty).
grid_labels: [2]?f32 = .{ null, null },

running: bool = true,
dirty: bool = true,
help_visible: bool = false,
/// The About box (gtty menu ▸ About gtty); any click or key closes it.
about_visible: bool = false,
/// Mouse pointer shapes: an I-beam over job text, the arrow elsewhere.
text_cursor: ?*c.SDL_Cursor = null,
arrow_cursor: ?*c.SDL_Cursor = null,
over_text: bool = false,

/// The open peek of a chip (one at a time; Peek.zig), and the chip the
/// mouse rests on (a peek opens after `chip_hover_ms`).
peek: ?Peek = null,
chip_hover: ?Tip = null,
/// The open menu (Menu.zig): the right-click menu or `show`'s app picker.
menu: ?Menu = null,
/// A submenu of `menu` (paste history, folder history), next to its row
/// `sub_row`.
sub_menu: ?Menu = null,
sub_row: usize = 0,
sub_labels: [JobWindow.folder_history_max][folder_label_max * 4 + 4]u8 = undefined,
/// This session's copies from job windows, newest first (the right-click
/// menu's Paste ▸).
paste_history: std.ArrayList([]u8) = .empty,
/// `show`'s app picker or the file menu's Open With ▸, while open: the
/// file and the apps that can open it (row code k = app k).
picker_path: ?[:0]u8 = null,
picker_apps: []c.gtty_app = &.{},
/// Their icons (macOS), as the menu rows show them.
picker_icons: []?*c.SDL_Texture = &.{},
/// The file menu's "Open with <default app>".
open_label: [300]u8 = undefined,
picker_title: [300]u8 = undefined,
/// The file the system's app chooser was opened for (its name, for the
/// answer's notice).
chooser_file: [256]u8 = undefined,
chooser_file_len: usize = 0,
msg_buf: [512]u8 = undefined,
msg_len: usize = 0,
msg_color: Rgb = .{ .r = 0, .g = 0, .b = 0 },
msg_until: u64 = 0,
/// A rejected line flashes red in the prompt until this time.
reject_until: u64 = 0,

pending_shot: ?[]u8 = null,

/// The start-up command (`-c`), until it has run.
startup: ?[]u8 = null,

script: std.ArrayList([]u8) = .empty,
script_pos: usize = 0,
script_next: u64 = 0,
/// `/target`: the OS window script hooks act on.
script_target: enum { main, settings } = .main,
/// `/pace`: the gap between script lines.
script_gap_ms: u64 = 400,
/// Where the script's mouse is (window pixels), the button it holds and
/// when it last pressed one: the pointer and its click ring are drawn in
/// recorded frames (`drawPointer`).
script_ptr: ?[2]f32 = null,
script_btn: u8 = 0,
script_press_ms: u64 = 0,
/// `/slow`: text still to be typed, one character every `slow_ms`.
slow_text: ?[]u8 = null,
slow_pos: usize = 0,
slow_next: u64 = 0,
/// `/glide`: a mouse move in progress (window coordinates).
glide: ?struct { from: [2]f32, to: [2]f32, start: u64, ms: u64 } = null,
/// `/drop`: the path a pushed drop event points at (kept until the next).
script_drop: ?[:0]u8 = null,
/// `/record`: frames saved to `dir` (frame-NNNNN.ppm + frames.txt with
/// each frame's ms since the start), at most one every `every_ms`.
rec: ?struct { dir: []u8, list: *c.FILE, every_ms: u64, start: u64, next: u64 = 0, n: u32 = 0 } = null,

/// The settings as in the file (see Config.zig); the settings window
/// edits them, App applies each change and saves.
cfg: Config,
save_config: bool,
/// The last save worked.
saved_ok: bool = true,
/// The settings window, while open.
settings: ?*SettingsWindow = null,
/// SDL event type of the gtty menu's picks (`gtty_menu.h` codes).
menu_event: u32 = 0,
/// gtty's menus are in the OS's menu bar (macOS). Otherwise gtty draws a
/// menu bar at the top of its window (`menubar_r`) with a button per menu
/// (`menubar_btns`: gtty, Edit).
native_menu: bool = false,
menubar_r: Rect = .{},
menubar_btns: [Menu.bar_titles.len]Rect = [_]Rect{.{}} ** Menu.bar_titles.len,
over_menubar_btn: ?usize = null,
/// Where the mouse is (window pixels), null when outside gtty's window.
mouse: ?[2]f32 = null,
/// A left press on an outlined file name, waiting to see what it becomes:
/// released → a plain click; moved after FileOpener.hold_ms (the outline
/// turned solid) → the file is dragged out; moved sooner → a text
/// selection from the press.
file_press: ?struct { window: ids_mod.Id, x: f32, y: f32, ms: u64 } = null,
/// Files from another app being dragged over gtty's window (SDL drop
/// events): the paths so far; on the drop they are copied into the folder
/// under the mouse (`dropTarget`). `drop_inside`: gtty's own drag (a
/// file from one job window to another): the file is `drag_path`, and the
/// drop is decided once the drag session says it ended on gtty's window
/// (`inside_drop`: where, `tickInsideDrop`: types cp / mv there).
dropping: bool = false,
drop_inside: bool = false,
drop_paths: std.ArrayList([:0]u8) = .empty,
drag_path: ?[:0]u8 = null,
inside_drop: ?struct { target: InsideTarget, ms: u64 } = null,
/// Copies of dropped files running in the background (gtty_copy).
copying: std.ArrayList(Copying) = .empty,
/// The modal dialog that is open (one at a time), and what its answer is
/// for (`resolveModal`).
modal: ?Modal = null,
modal_job: ModalJob = .none,
/// File actions: the ⌘-clicked names (Ctrl-click on Linux), gtty's file
/// clipboard (copy / cut, waiting for a paste), when the mouse last moved
/// or clicked and when a key was last pressed (`pointerFresh`).
file_sel: std.ArrayList(FileSel) = .empty,
file_clip: std.ArrayList([:0]u8) = .empty,
file_clip_move: bool = false,
last_point_ms: u64 = 0,
last_key_ms: u64 = 0,
/// The file menu's files, Paste's folder, the name's place on screen (the
/// rename field goes there), and its labels' text.
menu_files: ?[][:0]u8 = null,
menu_dest: ?[:0]u8 = null,
menu_anchor: ?Rect = null,
/// The name the file menu is for (Copy / Cut flash it).
menu_range: ?Screen.TextRange = null,
/// The file menu's "cd <folder>" label.
menu_cd_label: [cd_label_max * 4 + 8]u8 = undefined,
/// The next `JobWindow.file_fx` id (FileFx: what a mouse action did to a
/// window's files, shown on it for a moment).
fx_next_id: u32 = 1,
/// A file dragged out of gtty (`drag_path`): once the drag ends, checked
/// for a while; gone from its folder → moved out (FileFx on its window).
drag_out: ?struct { window: ids_mod.Id, ended_ms: u64 = 0, next_ms: u64 = 0 } = null,
/// The window whose text the mouse is over (its file opener follows the
/// mouse).
hover_src: ?ids_mod.Id = null,
/// Mouse pointer shape now.
cursor_kind: enum { arrow, text, hand } = .arrow,
hand_cursor: ?*c.SDL_Cursor = null,
/// A window was closed, or a shell ended by itself: on the next frame,
/// open a new shell if none is running (`ensureShell`).
want_shell: bool = false,
/// When the last shells were opened (ms, a ring): more than
/// `shell_burst_max` within `shell_burst_ms` turns `auto_shell` off.
shell_opens: [shell_burst_max]u64 = @splat(0),
shell_opens_at: usize = 0,
/// New shells open by themselves (`ensureShell`); off after a burst (shells
/// that keep exiting), back on when the user opens one.
auto_shell: bool = true,
/// The last shell gone (and no other job running): quit instead of
/// opening a new one (config `quit-on-last-shell`; off in a test script
/// without `GTTY_CONFIG`).
quit_on_last_shell: bool = true,
/// A remote file being copied (the file opener in an ssh session), with
/// its modal over the job window: progress and Cancel.
fetch: ?Fetching = null,
/// Hover times (settings).
tip_delay_ms: u64 = 500,
chip_hover_ms: u64 = 500,

/// AI at the prompt (src/ai/): the request in flight, the user's text
/// (shown in the shell's line), `-x` (show the script first).
ai_req: ?*Ai.Request = null,
ai_text: std.ArrayList(u8) = .empty,
ai_show: bool = false,
/// The plan being carried out, step by step (a shell step waits for its
/// window to be at its prompt, and for the plan's previous command there
/// to end); `ai_danger`: the model said so, every script of it is shown
/// and asked about first (gtty's own check asks for a script it finds
/// dangerous either way).
ai_plan: ?Ai.Plan = null,
ai_step: usize = 0,
ai_step_ms: u64 = 0,
ai_danger: bool = false,
/// The shell `"current"` means (picked when asking) and the one the last
/// `sh` of the plan opened (`"new"`).
ai_cur: ?ids_mod.Id = null,
ai_new: ?ids_mod.Id = null,
/// Numbers the script files (`ai-<n>.sh`).
ai_seq: u32 = 0,
/// A window that got the keyboard to answer a script's y/N: the prompt
/// gets it back when that script is done.
ai_return: ?ids_mod.Id = null,
/// gtty's local memory for the AI (folders, ssh hosts, notes); written to
/// its file only when `memory_file` (not in test scripts unless
/// GTTY_AI_MEMORY says where).
memory: Memory,
memory_file: bool = false,
memory_saved_ms: u64 = 0,
/// New Window: the new gtty's process, yielded the front to until this
/// time (`tickFront`); in the new gtty, asking for the front until
/// `front_until` (0: done).
yield_pid: c_int = 0,
yield_until: u64 = 0,
front_until: u64 = 0,

pub fn create(gpa: std.mem.Allocator, opts: Options) !*App {
    // macOS: the click that activates gtty also counts (focus a window or
    // the prompt with one click, even when another app was in front).
    _ = c.SDL_SetHint(c.SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
    // Linux: the app id (Wayland) / WM class (X11) that matches the
    // installed gtty.desktop, so the desktop shows gtty's name and icon.
    _ = c.SDL_SetHint(c.SDL_HINT_APP_ID, "gtty");
    _ = c.SDL_SetAppMetadata("gtty", std.fmt.comptimePrint("{s}", .{build_options.version}), "gtty");
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    c.gtty_ignore_sigpipe();

    // GTTY_WINDOW ("x,y,w,h", from New Window in another gtty): where the
    // window goes (cascaded from that one). Taken out of the environment
    // so the jobs don't see it.
    const geo = windowGeometry();
    const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (geo != null) c.SDL_WINDOW_HIDDEN else 0);
    const window = c.SDL_CreateWindow("gtty", if (geo) |g| g[2] else 1100, if (geo) |g| g[3] else 720, flags) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindow;
    };
    if (geo) |g| {
        _ = c.SDL_SetWindowPosition(window, g[0], g[1]);
        _ = c.SDL_ShowWindow(window);
    }
    setIcon(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlRenderer;
    };
    _ = c.SDL_SetRenderVSync(renderer, 1);
    _ = c.SDL_StartTextInput(window);

    // The gtty menu: in the system menu bar (macOS), else drawn by gtty.
    // GTTY_MENU_BAR=1 draws it on macOS too (to test the Linux look).
    const menu_event = c.SDL_RegisterEvents(1);
    const native_menu = menu_event != 0 and c.getenv("GTTY_MENU_BAR") == null and c.gtty_menu_install(menu_event, menuEnabled, menuChecked);

    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .window = window,
        // Opened by New Window: come to the front (`tickFront`).
        .front_until = if (geo != null) c.SDL_GetTicks() + 3000 else 0,
        .renderer = renderer,
        .gfx = try Gfx.init(gpa, renderer),
        .prompt = Prompt.init(gpa),
        .reaper = .{ .gpa = gpa },
        .shell_names = .init(gpa),
        .font_pt = opts.font_pt,
        .scrollback = opts.scrollback,
        .tmp = Tee.Dir.create(gpa) catch null,
        .ids = .init(c.SDL_rand_bits()),
        .cfg = opts.cfg,
        .save_config = opts.save_config,
        .menu_event = menu_event,
        .native_menu = native_menu,
        .tip_delay_ms = opts.cfg.tip_ms,
        .chip_hover_ms = opts.cfg.chip_hover_ms,
        .memory = .init(gpa),
        .memory_file = opts.save_config or c.getenv("GTTY_AI_MEMORY") != null,
        .quit_on_last_shell = opts.cfg.quit_on_last_shell and (opts.script == null or opts.save_config),
    };
    if (app.memory_file) app.memory.load();
    menu_app = app;
    JobWindow.sync_hook = .{ .ctx = app, .f = syncMirror };
    FileOpener.enabled = opts.cfg.file_opener;
    JobWindow.color_folders = opts.cfg.color_folders;
    JobWindow.refresh_ls = opts.cfg.refresh_ls;
    if (c.getenv("GTTY_COLOR_FOLDERS")) |v| JobWindow.color_folders = !std.mem.eql(u8, std.mem.span(v), "0");
    // Drag and drop with other apps (macOS; Linux only under Wayland).
    c.gtty_drag_init(window);
    Peek.dismiss_ms = opts.cfg.peek_close_ms;
    JobWindow.hard_kill_ms = opts.cfg.kill_grace_ms;
    app.applyColors();
    JobWindow.marks_on = opts.cfg.marks;
    JobWindow.mark_pt = @floatFromInt(opts.cfg.mark_width);
    app.marksFromEnv();
    if (app.tmp) |d| app.hooks = shell_hooks.install(d.path);
    app.updateScale();
    if (opts.script) |path| try app.loadScript(path);
    if (opts.command) |cmd| if (std.mem.trim(u8, cmd, " \t").len > 0) {
        app.startup = try gpa.dupe(u8, cmd);
    };
    app.shell_names.refresh(userShell(), &app.reaper);
    return app;
}

pub fn destroy(app: *App) void {
    if (app.ai_req) |r| r.destroy();
    if (app.ai_plan) |*p| p.deinit();
    app.ai_text.deinit(app.gpa);
    if (app.memory_file) app.memory.save();
    app.memory.deinit();
    if (app.settings) |sw| sw.close();
    if (app.fetch) |*f| f.job.deinit(app.gpa);
    for (app.jobs.items) |w| w.destroy(&app.reaper);
    app.jobs.deinit(app.gpa);
    app.extras.deinit(app.gpa);
    if (app.peek) |*pk| pk.deinit(&app.reaper);
    app.freePicker();
    for (app.paste_history.items) |t| app.gpa.free(t);
    app.paste_history.deinit(app.gpa);
    if (app.tmp) |*d| d.remove(app.gpa);
    app.shell_names.deinit(&app.reaper);
    app.reaper.deinit();
    for (app.drop_paths.items) |p| app.gpa.free(p);
    app.drop_paths.deinit(app.gpa);
    if (app.drag_path) |p| app.gpa.free(p);
    app.copying.deinit(app.gpa); // copies still running finish on their own
    @import("ui/DirCache.zig").deinit();
    app.freeModalJob(app.modal_job);
    app.clearFileSel();
    app.file_sel.deinit(app.gpa);
    for (app.file_clip.items) |p| app.gpa.free(p);
    app.file_clip.deinit(app.gpa);
    app.freeMenuFiles();
    app.prompt.deinit();
    if (app.startup) |s| app.gpa.free(s);
    for (app.script.items) |l| app.gpa.free(l);
    app.stopRecord();
    if (app.slow_text) |t| app.gpa.free(t);
    if (app.script_drop) |p| app.gpa.free(p);
    app.script.deinit(app.gpa);
    if (app.pending_shot) |p| app.gpa.free(p);
    if (app.text_cursor) |cur| c.SDL_DestroyCursor(cur);
    if (app.arrow_cursor) |cur| c.SDL_DestroyCursor(cur);
    if (app.hand_cursor) |cur| c.SDL_DestroyCursor(cur);
    if (app.anim_canvas) |cv| c.SDL_DestroyTexture(cv);
    app.gfx.deinit();
    c.SDL_DestroyRenderer(app.renderer);
    c.SDL_DestroyWindow(app.window);
    c.SDL_Quit();
    app.gpa.destroy(app);
}

const Tip = struct { uid: ids_mod.Id, hit: JobWindow.Hit, since: u64 };
// Tooltips after `tip_delay_ms`; the mouse resting on a chip
// `chip_hover_ms` opens its peek (so brushing past it on the way
// elsewhere doesn't; a click opens it at once). Both are settings.

// ------------------------------------------------------------ main loop

pub fn run(app: *App) void {
    while (app.running) {
        var ev: c.SDL_Event = undefined;
        if (c.SDL_WaitEventTimeout(&ev, 8)) {
            app.handle(&ev);
            while (c.SDL_PollEvent(&ev)) app.handle(&ev);
        }
        var rehover = false;
        // Shells that exited by themselves this frame: closed after the loop.
        var exited: [8]ids_mod.Id = undefined;
        var n_exited: usize = 0;
        for (app.jobs.items, 0..) |w, i| {
            const was_running = w.running();
            if (w.pump(&app.gfx)) app.dirty = true;
            // The text changed (output, scrolling, resize): the file
            // opener's outline went; look again under the mouse.
            if (w.textChanged()) {
                app.dirty = true;
                if (app.hover_src == w.uid) rehover = true;
            }
            if (w.tick(&app.gfx, c.SDL_GetTicks())) app.dirty = true;
            // The focused job ended: hand the keyboard back to the prompt.
            if (was_running and !w.running()) {
                if (app.focus == i) app.clearFocus();
                // A shell window closed: its config may have changed.
                if (w.kind == .shell) app.shell_names.refresh(userShell(), &app.reaper);
                // A shell that ended by itself (`exit`, a crash; not killed
                // from its kill menu) is treated as if × was pressed: the
                // window closes, and a new shell opens if none is left.
                if (w.kind == .shell and w.kill_ms == 0 and n_exited < exited.len) {
                    exited[n_exited] = w.uid;
                    n_exited += 1;
                }
                app.relayoutAnimated(); // borders, title-bar buttons change
            }
        }
        for (exited[0..n_exited]) |uid| if (app.jobByUid(uid)) |w| if (app.indexOfWindow(w)) |i| app.closeWindow(i);
        // The text under the mouse may be different now.
        if (rehover) app.sendHover();
        app.reaper.tick();
        app.shell_names.tick(&app.reaper);
        app.tickStartup();
        app.tickScript();
        c.gtty_drag_tick();
        app.tickFront();
        app.tickInsideDrop();
        app.tickFilePress();
        app.tickCopies();
        app.tickChooser();
        app.tickDragOut();
        app.tickModal();
        app.tickPeek();
        app.updateSync();
        if (app.reject_until != 0 and c.SDL_GetTicks() > app.reject_until) {
            app.reject_until = 0;
            app.dirty = true;
        }
        if (app.head_err_until != 0 and c.SDL_GetTicks() > app.head_err_until) {
            app.head_err_until = 0;
            app.dirty = true;
        }
        if (app.tip) |t| if (c.SDL_GetTicks() -| t.since >= app.tip_delay_ms and !app.tip_drawn) {
            app.dirty = true;
        };
        if (app.link_hover) |h| if (h.box == null and c.SDL_GetTicks() -| h.since >= app.tip_delay_ms) {
            app.dirty = true;
        };
        app.tickLinkHover();
        if (app.msg_until != 0 and c.SDL_GetTicks() > app.msg_until) {
            app.msg_until = 0;
            app.msg_len = 0;
            app.dirty = true;
        }
        app.tickSettings();
        app.tickRemote();
        app.tickAi();
        app.ensureShell();
        if (app.rec) |r| if (c.SDL_GetTicks() >= r.next) {
            app.dirty = true;
        };
        if (app.dirty) {
            app.render();
            app.dirty = false;
        }
    }
}

// ------------------------------------------------------------ scale & layout

/// HiDPI: everything is drawn in physical pixels. Fonts are rasterized at
/// font_pt × display scale, so text stays sharp on Retina and on
/// fractional-scaled Linux displays.
fn updateScale(app: *App) void {
    var wp: c_int = 0;
    var hp: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(app.window, &wp, &hp);
    app.width_px = @floatFromInt(wp);
    app.height_px = @floatFromInt(hp);
    app.density = c.SDL_GetWindowPixelDensity(app.window);
    if (app.density <= 0) app.density = 1;
    var ds = c.SDL_GetWindowDisplayScale(app.window);
    if (ds <= 0) ds = app.density;
    const scale: JobWindow.Scale = .{
        .ui = ds,
        .base_px = @intFromFloat(@round(app.font_pt * ds)),
    };
    const changed = scale.base_px != app.scale.base_px or scale.ui != app.scale.ui;
    app.scale = scale;
    if (changed) for (app.jobs.items) |w| w.setScale(&app.gfx, scale);
    app.relayout();
}

/// Very small text for the status bar.
fn statusFace(app: *App) *Gfx.Face {
    return app.gfx.face(@intFromFloat(@round(@as(f32, @floatFromInt(app.scale.base_px)) * 0.85))) catch unreachable;
}

fn promptFaces(app: *App) struct { *Gfx.Face, *Gfx.Face } {
    const f = app.gfx.face(app.scale.base_px) catch unreachable;
    const hf = app.gfx.face(@intFromFloat(@round(@as(f32, @floatFromInt(app.scale.base_px)) * 0.86))) catch unreachable;
    return .{ f, hf };
}

fn relayout(app: *App) void {
    const f, _ = app.promptFaces();
    const ph = Prompt.height(f, app.statusFace(), app.scale.ui);
    app.prompt.layout(.{ .x = 0, .y = app.height_px - ph, .w = app.width_px, .h = ph }, f, app.scale.ui);
    // The drawn menu bar (no system menu bar): a thin strip on top.
    const bar_h: f32 = if (app.native_menu) 0 else @round(app.statusFace().cell_h * 1.7);
    app.menubar_r = .{ .x = 0, .y = 0, .w = app.width_px, .h = bar_h };
    {
        const sf = app.statusFace();
        var bx = @round(4 * app.scale.ui);
        for (&app.menubar_btns, Menu.bar_titles) |*b, title| {
            const bw = if (bar_h > 0) Gfx.textWidth(sf, title) + @round(20 * app.scale.ui) else 0;
            b.* = .{ .x = bx, .y = 0, .w = bw, .h = bar_h };
            bx += bw;
        }
    }
    app.desktop_r = .{ .x = 0, .y = bar_h, .w = app.width_px, .h = app.height_px - ph - bar_h };

    // Moving into or out of the windows area is an action on both windows.
    const now_main: ?*JobWindow = if (app.main) |m| app.jobs.items[m] else null;
    if (app.shown != now_main) {
        if (app.shown) |old| for (app.jobs.items) |w| if (w == old) w.touch();
        if (now_main) |w| w.touch();
        app.shown = now_main;
    }

    // Where every window is now, to animate the ones that move.
    var old: [64]Rect = undefined;
    for (app.jobs.items, 0..) |w, i| old[i] = w.screenBox();
    defer if (app.animate) {
        app.animate = false;
        for (app.jobs.items, 0..) |w, i| {
            const b = w.screenBox();
            const o = old[i];
            if (o.w > 0 and (o.x != b.x or o.y != b.y or o.w != b.w or o.h != b.h)) w.animateFrom(o);
        }
    };

    var gbuf: [64]usize = undefined;
    var grid, var n_running = app.gridJobs(&gbuf);
    var l = app.layoutFor(grid.len);
    // Fewer windows fit than are selected (gtty's window got smaller): the
    // last ones go back to the job grid, unchecked; the rest re-split.
    if (app.extras.items.len > 0 and app.extras.items.len + 1 > app.viewCapacity(l.main)) {
        const cap = app.viewCapacity(l.main);
        while (app.extras.items.len + 1 > cap) app.unshow(app.extras.pop().?);
        grid, n_running = app.gridJobs(&gbuf);
        l = app.layoutFor(grid.len);
    }
    app.grid_r = l.grid;
    app.grid_head_r = l.head;
    {
        // Sort button: right-aligned in the header.
        const sf = app.statusFace();
        const ui = app.scale.ui;
        const bw = Gfx.textWidth(sf, sort_labels[0]) + @round(14 * ui);
        const bh = sf.cell_h + @round(6 * ui);
        app.grid_sort_r = .{ .x = l.head.x + l.head.w - bw - @round(6 * ui), .y = l.head.y + @round((l.head.h - bh) / 2), .w = bw, .h = bh };
        const box = @round(f.cell_h * 0.95);
        app.grid_check_r = .{ .x = l.head.x + @round(4 * ui), .y = l.head.y + @round((l.head.h - box) / 2), .w = box, .h = box };
    }
    defer app.dirty = true;

    // The windows area: the current window alone, or with the selected
    // ones (spread evenly, the current one first: see tiling.arrange).
    if (app.main) |m| {
        const top = app.menubar_r.h;
        const full: Rect = .{ .x = 0, .y = top, .w = app.width_px, .h = app.height_px - top };
        const n = 1 + app.extras.items.len;
        var tiles: [64]Rect = undefined;
        tiling.arrange(l.main, app.minWindow(), @round(8 * app.scale.ui), tiles[0..n]);
        for (0..n) |k| {
            const w = if (k == 0) app.jobs.items[m] else app.extras.items[k - 1];
            w.check = if (n == 1) .hidden else if (k == 0) .locked else .on;
            w.place(&app.gfx, if (w.maximized) full else tiles[k], null);
        }
    }

    // Minimized jobs keep a normal-size title bar (all actions usable) over
    // a scaled-down copy of their content; the program still sees the
    // windows-area size, so moving in and out never resizes its terminal.
    // Job grid: one column in two groups, running jobs above history
    // jobs, each by last activity (see gridJobs), under a small label;
    // scrolls down under the fixed header.
    const gap = @round(8 * app.scale.ui);
    const chrome_h = JobWindow.chromeHeight(&app.gfx, app.scale);
    // Content aspect (a grid copy shows the text only, no footer strip).
    const ratio = l.main.w / @max(l.main.h - chrome_h - JobWindow.footHeight(&app.gfx, app.scale), 1);
    const bar_w = @round(8 * app.scale.ui);
    app.grid_bar_r = .{ .x = l.grid.x + l.grid.w - bar_w - @round(3 * app.scale.ui), .y = l.grid.y + gap, .w = bar_w, .h = @max(l.grid.h - 2 * gap, 1) };
    const cell_w = @max(app.grid_bar_r.x - @round(5 * app.scale.ui) - l.grid.x, 1);
    const cell_h = @round(cell_w / ratio) + chrome_h;
    const label_h = app.statusFace().cell_h + gap;
    const groups = [2][]const usize{ grid[0..n_running], grid[n_running..] };
    var grid_h: f32 = 0;
    for (groups) |g| {
        if (g.len > 0) grid_h += label_h + @as(f32, @floatFromInt(g.len)) * (cell_h + gap);
    }
    app.grid_content_h = grid_h + gap;
    app.grid_scroll = std.math.clamp(app.grid_scroll, 0, app.gridMaxScroll());
    var y = l.grid.y - app.grid_scroll;
    for (groups, 0..) |g, k| {
        app.grid_labels[k] = if (g.len > 0) y else null;
        if (g.len == 0) continue;
        y += label_h;
        for (g) |i| {
            app.jobs.items[i].check = .off;
            app.jobs.items[i].place(&app.gfx, l.main, .{ .x = l.grid.x, .y = y, .w = cell_w, .h = cell_h });
            y += cell_h + gap;
        }
    }
}

/// Relayout, and show the windows that change place moving there.
fn relayoutAnimated(app: *App) void {
    app.animate = true;
    app.relayout();
}

fn gridMaxScroll(app: *const App) f32 {
    return @max(app.grid_content_h - app.grid_r.h, 0);
}

/// The job grid's scroll-bar thumb (y and height on its strip); null when
/// everything fits.
fn gridThumb(app: *const App) ?struct { y: f32, h: f32 } {
    const max = app.gridMaxScroll();
    if (max <= 0 or app.grid_r.w <= 0) return null;
    const r = app.grid_bar_r;
    const h = @round(@max(r.h * app.grid_r.h / app.grid_content_h, 24 * app.scale.ui));
    return .{ .y = r.y + @round((r.h - h) * app.grid_scroll / max), .h = h };
}

/// The scroll bar takes clicks a bit wider than it is drawn.
fn gridBarHit(app: *const App, x: f32, y: f32) bool {
    if (app.gridThumb() == null) return false;
    const r = app.grid_bar_r;
    const extra = @round(3 * app.scale.ui);
    return (Rect{ .x = r.x - extra, .y = r.y, .w = r.w + 2 * extra, .h = r.h }).contains(x, y);
}

/// Scroll the job grid so the thumb's top sits at `y - grid_grab`.
fn gridBarTo(app: *App, y: f32) void {
    const t = app.gridThumb() orelse return;
    const r = app.grid_bar_r;
    const frac = std.math.clamp((y - app.grid_grab - r.y) / @max(r.h - t.h, 1), 0, 1);
    app.grid_scroll = @round(frac * app.gridMaxScroll());
    app.relayout();
}

/// Every job not in the windows area: the running ones first, then the
/// finished ones, each group by last action, newest first (or oldest
/// first: `grid_oldest_first`) (`last_activity_ms`; then
/// higher #N). A job being closed or killed counts as finished already (it
/// may take up to 2 s to go). Also returns how
/// many are running.
fn gridJobs(app: *App, buf: []usize) struct { []usize, usize } {
    var n: usize = 0;
    var n_running: usize = 0;
    for ([_]bool{ true, false }) |want_running| {
        var i = app.jobs.items.len;
        while (i > 0 and n < buf.len) {
            i -= 1;
            const j = app.jobs.items[i];
            if (app.isShown(i) or (j.running() and !j.ending()) != want_running) continue;
            buf[n] = i;
            n += 1;
        }
        if (want_running) n_running = n;
    }
    const S = struct {
        fn newer(a: *App, x: usize, y: usize) bool {
            const p = a.jobs.items[x];
            const q = a.jobs.items[y];
            const later = if (p.last_activity_ms != q.last_activity_ms) p.last_activity_ms > q.last_activity_ms else p.serial > q.serial;
            return later != a.grid_oldest_first;
        }
    };
    std.mem.sort(usize, buf[0..n_running], app, S.newer);
    std.mem.sort(usize, buf[n_running..n], app, S.newer);
    return .{ buf[0..n], n_running };
}

/// Narrowest grid cell (at 1x): a grid title bar's checkbox, copy, serial
/// badge and × (no minimize / maximize there; the title is cut first),
/// and the header's "Jobs" + sort button.
const min_cell_w = 150;

/// Windows area split: the job grid down the right (windows area : grid =
/// 8 : 1, a ninth of the width; at least one cell wide; made smaller
/// once only minimized windows go there, 2026-10-06), only while it holds jobs: a fixed header on
/// top, the windows under it. The current job window gets the rest.
fn layoutFor(app: *App, grid_n: usize) struct { main: Rect, head: Rect, grid: Rect } {
    const gap = @round(8 * app.scale.ui);
    const a = app.desktop_r;
    const grid_w: f32 = if (grid_n > 0) @max(@round(a.w / 9), @round(min_cell_w * app.scale.ui) + gap) else 0;
    const f, _ = app.promptFaces();
    const head_h: f32 = if (grid_n > 0) @round(f.cell_h + 14 * app.scale.ui) else 0;
    const x = a.x + a.w - grid_w;
    return .{
        .head = .{ .x = x, .y = a.y, .w = grid_w, .h = head_h },
        .grid = .{ .x = x, .y = a.y + head_h, .w = grid_w, .h = a.h - head_h },
        .main = .{
            .x = a.x + gap,
            .y = a.y + gap,
            .w = @max(a.w - grid_w - 2 * gap, 1),
            .h = @max(a.h - 2 * gap, 1),
        },
    };
}

/// The sort button's two states (same width, so it doesn't jump).
const sort_labels = [2][]const u8{ "↓ newest", "↑ oldest" };

/// Flip the job grid's order; the windows slide to their new places.
fn toggleGridSort(app: *App) void {
    app.grid_oldest_first = !app.grid_oldest_first;
    app.grid_scroll = 0;
    app.relayoutAnimated();
}

/// Newest running job other than `except` (the next one to take the
/// windows area when the current one is minimized or closed).
fn newestRunning(app: *App, except: ?usize) ?usize {
    var i = app.jobs.items.len;
    while (i > 0) {
        i -= 1;
        if (i != except and app.jobs.items[i].running() and !app.jobs.items[i].ending()) return i;
    }
    return null;
}

// ------------------------------------------------------------ selection

/// In the windows area: the current window or a selected one.
fn isShown(app: *App, i: usize) bool {
    return app.main == i or app.extraIndex(app.jobs.items[i]) != null;
}

fn extraIndex(app: *App, w: *JobWindow) ?usize {
    for (app.extras.items, 0..) |e, k| if (e == w) return k;
    return null;
}

fn indexOfWindow(app: *App, w: *JobWindow) ?usize {
    for (app.jobs.items, 0..) |j, i| if (j == w) return i;
    return null;
}

/// Smallest usable job window: 40 × 10 at gtty's text size.
fn minWindow(app: *App) tiling.Size {
    const m = JobWindow.minSize(&app.gfx, app.scale, tiling.min_cols, tiling.min_rows);
    return .{ .w = m.w, .h = m.h };
}

/// How many windows fit in the windows area `area` (at least one).
fn viewCapacity(app: *App, area: Rect) usize {
    return tiling.capacity(.{ .w = area.w, .h = area.h }, app.minWindow(), @round(8 * app.scale.ui));
}

/// How many windows fit once `grid_n` windows are left in the job grid
/// (the grid takes room only while it holds some).
fn capacityWith(app: *App, grid_n: usize) usize {
    return app.viewCapacity(app.layoutFor(grid_n).main);
}

fn gridCount(app: *App) usize {
    var n: usize = 0;
    for (0..app.jobs.items.len) |i| {
        if (!app.isShown(i)) n += 1;
    }
    return n;
}

/// A selected window leaves the windows area for the job grid (moving out
/// is an activity). The caller already took it out of `extras`.
fn unshow(app: *App, w: *JobWindow) void {
    w.maximized = false;
    w.focused = false;
    w.touch();
    if (app.indexOfWindow(w)) |i| if (app.focus == i) {
        app.focus = null;
    };
}

/// The selection changed: give the selected windows new activity times
/// that keep their order (the oldest gets a base time, each next one 1 ms
/// more, the current window now), then order them for display: running
/// first, then finished, each newest first. The order then stays while
/// they are shown.
fn restamp(app: *App) void {
    const m = app.main orelse return;
    const items = app.extras.items;
    const S = struct {
        fn live(w: *JobWindow) bool {
            return w.running() and !w.ending();
        }
        fn older(_: void, a: *JobWindow, b: *JobWindow) bool {
            return if (a.last_activity_ms != b.last_activity_ms) a.last_activity_ms < b.last_activity_ms else a.serial < b.serial;
        }
        fn shownFirst(_: void, a: *JobWindow, b: *JobWindow) bool {
            if (live(a) != live(b)) return live(a);
            return a.last_activity_ms > b.last_activity_ms;
        }
    };
    std.mem.sort(*JobWindow, items, {}, S.older);
    const now = c.SDL_GetTicks();
    for (items, 0..) |w, k| w.last_activity_ms = now -| (items.len - k);
    app.jobs.items[m].last_activity_ms = now;
    std.mem.sort(*JobWindow, items, {}, S.shownFirst);
}

/// No room for one more window: red check for 2 s, the error beep, and a
/// notice with how many fit.
fn noRoom(app: *App, cap: usize) void {
    beep.beep();
    app.sayFmt("room for {d} window{s}", .{ cap, if (cap == 1) "" else "s" }, app.theme.stderr_accent);
}

/// The checkbox in a title bar: a grid window joins the windows area
/// (if it fits), a selected one goes back to the grid. The current window
/// is always selected.
fn toggleCheck(app: *App, i: usize) void {
    const w = app.jobs.items[i];
    if (app.extraIndex(w)) |k| {
        _ = app.extras.orderedRemove(k);
        app.unshow(w);
        app.restamp();
        return app.relayoutAnimated();
    }
    if (app.main == i) return;
    if (app.main == null) return app.setFocus(i);
    const cap = app.capacityWith(app.gridCount() - 1);
    if (app.extras.items.len + 2 > cap) {
        w.flashCheck();
        app.noRoom(cap);
        return;
    }
    w.touch(); // moving into the windows area is an activity
    app.extras.append(app.gpa, w) catch return;
    app.restamp();
    app.relayoutAnimated();
}

/// The job grid header's checkbox: with windows selected, clear the
/// selection; otherwise select as many as fit, in grid order.
fn toggleCheckAll(app: *App) void {
    if (app.extras.items.len > 0) {
        while (app.extras.pop()) |w| app.unshow(w);
        app.restamp();
        return app.relayoutAnimated();
    }
    var gbuf: [64]usize = undefined;
    const grid, _ = app.gridJobs(&gbuf);
    if (grid.len == 0) return;
    var from: usize = 0;
    if (app.main == null) {
        app.main = grid[0];
        app.jobs.items[grid[0]].touch();
        from = 1;
    }
    var added: usize = 0;
    for (grid[from..], from..) |i, k| {
        const left = grid.len - k - 1; // still in the grid after this one
        if (app.extras.items.len + 2 > app.capacityWith(left)) break;
        app.jobs.items[i].touch();
        app.extras.append(app.gpa, app.jobs.items[i]) catch break;
        added += 1;
    }
    if (added == 0 and from == 0) {
        app.head_err_until = c.SDL_GetTicks() + 2000;
        app.noRoom(app.capacityWith(grid.len));
        app.dirty = true;
        return;
    }
    app.restamp();
    app.relayoutAnimated();
}

/// The window in the windows area that is maximized, if any.
fn maximizedShown(app: *App) ?usize {
    if (app.main) |m| if (app.jobs.items[m].maximized) return m;
    for (app.extras.items) |w| if (w.maximized) return app.indexOfWindow(w);
    return null;
}

/// The focused window if it is in the windows area, else the current one.
fn activeShown(app: *App) ?usize {
    if (app.focus) |f| if (app.isShown(f)) return f;
    return app.main;
}

// ------------------------------------------------------------ jobs

fn openJob(app: *App, spec: JobWindow.Spec) void {
    if (app.jobs.items.len >= 64) {
        app.say("too many windows (64) — `/close` some first", app.theme.stderr_accent);
        return;
    }
    // Created at the windows area's size; the tiling then gives it its
    // place (the PTY is resized with it).
    const main_r = app.layoutFor(app.jobs.items.len).main;
    if (app.main) |m| app.jobs.items[m].maximized = false;
    var full = spec;
    full.max_lines = app.scrollback;
    full.log_dir = if (app.tmp) |d| d.path else null;
    const w = JobWindow.create(app.gpa, &app.gfx, app.ids.take(), app.next_serial, full, main_r, app.scale) catch |e| {
        app.sayFmt("could not start {s}: {s}", .{ spec.title, @errorName(e) }, app.theme.stderr_accent);
        return;
    };
    app.next_serial += 1;
    w.colors = app.cfg.colors;
    app.jobs.append(app.gpa, w) catch {
        w.destroy(&app.reaper);
        return;
    };
    app.grid_scroll = 0;
    // It joins what is in the windows area (setFocus).
    app.setFocus(app.jobs.items.len - 1);
    // A new window rises from the prompt.
    const p = app.prompt.rect;
    w.animateFrom(.{ .x = p.x + p.w / 4, .y = p.y, .w = p.w / 2, .h = p.h });
}

/// The window / Dock icon, embedded so even the bare binary shows it
/// (the .app bundle and the Linux packages also install it as files).
fn setIcon(window: *c.SDL_Window) void {
    const png = @embedFile("assets/gtty-icon.png");
    const io = c.SDL_IOFromConstMem(png, png.len) orelse return;
    const full = c.SDL_LoadPNG_IO(io, true) orelse return;
    defer c.SDL_DestroySurface(full);
    // macOS: the Dock wants the full 1024 px; X11 copies the pixels into a
    // window property, so keep that small.
    if (builtin.os.tag == .macos) {
        _ = c.SDL_SetWindowIcon(window, full);
        return;
    }
    const small = c.SDL_ScaleSurface(full, 256, 256, c.SDL_SCALEMODE_LINEAR) orelse return;
    defer c.SDL_DestroySurface(small);
    _ = c.SDL_SetWindowIcon(window, small);
}

fn userShell() []const u8 {
    if (c.getenv("SHELL")) |s| if (s[0] != 0) return std.mem.span(s);
    // Started from Finder / the Dock / a desktop launcher $SHELL may be
    // unset: the login shell from the user database.
    if (c.getpwuid(c.getuid())) |pw| if (pw.*.pw_shell) |s| if (s[0] != 0) return std.mem.span(s);
    return "/bin/sh";
}

const shell_burst_max = 5;
const shell_burst_ms = 5000;

/// The window the user is working with: the focused one, else the current
/// one in the windows area.
fn currentJob(app: *App) ?*JobWindow {
    const i = app.activeShown() orelse return null;
    return app.jobs.items[i];
}

/// New Shell (⌘T / Ctrl+Shift+T, the gtty menu, the right-click menu): the
/// user's shell in a new window, in the folder `from`'s program is in
/// (like a new tab in a terminal); no window, or its folder unknown: the
/// home folder.
fn newShell(app: *App, from: ?*JobWindow) void {
    var buf: [4096]u8 = undefined;
    var zbuf: [4097]u8 = undefined;
    var dir: ?[:0]const u8 = null;
    if (from) |w| {
        const d = w.folder(&buf);
        if (d.len > 0) if (std.fmt.bufPrintZ(&zbuf, "{s}", .{d}) catch null) |z| {
            if (isDir(z)) dir = z;
        };
    }
    if (dir == null) if (c.getenv("HOME")) |h| {
        dir = std.mem.span(h);
    };
    app.auto_shell = true; // the user's own: new shells open again
    app.openShellIn(null, dir);
}

/// New Window (gtty menu, ⌘N / Ctrl+Shift+N): another gtty — its own OS
/// window and process — starting in the folder `from`'s program is in
/// (else home), with a shell there. Its window is cascaded from this one
/// (`cascade`). `GTTY_SHOW_DRY=1`: only says so.
fn newWindow(app: *App, from: ?*JobWindow) void {
    var buf: [4096]u8 = undefined;
    var zbuf: [4097]u8 = undefined;
    var dir: ?[:0]const u8 = null;
    if (from) |w| {
        const d = w.folder(&buf);
        if (d.len > 0) if (std.fmt.bufPrintZ(&zbuf, "{s}", .{d}) catch null) |z| {
            if (isDir(z)) dir = z;
        };
    }
    if (dir == null) if (c.getenv("HOME")) |h| {
        dir = std.mem.span(h);
    };
    var gbuf: [64]u8 = undefined;
    const geo: ?[:0]const u8 = if (app.cascade()) |g| std.fmt.bufPrintZ(&gbuf, "{d},{d},{d},{d}", .{ g[0], g[1], g[2], g[3] }) catch null else null;
    if (c.getenv("GTTY_SHOW_DRY") != null) return app.sayFmt("would open a new gtty in {s} at {s}", .{ dir orelse ".", geo orelse "-" }, app.theme.dim);
    const pid = c.gtty_open_new_instance(if (dir) |d| d.ptr else null, if (geo) |g| g.ptr else null);
    if (pid <= 0) {
        beep.beep();
        return app.say("could not start a new gtty", app.theme.stderr_accent);
    }
    // Let it come to the front (`tickFront`).
    app.yield_pid = pid;
    app.yield_until = c.SDL_GetTicks() + 5000;
}

/// Each frame, after New Window: this gtty yields the front to the new one
/// once the system knows its process (macOS 14+); the new one asks to be
/// the active app and raises its window until it is (at most 3 s, so it
/// doesn't take the front back from something the user clicked).
fn tickFront(app: *App) void {
    const now = c.SDL_GetTicks();
    if (app.yield_pid > 0) {
        if (now > app.yield_until or c.gtty_app_yield_to(app.yield_pid)) app.yield_pid = 0;
    }
    if (app.front_until != 0) {
        if (now > app.front_until) {
            app.front_until = 0;
        } else if (c.gtty_app_activate()) {
            _ = c.SDL_RaiseWindow(app.window);
            app.front_until = 0;
        } else _ = c.SDL_RaiseWindow(app.window);
    }
}

/// Where a new gtty's window goes (x, y, w, h; window coordinates): this
/// window's size, moved down and right by about a title bar, as macOS
/// cascades new windows; one that would leave the display's usable area
/// starts again at its top-left corner. Null: unknown (Wayland doesn't
/// tell, nor lets a window be placed).
fn cascade(app: *App) ?[4]c_int {
    const step = 28;
    var x: c_int = 0;
    var y: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.SDL_GetWindowPosition(app.window, &x, &y) or !c.SDL_GetWindowSize(app.window, &w, &h)) return null;
    var g = [4]c_int{ x + step, y + step, w, h };
    var r: c.SDL_Rect = undefined;
    const display = c.SDL_GetDisplayForWindow(app.window);
    if (display != 0 and c.SDL_GetDisplayUsableBounds(display, &r)) {
        if (g[0] + w > r.x + r.w) g[0] = r.x;
        if (g[1] + h > r.y + r.h) g[1] = r.y + step; // under the title bar
        g[2] = @min(w, r.w);
        g[3] = @min(h, r.h);
    }
    return g;
}

/// GTTY_WINDOW "x,y,w,h" (see `cascade`), removed from the environment.
fn windowGeometry() ?[4]c_int {
    const v = c.getenv("GTTY_WINDOW") orelse return null;
    defer _ = c.unsetenv("GTTY_WINDOW");
    var g: [4]c_int = undefined;
    var it = std.mem.splitScalar(u8, std.mem.span(v), ',');
    for (&g) |*n| n.* = std.fmt.parseInt(c_int, it.next() orelse return null, 10) catch return null;
    if (g[2] < 200 or g[3] < 150) return null;
    return g;
}

fn openShell(app: *App, program: ?[]const u8) void {
    app.openShellIn(program, null);
}

/// A shell window starting in `cwd` (null: gtty's folder).
fn openShellIn(app: *App, program: ?[]const u8, cwd: ?[:0]const u8) void {
    app.shell_opens[app.shell_opens_at] = c.SDL_GetTicks();
    app.shell_opens_at = (app.shell_opens_at + 1) % shell_burst_max;
    const prog = program orelse userShell();
    const name = std.fs.path.basename(prog);
    const login = program == null;
    var argv_buf: [2][]const u8 = .{ prog, "-l" };
    var spec: JobWindow.Spec = .{ .kind = .shell, .title = name, .argv = if (login) &argv_buf else argv_buf[0..1], .cwd = cwd };
    // zsh / bash: with the hooks that mark each command's output (copy).
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    if (app.tmp) |d| if (app.hooks) {
        if (shell_hooks.launch(arena.allocator(), prog, login, d.path) catch null) |l| {
            spec.argv = l.argv;
            spec.env = l.env;
        }
    };
    app.openJob(spec);
}

/// An alias or function (or another name only the user's shell knows).
fn shellKnows(app: *App, cmd: []const u8) bool {
    const word = oscmd.commandWord(cmd) orelse return false;
    return app.shell_names.has(word);
}

/// Run a command line through the user's shell. Programs and the common
/// builtins start fast (`$SHELL -c`); a name only the user's config defines
/// (alias, function) needs that config loaded (`$SHELL -i -c`).
fn runCommand(app: *App, cmd: []const u8) void {
    const word = oscmd.commandWord(cmd) orelse "";
    const needs_config = !oscmd.isProgram(word) and !oscmd.isShellWord(word) and app.shell_names.has(word);
    const fast = [_][]const u8{ userShell(), "-c", cmd };
    const with_config = [_][]const u8{ userShell(), "-i", "-c", cmd };
    const argv: []const []const u8 = if (needs_config) &with_config else &fast;
    app.openJob(.{ .kind = .command, .title = cmd, .argv = argv });
}

/// Close from the user (× or `close`): a running shell window ends like
/// After a window was closed: no shell window running any more (one being
/// ended doesn't count) → open a new one, as `s` would.
/// Something keeps ending the shells (more than `shell_burst_max` opened
/// within `shell_burst_ms`): no new one opens by itself until the user
/// opens one.
/// `quit_on_last_shell`: gtty quits instead, once no other job is running
/// either (until then `want_shell` stays set; a shell opened meanwhile
/// cancels it).
fn ensureShell(app: *App) void {
    if (!app.want_shell) return;
    for (app.jobs.items) |w| if (w.kind == .shell and w.running() and !w.ending()) {
        app.want_shell = false;
        return;
    };
    if (app.quit_on_last_shell) {
        for (app.jobs.items) |w| if (w.running() and !w.ending()) return;
        app.running = false;
        return;
    }
    app.want_shell = false;
    if (!app.auto_shell) return;
    // The oldest of the last `shell_burst_max` opens (the ring's next slot).
    const oldest = app.shell_opens[app.shell_opens_at];
    if (oldest != 0 and c.SDL_GetTicks() -| oldest < shell_burst_ms) {
        app.auto_shell = false;
        beep.beep();
        return app.say("shells keep exiting: no new shell opened (type s to open one)", app.theme.stderr_accent);
    }
    app.openShell(null);
}

/// Close a window (× on a finished window or a shell waiting at its
/// prompt, `close`, a shell that exited by itself): it goes away, its job
/// hung up if it still runs (decided 2026-10-06: closing never sends a
/// window to the job grid, only minimize does). No shell window left
/// running: a new one (`ensureShell`).
fn closeWindow(app: *App, i: usize) void {
    app.want_shell = true;
    app.closeJob(i);
}

/// The red × of a window: a job still working (a command, or a shell
/// running one) opens the kill menu (only its skull kills); a shell
/// waiting at its prompt, or a finished job, closes.
fn closeOrKillMenu(app: *App, i: usize) void {
    const w = app.jobs.items[i];
    if (w.running() and !w.atPrompt()) {
        w.kill_menu = !w.kill_menu;
        app.dirty = true;
        return;
    }
    app.closeWindow(i);
}

fn closeJob(app: *App, index: usize) void {
    const w = app.jobs.items[index];
    if (app.extraIndex(w)) |k| _ = app.extras.orderedRemove(k);
    // The current window went away: the next selected one takes its place.
    const promoted: ?*JobWindow = if (app.main == index and app.extras.items.len > 0) app.extras.orderedRemove(0) else null;
    if (app.hover_src == w.uid) app.sendLeave();
    _ = app.jobs.orderedRemove(index);
    w.destroy(&app.reaper);
    const shift = struct {
        fn f(v: ?usize, removed: usize) ?usize {
            const x = v orelse return null;
            return if (x == removed) null else if (x > removed) x - 1 else x;
        }
    }.f;
    // Closing the focused job hands the keyboard to the prompt; if the
    // current job went away, the newest running job takes the windows area.
    app.focus = shift(app.focus, index);
    app.main = shift(app.main, index) orelse if (promoted) |p| app.indexOfWindow(p) else app.newestRunning(null);
    if (promoted != null) app.restamp();
    app.relayoutAnimated();
}

/// Minimize a window in the windows area: it goes to the job grid. For
/// the current window, the next selected one takes its place, or else the
/// newest running job. (Minimize on a job already in the grid: no-op.)
fn minimizeJob(app: *App, i: usize) void {
    const w = app.jobs.items[i];
    if (app.extraIndex(w)) |k| {
        _ = app.extras.orderedRemove(k);
        app.unshow(w);
        app.restamp();
        return app.relayoutAnimated();
    }
    if (app.main != i) return;
    w.maximized = false;
    w.focused = false;
    if (app.focus == i) app.focus = null;
    if (app.extras.items.len > 0) {
        app.main = app.indexOfWindow(app.extras.orderedRemove(0));
        app.restamp();
    } else app.main = app.newestRunning(i);
    app.relayoutAnimated();
}

/// Maximize toggle (also F11): the job window covers the entire gtty screen.
fn toggleMaximize(app: *App, i: usize) void {
    app.setFocus(i);
    const w = app.jobs.items[i];
    w.maximized = !w.maximized;
    w.touch();
    app.relayoutAnimated();
}

/// Job window by its serial number (#N).
fn indexOf(app: *App, serial: u32) ?usize {
    for (app.jobs.items, 0..) |w, i| if (w.serial == serial) return i;
    return null;
}

fn focused(app: *App) ?*JobWindow {
    const i = app.focus orelse return null;
    return app.jobs.items[i];
}

/// Give job `i` the keyboard. A window in the job grid takes the current
/// window's place (that one moves to the grid; other selected windows
/// stay). A window already in the windows area stays where it is.
fn setFocus(app: *App, i: usize) void {
    // Sync typing: the other windows are read-only, the keyboard stays
    // where it is; one from the job grid still comes in (and is read-only).
    if (app.syncSource()) |src| if (app.jobs.items[i] != src) {
        if (!app.isShown(i)) return app.bringIn(i);
        return app.sayFmt("#{d} is read-only: it gets #{d}'s typing (sync typing)", .{ app.jobs.items[i].serial, src.serial }, app.theme.dim);
    };
    for (app.jobs.items, 0..) |w, j| w.focused = (i == j);
    app.focus = i;
    app.dirty = true;
    if (app.isShown(i)) {
        // Gaining focus is an action; with several windows shown their
        // order stays as it was set (see restamp).
        if (app.extras.items.len == 0) app.jobs.items[i].touch();
        return;
    }
    app.bringIn(i);
}

/// Job `i` from the job grid (or new) into the windows area.
fn bringIn(app: *App, i: usize) void {
    // A window coming into the windows area (a new one, or one from the
    // job grid) joins what is shown there (decided 2026-10-06): it becomes
    // the current window (top-left) and the one that was current stays,
    // as a selected window next to it. Not all fit: the selected windows
    // last in order (finished first, then the oldest) go to the job grid
    // until they do.
    app.jobs.items[i].touch();
    if (app.main) |m| {
        app.jobs.items[m].maximized = false;
        app.extras.insert(app.gpa, 0, app.jobs.items[m]) catch {};
    }
    app.main = i;
    if (app.extras.items.len > 0) app.restamp();
    while (app.extras.items.len > 0 and app.extras.items.len + 1 > app.capacityWith(app.gridCount())) {
        app.unshow(app.extras.pop().?);
    }
    app.relayoutAnimated();
}

fn clearFocus(app: *App) void {
    for (app.jobs.items) |w| w.focused = false;
    app.focus = null;
    app.dirty = true;
}

fn cycleFocus(app: *App, delta: isize) void {
    // Sync typing: only the source window and the prompt take the keyboard.
    if (app.syncSource()) |src| {
        if (app.focused() == src) return app.clearFocus();
        if (app.indexOfWindow(src)) |i| app.setFocus(i);
        return;
    }
    // Cycle through the running jobs (those in the windows area first, in
    // their order), then the prompt.
    var buf: [65]usize = undefined;
    var n: usize = 0;
    if (app.main) |m| if (app.jobs.items[m].running()) {
        buf[n] = m;
        n += 1;
    };
    for (app.extras.items) |e| if (e.running()) if (app.indexOfWindow(e)) |i| {
        buf[n] = i;
        n += 1;
    };
    for (app.jobs.items, 0..) |w, i| if (w.running() and !app.isShown(i)) {
        buf[n] = i;
        n += 1;
    };
    if (n == 0) return app.clearFocus();
    var cur: usize = n; // the prompt
    for (buf[0..n], 0..) |j, k| if (app.focus == j) {
        cur = k;
    };
    const next: usize = @intCast(@mod(@as(isize, @intCast(cur)) + delta, @as(isize, @intCast(n + 1))));
    if (next == n) app.clearFocus() else app.setFocus(buf[next]);
}

fn zoomFocused(app: *App, z: commands.Zoom) void {
    const w = app.focused() orelse {
        app.say("no window to zoom", app.theme.dim);
        return;
    };
    app.zoomJob(w, z);
}

/// Text size of one job window (100% at the least).
fn zoomJob(app: *App, w: *JobWindow, z: commands.Zoom) void {
    const next: f32 = switch (z) {
        .in => w.zoom * 1.15,
        .out => w.zoom / 1.15,
        .reset => 1.0,
        .set => |v| v,
    };
    w.setZoom(&app.gfx, next);
    app.sayFmt("#{d} zoom {d:.0}%  ({d}×{d})", .{ w.serial, w.zoom * 100, w.cols, w.rows }, app.theme.dim);
    app.dirty = true;
}

/// Show or hide a window's colors (`on` null: toggle). Only the drawing
/// changes, so it applies to all of the output, old and new.
fn colorsJob(app: *App, w: *JobWindow, on: ?bool) void {
    w.colors = on orelse !w.colors;
    app.sayFmt("#{d} colors {s}", .{ w.serial, if (w.colors) "on" else "off" }, app.theme.dim);
    app.dirty = true;
}

/// The title bar's copy: a running shell's last command output, else
/// everything (JobWindow.copyText).
fn copyJob(app: *App, w: *JobWindow) void {
    const text = w.copyText(app.gpa) catch return;
    defer app.gpa.free(text);
    if (text.len == 0) return app.sayFmt("#{d}: nothing to copy (no output)", .{w.serial}, app.theme.dim);
    app.toClipboard(w, text);
    // Show what was taken: a flash over those rows, then "Copied".
    if (w.grid_r == null) {
        w.flashCopied();
        app.dirty = true;
    }
}

/// ⌘C (Ctrl+Shift+C on Linux): the text selected in the focused job
/// window, or else in any window in the windows area.
fn copySelection(app: *App) void {
    // No text selected: the file the mouse has, or the selected files.
    if (app.fileCopyKey()) return;
    const first = app.activeShown() orelse return;
    var w = app.jobs.items[first];
    if (w.selectedText(app.gpa)) |t| app.gpa.free(t) else for (app.extras.items) |e| if (e.out.sel != null) {
        w = e;
        break;
    };
    if (app.main) |m| if (w.out.sel == null) {
        w = app.jobs.items[m];
    };
    const text = w.selectedText(app.gpa) orelse return app.say("nothing selected", app.theme.dim);
    defer app.gpa.free(text);
    app.toClipboard(w, text);
}

/// A copy from a job window (selection, title-bar copy, menu Copy): it
/// goes on the clipboard and on top of the paste history.
fn toClipboard(app: *App, w: *JobWindow, text: []const u8) void {
    const z = app.gpa.dupeZ(u8, text) catch return;
    defer app.gpa.free(z);
    if (text.len > 0) app.pushPasteHistory(text);
    _ = c.SDL_SetClipboardText(z.ptr);
    const lines = std.mem.count(u8, text, "\n") + @intFromBool(text.len > 0);
    app.sayFmt("#{d}: copied {d} line{s}", .{ w.serial, lines, if (lines == 1) "" else "s" }, app.theme.ok);
}

/// Paste shortcut (⌘V, Ctrl+Shift+V, Shift+Insert): into the expanded
/// peek's filter box, the focused running job, or else the prompt.
fn pasteKey(app: *App) void {
    // Files copied last (gtty's file clipboard), the mouse on a window:
    // paste them there.
    if (app.filePasteKey()) return;
    if (app.peek) |*pk| if (pk.wantsKeys()) {
        if (c.SDL_GetClipboardText()) |t| {
            defer c.SDL_free(t);
            app.onText(std.mem.span(t));
        }
        return;
    };
    // Files copied last, the mouse elsewhere: into the current window's
    // folder.
    if (app.file_clip.items.len > 0) {
        if (!app.pasteFilesInto(app.currentJob())) {
            beep.beep();
            app.say("point at a window to paste the files", app.theme.stderr_accent);
        }
        return;
    }
    app.pasteInto(app.focusedJob());
}

/// The clipboard got new text (gtty's copy or another app's): it is now
/// what was copied last, so files waiting on gtty's file clipboard go.
fn clipboardChanged(app: *App) void {
    if (app.file_clip.items.len == 0) return;
    for (app.file_clip.items) |p| app.gpa.free(p);
    app.file_clip.clearRetainingCapacity();
    app.dirty = true;
}

/// The clipboard into running job `job` (as a terminal paste, see
/// JobWindow.paste), or into the prompt when null (line ends dropped).
fn pasteInto(app: *App, job: ?*JobWindow) void {
    const raw = if (c.SDL_GetClipboardText()) |t| t else return;
    defer c.SDL_free(raw);
    app.pasteText(job, std.mem.span(raw));
}

/// Every paste ends here: the clipboard (keys, menus) or a paste history
/// entry.
fn pasteText(app: *App, job: ?*JobWindow, text: []const u8) void {
    if (text.len == 0) return app.say("clipboard is empty", app.theme.dim);
    if (job) |w| if (w.sync == .follower) return app.readOnly(w);
    if (job) |w| w.paste(app.gpa, text) else app.prompt.insertUtf8(text);
    app.dirty = true;
}

const paste_history_max = 5;
const paste_label_max = 20;
const folder_label_max = 48;

/// `text` on top of the paste history (moved up if already there; the
/// oldest goes past `paste_history_max`).
fn pushPasteHistory(app: *App, text: []const u8) void {
    for (app.paste_history.items, 0..) |t, i| if (std.mem.eql(u8, t, text)) {
        app.gpa.free(app.paste_history.orderedRemove(i));
        break;
    };
    const copy = app.gpa.dupe(u8, text) catch return;
    app.paste_history.insert(app.gpa, 0, copy) catch return app.gpa.free(copy);
    if (app.paste_history.items.len > paste_history_max) app.gpa.free(app.paste_history.pop().?);
}

fn jobByUid(app: *App, uid: ids_mod.Id) ?*JobWindow {
    for (app.jobs.items) |w| if (w.uid == uid) return w;
    return null;
}

// ------------------------------------------------------------ sync typing

/// The window whose typing sync typing copies, while it is on.
fn syncSource(app: *App) ?*JobWindow {
    const uid = app.sync_src orelse return null;
    return app.jobByUid(uid);
}

/// Sync typing can start from `w`: running, in the windows area.
fn canSync(app: *App, w: ?*JobWindow) bool {
    const j = w orelse return false;
    const i = app.indexOfWindow(j) orelse return false;
    return j.running() and !j.ending() and app.isShown(i);
}

/// Sync typing on, from window `from` (it gets the keyboard), or off.
fn toggleSync(app: *App, from: ?*JobWindow) void {
    if (app.sync_src != null) return app.syncOff("sync typing off");
    const w = from orelse return app.say("sync typing: no window", app.theme.dim);
    if (!app.canSync(w)) {
        beep.beep();
        return app.sayFmt("#{d}: sync typing needs a running window in the windows area", .{w.serial}, app.theme.stderr_accent);
    }
    app.setFocus(app.indexOfWindow(w).?);
    app.sync_src = w.uid;
    app.updateSync();
    var n: usize = 0;
    for (app.jobs.items) |j| n += @intFromBool(j.sync == .follower);
    app.sayFmt("sync typing on: #{d} types into {d} other window{s}", .{ w.serial, n, if (n == 1) "" else "s" }, app.theme.ok);
}

fn syncOff(app: *App, why: []const u8) void {
    app.sync_src = null;
    for (app.jobs.items) |w| w.sync = .off;
    app.say(why, app.theme.dim);
    app.dirty = true;
}

/// Something was to be typed into a read-only window: not done.
fn readOnly(app: *App, w: *JobWindow) void {
    beep.beep();
    const src = app.syncSource() orelse return;
    app.sayFmt("#{d} is read-only: it gets only #{d}'s typing (sync typing)", .{ w.serial, src.serial }, app.theme.stderr_accent);
}

/// Once a frame: which windows sync typing covers now. The source, while
/// it runs in the windows area; read-only: every other running window
/// there (one coming in joins, one minimized leaves). The source gone,
/// ended or minimized: sync typing is off.
fn updateSync(app: *App) void {
    var refused: ?*JobWindow = null;
    for (app.jobs.items) |w| if (w.sync_refused) {
        w.sync_refused = false;
        refused = w;
    };
    if (app.sync_src == null) return;
    const src = app.syncSource() orelse return app.syncOff("sync typing off: its window closed");
    const si = app.indexOfWindow(src).?;
    if (!src.running() or src.ending()) return app.syncOff("sync typing off: its window's job ended");
    if (!app.isShown(si)) return app.syncOff("sync typing off: its window left the windows area");
    for (app.jobs.items, 0..) |w, i| {
        const s: JobWindow.Sync = if (w == src) .source else if (app.isShown(i) and w.running() and !w.ending()) .follower else .off;
        if (w.sync != s) {
            w.sync = s;
            app.dirty = true;
        }
    }
    // A read-only window never keeps the keyboard.
    if (app.focused()) |f| if (f.sync == .follower) app.setFocus(si);
    if (refused) |w| app.readOnly(w);
}

/// JobWindow.sync_hook: what the source window got typed, into each
/// read-only window.
fn syncMirror(ctx: *anyopaque, src: *JobWindow, bytes: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    for (app.jobs.items, 0..) |w, i| {
        if (w != src and w.sync == .follower and app.isShown(i) and w.running()) w.syncBytes(bytes);
    }
}

// ------------------------------------------------------------ context menu

/// Right click: open the menu (Copy / Paste) on a job window's text or
/// footer in the windows area (the window gets the focus, its selection
/// stays), or on the prompt. False when the click is somewhere else.
fn openMenu(app: *App, x: f32, y: f32) bool {
    var target: Menu.Target = .prompt;
    var copy_ok = false;
    var paste_ok = true;
    var folders: ?bool = null;
    var output: ?[]const u8 = null;
    var job: ?*JobWindow = null;
    if (app.maximizedShown() == null and app.prompt.rect.contains(x, y)) {
        target = .prompt;
    } else {
        const i = app.windowAt(x, y) orelse return false;
        if (!app.isShown(i)) return false;
        const w = app.jobs.items[i];
        switch (w.hit(x, y)) {
            .out, .footer => {},
            else => return false,
        }
        if (w.running() and w.sync != .follower) app.setFocus(i);
        target = .{ .job = w.uid };
        copy_ok = w.out.sel != null;
        paste_ok = w.running() and w.sync != .follower; // read-only: sync typing
        folders = w.folders_left.items.len > 0;
        output = if (w.copiesLast()) "Copy last output" else "Copy all output";
        job = w;
    }
    const history_ok = paste_ok and app.paste_history.items.len > 0;
    // Paste: files copied last go into the window's folder (the prompt:
    // the current window's); text into the job / the prompt.
    if (app.file_clip.items.len > 0) {
        var dbuf: [4096]u8 = undefined;
        paste_ok = pasteFolder(job orelse app.currentJob(), &dbuf) != null;
    } else paste_ok = paste_ok and c.SDL_HasClipboardText();
    app.popMenu(Menu.edit(target, .{ x, y }, copy_ok, output, paste_ok, history_ok, folders));
    return true;
}

/// Where files pasted into window `w` go: the folder its program is in
/// (in `buf`); null for none, a remote session or no folder.
fn pasteFolder(w: ?*JobWindow, buf: []u8) ?[]const u8 {
    const win = w orelse return null;
    var rbuf: [4096]u8 = undefined;
    if (win.remoteNow(&rbuf) != null) return null;
    const d = win.folder(buf);
    return if (d.len > 0) d else null;
}

/// Paste (menu row or key) with files on gtty's file clipboard: into
/// `w`'s folder (asks). False: no place for them there.
fn pasteFilesInto(app: *App, w: ?*JobWindow) bool {
    var dbuf: [4096]u8 = undefined;
    const d = pasteFolder(w, &dbuf) orelse return false;
    app.askPaste(d, w.?);
    return true;
}

/// Open menu `m` (closing any other), laid out on screen.
fn popMenu(app: *App, m: Menu) void {
    app.closeMenu();
    app.hideTip();
    app.menu = m;
    const f, _ = app.promptFaces();
    app.menu.?.layout(f, app.scale.ui, .{ .x = 0, .y = 0, .w = app.width_px, .h = app.height_px });
    _ = app.menu.?.motion(m.at[0], m.at[1]);
    app.dirty = true;
}

fn closeMenu(app: *App) void {
    const m = app.menu orelse return;
    app.menu = null;
    app.sub_menu = null;
    app.freePicker(); // the picker's, or the file menu's Open With ▸
    if (m.purpose == .files) app.freeMenuFiles();
    app.dirty = true;
}

/// A ▸ in the right-click menu: open (or close) its submenu next to that
/// row: Paste ▸ the paste history, History ▸ the window's folders.
fn toggleSubMenu(app: *App, row: usize) void {
    const m = app.menu orelse return;
    app.dirty = true;
    const was_open = app.sub_menu != null and app.sub_row == row;
    app.sub_menu = null;
    if (was_open or !m.rows[row].sub_on) return;
    const f, _ = app.promptFaces();
    const bounds: Rect = .{ .x = 0, .y = 0, .w = app.width_px, .h = app.height_px };
    if (m.purpose == .files) {
        // "Open with <default>" ▸: the other apps, Other….
        var sub: Menu = .{ .purpose = .open_with, .at = .{ 0, 0 } };
        app.addPickerRows(&sub, true);
        app.sub_row = row;
        sub.layoutBeside(f, app.scale.ui, bounds, &m, row);
        app.sub_menu = sub;
        return;
    }
    const target = switch (m.purpose) {
        .edit => |t| t,
        else => return,
    };
    var sub: Menu = .{ .purpose = .{ .paste_history = target }, .at = .{ m.r.x + m.r.w, m.row_r[row].y } };
    if (m.codes[row] == Menu.edit_folders) {
        const w = switch (target) {
            .job => |uid| app.jobByUid(uid) orelse return,
            .prompt => return,
        };
        // A cd needs the shell waiting at its prompt.
        const ok = w.atPrompt() and w.sync != .follower;
        sub.purpose = .{ .folder_history = w.uid };
        sub.title = if (w.sync == .follower) "cd to (read-only: sync typing)" else if (ok) "cd to" else "cd to (the shell is busy)";
        const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "";
        for (w.folders_left.items, 0..) |d, i| sub.add(.{ .label = Menu.shortPath(&app.sub_labels[i], d, home, folder_label_max), .enabled = ok });
    } else {
        for (app.paste_history.items, 0..) |t, i| sub.add(.{ .label = Menu.oneLine(&app.sub_labels[i], t, paste_label_max) });
    }
    app.sub_row = row;
    sub.layoutBeside(f, app.scale.ui, bounds, &m, row);
    app.sub_menu = sub;
}

/// The mouse moved in the menu: a row that only opens a submenu (Open
/// With… ▸), or a file menu row's ▸ box, opens it; moving onto another
/// row closes such a submenu.
fn hoverSubMenu(app: *App) void {
    const m = app.menu orelse return;
    const i = m.over orelse return;
    const open_here = app.sub_menu != null and app.sub_row == i;
    const files = m.purpose == .files;
    if (m.rows[i].hover_sub or (files and m.over_arrow)) {
        if (!open_here) app.toggleSubMenu(i);
    } else if (app.sub_menu != null and app.sub_row != i and app.sub_row < m.n and (files or m.rows[app.sub_row].hover_sub)) {
        app.sub_menu = null;
        app.dirty = true;
    }
}

/// A left click inside the open menu: act on an enabled row and close;
/// a disabled one does nothing (the menu stays). Paste's ▸ box opens the
/// paste history.
fn menuClick(app: *App, x: f32, y: f32) void {
    const m = app.menu orelse return;
    if (m.arrowAt(x, y)) |row| {
        // The file menu's ▸ opened on hover: a click keeps it.
        if (m.purpose == .files and app.sub_menu != null and app.sub_row == row) return;
        return app.toggleSubMenu(row);
    }
    const row = m.rowAt(x, y) orelse return;
    if (!m.isEnabled(row)) return;
    // A row that only opens a submenu: open it (a click doesn't close it).
    if (m.rows[row].hover_sub) {
        if (!(app.sub_menu != null and app.sub_row == row)) app.toggleSubMenu(row);
        return;
    }
    switch (m.purpose) {
        .bar => {
            const code = m.codes[row];
            app.closeMenu();
            app.menuPick(code);
        },
        .open_with => app.openWithPick(m.codes[row]),
        .edit => |target| {
            app.closeMenu();
            const job: ?*JobWindow = switch (target) {
                .prompt => null,
                .job => |uid| app.jobByUid(uid) orelse return,
            };
            switch (m.codes[row]) {
                Menu.edit_copy => if (job) |w| {
                    const text = w.selectedText(app.gpa) orelse return app.say("nothing selected", app.theme.dim);
                    defer app.gpa.free(text);
                    app.toClipboard(w, text);
                },
                // What was copied last: files into the window's folder
                // (the prompt: the current window's), else the text.
                Menu.edit_paste => if (app.file_clip.items.len > 0) {
                    if (!app.pasteFilesInto(job orelse app.currentJob())) app.say("nowhere to paste the files here", app.theme.dim);
                } else if (job) |w| {
                    if (w.running()) app.pasteInto(w);
                } else app.pasteInto(null),
                // The title-bar copy: the last command's output (or all), with
                // its flash.
                Menu.edit_output => if (job) |w| app.copyJob(w),
                // A new shell in the folder of the window clicked (the
                // prompt: of the current window).
                Menu.edit_new_shell => app.newShell(job orelse app.currentJob()),
                Menu.edit_folders => {
                    // The row itself opens its submenu too (it does nothing else).
                    app.menu = m;
                    app.toggleSubMenu(row);
                },
                else => {},
            }
        },
        .files => |uid| {
            // Keep the files and Paste's folder while the menu goes.
            const files = app.menu_files;
            const dest = app.menu_dest;
            app.menu_files = null;
            app.menu_dest = null;
            app.closeMenu();
            app.menu_files = files;
            app.menu_dest = dest;
            app.fileMenuPick(uid, m.codes[row]);
            app.freeMenuFiles();
        },
        .paste_history, .folder_history => {}, // the submenus have their own click (subMenuClick)
    }
}

/// A click on a paste history row: paste that value into the menu's
/// target.
fn subMenuClick(app: *App, x: f32, y: f32) void {
    const sm = app.sub_menu orelse return;
    const row = sm.rowAt(x, y) orelse return;
    if (!sm.isEnabled(row)) return;
    const target = switch (sm.purpose) {
        .paste_history => |t| t,
        .open_with => return app.openWithPick(sm.codes[row]),
        .folder_history => |uid| {
            const w = app.jobByUid(uid) orelse return app.closeMenu();
            app.closeMenu();
            if (row < w.folders_left.items.len and w.atPrompt()) {
                const dir = app.gpa.dupe(u8, w.folders_left.items[row]) catch return;
                defer app.gpa.free(dir);
                w.cdTo(dir);
            }
            return;
        },
        else => return,
    };
    if (row >= app.paste_history.items.len) return;
    const text = app.gpa.dupe(u8, app.paste_history.items[row]) catch return;
    defer app.gpa.free(text);
    app.closeMenu();
    switch (target) {
        .prompt => app.pasteText(null, text),
        .job => |uid| if (app.jobByUid(uid)) |w| if (w.running()) app.pasteText(w, text),
    }
}

// ------------------------------------------------------------ gtty menu & settings

/// A pick from the gtty menu (system menu bar, drawn bar, or `/menu`).
fn menuPick(app: *App, code: i32) void {
    switch (code) {
        // Run command: the keyboard to the prompt, ready to type.
        c.GTTY_MENU_RUN => {
            app.closeMenu();
            app.closePeek();
            _ = c.SDL_RaiseWindow(app.window);
            app.clearFocus();
            app.dirty = true;
        },
        c.GTTY_MENU_SETTINGS => app.openSettings(),
        // A new shell in the current window's folder.
        c.GTTY_MENU_NEW_SHELL => app.newShell(app.currentJob()),
        c.GTTY_MENU_NEW_WINDOW => app.newWindow(app.currentJob()),
        c.GTTY_MENU_SYNC_TYPING => app.toggleSync(app.currentJob()),
        c.GTTY_MENU_ABOUT => {
            app.closeMenu();
            app.about_visible = true;
            app.dirty = true;
        },
        else => {},
    }
}

/// For the system menu (it asks when it opens, or when a row's key is
/// pressed): is the row usable now? A disabled row's key goes on to gtty
/// as a plain key.
var menu_app: ?*App = null;

fn menuEnabled(code: c_int) callconv(.c) bool {
    const app = menu_app orelse return true;
    return app.menuRowEnabled(code);
}

fn menuChecked(code: c_int) callconv(.c) bool {
    const app = menu_app orelse return false;
    return code == c.GTTY_MENU_SYNC_TYPING and app.sync_src != null;
}

fn menuRowEnabled(app: *App, code: c_int) bool {
    return switch (code) {
        c.GTTY_MENU_SYNC_TYPING => app.sync_src != null or app.canSync(app.currentJob()),
        else => true,
    };
}

/// A key press the native menu bar also gets (and acts on): ⌘N / ⌘T
/// alone, while that row is enabled.
fn menuOwnsKey(app: *App, key: c.SDL_Keycode, mod: c.SDL_Keymod) bool {
    if (builtin.os.tag != .macos or !app.native_menu) return false;
    if (mod & c.SDL_KMOD_GUI == 0 or mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT) != 0) return false;
    const code = switch (key) {
        c.SDLK_N => c.GTTY_MENU_NEW_WINDOW,
        c.SDLK_T => c.GTTY_MENU_NEW_SHELL,
        else => return false,
    };
    return app.menuRowEnabled(code);
}

/// A copy or paste shortcut: ⌘C / ⌘V, Ctrl+Shift+C / V, Shift+Insert.
fn clipboardKey(key: c.SDL_Keycode, mod: c.SDL_Keymod) bool {
    const cmd = mod & c.SDL_KMOD_GUI != 0;
    const ctrl_shift = mod & c.SDL_KMOD_CTRL != 0 and mod & c.SDL_KMOD_SHIFT != 0;
    return switch (key) {
        c.SDLK_C, c.SDLK_V => cmd or ctrl_shift,
        c.SDLK_INSERT => mod & c.SDL_KMOD_SHIFT != 0,
        else => false,
    };
}

/// The settings window, when it has the keyboard.
fn settingsFocused(app: *App) ?*SettingsWindow {
    const sw = app.settings orelse return null;
    return if (c.SDL_GetKeyboardFocus() == sw.window) sw else null;
}

/// Some window in the windows area has selected text.
fn hasSelection(app: *App) bool {
    for (app.jobs.items, 0..) |w, i| if (app.isShown(i) and w.out.sel != null) return true;
    return false;
}

/// ⌘A (Ctrl+Shift+A on Linux): all the text of the window you're typing into (or
/// the current one).
fn selectAll(app: *App) void {
    const w = app.focused() orelse if (app.main) |m| app.jobs.items[m] else return;
    const n = w.out.lines.items.len;
    if (n == 0) return;
    w.key_sel = false;
    w.out.sel = .{ .anchor = .{ .row = 0, .col = 0 }, .head = .{ .row = n - 1, .col = w.out.cols } };
    app.dirty = true;
}

/// The rows of a drawn-bar menu and what each does.
fn barRows(app: *App, which: Menu.Bar, rows: *[Menu.max_rows]Menu.Row, codes: *[Menu.max_rows]i32) usize {
    var n: usize = 0;
    const Add = struct {
        fn f(r: *[Menu.max_rows]Menu.Row, cs: *[Menu.max_rows]i32, k: *usize, row: Menu.Row, code: i32) void {
            if (k.* == Menu.max_rows) return;
            r[k.*] = row;
            cs[k.*] = code;
            k.* += 1;
        }
    }.f;
    switch (which) {
        .gtty => {
            Add(rows, codes, &n, .{ .label = "About gtty" }, c.GTTY_MENU_ABOUT);
            Add(rows, codes, &n, .{ .label = "Settings…" }, c.GTTY_MENU_SETTINGS);
            Add(rows, codes, &n, .{ .label = "New Window", .key = Menu.new_window_key }, c.GTTY_MENU_NEW_WINDOW);
            Add(rows, codes, &n, .{ .label = "New Shell", .key = Menu.new_shell_key }, c.GTTY_MENU_NEW_SHELL);
            Add(rows, codes, &n, .{ .label = "Run command" }, c.GTTY_MENU_RUN);
            Add(rows, codes, &n, .{ .label = "Sync typing", .key = if (app.sync_src != null) "✓" else "", .enabled = app.menuRowEnabled(c.GTTY_MENU_SYNC_TYPING) }, c.GTTY_MENU_SYNC_TYPING);
        },
    }
    return n;
}

/// A drawn menu bar button: its menu under it.
fn openBarMenu(app: *App, which: Menu.Bar) void {
    var rows: [Menu.max_rows]Menu.Row = undefined;
    var codes: [Menu.max_rows]i32 = undefined;
    const n = app.barRows(which, &rows, &codes);
    const b = app.menubar_btns[@intFromEnum(which)];
    app.popMenu(Menu.bar(which, .{ b.x, b.y + b.h }, rows[0..n], codes[0..n]));
}

fn barButtonAt(app: *App, x: f32, y: f32) ?usize {
    for (app.menubar_btns, 0..) |b, i| if (b.contains(x, y)) return i;
    return null;
}

fn drawMenuBar(app: *App) void {
    const r = app.menubar_r;
    if (r.h == 0) return;
    const t = &app.theme;
    const sf = app.statusFace();
    app.gfx.fill(r, t.title_bg);
    const open: ?usize = if (app.menu) |m| switch (m.purpose) {
        .bar => |which| @intFromEnum(which),
        else => null,
    } else null;
    for (app.menubar_btns, Menu.bar_titles, 0..) |b, title, i| {
        if (open == i or app.over_menubar_btn == i) app.gfx.fill(b, t.focus.mix(t.title_bg, 0.55));
        _ = app.gfx.text(sf, b.x + @round((b.w - Gfx.textWidth(sf, title)) / 2), b.y + @round((b.h - sf.cell_h) / 2), title, t.title_fg);
    }
}

/// Open the settings window (or bring it to the front).
fn openSettings(app: *App) void {
    app.closeMenu();
    if (app.settings) |sw| return sw.raise();
    app.settings = SettingsWindow.open(app.gpa, &app.cfg) catch |e| {
        beep.beep();
        return app.sayFmt("settings: could not open the window ({s})", .{@errorName(e)}, app.theme.stderr_accent);
    };
}

/// Each frame: apply what the settings window changed, draw it, close it
/// when asked.
fn tickSettings(app: *App) void {
    const sw = app.settings orelse return;
    if (sw.want_close) {
        sw.close();
        app.settings = null;
        if (app.script_target == .settings) app.script_target = .main;
        _ = c.SDL_RaiseWindow(app.window);
        return;
    }
    const changes = sw.takeChanges();
    for (changes) |ch| app.applyChange(ch);
    if (changes.len > 0) {
        app.saveConfig();
        sw.save_failed = app.save_config and !app.saved_ok;
        sw.dirty = true;
    }
    sw.render(&app.theme);
    if (sw.shot_ok) |ok| {
        sw.shot_ok = null;
        if (ok) app.say("saved the settings window's picture", app.theme.ok) else app.say("screenshot failed", app.theme.stderr_accent);
    }
}

/// One setting changed in the settings window: take it into use now.
fn applyChange(app: *App, ch: SettingsWindow.Change) void {
    switch (ch) {
        .num => |i| switch (Config.nums[i].field) {
            .font_pt => {
                app.font_pt = app.cfg.font_pt;
                app.updateScale();
            },
            .scrollback => app.scrollback = app.cfg.scrollback, // new windows
            .anim_ms => JobWindow.anim_len_ms = app.cfg.anim_ms,
            .tip_ms => app.tip_delay_ms = app.cfg.tip_ms,
            .chip_hover_ms => app.chip_hover_ms = app.cfg.chip_hover_ms,
            .peek_close_ms => Peek.dismiss_ms = app.cfg.peek_close_ms,
            .kill_grace_ms => JobWindow.hard_kill_ms = app.cfg.kill_grace_ms,
            .mark_width => app.setMarks(app.cfg.marks, app.cfg.mark_width),
        },
        .marks => app.setMarks(app.cfg.marks, app.cfg.mark_width),
        .file_opener => app.setFileOpener(app.cfg.file_opener),
        .color_folders => app.setColorFolders(app.cfg.color_folders),
        .refresh_ls => JobWindow.refresh_ls = app.cfg.refresh_ls,
        .quit_on_last_shell => app.quit_on_last_shell = app.cfg.quit_on_last_shell,
        .command => {}, // at the next start
        .ai => {}, // read at each request
        .ai_forget => {
            app.memory.clear();
            if (app.memory_file) app.memory.save();
            app.say("AI memory: forgotten", app.theme.dim);
        },
        .colors_default => {}, // new windows
        .color, .colors_reset => app.applyColors(),
    }
    app.dirty = true;
}

/// The theme's text, background, 16 colors and mark colors from the
/// settings.
fn applyColors(app: *App) void {
    app.theme.fg = app.cfg.fg;
    app.theme.bg = app.cfg.bg;
    app.theme.palette = app.cfg.palette;
    app.theme.mark_input = app.cfg.mark_input;
    app.theme.mark_ai = app.cfg.mark_ai;
    app.dirty = true;
}

/// The left-edge marks on / off and their width: every window's text
/// moves, so all are laid out again.
fn setMarks(app: *App, on: bool, width: u64) void {
    JobWindow.marks_on = on;
    JobWindow.mark_pt = @floatFromInt(width);
    for (app.jobs.items) |w| w.relayout(&app.gfx) catch {};
    app.relayout();
    app.dirty = true;
}

/// GTTY_MARKS=0 (off), GTTY_MARK_WIDTH (points), GTTY_MARK_INPUT /
/// _AI (#rrggbb): win over the settings for this run.
fn marksFromEnv(app: *App) void {
    if (c.getenv("GTTY_MARKS")) |v| {
        const s = std.mem.span(v);
        JobWindow.marks_on = !(std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "off"));
    }
    if (c.getenv("GTTY_MARK_WIDTH")) |v| {
        const n = std.fmt.parseFloat(f32, std.mem.span(v)) catch JobWindow.mark_pt;
        JobWindow.mark_pt = std.math.clamp(n, 1, 8);
    }
    const env = [_]struct { [*:0]const u8, *Rgb }{
        .{ "GTTY_MARK_INPUT", &app.theme.mark_input },
        .{ "GTTY_MARK_AI", &app.theme.mark_ai },
    };
    for (env) |e| if (c.getenv(e[0])) |v| if (Config.parseRgb(std.mem.span(v))) |rgb| {
        e[1].* = rgb;
    };
}

fn saveConfig(app: *App) void {
    if (!app.save_config) return;
    app.saved_ok = app.cfg.save();
    if (!app.saved_ok) app.say("could not save the settings", app.theme.stderr_accent);
}

// ------------------------------------------------------------ folder

/// A job window's folder button: the folder its program is in now, in the
/// system's file manager (macOS Finder; Linux the desktop's, via
/// xdg-open). Not in a remote session (the files are on the other
/// machine). `GTTY_SHOW_DRY=1`: only says which folder.
fn openFolder(app: *App, w: *JobWindow) void {
    var rbuf: [4096]u8 = undefined;
    if (w.remoteNow(&rbuf) != null) {
        beep.beep();
        return app.sayFmt("#{d}: folders on the remote machine can't be opened here yet", .{w.serial}, app.theme.dim);
    }
    var buf: [4096]u8 = undefined;
    const dir = w.folder(&buf);
    if (dir.len == 0) {
        beep.beep();
        return app.sayFmt("#{d}: its folder is not known", .{w.serial}, app.theme.stderr_accent);
    }
    var zbuf: [4097]u8 = undefined;
    const dz = std.fmt.bufPrintZ(&zbuf, "{s}", .{dir}) catch return;
    const manager = if (builtin.os.tag == .macos) "Finder" else "the file manager";
    if (c.getenv("GTTY_SHOW_DRY") != null) return app.sayFmt("would open {s} in {s}", .{ dz, manager }, app.theme.dim);
    if (c.gtty_open_with(dz.ptr, null) != 0) {
        beep.beep();
        return app.sayFmt("could not open {s} in {s}", .{ std.fs.path.basename(dz), manager }, app.theme.stderr_accent);
    }
    app.sayFmt("opened {s} in {s}", .{ std.fs.path.basename(dz), manager }, app.theme.dim);
}

// ------------------------------------------------------------ show

/// `show <file>`: open the file with its default app, or let the user pick
/// the app (`-a`, or when the file has no default app: the app picker,
/// else the system's app chooser). No job window.
/// A relative path is taken from gtty's folder; `~` is the home folder.
fn showFile(app: *App, path_in: []const u8, pick: bool) void {
    var buf: [4096]u8 = undefined;
    const path = expandHome(&buf, path_in) orelse return app.say("show: path too long", app.theme.stderr_accent);
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) {
        beep.beep();
        return app.sayFmt("show: no such file: {s}", .{path_in}, app.theme.stderr_accent);
    }
    if (!pick) {
        var name: [256]u8 = undefined;
        switch (c.gtty_open_default_app(path.ptr, &name, name.len)) {
            0 => {}, // no default app: the picker
            1 => return app.openWithName(path, null, std.mem.sliceTo(&name, 0)),
            else => return app.openWithName(path, null, "its default app"),
        }
    }
    app.openPicker(path);
}

/// "~/x" → "$HOME/x", NUL-terminated in `buf`.
fn expandHome(buf: []u8, path: []const u8) ?[:0]const u8 {
    if (path.len > 0 and path[0] == '~' and (path.len == 1 or path[1] == '/')) {
        const home = std.mem.span(c.getenv("HOME") orelse return null);
        return std.fmt.bufPrintZ(buf, "{s}{s}", .{ home, path[1..] }) catch null;
    }
    return std.fmt.bufPrintZ(buf, "{s}", .{path}) catch null;
}

/// The app picker for `path`: a menu over the prompt listing the apps
/// that can open it (the default one first, marked), then Other…; no app
/// known: the system's app chooser at once.
fn openPicker(app: *App, path: [:0]const u8) void {
    const base = std.fs.path.basename(path);
    app.closeMenu();
    if (!app.loadPicker(path)) {
        app.freePicker();
        return app.chooseApp(path);
    }
    var m: Menu = .{ .purpose = .open_with, .at = .{ app.prompt.rect.x, app.prompt.rect.y } };
    m.title = std.fmt.bufPrint(&app.picker_title, "Open {s} with", .{base}) catch "Open with";
    app.addPickerRows(&m, false);
    app.popMenu(m);
    // Its bottom on the prompt's top (the size is known once laid out).
    if (app.menu) |*pm| {
        const f, _ = app.promptFaces();
        pm.at[1] = @max(app.prompt.rect.y - pm.r.h, 0);
        pm.layout(f, app.scale.ui, .{ .x = 0, .y = 0, .w = app.width_px, .h = app.height_px });
    }
}

/// Fill `picker_path` / `picker_apps` / `picker_icons` with the apps
/// that can open `path` (the default one first; room left for the
/// separators and Other…). False: no app known (`picker_path` is set
/// all the same, for Other…).
fn loadPicker(app: *App, path: [:0]const u8) bool {
    app.freePicker();
    app.picker_path = app.gpa.dupeZ(u8, path) catch return false;
    var apps: [Menu.max_rows - 3]c.gtty_app = undefined;
    const n: usize = @intCast(@max(c.gtty_open_apps(path.ptr, &apps, apps.len), 0));
    if (n == 0) return false;
    app.picker_apps = app.gpa.dupe(c.gtty_app, apps[0..n]) catch return false;
    app.picker_icons = app.gpa.alloc(?*c.SDL_Texture, n) catch {
        app.freePicker();
        return false;
    };
    @memset(app.picker_icons, null);
    const f, _ = app.promptFaces();
    const px = Menu.iconPx(f);
    const rgba = app.gpa.alloc(u8, px * px * 4) catch return true;
    defer app.gpa.free(rgba);
    for (app.picker_apps, app.picker_icons) |*a, *icon| {
        if (c.gtty_app_icon(@ptrCast(&a.id), @intCast(px), rgba.ptr) == 1) icon.* = app.gfx.imageRgba(rgba, px);
    }
    return true;
}

/// The default app of the loaded picker, if the file has one.
fn pickerDefault(app: *App) ?usize {
    return if (app.picker_apps.len > 0 and app.picker_apps[0].is_default != 0) 0 else null;
}

/// The picker's rows (row code k = `picker_apps[k]`), then a line and
/// Other…. With the default app: it first and a line after it, or left
/// out (`skip_default`: the file menu's "Open with <it>" row is it).
fn addPickerRows(app: *App, m: *Menu, skip_default: bool) void {
    for (app.picker_apps, app.picker_icons, 0..) |*a, icon, k| {
        const def = a.is_default != 0;
        if (def and skip_default) continue;
        m.addCode(.{ .label = std.mem.sliceTo(&a.name, 0), .key = if (def) "default" else "", .icon = icon }, @intCast(k));
        if (def and k + 1 < app.picker_apps.len) m.add(Menu.separator);
    }
    if (m.n > 0) m.add(Menu.separator);
    m.addCode(.{ .label = "Other…" }, Menu.open_with_other);
}

/// A row of the app picker (or of Open With ▸) was picked: open the file
/// with that app, or ask the system (Other…). Closes the menu.
fn openWithPick(app: *App, code: i32) void {
    // The picker's data is freed with the menu: act first.
    if (app.picker_path) |path| {
        if (code == Menu.open_with_other) {
            app.chooseApp(path);
        } else if (code >= 0 and code < app.picker_apps.len) {
            app.openWith(path, &app.picker_apps[@intCast(code)]);
        }
    }
    app.closeMenu();
}

/// The system's choose-an-app dialog for `path` (macOS: a sheet on
/// gtty's window as Finder's Other…; Linux: the desktop portal's app
/// chooser). The answer arrives in `tickChooser`. `GTTY_SHOW_DRY=1` only
/// says it.
fn chooseApp(app: *App, path: [:0]const u8) void {
    const base = std.fs.path.basename(path);
    if (c.getenv("GTTY_SHOW_DRY") != null)
        return app.sayFmt("show: would ask which app opens {s}", .{base}, app.theme.dim);
    var why: [256]u8 = undefined;
    if (c.gtty_choose_app(app.window, path.ptr, &why, why.len) == 0) {
        beep.beep();
        return app.sayFmt("{s}", .{std.mem.sliceTo(&why, 0)}, app.theme.stderr_accent);
    }
    const n = @min(base.len, app.chooser_file.len);
    @memcpy(app.chooser_file[0..n], base[0..n]);
    app.chooser_file_len = n;
    app.sayFmt("choose the app that opens {s}", .{base}, app.theme.dim);
}

/// The app chooser's answer, once it has one.
fn tickChooser(app: *App) void {
    var text: [512]u8 = undefined;
    const r = c.gtty_choose_app_take(&text, text.len);
    if (r == 0) return;
    const base = app.chooser_file[0..app.chooser_file_len];
    const t = std.mem.sliceTo(&text, 0);
    switch (r) {
        1 => app.sayFmt("opened {s} with {s}", .{ base, t }, app.theme.dim),
        2 => app.say("nothing opened", app.theme.dim),
        3 => {}, // the system opens it
        else => {
            beep.beep();
            app.sayFmt("could not open {s}: {s}", .{ base, t }, app.theme.stderr_accent);
        },
    }
}

fn freePicker(app: *App) void {
    if (app.picker_path) |p| app.gpa.free(p);
    app.picker_path = null;
    app.gpa.free(app.picker_apps);
    app.picker_apps = &.{};
    for (app.picker_icons) |icon| if (icon) |t| c.SDL_DestroyTexture(t);
    app.gpa.free(app.picker_icons);
    app.picker_icons = &.{};
}

/// A row of the app picker was picked.
fn openWith(app: *App, path: [:0]const u8, a: *const c.gtty_app) void {
    app.openWithName(path, @ptrCast(&a.id), std.mem.sliceTo(&a.name, 0));
}

/// Open `path` with app `id` (null: the default app) and say so.
/// `GTTY_SHOW_DRY=1` only says it (for test scripts).
fn openWithName(app: *App, path: [:0]const u8, id: ?[*:0]const u8, name: []const u8) void {
    const base = std.fs.path.basename(path);
    if (c.getenv("GTTY_SHOW_DRY") != null)
        return app.sayFmt("show: would open {s} with {s}", .{ base, name }, app.theme.dim);
    if (c.gtty_open_with(path.ptr, id) != 0) {
        beep.beep();
        return app.sayFmt("show: could not open {s} with {s}", .{ base, name }, app.theme.stderr_accent);
    }
    app.sayFmt("opened {s} with {s}", .{ base, name }, app.theme.dim);
}

// ------------------------------------------------------------ chips & peeks

/// The window the open peek belongs to, while its chip is on screen
/// (in the windows area, not under a maximized window).
fn peekWindow(app: *App) ?*JobWindow {
    const pk = if (app.peek) |*p| p else return null;
    for (app.jobs.items, 0..) |w, i| if (w.uid == pk.uid) {
        if (!app.isShown(i) or peekChip(w, pk.kind).w <= 0) return null;
        if (app.maximizedShown()) |m| if (m != i) return null;
        return w;
    };
    return null;
}

/// The chip a peek of `kind` grows from.
fn peekChip(w: *const JobWindow, kind: Peek.Kind) Gfx.Rect {
    return switch (kind) {
        .git => w.git_chip_r,
        .folder => w.folder_chip_r,
    };
}

/// Open the peek of window `i`'s folder chip (hover or click; closing any
/// other peek): the full path; its expand button grows it into the list.
fn openFolderPeek(app: *App, i: usize) void {
    const w = app.jobs.items[i];
    if (w.cwd().len == 0) return;
    if (app.peek) |pk| if (pk.uid == w.uid and pk.kind == .folder) return;
    app.closePeek();
    app.hideTip();
    app.chip_hover = null;
    app.peek = Peek.openFolder(app.gpa, w.uid, w.cwd(), w.folder_chip_r) catch return;
    w.folder_peek_open = true;
    app.layoutPeek();
    app.dirty = true;
}

/// Open the peek of window `i`'s git chip (closing any other peek).
fn openGitPeek(app: *App, i: usize) void {
    const w = app.jobs.items[i];
    const b = w.branch() orelse return;
    // The branch of a remote folder: switching would run git here, in the
    // wrong folder.
    if (w.remoteDest().len > 0) return app.sayFmt("{s} on {s} (switching branches there: not yet)", .{ b, w.remoteDest() }, app.theme.dim);
    if (app.peek) |pk| if (pk.uid == w.uid and pk.kind == .git) return;
    app.closePeek();
    app.hideTip();
    app.chip_hover = null;
    app.peek = Peek.open(app.gpa, w.uid, w.cwd(), b, w.git_chip_r) catch return;
    w.git_peek_open = true;
    app.layoutPeek();
    app.dirty = true;
}

fn closePeek(app: *App) void {
    var pk = app.peek orelse return;
    for (app.jobs.items) |w| if (w.uid == pk.uid) {
        w.git_peek_open = false;
        w.folder_peek_open = false;
    };
    pk.deinit(&app.reaper);
    app.peek = null;
    app.dirty = true;
}

/// The peek in the normal text size, over its chip, kept on screen.
fn layoutPeek(app: *App) void {
    const pk = if (app.peek) |*p| p else return;
    const f, _ = app.promptFaces();
    pk.layout(f, app.statusFace(), app.scale.ui, .{ .x = 0, .y = 0, .w = app.width_px, .h = app.height_px });
}

/// Act on what the peek returned for a click or a key.
fn peekAction(app: *App, a: Peek.Action) void {
    const pk = if (app.peek) |*p| p else return;
    switch (a) {
        .none, .redraw => {},
        .close => return app.closePeek(),
        .copy => {
            const z = app.gpa.dupeZ(u8, pk.full) catch return;
            defer app.gpa.free(z);
            _ = c.SDL_SetClipboardText(z.ptr);
            app.sayFmt("copied {s}", .{pk.full}, app.theme.ok);
        },
        // A folder picked in the folder chip's peek: cd there, if the
        // shell waits at its prompt.
        .cd => if (app.jobByUid(pk.uid)) |w| {
            if (w.atPrompt()) {
                w.cdTo(pk.target);
                pk.cdDone(true, "");
            } else {
                pk.cdDone(false, "the shell is busy: cd only at its prompt");
                beep.beep();
            }
        },
    }
    app.layoutPeek();
    app.dirty = true;
}

/// Once a frame: open a peek the mouse rested on, follow its chip (the
/// window may move or its branch change), run its timers and git runs.
fn tickPeek(app: *App) void {
    const now = c.SDL_GetTicks();
    if (app.chip_hover) |h| if (now -| h.since >= app.chip_hover_ms) {
        app.chip_hover = null;
        for (app.jobs.items, 0..) |w, i| if (w.uid == h.uid) {
            if (h.hit == .folder_chip) app.openFolderPeek(i) else app.openGitPeek(i);
        };
    };
    if (app.peek == null) return;
    const w = app.peekWindow() orelse return app.closePeek();
    const pk = &app.peek.?;
    if (!std.meta.eql(pk.anchor, peekChip(w, pk.kind))) {
        pk.anchor = peekChip(w, pk.kind);
        app.dirty = true;
    }
    switch (pk.kind) {
        // Out of the repo: the chip is disabled, its peek goes.
        .git => if (pk.state != .busy) if (w.branch()) |b| pk.setFull(b) else return app.closePeek(),
        // The shell went elsewhere (not by this peek): its list is stale.
        .folder => if (pk.state == .idle and !std.mem.eql(u8, w.cwd(), pk.full)) return app.closePeek(),
    }
    switch (pk.tick(now, &app.reaper)) {
        .none => {},
        .redraw => app.dirty = true,
        .close => app.closePeek(),
        .switched => {
            // Show the new branch on the chip at once.
            w.refreshChipsSoon();
            pk.setFull(pk.target);
            app.sayFmt("#{d}: switched to {s}", .{ w.serial, pk.target }, app.theme.ok);
        },
        .failed => {
            beep.beep();
            app.sayFmt("#{d}: git: {s}", .{ w.serial, pk.errorLine() }, app.theme.stderr_accent);
        },
    }
}

// ------------------------------------------------------------ AI

/// The AI settings in use: the settings file's, with GTTY_AI_PROVIDER /
/// _MODEL / _ENDPOINT / _KEY winning for this run.
fn aiSetup(app: *App) Ai.Setup {
    var s = Ai.Setup.of(&app.cfg);
    if (c.getenv("GTTY_AI_PROVIDER")) |v| if (Config.AiProvider.parse(std.mem.span(v))) |p| {
        s.provider = p;
        if (app.cfg.ai_model.len == 0) s.model = Ai.defaultModel(p);
        if (app.cfg.ai_endpoint.len == 0) s.endpoint = Ai.defaultEndpoint(p);
    };
    if (c.getenv("GTTY_AI_MODEL")) |v| s.model = std.mem.span(v);
    if (c.getenv("GTTY_AI_ENDPOINT")) |v| s.endpoint = std.mem.trimEnd(u8, std.mem.span(v), "/");
    if (c.getenv("GTTY_AI_KEY")) |v| s.key = std.mem.span(v);
    return s;
}

/// The AI is set up: lines typed at the prompt go to it (gtty's own
/// commands and `!line` excepted). `GTTY_AI_REPLY=<file>` (tests): the
/// file's text is the answer, nothing is sent.
fn aiReady(app: *App) bool {
    return c.getenv("GTTY_AI_REPLY") != null or app.aiSetup().ready();
}

fn aiBusy(app: *App) bool {
    return app.ai_req != null or app.ai_plan != null;
}

/// A line typed at the prompt with the AI on: gtty's own commands (exact,
/// see `commands.parseExact`), `/name` and `!line` (as without the AI) run
/// at once; anything else is a request.
fn askAi(app: *App, line: []const u8) void {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0 or t[0] == '/') return app.exec(t);
    if (t[0] == '!') return app.exec(std.mem.trim(u8, t[1..], " \t"));
    if (commands.parseExact(t)) |cmd| exact: {
        if (cmd == .show) {
            var buf: [4096]u8 = undefined;
            const p = expandHome(&buf, cmd.show.path) orelse break :exact;
            if (c.access(p.ptr, c.F_OK) != 0) break :exact;
        }
        return app.execGtty(cmd);
    }
    if (app.aiBusy()) {
        beep.beep();
        app.prompt.insertUtf8(line);
        return app.say("the AI is still on the last request — Esc cancels it", app.theme.stderr_accent);
    }
    // `-x` (show the script before it runs) is gtty's, not the AI's.
    app.ai_show = false;
    app.ai_text.clearRetainingCapacity();
    var words = std.mem.tokenizeAny(u8, t, " \t");
    while (words.next()) |wd| {
        if (std.mem.eql(u8, wd, "-x")) {
            app.ai_show = true;
            continue;
        }
        if (app.ai_text.items.len > 0) app.ai_text.append(app.gpa, ' ') catch return;
        app.ai_text.appendSlice(app.gpa, wd) catch return;
    }
    const request = app.ai_text.items;
    const target = app.aiTarget();
    app.ai_cur = if (target) |w| w.uid else null;
    app.ai_new = null;

    if (c.getenv("GTTY_AI_REPLY")) |path| {
        const text = readSmallFile(app.gpa, std.mem.span(path)) orelse return app.say("GTTY_AI_REPLY: can't read the file", app.theme.stderr_accent);
        defer app.gpa.free(text);
        return app.aiResult(Ai.parsePlan(app.gpa, text));
    }
    const dir = if (app.tmp) |d| d.path else return app.say("AI: no temp folder", app.theme.stderr_accent);
    const system = app.aiSystemPrompt(target) catch return app.say("AI: out of memory", app.theme.stderr_accent);
    defer app.gpa.free(system);
    app.ai_req = Ai.Request.start(app.gpa, app.aiSetup(), dir, system, request, c.SDL_GetTicks()) catch |e| {
        beep.beep();
        return app.sayFmt("AI: could not start curl ({s})", .{@errorName(e)}, app.theme.stderr_accent);
    };
}

/// The shell the AI's `"current"` means: the window in front if it is a
/// shell at its prompt, else another shown one, else the most recently
/// used one at its prompt; null: a new shell will be opened.
fn aiTarget(app: *App) ?*JobWindow {
    // Not a read-only window (sync typing).
    if (app.main) |m| if (app.jobs.items[m].atPrompt() and app.jobs.items[m].sync != .follower) return app.jobs.items[m];
    for (app.extras.items) |w| if (w.atPrompt() and w.sync != .follower) return w;
    var best: ?*JobWindow = null;
    for (app.jobs.items) |w| if (w.atPrompt() and w.sync != .follower) {
        if (best == null or w.last_activity_ms > best.?.last_activity_ms) best = w;
    };
    return best;
}

/// The system prompt with this session's facts.
fn aiSystemPrompt(app: *App, target: ?*JobWindow) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "";
    var cwd_buf: [4096]u8 = undefined;
    const gtty_cwd: []const u8 = if (c.getcwd(&cwd_buf, cwd_buf.len)) |p| std.mem.span(@as([*:0]u8, @ptrCast(p))) else home;

    var target_s: []const u8 = "new (no shell is waiting at its prompt; gtty opens one)";
    var shell: []const u8 = std.fs.path.basename(userShell());
    var cwd: []const u8 = gtty_cwd;
    if (target) |w| {
        target_s = try std.fmt.allocPrint(a, "#{d} {s}", .{ w.serial, w.title });
        shell = std.fs.path.basename(w.title);
        if (w.cwd().len > 0) cwd = w.cwd();
    }

    var wins: std.Io.Writer.Allocating = .init(a);
    if (app.jobs.items.len == 0) try wins.writer.writeAll("(none)\n");
    for (app.jobs.items) |w| {
        var sb: [48]u8 = undefined;
        const folder = if (w.remoteDest().len > 0) w.remoteDest() else w.cwd();
        try wins.writer.print("- #{d} {s} — {s}{s}{s}\n", .{ w.serial, w.title, w.statusText(&sb), if (folder.len > 0) " — " else "", folder });
    }

    var mem: std.Io.Writer.Allocating = .init(a);
    var hosts: std.Io.Writer.Allocating = .init(a);
    if (app.cfg.ai_memory) {
        try app.memory.describe(&mem.writer, home, 40);
        var pbuf: [4096]u8 = undefined;
        const ssh_conf = std.fmt.bufPrint(&pbuf, "{s}/.ssh/config", .{home}) catch "";
        const conf = readSmallFile(a, ssh_conf) orelse "";
        try app.memory.describeHosts(&hosts.writer, conf);
    } else {
        try mem.writer.writeAll("(memory is off)\n");
        try hosts.writer.writeAll("(memory is off)\n");
    }
    return Ai.fillPrompt(app.gpa, .{
        .os = Ai.osName(),
        .shell = shell,
        .home = home,
        .target = target_s,
        .cwd = cwd,
        .windows = wins.written(),
        .memory = mem.written(),
        .ssh_hosts = hosts.written(),
    });
}

/// A small text file (≤ 256 KB) read whole; null if missing.
fn readSmallFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var buf: [4096]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return null;
    const fp = c.fopen(p.ptr, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (out.items.len < 256 * 1024) {
        const n = c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        out.appendSlice(gpa, chunk[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// Esc at the prompt while the AI works: drop the request (or what is
/// left of the plan).
fn cancelAi(app: *App) void {
    if (app.ai_req) |r| r.destroy();
    app.ai_req = null;
    app.endPlan();
    app.say("AI: cancelled", app.theme.dim);
}

fn endPlan(app: *App) void {
    if (app.ai_plan) |*p| p.deinit();
    app.ai_plan = null;
    app.ai_step = 0;
}

/// Each frame: the request's answer, the plan's next steps, the memory.
fn tickAi(app: *App) void {
    const now = c.SDL_GetTicks();
    if (app.ai_req) |r| {
        if (r.poll(now)) {
            const res = r.result();
            r.destroy();
            app.ai_req = null;
            app.aiResult(res);
        } else if (now / 400 != (now -| 8) / 400) app.dirty = true; // the "thinking" dots
    }
    if (app.ai_plan != null) app.stepPlan(now);
    // The y/N script is done: the keyboard back to the prompt.
    if (app.ai_return) |uid| for (app.jobs.items, 0..) |w, i| if (w.uid == uid) {
        if (w.out.ai == .off and w.atPrompt()) {
            app.ai_return = null;
            if (app.focus == i) app.clearFocus();
        }
        break;
    } else {
        app.ai_return = null;
    };
    app.tickMemory(now);
}

fn aiResult(app: *App, res: Ai.Result) void {
    app.dirty = true;
    switch (res) {
        .err => |e| {
            beep.beep();
            // The request back in the prompt, to try again or fix.
            if (app.prompt.isEmpty()) app.prompt.insertUtf8(app.ai_text.items);
            app.say(e, app.theme.stderr_accent);
        },
        .plan => |p| {
            app.endPlan();
            app.ai_plan = p;
            app.ai_step = 0;
            app.ai_step_ms = c.SDL_GetTicks();
            app.ai_danger = p.danger;
            if (p.summary.len > 0) app.sayFmt("✦ {s}", .{p.summary}, app.theme.mark_ai);
        },
    }
}

/// How long a shell step waits for its window to reach its prompt.
const ai_wait_ms = 20_000;

/// Carry out the plan's steps in order; a step for a shell that isn't at
/// its prompt yet (just opened, or busy) waits for it.
fn stepPlan(app: *App, now: u64) void {
    while (app.ai_plan) |*p| {
        if (app.ai_step >= p.actions.len) return app.endPlan();
        switch (p.actions[app.ai_step]) {
            .message => |m| app.sayFmt("✦ {s}", .{m}, app.theme.prompt_fg),
            .remember => |t| if (app.cfg.ai_memory) app.memory.addNote(t),
            .gt => |g| app.aiGt(g.cmd, g.args),
            .shell, .cd => {
                const target = switch (p.actions[app.ai_step]) {
                    .shell => |sh| sh.target,
                    .cd => |cd| cd.target,
                    else => unreachable,
                };
                const w = switch (app.aiWindow(target)) {
                    .wait => return app.aiWaitTimeout(now, "the shell did not start"),
                    .gone => |msg| {
                        app.say(msg, app.theme.stderr_accent);
                        return app.endPlan();
                    },
                    .ok => |w| w,
                };
                // The plan's last step there still runs (its line was
                // typed, or its command hasn't ended): wait, however long.
                if (w.out.ai != .off) {
                    app.ai_step_ms = now;
                    return;
                }
                if (!w.atPrompt()) return app.aiWaitTimeout(now, "the shell is busy");
                switch (p.actions[app.ai_step]) {
                    .shell => |sh| app.aiRunScript(w, sh.script, p.summary),
                    .cd => |cd| {
                        w.cdOnly(cd.dir);
                        w.out.ai = .armed; // an AI line too (purple), waited for
                    },
                    else => unreachable,
                }
            },
        }
        app.ai_step += 1;
        app.ai_step_ms = now;
        app.dirty = true;
    }
}

fn aiWaitTimeout(app: *App, now: u64, why: []const u8) void {
    if (now -| app.ai_step_ms < ai_wait_ms) return;
    beep.beep();
    app.sayFmt("AI: {s} — the rest of the plan was not run", .{why}, app.theme.stderr_accent);
    app.endPlan();
}

const AiWin = union(enum) { ok: *JobWindow, wait, gone: []const u8 };

/// The window a step's `target` names; `"current"` / `"new"` open a shell
/// when there is none yet (the step waits for it).
fn aiWindow(app: *App, target: []const u8) AiWin {
    if (target.len > 0 and (target[0] == '#' or std.ascii.isDigit(target[0]))) {
        const n = std.fmt.parseInt(u32, std.mem.trimStart(u8, target, "#"), 10) catch return .{ .gone = "AI: bad window number" };
        const i = app.indexOf(n) orelse return .{ .gone = "AI: that window is gone" };
        const w = app.jobs.items[i];
        return if (w.running()) .{ .ok = w } else .{ .gone = "AI: that window has finished" };
    }
    const slot = if (std.mem.eql(u8, target, "new")) &app.ai_new else &app.ai_cur;
    if (slot.*) |uid| for (app.jobs.items) |w| if (w.uid == uid) {
        if (w.running()) return .{ .ok = w };
        break;
    };
    // None (or it ended): a new shell, then wait for its prompt.
    if (!app.aiOpenShell(null)) return .{ .gone = "AI: could not open a shell" };
    slot.* = app.ai_new;
    return .wait;
}

/// A shell for the AI: in front, but the keyboard stays at the prompt.
fn aiOpenShell(app: *App, cwd: ?[:0]const u8) bool {
    const n = app.jobs.items.len;
    app.openShellIn(null, cwd);
    if (app.jobs.items.len == n) return false;
    app.ai_new = app.jobs.items[n].uid;
    app.clearFocus();
    return true;
}

/// A gtty command from the plan.
fn aiGt(app: *App, cmd: []const u8, args: []const []const u8) void {
    const eq = std.mem.eql;
    if (eq(u8, cmd, "sh") or eq(u8, cmd, "s") or eq(u8, cmd, "shell")) {
        var cwd: ?[]const u8 = null;
        if (args.len >= 2 and eq(u8, args[0], "--cwd")) cwd = args[1];
        const dir = cwd orelse {
            _ = app.aiOpenShell(null);
            return;
        };
        var buf: [4096]u8 = undefined;
        var rel: [4096]u8 = undefined;
        // Relative to the target shell's folder.
        const abs = if (dir.len > 0 and dir[0] != '/' and dir[0] != '~') blk: {
            const base = if (app.ai_cur) |uid| (for (app.jobs.items) |w| (if (w.uid == uid) break w.cwd()) else "") else "";
            break :blk if (base.len > 0) std.fmt.bufPrint(&rel, "{s}/{s}", .{ base, dir }) catch dir else dir;
        } else dir;
        const full = expandHome(&buf, abs) orelse return;
        if (!isDir(full)) return app.sayFmt("AI: no folder {s}", .{dir}, app.theme.stderr_accent);
        _ = app.aiOpenShell(full);
        return;
    }
    if (!(eq(u8, cmd, "close") or eq(u8, cmd, "focus") or eq(u8, cmd, "show") or eq(u8, cmd, "list")))
        return app.sayFmt("AI: gtty has no command {s}", .{cmd}, app.theme.stderr_accent);
    var line: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line);
    w.writeAll(cmd) catch return;
    for (args) |a| {
        w.writeByte(' ') catch return;
        w.writeAll(a) catch return;
    }
    if (commands.parseExact(w.buffered())) |g| app.execGtty(g) else app.sayFmt("AI: bad gtty command: {s}", .{w.buffered()}, app.theme.stderr_accent);
}

/// Programs that want the keyboard: the window gets it after the script
/// starts.
fn wantsKeyboard(script: []const u8) bool {
    const progs = [_][]const u8{ "ssh", "mosh", "vim", "vi", "nvim", "nano", "emacs", "top", "htop", "btop", "less", "more", "man", "python", "python3", "node", "irb", "sqlite3", "psql", "mysql", "tmux", "screen" };
    const first = std.mem.trim(u8, script, " \t\r\n");
    var it = std.mem.tokenizeAny(u8, first, " \t\r\n;|&");
    const word = std.fs.path.basename(it.next() orelse return false);
    for (progs) |p| if (std.mem.eql(u8, word, p)) return true;
    return false;
}

/// Write the script to `ai-<n>.sh` in gtty's temp folder and have the
/// shell run it (`gtty-ai <n> '<request>'`). Dangerous ones (and `-x`)
/// print the script first; dangerous ones then ask `Run it? [y/N]` and
/// the window gets the keyboard for the answer.
fn aiRunScript(app: *App, w: *JobWindow, script: []const u8, summary: []const u8) void {
    const dir = if (app.tmp) |d| d.path else return;
    app.ai_seq += 1;
    const n = app.ai_seq;
    var pbuf: [4096]u8 = undefined;
    var bbuf: [4096]u8 = undefined;
    const main_path = std.fmt.bufPrintSentinel(&pbuf, "{s}/ai-{d}.sh", .{ dir, n }, 0) catch return;
    const body_path = std.fmt.bufPrintSentinel(&bbuf, "{s}/ai-{d}-body.sh", .{ dir, n }, 0) catch return;
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    const o = &out.writer;
    // The model said the plan is dangerous, or gtty's own check says
    // this script is.
    const ask = app.ai_danger or Ai.looksDangerous(script);
    o.print("# gtty AI: {s}\n", .{oneLineOf(summary)}) catch return;
    if (ask or app.ai_show) {
        const nl: []const u8 = if (std.mem.endsWith(u8, script, "\n")) "" else "\n";
        writeFileZ2(body_path, script, nl) catch return app.say("AI: could not write the script", app.theme.stderr_accent);
        o.writeAll("printf '\\033[35m── gtty AI: %s ──\\033[0m\\n' ") catch return;
        shellQuote(o, oneLineOf(summary)) catch return;
        o.writeAll("\ncat -- ") catch return;
        shellQuote(o, body_path) catch return;
        o.writeAll("\nprintf '\\033[35m──\\033[0m\\n'\n") catch return;
        if (ask) o.writeAll(
            \\printf 'This can change or delete files, or send data out. Run it? [y/N] '
            \\read -r __gtty_ok
            \\case "$__gtty_ok" in [yY]|[yY][eE][sS]) ;; *) echo 'not run'; exit 1 ;; esac
            \\
        ) catch return;
        o.writeAll(". ") catch return;
        shellQuote(o, body_path) catch return;
        o.writeAll("\n") catch return;
    } else {
        o.writeAll(script) catch return;
        o.writeAll("\n") catch return;
    }
    writeFileZ(main_path, out.written()) catch return app.say("AI: could not write the script", app.theme.stderr_accent);
    w.runAi(n, app.ai_text.items);
    // In front; the keyboard goes to it when the script asks or runs an
    // interactive program, else it stays at the prompt.
    if (app.indexOfWindow(w)) |i| {
        app.setFocus(i);
        if (!(ask or wantsKeyboard(script))) app.clearFocus();
        app.ai_return = if (ask and !wantsKeyboard(script)) w.uid else null;
    }
}

fn oneLineOf(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfAny(u8, s, "\r\n") orelse s.len];
}

/// `'…'` for sh (a ' inside becomes '\'').
fn shellQuote(o: *std.Io.Writer, s: []const u8) !void {
    try o.writeByte('\'');
    for (s) |ch| if (ch == '\'') try o.writeAll("'\\''") else try o.writeByte(ch);
    try o.writeByte('\'');
}

fn writeFileZ(p: [:0]const u8, data: []const u8) !void {
    return writeFileZ2(p, data, "");
}

/// `data` then `tail`, only the user can read it.
fn writeFileZ2(p: [:0]const u8, data: []const u8, tail: []const u8) !void {
    const fp = c.fopen(p.ptr, "w") orelse return error.Write;
    _ = c.chmod(p.ptr, 0o600);
    const ok = c.fwrite(data.ptr, 1, data.len, fp) == data.len and c.fwrite(tail.ptr, 1, tail.len, fp) == tail.len;
    if (c.fclose(fp) != 0 or !ok) return error.Write;
}

fn isDir(p: [:0]const u8) bool {
    var st: c.struct_stat = undefined;
    return c.stat(p.ptr, &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFDIR;
}

/// The memory notes each folder a shell moves to and each ssh / mosh
/// destination (with the setting on), and is saved now and then.
fn tickMemory(app: *App, now: u64) void {
    if (!app.cfg.ai_memory) return;
    for (app.jobs.items) |w| {
        if (w.folder_seq != w.mem_seq) {
            w.mem_seq = w.folder_seq;
            if (w.remoteDest().len == 0) app.memory.visitFolder(w.folder_now.items);
        }
        const dest = w.remoteDest();
        const h: u64 = if (dest.len > 0) std.hash.Wyhash.hash(0, dest) else 0;
        if (h != w.mem_host) {
            w.mem_host = h;
            if (dest.len > 0) app.memory.usedHost(dest);
        }
    }
    if (app.memory_file and app.memory.dirty and now -| app.memory_saved_ms > 10_000) {
        app.memory_saved_ms = now;
        app.memory.save();
    }
}

// ------------------------------------------------------------ commands

fn submit(app: *App) void {
    const line = app.prompt.take() catch return;
    defer app.gpa.free(line);
    if (app.focusedJob() == null and app.aiReady()) app.askAi(line) else app.exec(line);
    app.dirty = true;
}

fn exec(app: *App, line: []const u8) void {
    switch (commands.parse(line)) {
        .empty => if (app.focusedJob()) |w| w.send("\n"),
        .line => |cmd| app.execLine(cmd),
        .unknown => app.reject(line),
        else => |g| app.execGtty(g),
    }
}

/// A line without a leading `/`. (Script mode: a focused running job gets
/// it.) Otherwise the OS gets the first chance, then gtty's own commands;
/// if neither knows it, it's rejected.
fn execLine(app: *App, cmd: []const u8) void {
    if (app.focusedJob()) |w| {
        w.send(cmd);
        w.send("\n");
        return;
    }
    if (oscmd.knows(cmd) or app.shellKnows(cmd)) return app.runCommand(cmd);
    switch (commands.parseGtty(cmd, false)) {
        .unknown => app.reject(cmd),
        else => |g| app.execGtty(g),
    }
}

/// Nothing understood the line: error beep, the text goes back into the
/// prompt (to fix it) and flashes red for a second.
fn reject(app: *App, line: []const u8) void {
    beep.beep();
    app.prompt.insertUtf8(line);
    app.reject_until = c.SDL_GetTicks() + 1000;
    const word = oscmd.commandWord(line) orelse line;
    app.sayFmt("not a command: {s}", .{word}, app.theme.stderr_accent);
}

fn execGtty(app: *App, cmd_parsed: commands.Command) void {
    switch (cmd_parsed) {
        .wait, .shot, .help => {},
        else => app.help_visible = false,
    }
    switch (cmd_parsed) {
        .empty, .line, .unknown => {},
        .bad => |msg| app.say(msg, app.theme.stderr_accent),
        .help => app.help_visible = true,
        .shell => |sh| {
            app.auto_shell = true; // the user's own: new shells open again
            if (sh.cwd) |dir| {
                var buf: [4096]u8 = undefined;
                const full = expandHome(&buf, dir) orelse return app.say("s --cwd: folder name too long", app.theme.stderr_accent);
                if (!isDir(full)) return app.sayFmt("no folder {s}", .{dir}, app.theme.stderr_accent);
                app.openShellIn(sh.program, full);
            } else app.openShell(sh.program);
        },
        .run => |cmd| app.runCommand(cmd),
        // `close`: the windows go (running jobs are hung up); nothing goes
        // to the job grid.
        .close => |t| switch (t) {
            .all => {
                var closed: usize = 0;
                while (app.jobs.items.len > 0) : (closed += 1) app.closeWindow(app.jobs.items.len - 1);
                app.sayFmt("closed {d} window{s}", .{ closed, if (closed == 1) "" else "s" }, app.theme.dim);
            },
            .focused => if (app.focus) |i| app.closeWindow(i),
            .id => |id| if (app.indexOf(id)) |i| app.closeWindow(i) else app.sayFmt("no window #{d}", .{id}, app.theme.stderr_accent),
        },
        .clear => |t| switch (t) {
            .all => for (app.jobs.items) |w| {
                w.out.clear();
            },
            .focused => if (app.main) |m| app.jobs.items[m].out.clear(),
            .id => |id| if (app.indexOf(id)) |i| {
                app.jobs.items[i].out.clear();
            },
        },
        .focus => |id| if (app.indexOf(id)) |i| app.setFocus(i) else app.sayFmt("no window #{d}", .{id}, app.theme.stderr_accent),
        .zoom => |z| app.zoomFocused(z),
        .colors => |on| if (app.activeShown()) |m| app.colorsJob(app.jobs.items[m], on) else app.say("no window", app.theme.dim),
        .show => |sh| app.showFile(sh.path, sh.pick),
        .list => app.listJobs(),
        .settings => app.openSettings(),
        .menu => |pick| app.menuPick(switch (pick) {
            .run => c.GTTY_MENU_RUN,
            .settings => c.GTTY_MENU_SETTINGS,
            .new_shell => c.GTTY_MENU_NEW_SHELL,
            .new_window => c.GTTY_MENU_NEW_WINDOW,
            .sync_typing => c.GTTY_MENU_SYNC_TYPING,
            .about => c.GTTY_MENU_ABOUT,
        }),
        .mods => |spec| {
            var mod: c.SDL_Keymod = 0;
            if (!std.mem.eql(u8, spec, "none")) {
                var it = std.mem.splitScalar(u8, spec, '+');
                while (it.next()) |part| {
                    const m: c.SDL_Keymod = if (std.mem.eql(u8, part, "cmd")) c.SDL_KMOD_LGUI else if (std.mem.eql(u8, part, "shift")) c.SDL_KMOD_LSHIFT else if (std.mem.eql(u8, part, "alt")) c.SDL_KMOD_LALT else if (std.mem.eql(u8, part, "ctrl")) c.SDL_KMOD_LCTRL else {
                        app.sayFmt("/mods: unknown key {s}", .{part}, app.theme.stderr_accent);
                        return;
                    };
                    mod |= m;
                }
            }
            c.SDL_SetModState(mod);
            app.sendHover();
        },
        .target => |t| app.script_target = switch (t) {
            .main => .main,
            .settings => .settings,
        },
        .quit => app.running = false,
        .shot => |path| if (app.scriptSettings()) |sw| {
            sw.takeShot(path);
        } else {
            if (app.pending_shot) |p| app.gpa.free(p);
            app.pending_shot = app.gpa.dupe(u8, path) catch null;
            app.dirty = true; // taken on the next frame
        },
        .type => |text| if (app.scriptSettings()) |sw| {
            sw.onText(text);
            sw.onKey(c.SDLK_RETURN, 0);
        } else {
            app.onText(text);
            app.onKey(c.SDLK_RETURN, 0);
        },
        .text => |text| if (app.scriptSettings()) |sw| sw.onText(text) else app.onText(text),
        .key => |spec| if (keySpec(spec)) |k| {
            if (app.scriptSettings()) |sw| sw.onKey(k.key, k.mod) else app.onKey(k.key, k.mod);
        } else app.sayFmt("/key: unknown key {s}", .{spec}, app.theme.stderr_accent),
        // Real mouse events (window coordinates, like SDL), to the
        // `/target` window.
        .click => |p| {
            const win = app.scriptWindow();
            app.notePointer(p.x, p.y, true);
            pushMouse(win, c.SDL_EVENT_MOUSE_BUTTON_DOWN, p.x, p.y, c.SDL_BUTTON_LEFT);
            pushMouse(win, c.SDL_EVENT_MOUSE_BUTTON_UP, p.x, p.y, c.SDL_BUTTON_LEFT);
        },
        .rclick => |p| {
            const win = app.scriptWindow();
            app.notePointer(p.x, p.y, true);
            pushMouse(win, c.SDL_EVENT_MOUSE_BUTTON_DOWN, p.x, p.y, c.SDL_BUTTON_RIGHT);
            pushMouse(win, c.SDL_EVENT_MOUSE_BUTTON_UP, p.x, p.y, c.SDL_BUTTON_RIGHT);
        },
        .move => |p| {
            app.notePointer(p.x, p.y, false);
            pushMouse(app.scriptWindow(), c.SDL_EVENT_MOUSE_MOTION, p.x, p.y, app.script_btn);
        },
        .dclick => |p| {
            const win = app.scriptWindow();
            app.notePointer(p.x, p.y, true);
            pushMouseN(win, c.SDL_EVENT_MOUSE_BUTTON_DOWN, p.x, p.y, c.SDL_BUTTON_LEFT, 1);
            pushMouseN(win, c.SDL_EVENT_MOUSE_BUTTON_UP, p.x, p.y, c.SDL_BUTTON_LEFT, 1);
            pushMouseN(win, c.SDL_EVENT_MOUSE_BUTTON_DOWN, p.x, p.y, c.SDL_BUTTON_LEFT, 2);
            pushMouseN(win, c.SDL_EVENT_MOUSE_BUTTON_UP, p.x, p.y, c.SDL_BUTTON_LEFT, 2);
        },
        .down => |p| {
            app.notePointer(p.x, p.y, true);
            app.script_btn = c.SDL_BUTTON_LEFT;
            pushMouse(app.scriptWindow(), c.SDL_EVENT_MOUSE_BUTTON_DOWN, p.x, p.y, c.SDL_BUTTON_LEFT);
        },
        .up => |p| {
            app.notePointer(p.x, p.y, false);
            app.script_btn = 0;
            pushMouse(app.scriptWindow(), c.SDL_EVENT_MOUSE_BUTTON_UP, p.x, p.y, c.SDL_BUTTON_LEFT);
        },
        .drag => |v| {
            const win = app.scriptWindow();
            app.notePointer(v[2], v[3], true);
            pushMouse(win, c.SDL_EVENT_MOUSE_BUTTON_DOWN, v[0], v[1], c.SDL_BUTTON_LEFT);
            pushMouse(win, c.SDL_EVENT_MOUSE_MOTION, v[2], v[3], c.SDL_BUTTON_LEFT);
            pushMouse(win, c.SDL_EVENT_MOUSE_BUTTON_UP, v[2], v[3], c.SDL_BUTTON_LEFT);
        },
        .wait => |ms| app.script_next = c.SDL_GetTicks() + ms,
        .pace => |ms| app.script_gap_ms = ms,
        .slow => |text| {
            if (app.slow_text) |old| app.gpa.free(old);
            app.slow_text = app.gpa.dupe(u8, text) catch null;
            app.slow_pos = 0;
            app.slow_next = 0;
        },
        .glide => |g| {
            const from: [2]f32 = if (app.script_ptr) |p| .{ p[0] / app.density, p[1] / app.density } else .{ g.x, g.y };
            app.glide = .{ .from = from, .to = .{ g.x, g.y }, .start = c.SDL_GetTicks(), .ms = @max(g.ms, 1) };
        },
        .dropover => |p| {
            app.notePointer(p.x, p.y, false);
            pushDrop(c.SDL_EVENT_DROP_BEGIN, 0, 0, null);
            pushDrop(c.SDL_EVENT_DROP_POSITION, p.x, p.y, null);
        },
        .drop => |d| {
            app.notePointer(d.x, d.y, true);
            if (app.script_drop) |old| app.gpa.free(old);
            app.script_drop = app.gpa.dupeZ(u8, d.path) catch null;
            const path = app.script_drop orelse return;
            if (!app.dropping) pushDrop(c.SDL_EVENT_DROP_BEGIN, 0, 0, null);
            pushDrop(c.SDL_EVENT_DROP_POSITION, d.x, d.y, null);
            pushDrop(c.SDL_EVENT_DROP_FILE, d.x, d.y, path.ptr);
            pushDrop(c.SDL_EVENT_DROP_COMPLETE, d.x, d.y, null);
        },
        .record => |r| switch (r) {
            .start => |st| app.startRecord(st.dir, st.fps),
            .stop => app.stopRecord(),
        },
        .resize => |v| _ = c.SDL_SetWindowSize(app.window, @intFromFloat(v[0]), @intFromFloat(v[1])),
    }
}

/// Script hook `/key`: "ctrl+shift+left" → the key and its modifiers.
fn keySpec(spec: []const u8) ?struct { key: c.SDL_Keycode, mod: c.SDL_Keymod } {
    const Name = struct { name: []const u8, v: u32 };
    const mods = [_]Name{ .{ .name = "ctrl", .v = c.SDL_KMOD_LCTRL }, .{ .name = "shift", .v = c.SDL_KMOD_LSHIFT }, .{ .name = "alt", .v = c.SDL_KMOD_LALT }, .{ .name = "cmd", .v = c.SDL_KMOD_LGUI } };
    const keys = [_]Name{
        .{ .name = "left", .v = c.SDLK_LEFT },           .{ .name = "right", .v = c.SDLK_RIGHT },
        .{ .name = "up", .v = c.SDLK_UP },               .{ .name = "down", .v = c.SDLK_DOWN },
        .{ .name = "home", .v = c.SDLK_HOME },           .{ .name = "end", .v = c.SDLK_END },
        .{ .name = "backspace", .v = c.SDLK_BACKSPACE }, .{ .name = "delete", .v = c.SDLK_DELETE },
        .{ .name = "enter", .v = c.SDLK_RETURN },        .{ .name = "escape", .v = c.SDLK_ESCAPE },
        .{ .name = "tab", .v = c.SDLK_TAB },             .{ .name = "c", .v = c.SDLK_C },
        .{ .name = "v", .v = c.SDLK_V },                 .{ .name = "insert", .v = c.SDLK_INSERT },
        .{ .name = "a", .v = c.SDLK_A },                 .{ .name = "period", .v = c.SDLK_PERIOD },
        .{ .name = "n", .v = c.SDLK_N },                 .{ .name = "t", .v = c.SDLK_T },
        .{ .name = "pageup", .v = c.SDLK_PAGEUP },       .{ .name = "pagedown", .v = c.SDLK_PAGEDOWN },
        .{ .name = "x", .v = c.SDLK_X },                 .{ .name = "f2", .v = c.SDLK_F2 },
    };
    var mod: c.SDL_Keymod = 0;
    var it = std.mem.splitScalar(u8, spec, '+');
    while (it.next()) |part| {
        if (it.peek() == null) { // the key comes last
            for (keys) |k| if (std.mem.eql(u8, part, k.name)) return .{ .key = k.v, .mod = mod };
            return null;
        }
        const m = for (mods) |m| {
            if (std.mem.eql(u8, part, m.name)) break m;
        } else return null;
        mod |= @intCast(m.v);
    }
    return null;
}

/// The settings window, when script hooks go to it (`/target settings`).
fn scriptSettings(app: *App) ?*SettingsWindow {
    return if (app.script_target == .settings) app.settings else null;
}

/// The OS window id script mouse events go to (0: gtty's own).
fn scriptWindow(app: *App) c.SDL_WindowID {
    if (app.scriptSettings()) |sw| return sw.id;
    return 0;
}

/// Script hooks: a mouse event at window coordinates (`button`: which
/// button is pressed / released, or held during a motion; 0 for none) in
/// OS window `win` (0: gtty's own).
fn pushMouse(win: c.SDL_WindowID, kind: u32, x: f32, y: f32, button: u8) void {
    pushMouseN(win, kind, x, y, button, 1);
}

/// The same, as the `clicks`-th click (2: a double-click's second).
fn pushMouseN(win: c.SDL_WindowID, kind: u32, x: f32, y: f32, button: u8, clicks: u8) void {
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    ev.type = kind;
    if (kind == c.SDL_EVENT_MOUSE_MOTION) {
        ev.motion.windowID = win;
        ev.motion.x = x;
        ev.motion.y = y;
        ev.motion.state = if (button == c.SDL_BUTTON_LEFT) c.SDL_BUTTON_LMASK else 0;
    } else {
        ev.button.windowID = win;
        ev.button.button = button;
        ev.button.down = kind == c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        ev.button.clicks = clicks;
        ev.button.x = x;
        ev.button.y = y;
    }
    _ = c.SDL_PushEvent(&ev);
}

fn focusedJob(app: *App) ?*JobWindow {
    const w = app.focused() orelse return null;
    return if (w.running()) w else null;
}

fn listJobs(app: *App) void {
    if (app.jobs.items.len == 0) {
        app.say("no windows", app.theme.dim);
        return;
    }
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    for (app.jobs.items) |w| {
        var sb: [48]u8 = undefined;
        var hb: [8]u8 = undefined;
        const s = std.fmt.bufPrint(buf[len..], "#{d} [{s}] {s} ({s})   ", .{ w.serial, ids_mod.hex(w.uid, &hb), w.title, w.statusText(&sb) }) catch break;
        len += s.len;
    }
    app.say(buf[0..len], app.theme.prompt_fg);
}

fn say(app: *App, s: []const u8, col: Rgb) void {
    const n = @min(s.len, app.msg_buf.len);
    @memcpy(app.msg_buf[0..n], s[0..n]);
    app.msg_len = n;
    app.msg_color = col;
    app.msg_until = c.SDL_GetTicks() + 8000;
    app.dirty = true;
}

fn sayFmt(app: *App, comptime fmt: []const u8, args: anytype, col: Rgb) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    app.say(s, col);
}

// ------------------------------------------------------------ input

fn handle(app: *App, ev: *const c.SDL_Event) void {
    if (trace.on()) switch (ev.type) {
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => trace.line("key {s} {s} mod=0x{x} repeat={} win={d}", .{
            if (ev.type == c.SDL_EVENT_KEY_DOWN) "down" else "up",
            std.mem.span(c.SDL_GetKeyName(ev.key.key)),
            ev.key.mod,
            ev.key.repeat,
            ev.key.windowID,
        }),
        c.SDL_EVENT_TEXT_INPUT => trace.bytes("text", 0, std.mem.span(ev.text.text)),
        c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, c.SDL_EVENT_WINDOW_FOCUS_GAINED, c.SDL_EVENT_WINDOW_FOCUS_LOST => trace.line("window event 0x{x} win={d}", .{ ev.type, ev.window.windowID }),
        else => {},
    };
    if (ev.type == app.menu_event and app.menu_event != 0) return app.menuPick(ev.user.code);
    // ⌘C / ⌘V / ⌘A with the macOS menu bar: its Edit row fires for the same key
    // press (SDL still sends the key down), so the menu alone acts on it,
    // or a paste would happen twice. A disabled row lets the key through.
    if (ev.type == c.SDL_EVENT_KEY_DOWN and app.menuOwnsKey(ev.key.key, ev.key.mod)) return;
    // A paste / copy key acts once per press: its auto-repeats are dropped
    // (a VM or a remote X server easily sends one, and each would paste).
    if (ev.type == c.SDL_EVENT_KEY_DOWN and ev.key.repeat and clipboardKey(ev.key.key, ev.key.mod)) return;
    // Events of the settings window go to it.
    if (app.settings) |sw| if (eventWindow(ev) == sw.id) return sw.handle(ev);
    switch (ev.type) {
        c.SDL_EVENT_QUIT => app.running = false,
        // Closing gtty's own window ends gtty (with the settings window
        // open, SDL doesn't send QUIT for it).
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => app.running = false,
        c.SDL_EVENT_WINDOW_RESIZED,
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
        c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
        c.SDL_EVENT_WINDOW_DISPLAY_CHANGED,
        => {
            app.closeMenu();
            app.updateScale();
        },
        c.SDL_EVENT_WINDOW_EXPOSED => app.dirty = true,
        c.SDL_EVENT_TEXT_INPUT => app.onText(std.mem.span(ev.text.text)),
        c.SDL_EVENT_KEY_DOWN => {
            if (isModifier(ev.key.key)) app.sendHover();
            app.onKey(ev.key.key, ev.key.mod);
        },
        // A modifier key down / up with the mouse on a window's text: look
        // again under the mouse.
        c.SDL_EVENT_KEY_UP => if (isModifier(ev.key.key)) app.sendHover(),
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => app.onClick(ev.button.x * app.density, ev.button.y * app.density, ev.button.button, ev.button.clicks),
        c.SDL_EVENT_MOUSE_BUTTON_UP => app.onMouseUp(),
        c.SDL_EVENT_MOUSE_MOTION => app.onMotion(ev.motion.x * app.density, ev.motion.y * app.density),
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => app.onMouseLeave(),
        c.SDL_EVENT_MOUSE_WHEEL => app.onWheel(ev.wheel.mouse_x * app.density, ev.wheel.mouse_y * app.density, ev.wheel.y),
        c.SDL_EVENT_DROP_BEGIN, c.SDL_EVENT_DROP_POSITION, c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_COMPLETE => app.onDrop(ev),
        c.SDL_EVENT_CLIPBOARD_UPDATE => app.clipboardChanged(),
        else => {},
    }
}

/// The OS window an event is for (0: none / not a window event).
fn eventWindow(ev: *const c.SDL_Event) c.SDL_WindowID {
    return switch (ev.type) {
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => ev.key.windowID,
        c.SDL_EVENT_TEXT_INPUT => ev.text.windowID,
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => ev.button.windowID,
        c.SDL_EVENT_MOUSE_MOTION => ev.motion.windowID,
        c.SDL_EVENT_MOUSE_WHEEL => ev.wheel.windowID,
        c.SDL_EVENT_DROP_BEGIN, c.SDL_EVENT_DROP_POSITION, c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_TEXT, c.SDL_EVENT_DROP_COMPLETE => ev.drop.windowID,
        else => if (ev.type >= c.SDL_EVENT_WINDOW_FIRST and ev.type <= c.SDL_EVENT_WINDOW_LAST) ev.window.windowID else 0,
    };
}

/// Typed text goes to the focused running window, otherwise to the prompt.
fn onText(app: *App, text: []const u8) void {
    if (app.modal) |*m| {
        m.typed(text, c.SDL_GetTicks());
        app.dirty = true;
        return;
    }
    if (app.peek) |*pk| if (pk.wantsKeys()) {
        pk.text(text);
        app.layoutPeek();
        app.dirty = true;
        return;
    };
    if (app.focusedJob()) |w| {
        // Typing over a selection in the shell's input line replaces it.
        _ = w.deleteSel();
        w.typeBytes(text);
    } else app.prompt.insertUtf8(text);
    app.dirty = true;
}

fn onKey(app: *App, key: c.SDL_Keycode, mod: c.SDL_Keymod) void {
    const ctrl = mod & c.SDL_KMOD_CTRL != 0;
    const cmd = mod & c.SDL_KMOD_GUI != 0; // ⌘ on macOS
    const alt = mod & c.SDL_KMOD_ALT != 0;
    const shift = mod & c.SDL_KMOD_SHIFT != 0;
    app.dirty = true;
    // The mouse no longer "has" a file (`pointerFresh`) once a key is
    // pressed (modifier keys alone don't count).
    defer if (!isModifier(key)) {
        app.last_key_ms = c.SDL_GetTicks();
    };

    // Any key closes the About box, and does nothing else.
    if (app.about_visible) {
        app.about_visible = false;
        return;
    }
    // A modal takes every key (Enter, Esc, ←/→/Tab, its field's editing
    // keys and paste; the rest does nothing).
    if (app.modal) |*m| {
        if (key == c.SDLK_V and (cmd or (ctrl and shift))) {
            if (c.SDL_GetClipboardText()) |t| {
                defer c.SDL_free(t);
                m.typed(std.mem.span(t), c.SDL_GetTicks());
            }
            return;
        }
        if (m.key(key, mod, c.SDL_GetTicks())) |p| app.resolveModal(p, .picked);
        return;
    }
    // Esc cancels a remote copy in progress (its modal is up).
    if (key == c.SDLK_ESCAPE and app.fetch != null) return app.cancelFetch("copy cancelled");

    // Any key closes the right-click menu; Esc does only that.
    if (app.menu != null) {
        app.closeMenu();
        if (key == c.SDLK_ESCAPE) return;
    }

    // An expanded peek has the keyboard (its filter box and list).
    if (app.peek) |*pk| if (pk.wantsKeys() and !cmd) return app.peekAction(pk.key(key));

    // File actions on the name the mouse has (or the selected names).
    if (app.fileKey(key, ctrl, cmd, alt, shift)) return;

    // Esc closes an open kill menu (instead of going to the job).
    if (key == c.SDLK_ESCAPE) for (app.jobs.items) |w| if (w.kill_menu) {
        w.kill_menu = false;
        return;
    };

    // F11: maximize / back to normal.
    if (key == c.SDLK_F11) {
        if (app.activeShown()) |m| app.toggleMaximize(m);
        return;
    }

    // Zoom: Ctrl or ⌘ with + / - / 0
    if (ctrl or cmd) {
        switch (key) {
            c.SDLK_EQUALS, c.SDLK_PLUS, c.SDLK_KP_PLUS => return app.zoomFocused(.in),
            c.SDLK_MINUS, c.SDLK_KP_MINUS => return app.zoomFocused(.out),
            c.SDLK_0, c.SDLK_KP_0 => return app.zoomFocused(.reset),
            c.SDLK_TAB => return app.cycleFocus(if (shift) -1 else 1),
            else => {},
        }
    }
    // New window (another gtty): ⌘N, or Ctrl+Shift+N; new shell (a new
    // tab elsewhere): ⌘T, or Ctrl+Shift+T — as GNOME Terminal (Ctrl+N /
    // Ctrl+T alone are the job's). On macOS the native menu's key
    // equivalents act first (menuOwnsKey drops the key).
    const new_key = !alt and ((cmd and !ctrl and !shift) or (ctrl and shift and !cmd));
    if (key == c.SDLK_N and new_key) return app.newWindow(app.currentJob());
    if (key == c.SDLK_T and new_key) return app.newShell(app.currentJob());
    // Copy the selection: ⌘C, or Ctrl+Shift+C (Ctrl+C alone is the job's).
    if (key == c.SDLK_C and (cmd or (ctrl and shift))) return app.copySelection();
    // Paste: ⌘V, Ctrl+Shift+V or Shift+Insert (Ctrl+V alone is the job's).
    if (key == c.SDLK_V and (cmd or (ctrl and shift))) return app.pasteKey();
    if (key == c.SDLK_INSERT and shift and !ctrl and !cmd and !alt) return app.pasteKey();
    // Select all the window's text: ⌘A, or Ctrl+Shift+A (Ctrl+A alone is
    // the job's: start of line).
    if (key == c.SDLK_A and ((cmd and !ctrl and !alt and !shift) or (ctrl and shift and !cmd))) return app.selectAll();
    // Moving in a job's input: words with Ctrl or ⌥ + arrows, selecting
    // with Shift (see editKey).
    if (app.focusedJob()) |w| if (app.editKey(w, key, ctrl, cmd, alt, shift)) return;
    if (cmd) {
        switch (key) {
            c.SDLK_W => if (app.focus) |i| app.closeWindow(i),
            c.SDLK_Q => app.running = false,
            else => {},
        }
        return;
    }
    // A running window has focus: keys go straight to its terminal.
    if (app.focusedJob()) |w| {
        if (jobKeyBytes(key, ctrl, shift, w.out.app_cursor, w.out.alt != null)) |bytes| {
            w.typeBytes(bytes);
        } else switch (key) {
            c.SDLK_PAGEUP => w.out.scrollBy(@intCast(w.rows -| 1)),
            c.SDLK_PAGEDOWN => w.out.scrollBy(-@as(isize, @intCast(w.rows -| 1))),
            else => {},
        }
        return;
    }
    if (ctrl) {
        switch (key) {
            c.SDLK_C => if (app.focused()) |w| {
                if (w.running()) {
                    w.send("\x03");
                    app.prompt.clear();
                    return;
                }
                app.prompt.clear();
            } else app.prompt.clear(),
            c.SDLK_D => if (app.focused()) |w| w.send("\x04"),
            c.SDLK_Z => if (app.focused()) |w| w.send("\x1a"),
            c.SDLK_A => app.prompt.home(),
            c.SDLK_E => app.prompt.end(),
            c.SDLK_U => app.prompt.clear(),
            c.SDLK_L => if (app.focused()) |w| {
                w.out.clear();
            },
            c.SDLK_LEFT => app.prompt.wordLeft(),
            c.SDLK_RIGHT => app.prompt.wordRight(),
            else => {},
        }
        return;
    }
    switch (key) {
        c.SDLK_RETURN, c.SDLK_KP_ENTER => app.submit(),
        c.SDLK_BACKSPACE => app.prompt.backspace(),
        c.SDLK_DELETE => app.prompt.delete(),
        c.SDLK_LEFT => if (alt) app.prompt.wordLeft() else app.prompt.left(),
        c.SDLK_RIGHT => if (alt) app.prompt.wordRight() else app.prompt.right(),
        c.SDLK_HOME => app.prompt.home(),
        c.SDLK_END => app.prompt.end(),
        c.SDLK_UP => app.prompt.historyPrev(),
        c.SDLK_DOWN => app.prompt.historyNext(),
        c.SDLK_ESCAPE => {
            if (app.aiBusy()) return app.cancelAi();
            app.prompt.clear();
            app.help_visible = false;
        },
        c.SDLK_PAGEUP => if (app.focused()) |w| w.out.scrollBy(@intCast(w.rows -| 1)),
        c.SDLK_PAGEDOWN => if (app.focused()) |w| w.out.scrollBy(-@as(isize, @intCast(w.rows -| 1))),
        else => {},
    }
}

/// Arrows, Home and End with modifiers in a running job. A shell at its
/// prompt: gtty moves its cursor (Ctrl / ⌥ + ←/→ by words, ⌘ + ←/→ to the
/// line's ends) and Shift selects what the cursor passes over; Backspace /
/// Delete erase the selection (that one, or one made with the mouse in the
/// line being typed: `JobWindow.deleteSel`). A program: xterm's modified key sequence
/// (`ESC [1;<mod>D`). Any other key drops a keyboard selection. True when
/// the key was handled here.
fn editKey(app: *App, w: *JobWindow, key: c.SDL_Keycode, ctrl: bool, cmd: bool, alt: bool, shift: bool) bool {
    const m: JobWindow.Move = switch (key) {
        c.SDLK_LEFT => if (cmd) .home else if (ctrl or alt) .word_left else .left,
        c.SDLK_RIGHT => if (cmd) .end else if (ctrl or alt) .word_right else .right,
        c.SDLK_HOME => .home,
        c.SDLK_END => .end,
        // Modifier keys on their own (Shift before an arrow) change nothing.
        c.SDLK_LSHIFT, c.SDLK_RSHIFT, c.SDLK_LCTRL, c.SDLK_RCTRL, c.SDLK_LALT, c.SDLK_RALT, c.SDLK_LGUI, c.SDLK_RGUI, c.SDLK_CAPSLOCK => return false,
        else => {
            if ((key == c.SDLK_BACKSPACE or key == c.SDLK_DELETE) and !ctrl and !alt and !cmd and w.deleteSel()) {
                app.dirty = true;
                return true;
            }
            // ⌘ keys (copy, paste) keep it: paste types over it.
            if (!cmd) w.dropKeySel();
            return false;
        },
    };
    app.dirty = true;
    if (w.atPrompt()) {
        w.editMove(m, shift);
        return true;
    }
    w.dropKeySel();
    const mods: u8 = 1 + @as(u8, @intFromBool(shift)) + 2 * @as(u8, @intFromBool(alt)) + 4 * @as(u8, @intFromBool(ctrl));
    const final: u8 = switch (key) {
        c.SDLK_LEFT => if (cmd) 'H' else 'D',
        c.SDLK_RIGHT => if (cmd) 'F' else 'C',
        c.SDLK_HOME => 'H',
        else => 'F',
    };
    if (mods == 1 or cmd) {
        const plain = [_]u8{ 0x1b, '[', final };
        w.typeBytes(&plain);
    } else {
        var buf: [8]u8 = undefined;
        w.typeBytes(std.fmt.bufPrint(&buf, "\x1b[1;{d}{c}", .{ mods, final }) catch return true);
    }
    return true;
}

/// Bytes a terminal sends for a non-text key (text arrives as TEXT_INPUT).
/// `app_cursor`: the program asked for application cursor keys (vim, less);
/// `full_screen`: it runs on the alternate screen, so PageUp / PageDown
/// are its keys, not gtty's scrolling.
fn jobKeyBytes(key: c.SDL_Keycode, ctrl: bool, shift: bool, app_cursor: bool, full_screen: bool) ?[]const u8 {
    if (ctrl and key >= c.SDLK_A and key <= c.SDLK_Z) {
        const ctl = comptime blk: {
            var t: [26][1]u8 = undefined;
            for (&t, 0..) |*b, i| b.* = .{@intCast(i + 1)};
            break :blk t;
        };
        return &ctl[key - c.SDLK_A];
    }
    return switch (key) {
        c.SDLK_RETURN, c.SDLK_KP_ENTER => "\r",
        c.SDLK_BACKSPACE => "\x7f",
        c.SDLK_TAB => if (shift) "\x1b[Z" else "\t",
        c.SDLK_ESCAPE => "\x1b",
        c.SDLK_UP => if (app_cursor) "\x1bOA" else "\x1b[A",
        c.SDLK_DOWN => if (app_cursor) "\x1bOB" else "\x1b[B",
        c.SDLK_RIGHT => if (app_cursor) "\x1bOC" else "\x1b[C",
        c.SDLK_LEFT => if (app_cursor) "\x1bOD" else "\x1b[D",
        c.SDLK_HOME => if (app_cursor) "\x1bOH" else "\x1b[H",
        c.SDLK_END => if (app_cursor) "\x1bOF" else "\x1b[F",
        c.SDLK_DELETE => "\x1b[3~",
        c.SDLK_PAGEUP => if (full_screen) "\x1b[5~" else null,
        c.SDLK_PAGEDOWN => if (full_screen) "\x1b[6~" else null,
        else => null,
    };
}

fn onClick(app: *App, x: f32, y: f32, button: u8, clicks: u8) void {
    app.hideTip();
    // The link box: a click on it cd's to the target's folder; a click
    // elsewhere closes it and still acts.
    if (app.link_hover) |h| if (h.box) |b| if (b.contains(x, y) and app.modal == null and app.menu == null) {
        if (button == c.SDL_BUTTON_LEFT) app.linkHoverClick();
        return;
    };
    app.hideLinkHover();
    // A modal: a left click on one of its buttons picks it; nothing else
    // does anything.
    if (app.modal) |*m| {
        if (button == c.SDL_BUTTON_LEFT) if (m.click(x, y)) |p| app.resolveModal(p, .picked);
        return;
    }
    // Any click closes the About box, and does nothing else.
    if (app.about_visible) {
        app.about_visible = false;
        app.dirty = true;
        return;
    }
    // The open right-click menu: a left click inside picks an item; a
    // click outside only closes it (a right click opens it again there).
    if (app.sub_menu) |*sm| if (sm.contains(x, y)) {
        if (button == c.SDL_BUTTON_LEFT) app.subMenuClick(x, y);
        return;
    };
    if (app.menu) |*m| {
        if (m.contains(x, y)) {
            if (button == c.SDL_BUTTON_LEFT) app.menuClick(x, y);
            return;
        }
        app.closeMenu();
        if (button != c.SDL_BUTTON_RIGHT) return;
    }
    // The copy modal: its Cancel button; the rest of it does nothing.
    if (app.fetch) |*f| if (f.box.contains(x, y)) {
        if (button == c.SDL_BUTTON_LEFT and f.cancel_r.contains(x, y)) app.cancelFetch("copy cancelled");
        return;
    };
    // An open peek: a click inside is the peek's (not a focus change); a
    // click anywhere else closes it and still does what it does.
    if (app.peek) |*pk| {
        if (pk.contains(x, y)) {
            if (button == c.SDL_BUTTON_LEFT) app.peekAction(pk.click(x, y));
            return;
        }
        app.closePeek();
    }
    // An open kill menu: only its skull or the × itself act; any other
    // click just dismisses it.
    for (app.jobs.items, 0..) |w, i| if (w.kill_menu) {
        switch (w.hit(x, y)) {
            .kill, .close => return app.clickJob(i, x, y, button, clicks),
            else => {
                w.kill_menu = false;
                app.dirty = true;
                return;
            },
        }
    };
    // A left press on an outlined file name goes to the window's file
    // opener first: double-click opens it; a single press waits to see if
    // it becomes a click, a drag of the file or a text selection.
    app.last_point_ms = c.SDL_GetTicks();
    const sel_mod = c.SDL_GetModState() & (if (builtin.os.tag == .macos) c.SDL_KMOD_GUI else c.SDL_KMOD_CTRL) != 0;
    if (button == c.SDL_BUTTON_LEFT) if (app.textWindowAt(x, y)) |i| {
        // Hover there first (the outline is for the spot clicked).
        app.mouse = .{ x, y };
        app.sendHover();
        const w = app.jobs.items[i];
        // ⌘-click (Ctrl-click) on a name: select it (or not) for the file
        // actions; a plain click drops the selection.
        if (sel_mod and FileOpener.enabled) if (w.fileMarkAt(x, y)) |m| if (!m.remote) {
            if (clicks == 1) app.toggleFileSel(w, m);
            return;
        };
        app.clearFileSel();
        if (w.fileMarkAt(x, y) != null) switch (clicks) {
            1 => {
                app.setFocus(i);
                app.file_press = .{ .window = w.uid, .x = x, .y = y, .ms = c.SDL_GetTicks() };
                return;
            },
            2 => {
                const pick = c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0;
                switch (w.fileOpen(x, y, pick)) {
                    .none => {},
                    .done => return,
                    .show => |sh| return app.execGtty(.{ .show = .{ .path = sh.path, .pick = sh.pick } }),
                    .fetch => |fe| return app.fetchRemote(w, fe.path, fe.pick),
                }
            },
            else => {},
        };
    };
    // The drawn menu bar: its "gtty" button opens the gtty menu.
    if (app.menubar_r.contains(x, y)) {
        if (button == c.SDL_BUTTON_LEFT) if (app.barButtonAt(x, y)) |i| app.openBarMenu(@enumFromInt(i));
        return;
    }
    // Right click on a file or folder name: the file actions; elsewhere on
    // job text or the prompt: the Copy / Paste menu.
    if (button == c.SDL_BUTTON_RIGHT) {
        app.mouse = .{ x, y };
        app.sendHover();
        if (app.openFileMenu(x, y)) return;
        if (app.openMenu(x, y)) return;
    }
    // A maximized job window covers everything.
    if (app.maximizedShown()) |m| return app.clickJob(m, x, y, button, clicks);
    if (app.prompt.rect.contains(x, y)) return app.clearFocus();
    // The job grid's header: the checkbox and the sort button; the rest of
    // it does nothing.
    if (app.grid_head_r.contains(x, y)) {
        if (button == c.SDL_BUTTON_LEFT and app.grid_sort_r.contains(x, y)) app.toggleGridSort();
        if (button == c.SDL_BUTTON_LEFT and app.grid_check_r.contains(x, y)) app.toggleCheckAll();
        return;
    }
    // The job grid's scroll bar: take the thumb, or jump there (the thumb
    // centers on the click) and keep dragging.
    if (button == c.SDL_BUTTON_LEFT and app.gridBarHit(x, y)) {
        const t = app.gridThumb().?;
        if (y >= t.y and y < t.y + t.h) {
            app.grid_grab = y - t.y;
        } else {
            app.grid_grab = t.h / 2;
            app.gridBarTo(y);
        }
        app.grid_drag = true;
        app.dirty = true;
        return;
    }
    const in_grid = app.grid_r.contains(x, y);
    for (app.jobs.items, 0..) |w, i| {
        const here = if (app.isShown(i)) !in_grid else in_grid;
        if (here and w.hit(x, y) != .none) return app.clickJob(i, x, y, button, clicks);
    }
    // Empty space: back to the prompt.
    app.clearFocus();
}

fn clickJob(app: *App, i: usize, x: f32, y: f32, button: u8, clicks: u8) void {
    const w = app.jobs.items[i];
    const hit = w.hit(x, y);
    switch (hit) {
        .none => {},
        // The red ×: close once done; while running, open / close the kill
        // menu — only its skull kills (the window stays, red, with the code).
        // A shell waiting at its prompt closes, like a finished window.
        .close => app.closeOrKillMenu(i),
        .kill => w.kill(),
        .check => if (button == c.SDL_BUTTON_LEFT) app.toggleCheck(i),
        .copy => app.copyJob(w),
        .zoom_in => app.zoomJob(w, .in),
        .zoom_out => app.zoomJob(w, .out),
        .colors => app.colorsJob(w, null),
        .sync => if (button == c.SDL_BUTTON_LEFT) app.toggleSync(w),
        .files => app.openFolder(w),
        .scroller => if (button == c.SDL_BUTTON_LEFT) w.scrollerDown(y),
        // The git chip: its peek at once (no focus change).
        .git_chip => app.openGitPeek(i),
        // The folder chip: the folders above, at once.
        .folder_chip => app.openFolderPeek(i),
        .minimize => app.minimizeJob(i),
        .maximize => app.toggleMaximize(i),
        // Anywhere else: the job becomes (or stays) the current job window.
        // A left press on the text of the current one starts a selection.
        else => {
            const was_main = w.grid_r == null;
            app.setFocus(i);
            if (was_main and hit == .out and button == c.SDL_BUTTON_LEFT) w.mouseDown(x, y, clicks);
        },
    }
}

fn onMouseUp(app: *App) void {
    // A press on a file name that didn't move: a plain click there, and
    // the name goes on the clipboard.
    if (app.file_press) |p| {
        app.file_press = null;
        if (app.jobByUid(p.window)) |w| {
            w.opener.held = false;
            w.mouseDown(p.x, p.y, 1);
            w.mouseUp();
            if (w.fileMarkAt(p.x, p.y)) |m| app.copyNames(@as([]const []const u8, &.{m.file()}), w, m.range);
            app.dirty = true;
        }
    }
    if (app.grid_drag) {
        app.grid_drag = false;
        app.dirty = true;
    }
    for (app.jobs.items) |w| if (w.drag != .none) {
        w.mouseUp();
        app.dirty = true;
    };
}

/// Drag a selection; mark the hovered row in the current window's gutter;
/// an I-beam pointer over its text.
fn onMotion(app: *App, x: f32, y: f32) void {
    app.last_point_ms = c.SDL_GetTicks();
    if (app.grid_drag) app.gridBarTo(y);
    // A press on a file name moved: held long enough → drag the file out;
    // else → select text from the press.
    if (app.file_press) |p| {
        const far = @max(@round(4 * app.scale.ui), 2);
        if ((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y) >= far * far) {
            app.file_press = null;
            if (app.jobByUid(p.window)) |w| {
                if (w.opener.held) app.dragFile(w) else w.mouseDown(p.x, p.y, 1);
            }
        }
    }
    const in_menu = (if (app.menu) |*m| m.contains(x, y) else false) or (if (app.sub_menu) |*m| m.contains(x, y) else false);
    app.updateLinkHover(x, y, in_menu);
    if (app.menu) |*m| if (m.motion(x, y)) {
        app.dirty = true;
        app.hoverSubMenu();
    };
    if (app.sub_menu) |*m| if (m.motion(x, y)) {
        app.dirty = true;
    };
    // Over the peek or the menu: nothing under them reacts.
    const in_peek = in_menu or (if (app.peek) |*pk| pk.contains(x, y) else false);
    if (app.peek) |*pk| if (pk.motion(x, y, c.SDL_GetTicks())) {
        app.dirty = true;
    };
    app.hoverChip(if (in_peek) null else .{ x, y });
    const over_btn = app.barButtonAt(x, y);
    if (over_btn != app.over_menubar_btn) {
        app.over_menubar_btn = over_btn;
        app.dirty = true;
        // A bar menu is open: moving onto another button opens that one.
        if (over_btn) |b| if (app.menu) |m| if (m.purpose == .bar and @intFromEnum(m.purpose.bar) != b) app.openBarMenu(@enumFromInt(b));
    }
    const over_sort = app.grid_sort_r.contains(x, y);
    if (over_sort != app.over_grid_sort) {
        app.over_grid_sort = over_sort;
        app.dirty = true;
    }
    const over_bar = app.gridBarHit(x, y);
    if (over_bar != app.over_grid_bar) {
        app.over_grid_bar = over_bar;
        app.dirty = true;
    }
    for (app.jobs.items) |w| if (w.drag != .none) {
        w.mouseDrag(x, y);
        app.dirty = true;
    };
    var over_text = false;
    const top = app.maximizedShown();
    for (app.jobs.items, 0..) |w, i| {
        const shown = app.isShown(i) and (top == null or top == i) and !in_peek;
        const pt: ?[2]f32 = if (shown) .{ x, y } else null;
        if (w.hover(pt)) app.dirty = true;
        if (shown and w.hit(x, y) == .out and !w.kill_menu) over_text = true;
    }
    if (in_peek) app.hideTip() else app.updateTip(x, y);
    app.over_text = over_text;
    app.mouse = .{ x, y };
    app.sendHover(); // sets the pointer shape too
}

/// Pointer: a hand over an outlined file name, the text beam over text,
/// else the arrow.
fn updateCursor(app: *App) void {
    const marked = if (app.hoverWindow()) |w| w.opener.mark != null else false;
    const want: @TypeOf(app.cursor_kind) = if (marked) .hand else if (app.over_text) .text else .arrow;
    if (want == app.cursor_kind) return;
    app.cursor_kind = want;
    if (app.text_cursor == null) app.text_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT);
    if (app.arrow_cursor == null) app.arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
    if (app.hand_cursor == null) app.hand_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
    _ = c.SDL_SetCursor(switch (want) {
        .hand => app.hand_cursor,
        .text => app.text_cursor,
        .arrow => app.arrow_cursor,
    });
}

// ------------------------------------------------------------ file opener

fn isModifier(key: c.SDL_Keycode) bool {
    return switch (key) {
        c.SDLK_LGUI, c.SDLK_RGUI, c.SDLK_LALT, c.SDLK_RALT, c.SDLK_LCTRL, c.SDLK_RCTRL, c.SDLK_LSHIFT, c.SDLK_RSHIFT, c.SDLK_MODE, c.SDLK_CAPSLOCK => true,
        else => false,
    };
}

/// The window whose text is at (x, y) in the windows area (a maximized
/// window covers the rest; nothing under an open menu or peek, or a
/// window in transition).
fn textWindowAt(app: *App, x: f32, y: f32) ?usize {
    if (app.menu) |*m| if (m.contains(x, y)) return null;
    if (app.peek) |*pk| if (pk.contains(x, y)) return null;
    const top = app.maximizedShown();
    for (app.jobs.items, 0..) |w, i| {
        if (!app.isShown(i) or w.grid_r != null or w.anim_from != null or w.kill_menu) continue;
        if (top != null and top != i) continue;
        if (w.hit(x, y) == .out and w.out_r.contains(x, y)) return i;
    }
    return null;
}

/// The status bar's left side: where a drop would go while files are
/// dragged over gtty, else the file opener's help.
fn helpLine(app: *App, buf: []u8) []const u8 {
    if (app.dropping and app.drop_inside) return app.insideHelp(buf);
    if (app.dropping) {
        var dbuf: [4096]u8 = undefined;
        return switch (app.dropTarget(&dbuf)) {
            .none => "drop on a job window to copy into its folder",
            .remote => "can't copy into an ssh session yet",
            .folder => |d| std.fmt.bufPrint(buf, "drop: copy into {s}", .{std.fs.path.basename(d)}) catch "",
        };
    }
    if (app.hoverWindow()) |w| {
        const h = w.opener.help(buf);
        if (h.len > 0) return h;
    }
    return app.clipHelp(buf);
}

/// The window whose text the mouse is over, if any.
fn hoverWindow(app: *App) ?*JobWindow {
    return app.jobByUid(app.hover_src orelse return null);
}

/// Tell the window under the mouse where it is (with the modifier keys
/// held now): its file opener outlines a name there. Or the mouse left
/// the text.
fn sendHover(app: *App) void {
    defer app.updateCursor();
    const pt = app.mouse orelse return app.sendLeave();
    const i = app.textWindowAt(pt[0], pt[1]) orelse return app.sendLeave();
    const w = app.jobs.items[i];
    if (app.hover_src) |src| if (src != w.uid) app.sendLeave();
    app.hover_src = w.uid;
    if (w.fileHover(pt[0], pt[1])) app.dirty = true;
}

fn sendLeave(app: *App) void {
    const w = app.hoverWindow();
    app.hover_src = null;
    if (w) |hw| if (hw.opener.leave()) {
        app.dirty = true;
    };
    app.updateCursor();
}

/// Each frame: a press on a file name held long enough turns its outline
/// solid (moving now drags the file).
fn tickFilePress(app: *App) void {
    const p = app.file_press orelse return;
    const w = app.jobByUid(p.window) orelse {
        app.file_press = null;
        return;
    };
    if (w.opener.held or w.opener.mark == null or !c.gtty_drag_supported()) return;
    if (c.SDL_GetTicks() -| p.ms < FileOpener.hold_ms) return;
    w.opener.held = true;
    app.dirty = true;
}

/// Drag window `w`'s outlined file out of gtty (the button is down):
/// macOS a drag session as from Finder; Linux a drag helper window.
fn dragFile(app: *App, w: *JobWindow) void {
    w.opener.held = false;
    app.dirty = true;
    const m = if (w.opener.mark) |*m| m else return;
    if (m.remote) {
        beep.beep();
        return app.say("drag: only files on this machine for now", app.theme.stderr_accent);
    }
    var buf: [4097]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "{s}", .{m.file()}) catch return;
    const name = std.fs.path.basename(p);
    // Scripts: only say what would be dragged.
    if (c.getenv("GTTY_DRAG_DRY") != null) return app.sayFmt("would drag {s}", .{p}, app.theme.dim);
    _ = name;
    // Kept for a drop on another job window (`tickInsideDrop`).
    if (app.drag_path) |old| app.gpa.free(old);
    app.drag_path = app.gpa.dupeZ(u8, p) catch null;
    app.inside_drop = null;
    const one = [_][*c]const u8{p.ptr};
    if (c.gtty_drag_files(app.window, &one, 1)) app.drag_out = .{ .window = w.uid };
}

// ------------------------------------------------------------ drop

/// Files dragged in from another app (SDL drop events, gtty's window).
/// While over a job window, a folder name under the mouse is outlined
/// (the file opener in drop mode: folders only, anywhere); the drop copies
/// the files there, else into the folder the window's program is in. Off
/// where drag and drop isn't supported (X11). gtty's own drag (a file from
/// one job window to another): the same outlines and status line, but
/// the file is `drag_path` (SDL's data is ignored: on Wayland it can't be
/// read), and whether it was dropped here comes from the drag session
/// (`tickInsideDrop`).
fn onDrop(app: *App, ev: *const c.SDL_Event) void {
    if (!c.gtty_drag_supported()) return;
    switch (ev.type) {
        c.SDL_EVENT_DROP_BEGIN => {
            app.drop_inside = c.gtty_drag_active();
            app.inside_drop = null;
            app.dropMode(true);
        },
        c.SDL_EVENT_DROP_POSITION => {
            if (!app.dropping) {
                app.drop_inside = c.gtty_drag_active();
                app.inside_drop = null;
                app.dropMode(true);
            }
            app.mouse = .{ ev.drop.x * app.density, ev.drop.y * app.density };
            app.sendHover();
            app.dirty = true;
        },
        c.SDL_EVENT_DROP_FILE => {
            if (app.drop_inside) return;
            if (!app.dropping) app.dropMode(true);
            const data = ev.drop.data orelse return;
            const p = app.gpa.dupeZ(u8, std.mem.span(data)) catch return;
            app.drop_paths.append(app.gpa, p) catch app.gpa.free(p);
        },
        c.SDL_EVENT_DROP_COMPLETE => {
            defer {
                for (app.drop_paths.items) |p| app.gpa.free(p);
                app.drop_paths.clearRetainingCapacity();
                app.drop_inside = false;
                app.dropMode(false);
            }
            if (app.drop_inside) {
                // Where it would go; acted on once the drag session says
                // it was dropped here (else the drag just left the window).
                app.inside_drop = .{ .target = app.insideTarget(), .ms = c.SDL_GetTicks() };
                return;
            }
            if (app.drop_paths.items.len == 0) return;
            var buf: [4096]u8 = undefined;
            const t = app.dropTarget(&buf);
            switch (t) {
                .none => app.say("drop files on a job window to copy them into its folder", app.theme.dim),
                .remote => {
                    beep.beep();
                    app.say("copying into an ssh session isn't there yet", app.theme.stderr_accent);
                },
                .folder => |dest| app.askCopy(dest),
            }
        },
        else => {},
    }
}

/// Where gtty's own drag (a file from one job window) would go: the job
/// window under the mouse; into the folder name outlined there, else the
/// folder its shell is in.
const InsideTarget = struct {
    kind: enum { none, remote, window } = .none,
    window: ids_mod.Id = 0,
    /// The outlined folder (absolute); none: the shell's own folder (`.`).
    outlined: bool = false,
    /// The folder it goes into (absolute; the window's when not outlined).
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn dest(t: *const InsideTarget) []const u8 {
        return t.buf[0..t.len];
    }
};

fn insideTarget(app: *App) InsideTarget {
    var t: InsideTarget = .{};
    const pt = app.mouse orelse return t;
    const i = app.windowAt(pt[0], pt[1]) orelse return t;
    const w = app.jobs.items[i];
    t.window = w.uid;
    var rbuf: [4096]u8 = undefined;
    if (w.remoteNow(&rbuf) != null) {
        t.kind = .remote;
        return t;
    }
    t.kind = .window;
    if (w.fileMarkAt(pt[0], pt[1])) |m| if (m.folder and !m.remote) {
        t.outlined = true;
        t.len = @min(m.len, t.buf.len);
        @memcpy(t.buf[0..t.len], m.buf[0..t.len]);
        return t;
    };
    t.len = w.folder(&t.buf).len;
    return t;
}

/// The dragged file is in folder `dest` already.
fn alreadyIn(path: []const u8, dest: []const u8) bool {
    const from = std.fs.path.dirname(path) orelse "/";
    return dest.len > 0 and std.mem.eql(u8, std.mem.trimEnd(u8, dest, "/"), std.mem.trimEnd(u8, from, "/"));
}

/// The status line while gtty's own drag is over gtty.
fn insideHelp(app: *App, buf: []u8) []const u8 {
    const path = app.drag_path orelse return "";
    const t = app.insideTarget();
    const w = app.jobByUid(t.window);
    return switch (t.kind) {
        .none => "drop on a job window: cp there (" ++ move_key_name ++ ": mv)",
        .remote => "can't copy into an ssh session yet",
        .window => if (alreadyIn(path, t.dest()))
            std.fmt.bufPrint(buf, "{s} is already in {s}", .{ std.fs.path.basename(path), std.fs.path.basename(t.dest()) }) catch ""
        else if (w != null and !w.?.atPrompt())
            std.fmt.bufPrint(buf, "#{d}: the shell is busy", .{w.?.serial}) catch ""
        else
            std.fmt.bufPrint(buf, "drop: {s} into {s} in #{d}{s}", .{
                if (c.gtty_drag_move_key()) "mv" else "cp",
                if (t.len > 0) std.fs.path.basename(t.dest()) else ".",
                if (w) |jw| jw.serial else 0,
                if (c.gtty_drag_move_key()) "" else "  (" ++ move_key_name ++ ": mv)",
            }) catch "",
    };
}

const move_key_name = if (builtin.os.tag == .macos) "⌘" else "Shift";

/// Each frame: gtty's own drag (a file from one job window) dropped on a
/// job window → `cp -i -- '<file>' <folder>` typed into its shell (`mv -i`
/// with the move key: ⌘ on macOS, Shift on Linux), not run: the window
/// takes the keyboard, Enter runs it. The drag ended elsewhere → forgotten.
fn tickInsideDrop(app: *App) void {
    const d = app.inside_drop orelse return;
    var move = false;
    if (!c.gtty_drag_take_drop(&move)) {
        // Still dragging (it left the window), or ended outside gtty.
        if (!c.gtty_drag_active() or c.SDL_GetTicks() -| d.ms > 2000) app.inside_drop = null;
        return;
    }
    app.inside_drop = null;
    const path = app.drag_path orelse return;
    const t = d.target;
    switch (t.kind) {
        .none => app.say("drop on a job window to cp the file there", app.theme.dim),
        .remote => {
            beep.beep();
            app.say("copying into an ssh session isn't there yet", app.theme.stderr_accent);
        },
        .window => {
            if (alreadyIn(path, t.dest())) {
                return app.sayFmt("{s} is already in {s}", .{ std.fs.path.basename(path), std.fs.path.basename(t.dest()) }, app.theme.dim);
            }
            const w = app.jobByUid(t.window) orelse return;
            if (w.sync == .follower) return app.readOnly(w);
            if (!w.atPrompt()) {
                beep.beep();
                return app.sayFmt("#{d}: the shell is busy", .{w.serial}, app.theme.stderr_accent);
            }
            // The command typed into the shell shows what happened: no
            // effect on the window.
            w.typeFileCommand(if (move) "mv" else "cp", path, if (t.outlined) t.dest() else null);
            _ = c.SDL_RaiseWindow(app.window);
            if (app.indexOfWindow(w)) |i| app.setFocus(i);
            app.sayFmt("Enter: {s} {s}", .{ if (move) "mv" else "cp", std.fs.path.basename(path) }, app.theme.dim);
        },
    }
}

/// Drop mode on / off: the file opener outlines folders only, and the
/// window under the mouse looks again.
fn dropMode(app: *App, on: bool) void {
    app.dropping = on;
    FileOpener.drop_mode = on;
    if (app.hoverWindow()) |w| {
        _ = w.opener.clear();
    }
    app.sendHover();
    app.dirty = true;
}

const DropTarget = union(enum) { none, remote, folder: []const u8 };

/// Where a drop at the mouse goes: the outlined folder name under it, else
/// the folder of the job window there.
fn dropTarget(app: *App, buf: []u8) DropTarget {
    const pt = app.mouse orelse return .none;
    const i = app.windowAt(pt[0], pt[1]) orelse return .none;
    const w = app.jobs.items[i];
    var rbuf: [4096]u8 = undefined;
    if (w.remoteNow(&rbuf) != null) return .remote;
    if (w.fileMarkAt(pt[0], pt[1])) |m| if (m.folder and !m.remote) {
        const n = @min(m.len, buf.len);
        @memcpy(buf[0..n], m.buf[0..n]);
        return .{ .folder = buf[0..n] };
    };
    const d = w.folder(buf);
    return if (d.len > 0) .{ .folder = d } else .none;
}

/// What the open modal's answer is for. A job owns its data until
/// `resolveModal` (or `closeModal`) frees it.
const ModalJob = union(enum) {
    none,
    /// Files dropped in from another app: copy them into `dest` (window
    /// `window`)? Buttons: 0 Cancel, 1 Copy.
    copy_drop: struct { paths: [][:0]u8, dest: [:0]u8, window: ids_mod.Id },
    /// Paste gtty's file clipboard into `dest` (copy, or move after a
    /// cut)? 0 Cancel, 1 Copy / Move.
    paste: struct { dest: [:0]u8, window: ids_mod.Id },
    /// Delete `paths` for good? 0 Cancel, 1 Delete.
    delete: struct { paths: [][:0]u8, window: ids_mod.Id },
    /// Rename `path` to the field's text? 0 Cancel, 1 Rename.
    rename: struct { path: [:0]u8, window: ids_mod.Id },

    /// The window it is about.
    fn window(j: ModalJob) ?ids_mod.Id {
        return switch (j) {
            .none => null,
            inline else => |d| d.window,
        };
    }
};

/// Free what a modal's job owns.
fn freeModalJob(app: *App, job: ModalJob) void {
    switch (job) {
        .none => {},
        .copy_drop => |d| {
            app.freePaths(d.paths);
            app.gpa.free(d.dest);
        },
        .paste => |d| app.gpa.free(d.dest),
        .delete => |d| app.freePaths(d.paths),
        .rename => |d| app.gpa.free(d.path),
    }
}

/// Open a modal for `job` (one at a time: one already open gets its safe
/// answer first).
fn openModal(app: *App, spec: Modal.Spec, job: ModalJob) void {
    if (app.modal) |m| app.resolveModal(m.safe, .replaced);
    app.closeMenu();
    app.closePeek();
    app.hideTip();
    app.modal = Modal.init(spec, c.SDL_GetTicks());
    app.modal_job = job;
    app.dirty = true;
}

/// How the modal's answer came: picked, no answer in time, or a newer
/// modal took its place.
const ModalHow = enum { picked, timeout, replaced };

/// Act on the modal's answer (button `pick`) and close it.
fn resolveModal(app: *App, pick: usize, how: ModalHow) void {
    const job = app.modal_job;
    // A rename with a bad name stays open (the dialog says why).
    if (job == .rename and pick == 1 and how == .picked and !app.doRename(job.rename.path, job.rename.window)) {
        app.dirty = true;
        return;
    }
    app.modal = null;
    app.modal_job = .none;
    app.dirty = true;
    defer app.freeModalJob(job);
    switch (job) {
        .none, .rename => {},
        .paste => |d| {
            if (pick != 1) return app.cancelled(if (app.file_clip_move) "move" else "copy", how);
            const move = app.file_clip_move;
            app.startFileOp(if (move) .move else .copy, app.file_clip.items, d.dest, d.window);
            // Moved: the clipboard is done with (a copy can be pasted again).
            if (move) {
                for (app.file_clip.items) |p| app.gpa.free(p);
                app.file_clip.clearRetainingCapacity();
            }
        },
        .delete => |d| {
            if (pick != 1) return app.cancelled("delete", how);
            app.clearFileSel();
            app.startFileOp(.remove, d.paths, "", d.window);
        },
        .copy_drop => |d| {
            if (pick == 1) return app.startCopy(d.paths, d.dest, d.window);
            const text = switch (how) {
                .picked => "copy cancelled",
                .timeout => "no answer: copy cancelled",
                .replaced => "another drop came: copy cancelled",
            };
            app.say(text, app.theme.dim); // nothing done: no effect on the window
        },
    }
}

/// Files changed (a file action ended): every window looks for its
/// outlined name again (a deleted one loses its outline).
fn filesChanged(app: *App) void {
    for (app.jobs.items) |w| _ = w.opener.clear();
    app.sendHover();
    app.dirty = true;
}

/// A file action done in gtty changed files: the window it was done in
/// lists its folder again (`JobWindow.refreshListing`, setting
/// `refresh-ls`).
fn refreshAfter(app: *App, uid: ids_mod.Id) void {
    const w = app.jobByUid(uid) orelse return;
    if (w.refreshListing()) app.dirty = true;
}

/// A file action the user said no to (or didn't answer): the status bar
/// says so; nothing on the window (nothing was done).
fn cancelled(app: *App, what: []const u8, how: ModalHow) void {
    var buf: [120]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}{s} cancelled", .{ if (how == .timeout) "no answer: " else "", what }) catch "cancelled";
    app.say(text, app.theme.dim); // nothing done: no effect on the window
}

/// Each frame while a modal is open: redraw (the countdown); no answer
/// in time → its safe button.
fn tickModal(app: *App) void {
    const m = app.modal orelse return;
    app.dirty = true;
    if (m.expired(c.SDL_GetTicks())) app.resolveModal(m.safe, .timeout);
}

/// Files dropped from another app on a job window: ask before copying
/// them into `dest` (the dropped paths are taken from `drop_paths`).
fn askCopy(app: *App, dest: []const u8) void {
    const pt = app.mouse orelse return;
    const i = app.windowAt(pt[0], pt[1]) orelse return;
    const window = app.jobs.items[i].uid;
    const dz = app.gpa.dupeZ(u8, dest) catch return;
    const paths = app.drop_paths.toOwnedSlice(app.gpa) catch {
        app.gpa.free(dz);
        return;
    };
    var tbuf: [300]u8 = undefined;
    var bbuf: [1024]u8 = undefined;
    const name = std.fs.path.basename(dest);
    const title = std.fmt.bufPrint(&tbuf, "Copy into {s}?", .{if (name.len > 0) name else "/"}) catch "Copy?";
    var what_buf: [400]u8 = undefined;
    const what = listNames(paths, &what_buf);
    var sbuf: [256]u8 = undefined;
    const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "";
    const body = std.fmt.bufPrint(&bbuf, "{s}\ninto {s}\nA name already there gets a number; nothing is overwritten.", .{ what, Menu.shortPath(&sbuf, dest, home, 60) }) catch what;
    app.openModal(.{
        .title = title,
        .body = body,
        .buttons = &.{ .{ .label = "Cancel" }, .{ .label = "Copy", .kind = .primary } },
        .default = 1,
        .safe = 0,
    }, .{ .copy_drop = .{ .paths = paths, .dest = dz, .window = window } });
}

const FileOp = enum {
    copy,
    move,
    remove,

    fn verb(op: FileOp) []const u8 {
        return switch (op) {
            .copy => "copy",
            .move => "move",
            .remove => "delete",
        };
    }
    fn ing(op: FileOp) []const u8 {
        return switch (op) {
            .copy => "copying",
            .move => "moving",
            .remove => "deleting",
        };
    }
    fn done(op: FileOp) []const u8 {
        return switch (op) {
            .copy => "copied",
            .move => "moved",
            .remove => "deleted",
        };
    }
};

/// A copy / move / delete running in the background (gtty_copy.c).
const Copying = struct {
    pid: c_int,
    n: usize,
    op: FileOp = .copy,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    /// The first item's name (the one named when only one is copied).
    item_buf: [256]u8 = undefined,
    item_len: usize = 0,
    /// Its FileFx on the window it was dropped on.
    fx: FxRef = .{},

    fn what(cp: *const Copying, buf: []u8) []const u8 {
        if (cp.n == 1) return cp.item_buf[0..cp.item_len];
        return std.fmt.bufPrint(buf, "{d} items", .{cp.n}) catch "items";
    }
};

/// Copy `paths` into folder `dest` in the background (gtty_copy: a name
/// that is there already gets a number; nothing is overwritten).
fn startCopy(app: *App, paths: []const [:0]u8, dest: []const u8, window: ids_mod.Id) void {
    app.startFileOp(.copy, paths, dest, window);
}

/// Copy / move `paths` into folder `dest`, or delete them (`dest` unused),
/// in the background (gtty_copy.c), with the window's FileFx and notices.
fn startFileOp(app: *App, op: FileOp, paths: []const [:0]u8, dest: []const u8, window: ids_mod.Id) void {
    if (paths.len == 0) return;
    const ptrs = app.gpa.alloc([*c]const u8, paths.len) catch return;
    defer app.gpa.free(ptrs);
    for (paths, 0..) |p, i| ptrs[i] = p.ptr;
    var dbuf: [4097]u8 = undefined;
    const dz = std.fmt.bufPrintZ(&dbuf, "{s}", .{dest}) catch return;
    const pid = switch (op) {
        .copy => c.gtty_copy_start(ptrs.ptr, @intCast(paths.len), dz.ptr),
        .move => c.gtty_move_start(ptrs.ptr, @intCast(paths.len), dz.ptr),
        .remove => c.gtty_remove_start(ptrs.ptr, @intCast(paths.len)),
    };
    const name = if (op == .remove) "" else std.fs.path.basename(dest);
    var fbuf: [300]u8 = undefined;
    if (pid < 0) {
        beep.beep();
        const text = std.fmt.bufPrint(&fbuf, "could not {s} {s}", .{ op.verb(), name }) catch "failed";
        app.say(text, app.theme.stderr_accent);
        return app.finishFx(app.fxOn(window, text), .failed, text);
    }
    var cp: Copying = .{ .pid = pid, .n = paths.len, .op = op };
    cp.name_len = @min(name.len, cp.name_buf.len);
    @memcpy(cp.name_buf[0..cp.name_len], name[0..cp.name_len]);
    const item = std.fs.path.basename(paths[0]);
    cp.item_len = @min(item.len, cp.item_buf.len);
    @memcpy(cp.item_buf[0..cp.item_len], item[0..cp.item_len]);
    var wbuf: [32]u8 = undefined;
    const text = (if (op == .remove)
        std.fmt.bufPrint(&fbuf, "deleting {s}…", .{cp.what(&wbuf)})
    else
        std.fmt.bufPrint(&fbuf, "{s} {s} into {s}…", .{ op.ing(), cp.what(&wbuf), name })) catch "working…";
    cp.fx = app.fxOn(window, text);
    app.copying.append(app.gpa, cp) catch {};
    app.say(text, app.theme.dim);
}

/// Each frame: copies / moves / deletes that finished say so.
fn tickCopies(app: *App) void {
    var i: usize = 0;
    while (i < app.copying.items.len) {
        const cp = app.copying.items[i];
        const r = c.gtty_copy_poll(cp.pid);
        if (r < 0) {
            i += 1;
            continue;
        }
        _ = app.copying.swapRemove(i);
        app.filesChanged();
        const name = cp.name_buf[0..cp.name_len];
        var fbuf: [300]u8 = undefined;
        var wbuf: [32]u8 = undefined;
        if (r == 0) {
            const text = (if (cp.op == .remove)
                std.fmt.bufPrint(&fbuf, "deleted {s}", .{cp.what(&wbuf)})
            else
                std.fmt.bufPrint(&fbuf, "{s} {s} into {s}", .{ cp.op.done(), cp.what(&wbuf), name })) catch "done";
            app.say(text, app.theme.ok);
            app.finishFx(cp.fx, .ok, text);
            app.refreshAfter(cp.fx.window);
        } else {
            beep.beep();
            const failed = @min(@as(usize, @intCast(r)), cp.n);
            if (failed < cp.n) app.refreshAfter(cp.fx.window); // some were done
            const text = (if (cp.op == .remove)
                std.fmt.bufPrint(&fbuf, "delete: {d} of {d} failed", .{ failed, cp.n })
            else
                std.fmt.bufPrint(&fbuf, "{s} into {s}: {d} of {d} failed", .{ cp.op.verb(), name, failed, cp.n })) catch "failed";
            app.say(text, app.theme.stderr_accent);
            app.finishFx(cp.fx, .failed, text);
        }
    }
}

/// A file dragged out of gtty: once the drag ended, look for it every
/// 100 ms for 2 s; gone (the target moved it) → say so on its window.
fn tickDragOut(app: *App) void {
    const d = &(app.drag_out orelse return);
    if (c.gtty_drag_active()) return;
    const now = c.SDL_GetTicks();
    if (d.ended_ms == 0) d.ended_ms = now;
    if (now < d.next_ms) return;
    d.next_ms = now + 100;
    const path = app.drag_path orelse {
        app.drag_out = null;
        return;
    };
    if (std.c.access(path.ptr, std.c.F_OK) != 0) {
        const uid = d.window;
        app.drag_out = null;
        const w = app.jobByUid(uid) orelse return;
        var fbuf: [200]u8 = undefined;
        const from = std.fs.path.basename(std.fs.path.dirname(path) orelse "/");
        const text = std.fmt.bufPrint(&fbuf, "moved {s} out of {s}", .{ std.fs.path.basename(path), if (from.len > 0) from else "/" }) catch "moved out";
        app.finishFx(app.newFx(w, text), .ok, text);
        app.sayFmt("{s}", .{text}, app.theme.dim);
        app.refreshAfter(uid);
        return;
    }
    if (now -| d.ended_ms > 2000) app.drag_out = null;
}

/// A FileFx on a job window: which one, and which of its effects (a
/// later one replaces it).
const FxRef = struct { window: ids_mod.Id = 0, id: u32 = 0 };

/// A FileFx (working) on window `w`.
fn newFx(app: *App, w: *JobWindow, text: []const u8) FxRef {
    const id = app.fx_next_id;
    app.fx_next_id +%= 1;
    if (app.fx_next_id == 0) app.fx_next_id = 1;
    w.file_fx = FileFx.init(id, c.SDL_GetTicks(), text);
    app.dirty = true;
    return .{ .window = w.uid, .id = id };
}

/// A FileFx (working) on job window `uid` (gone: an empty ref).
fn fxOn(app: *App, uid: ids_mod.Id, text: []const u8) FxRef {
    const w = app.jobByUid(uid) orelse return .{};
    return app.newFx(w, text);
}

fn finishFx(app: *App, ref: FxRef, state: FileFx.State, text: []const u8) void {
    const w = app.jobByUid(ref.window) orelse return;
    const f = if (w.file_fx) |*f| f else return;
    if (f.id != ref.id) return;
    f.finish(state, text, c.SDL_GetTicks());
    app.dirty = true;
}

// ------------------------------------------------------------ file actions

/// A ⌘-clicked (Ctrl-clicked on Linux) file or folder name: the window,
/// where in its text, and the file (owned).
const FileSel = struct {
    window: ids_mod.Id,
    range: Screen.TextRange,
    path: [:0]u8,
};

/// The right-click file menu's rows (`Menu.codes`).
/// The file menu's "cd <folder>": at most this many characters of the name.
const cd_label_max = 16;
const file_open = 0;
const file_open_with = 1;
const file_cd = 2;
const file_reveal = 3;
const file_rename = 4;
const file_copy = 5;
const file_cut = 6;
const file_paste = 7;
const file_trash = 8;
const file_delete = 9;
const file_copy_name = 10;

const sel_mod_name = if (builtin.os.tag == .macos) "⌘" else "Ctrl";
const file_keys = if (builtin.os.tag == .macos) struct {
    const copy = "⌘C";
    const cut = "⌘X";
    const paste = "⌘V";
    const trash = "⌘⌫";
    const delete = "⌫";
} else struct {
    const copy = "Ctrl+Shift+C";
    const cut = "Ctrl+Shift+X";
    const paste = "Ctrl+Shift+V";
    const trash = "Ctrl+Delete";
    const delete = "Delete";
};

/// The mouse "has" the file under it: it moved (or clicked) after the
/// last key. Then file shortcuts act on that name; while typing (the
/// mouse resting on a name) the keys stay the job's.
fn pointerFresh(app: *const App) bool {
    return app.last_point_ms > app.last_key_ms;
}

/// The outlined local name under the mouse, and its window.
fn markUnderMouse(app: *App) ?struct { w: *JobWindow, m: *FileOpener.Mark } {
    const pt = app.mouse orelse return null;
    const i = app.textWindowAt(pt[0], pt[1]) orelse return null;
    const w = app.jobs.items[i];
    const m = w.fileMarkAt(pt[0], pt[1]) orelse return null;
    if (m.remote) return null;
    return .{ .w = w, .m = m };
}

fn inFileSel(app: *const App, path: []const u8) ?usize {
    for (app.file_sel.items, 0..) |f, i| if (std.mem.eql(u8, f.path, path)) return i;
    return null;
}

fn clearFileSel(app: *App) void {
    if (app.file_sel.items.len == 0) return;
    for (app.file_sel.items) |f| app.gpa.free(f.path);
    app.file_sel.clearRetainingCapacity();
    app.dirty = true;
}

/// ⌘-click (Ctrl-click) on a name: add it to the selection, or take it
/// out.
fn toggleFileSel(app: *App, w: *JobWindow, m: *const FileOpener.Mark) void {
    app.dirty = true;
    if (app.inFileSel(m.file())) |i| {
        app.gpa.free(app.file_sel.orderedRemove(i).path);
    } else {
        const p = app.gpa.dupeZ(u8, m.file()) catch return;
        app.file_sel.append(app.gpa, .{ .window = w.uid, .range = m.range, .path = p }) catch app.gpa.free(p);
    }
    const n = app.file_sel.items.len;
    if (n == 0) return app.say("nothing selected", app.theme.dim);
    app.sayFmt("{d} selected  ({s}+click adds / removes; right-click one for the actions)", .{ n, sel_mod_name }, app.theme.dim);
}

/// The files an action is for: the selection when `at` (the name the
/// action was asked on) is in it or there is no such name, else just
/// `at`. Owned (free with `freePaths`); null: none.
fn fileTargets(app: *App, at: ?[]const u8) ?[][:0]u8 {
    const use_sel = app.file_sel.items.len > 0 and (at == null or app.inFileSel(at.?) != null);
    const n = if (use_sel) app.file_sel.items.len else if (at != null) @as(usize, 1) else return null;
    const out = app.gpa.alloc([:0]u8, n) catch return null;
    var k: usize = 0;
    errdefer {
        for (out[0..k]) |p| app.gpa.free(p);
        app.gpa.free(out);
    }
    if (use_sel) {
        for (app.file_sel.items) |f| {
            out[k] = app.gpa.dupeZ(u8, f.path) catch return null;
            k += 1;
        }
    } else {
        out[0] = app.gpa.dupeZ(u8, at.?) catch return null;
        k = 1;
    }
    return out;
}

fn freePaths(app: *App, paths: [][:0]u8) void {
    for (paths) |p| app.gpa.free(p);
    app.gpa.free(paths);
}

/// The names of `paths` on one line: "a.txt" or "3 items: a.txt, b.txt, …".
fn listNames(paths: []const [:0]u8, buf: []u8) []const u8 {
    if (paths.len == 1) return std.fs.path.basename(paths[0]);
    const head = std.fmt.bufPrint(buf, "{d} items: ", .{paths.len}) catch return "items";
    var n = head.len;
    for (paths, 0..) |p, k| {
        const b = std.fs.path.basename(p);
        const sep: []const u8 = if (k == 0) "" else ", ";
        if (n + sep.len + b.len + 1 > 60) {
            const more = "…";
            if (n + more.len <= buf.len) {
                @memcpy(buf[n..][0..more.len], more);
                n += more.len;
            }
            break;
        }
        @memcpy(buf[n..][0..sep.len], sep);
        n += sep.len;
        @memcpy(buf[n..][0..b.len], b);
        n += b.len;
    }
    return buf[0..n];
}

/// "notes.txt" or "3 items".
fn whatPaths(paths: []const [:0]u8, buf: []u8) []const u8 {
    if (paths.len == 1) return std.fs.path.basename(paths[0]);
    return std.fmt.bufPrint(buf, "{d} items", .{paths.len}) catch "items";
}

/// Copy (`move` false) or cut: the files go on gtty's file clipboard,
/// waiting for a paste (⌘V over a folder name or a window, or the file
/// menu's Paste). The names flash (`single`: the one name, in `w`; else
/// the ⌘-clicked ones).
fn fileClip(app: *App, paths: [][:0]u8, move: bool, w: ?*JobWindow, single: ?Screen.TextRange) void {
    app.flashTargets(paths.len, w, single);
    for (app.file_clip.items) |p| app.gpa.free(p);
    app.file_clip.clearRetainingCapacity();
    for (paths) |p| app.file_clip.append(app.gpa, p) catch app.gpa.free(p);
    app.gpa.free(paths);
    app.file_clip_move = move;
    app.clearFileSel();
    var wbuf: [32]u8 = undefined;
    var fbuf: [300]u8 = undefined;
    const text = std.fmt.bufPrint(&fbuf, "{s} {s}: select a destination, {s} pastes", .{
        if (move) "moving" else "copy",
        whatPaths(app.file_clip.items, &wbuf),
        file_keys.paste,
    }) catch "select a destination";
    app.say(text, app.theme.prompt_fg);
}

/// Copy Name (file menu) or a single click on an outlined name: the
/// names, as text, on the clipboard and the paste history (one per line
/// when several). The names flash (`single`: the one name, in `w`; else
/// the ⌘-clicked ones). Being text, it is now what Paste pastes.
fn copyNames(app: *App, paths: anytype, w: ?*JobWindow, single: ?Screen.TextRange) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(app.gpa);
    for (paths, 0..) |p, i| {
        if (i > 0) text.append(app.gpa, '\n') catch return;
        const name = std.fs.path.basename(p);
        text.appendSlice(app.gpa, if (name.len > 0) name else p) catch return;
    }
    text.append(app.gpa, 0) catch return;
    const z = text.items[0 .. text.items.len - 1 :0];
    if (z.len == 0) return;
    app.flashTargets(paths.len, w, single);
    app.clearFileSel();
    app.pushPasteHistory(z);
    _ = c.SDL_SetClipboardText(z.ptr);
    var wbuf: [32]u8 = undefined;
    var nbuf: [100]u8 = undefined;
    const what = if (paths.len == 1) Menu.oneLine(&nbuf, z, 40) else std.fmt.bufPrint(&wbuf, "{d} names", .{paths.len}) catch "names";
    app.sayFmt("copied {s}", .{what}, app.theme.ok);
}

/// An action done with no dialog (copy, cut, trash): flash the names it
/// took (`single`: the one name, in `w`; else the ⌘-clicked ones), the
/// only sign on screen that it happened.
fn flashTargets(app: *App, n: usize, w: ?*JobWindow, single: ?Screen.TextRange) void {
    if (n == 1 and single != null and w != null) w.?.flashNames(&.{single.?}) else app.flashFileSel();
    app.dirty = true;
}

/// Flash the ⌘-clicked names, on each window that has some.
fn flashFileSel(app: *App) void {
    for (app.jobs.items) |w| {
        var ranges: [16]Screen.TextRange = undefined;
        var n: usize = 0;
        for (app.file_sel.items) |f| if (f.window == w.uid and n < ranges.len) {
            ranges[n] = f.range;
            n += 1;
        };
        if (n > 0) w.flashNames(ranges[0..n]);
    }
}

/// Where a paste at the mouse goes: the folder name under it, else the
/// folder of the window there (in `buf`).
fn pasteDest(app: *App, buf: []u8) ?struct { dest: []const u8, w: *JobWindow } {
    const pt = app.mouse orelse return null;
    const i = app.textWindowAt(pt[0], pt[1]) orelse return null;
    const w = app.jobs.items[i];
    var rbuf: [4096]u8 = undefined;
    if (w.remoteNow(&rbuf) != null) return null;
    if (w.fileMarkAt(pt[0], pt[1])) |m| if (m.folder and !m.remote) {
        const n = @min(m.len, buf.len);
        @memcpy(buf[0..n], m.buf[0..n]);
        return .{ .dest = buf[0..n], .w = w };
    };
    const d = w.folder(buf);
    return if (d.len > 0) .{ .dest = d, .w = w } else null;
}

/// Paste the file clipboard into `dest`: ask first (Enter = OK, Esc /
/// no answer = nothing done).
fn askPaste(app: *App, dest: []const u8, w: *JobWindow) void {
    if (app.file_clip.items.len == 0) return;
    const move = app.file_clip_move;
    if (move) {
        const all_there = for (app.file_clip.items) |p| {
            if (!alreadyIn(p, dest)) break false;
        } else true;
        if (all_there) {
            return app.say("already in this folder: nothing to move", app.theme.dim);
        }
    }
    const dz = app.gpa.dupeZ(u8, dest) catch return;
    var tbuf: [300]u8 = undefined;
    var bbuf: [1024]u8 = undefined;
    var sbuf: [256]u8 = undefined;
    const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "";
    const name = std.fs.path.basename(dest);
    const title = std.fmt.bufPrint(&tbuf, "{s} into {s}?", .{ if (move) "Move" else "Copy", if (name.len > 0) name else "/" }) catch "Paste?";
    var lbuf: [400]u8 = undefined;
    const body = std.fmt.bufPrint(&bbuf, "{s}\ninto {s}\nA name already there gets a number; nothing is overwritten.", .{
        listNames(app.file_clip.items, &lbuf),
        Menu.shortPath(&sbuf, dest, home, 60),
    }) catch "";
    app.openModal(.{
        .title = title,
        .body = body,
        .buttons = &.{ .{ .label = "Cancel" }, .{ .label = if (move) "Move" else "Copy", .kind = .primary } },
        .default = 1,
        .safe = 0,
    }, .{ .paste = .{ .dest = dz, .window = w.uid } });
}

/// Delete for good: ask first (Enter = Delete, Esc / no answer = nothing).
fn askDelete(app: *App, paths: [][:0]u8, w: *JobWindow) void {
    var tbuf: [300]u8 = undefined;
    var bbuf: [512]u8 = undefined;
    var wbuf: [32]u8 = undefined;
    var folders = false;
    for (paths) |p| if (FileOpener.kindOf(p) == .folder) {
        folders = true;
    };
    const title = std.fmt.bufPrint(&tbuf, "Delete {s}?", .{whatPaths(paths, &wbuf)}) catch "Delete?";
    var lbuf: [400]u8 = undefined;
    const body = std.fmt.bufPrint(&bbuf, "{s}\n{s} deleted for good, not moved to the trash{s}.", .{
        listNames(paths, &lbuf),
        if (paths.len == 1) "It is" else "They are",
        if (folders) " (a folder with everything in it)" else "",
    }) catch "";
    app.openModal(.{
        .title = title,
        .body = body,
        .buttons = &.{ .{ .label = "Cancel" }, .{ .label = "Delete", .kind = .danger } },
        .default = 1,
        .safe = 0,
    }, .{ .delete = .{ .paths = paths, .window = w.uid } });
}

/// Rename: a field over the name, the name selected up to its last dot.
fn askRename(app: *App, path: []const u8, w: *JobWindow, anchor: ?Rect) void {
    const pz = app.gpa.dupeZ(u8, path) catch return;
    var tbuf: [300]u8 = undefined;
    const title = std.fmt.bufPrint(&tbuf, "Rename {s}", .{std.fs.path.basename(path)}) catch "Rename";
    app.openModal(.{
        .title = title,
        .body = "Enter renames · Esc leaves it as it is",
        .buttons = &.{ .{ .label = "Cancel" }, .{ .label = "Rename", .kind = .primary } },
        .default = 1,
        .safe = 0,
        .input = std.fs.path.basename(path),
        .select_stem = true,
        .anchor = anchor,
    }, .{ .rename = .{ .path = pz, .window = w.uid } });
}

/// The rename's new name, if it is a good one: done (true), or an error
/// shown in the dialog (false, it stays open).
fn doRename(app: *App, path: []const u8, window: ids_mod.Id) bool {
    const m = &(app.modal orelse return true);
    var nbuf: [1024]u8 = undefined;
    const name = std.mem.trim(u8, m.inputText(&nbuf), " ");
    const now = c.SDL_GetTicks();
    if (name.len == 0) {
        m.setError("a name can't be empty", now);
        return false;
    }
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        m.setError("a name can't have / in it, or be . or ..", now);
        return false;
    }
    const old = std.fs.path.basename(path);
    if (std.mem.eql(u8, name, old)) return true;
    const dir = std.fs.path.dirname(path) orelse "/";
    var tbuf: [4097]u8 = undefined;
    const to = std.fmt.bufPrintZ(&tbuf, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), name }) catch {
        m.setError("that name is too long", now);
        return false;
    };
    var st: c.struct_stat = undefined;
    // Only a change of case is the same file on a case-insensitive disk.
    if (c.lstat(to.ptr, &st) == 0 and !std.ascii.eqlIgnoreCase(name, old)) {
        var ebuf: [300]u8 = undefined;
        m.setError(std.fmt.bufPrint(&ebuf, "{s} is already there", .{name}) catch "that name is already there", now);
        return false;
    }
    var fbuf: [4097]u8 = undefined;
    const from = std.fmt.bufPrintZ(&fbuf, "{s}", .{path}) catch return true;
    var mbuf: [600]u8 = undefined;
    if (c.rename(from.ptr, to.ptr) != 0) {
        beep.beep();
        const text = std.fmt.bufPrint(&mbuf, "could not rename {s}", .{old}) catch "could not rename";
        app.say(text, app.theme.stderr_accent);
        app.finishFx(app.fxOn(window, text), .failed, text);
        return true;
    }
    app.filesChanged();
    const text = std.fmt.bufPrint(&mbuf, "renamed {s} to {s}", .{ old, name }) catch "renamed";
    app.say(text, app.theme.ok);
    app.finishFx(app.fxOn(window, text), .ok, text);
    app.refreshAfter(window);
    return true;
}

/// Move to the trash (no question: the trash gives it back).
fn fileTrash(app: *App, paths: [][:0]u8, w: *JobWindow, single: ?Screen.TextRange) void {
    defer app.freePaths(paths);
    var failed: usize = 0;
    for (paths) |p| if (c.gtty_trash(p.ptr) != 0) {
        failed += 1;
    };
    if (failed == 0) app.flashTargets(paths.len, w, single);
    if (failed < paths.len) app.refreshAfter(w.uid);
    app.clearFileSel();
    app.filesChanged();
    var wbuf: [32]u8 = undefined;
    var fbuf: [300]u8 = undefined;
    if (failed == 0) {
        const text = std.fmt.bufPrint(&fbuf, "moved {s} to the trash", .{whatPaths(paths, &wbuf)}) catch "moved to the trash";
        app.say(text, app.theme.ok); // the names flashed
    } else {
        beep.beep();
        const text = std.fmt.bufPrint(&fbuf, "trash: {d} of {d} failed", .{ failed, paths.len }) catch "trash failed";
        app.say(text, app.theme.stderr_accent);
        app.finishFx(app.newFx(w, text), .failed, text);
    }
}

/// File shortcuts while the mouse has a name (`pointerFresh`) or names
/// are selected: ⌘X cut, F2 rename, ⌫ / Delete delete (asks), ⌘⌫ (Linux
/// Ctrl+Delete) to the trash. ⌘C / ⌘V: in copySelection / pasteKey.
/// True: the key was used.
fn fileKey(app: *App, key: c.SDL_Keycode, ctrl: bool, cmd: bool, alt: bool, shift: bool) bool {
    if (!FileOpener.enabled or !app.pointerFresh()) return false;
    const under = app.markUnderMouse();
    if (under == null and app.file_sel.items.len == 0) return false;
    const w = if (under) |u| u.w else app.jobByUid(app.file_sel.items[0].window) orelse return false;
    const at: ?[]const u8 = if (under) |u| u.m.file() else null;
    const trash_key = if (builtin.os.tag == .macos) key == c.SDLK_BACKSPACE and cmd and !ctrl and !alt else key == c.SDLK_DELETE and ctrl and !shift and !alt;
    const plain = !ctrl and !cmd and !alt;
    if (trash_key) {
        if (!c.gtty_trash_supported()) return false;
        const paths = app.fileTargets(at) orelse return false;
        app.fileTrash(paths, w, if (under) |u| u.m.range else null);
        return true;
    }
    if (key == c.SDLK_X and (cmd or (ctrl and shift))) {
        const paths = app.fileTargets(at) orelse return false;
        app.fileClip(paths, true, w, if (under) |u| u.m.range else null);
        return true;
    }
    if (key == c.SDLK_F2 and plain and !shift) {
        const u = under orelse return false;
        var rects: [8]Rect = undefined;
        const rs = u.w.rangeRects(u.m.range, &rects);
        app.askRename(u.m.file(), u.w, if (rs.len > 0) rs[0] else null);
        return true;
    }
    if ((key == c.SDLK_BACKSPACE or key == c.SDLK_DELETE) and plain and !shift) {
        const paths = app.fileTargets(at) orelse return false;
        app.askDelete(paths, w);
        return true;
    }
    return false;
}

/// ⌘C with no text selected: copy the selected names, or the one the
/// mouse has. True: done.
fn fileCopyKey(app: *App) bool {
    if (!FileOpener.enabled or app.hasSelection()) return false;
    const under = app.markUnderMouse();
    if (app.file_sel.items.len == 0 and (under == null or !app.pointerFresh())) return false;
    const at: ?[]const u8 = if (under) |u| u.m.file() else null;
    const paths = app.fileTargets(at) orelse return false;
    const w = if (under) |u| u.w else app.jobByUid(app.file_sel.items[0].window);
    app.fileClip(paths, false, w, if (under) |u| u.m.range else null);
    return true;
}

/// ⌘V with files on gtty's file clipboard and the mouse on a window's
/// text: paste them there (asks). True: done.
fn filePasteKey(app: *App) bool {
    if (app.file_clip.items.len == 0 or !app.pointerFresh()) return false;
    var buf: [4096]u8 = undefined;
    const d = app.pasteDest(&buf) orelse return false;
    app.askPaste(d.dest, d.w);
    return true;
}

/// Right click on an outlined local name: the file menu (for the
/// selection when the name is in it). False: not on such a name.
fn openFileMenu(app: *App, x: f32, y: f32) bool {
    if (!FileOpener.enabled) return false;
    const i = app.textWindowAt(x, y) orelse return false;
    const w = app.jobs.items[i];
    const m = w.fileMarkAt(x, y) orelse return false;
    if (m.remote) return false;
    const paths = app.fileTargets(m.file()) orelse return false;
    app.closeMenu();
    app.freeMenuFiles();
    // Where Paste goes: into the folder clicked, else the window's folder.
    var dbuf: [4096]u8 = undefined;
    const dest = if (m.folder) m.file() else w.folder(&dbuf);
    app.menu_dest = app.gpa.dupeZ(u8, dest) catch null;
    var rects: [8]Rect = undefined;
    const rs = w.rangeRects(m.range, &rects);
    app.menu_anchor = if (rs.len > 0) rs[0] else null;
    app.menu_range = m.range;
    app.menu_files = paths;
    const one = paths.len == 1;
    const folder = one and FileOpener.kindOf(paths[0]) == .folder;
    var menu: Menu = .{ .purpose = .{ .files = w.uid }, .at = .{ x, y } };
    // No title: the menu opens at the name it is about.
    if (one and !folder) {
        // One row: "Open with <default app>" (its icon; ▸ the other apps
        // and Other…), or, with no default app, "Open With…" (a click:
        // the system's app chooser).
        _ = app.loadPicker(paths[0]);
        if (app.pickerDefault()) |d| {
            const a = &app.picker_apps[d];
            const label = std.fmt.bufPrint(&app.open_label, "Open with {s}", .{std.mem.sliceTo(&a.name, 0)}) catch "Open";
            menu.addCode(.{ .label = label, .icon = app.picker_icons[d], .sub = true, .sub_on = true }, file_open);
        } else {
            menu.addCode(.{ .label = "Open With…" }, file_open_with);
        }
    }
    if (folder) {
        // "cd <the folder's name>", a long name cut with ….
        var nbuf: [cd_label_max * 4 + 4]u8 = undefined;
        const name = Menu.oneLine(&nbuf, std.fs.path.basename(paths[0]), cd_label_max);
        const label = std.fmt.bufPrint(&app.menu_cd_label, "cd {s}", .{name}) catch "cd";
        menu.addCode(.{ .label = label, .enabled = w.atPrompt() and w.sync != .follower }, file_cd);
        menu.addCode(.{ .label = if (builtin.os.tag == .macos) "Open in Finder" else "Open in Files" }, file_reveal);
    }
    menu.addCode(.{ .label = "Rename…", .key = "F2", .enabled = one }, file_rename);
    menu.addCode(.{ .label = "Copy", .key = file_keys.copy }, file_copy);
    menu.addCode(.{ .label = if (one) "Copy Name" else "Copy Names" }, file_copy_name);
    menu.addCode(.{ .label = "Cut", .key = file_keys.cut }, file_cut);
    // Paste: what was copied last. Files go into the folder clicked (else
    // the window's); text is typed into the window's job.
    const paste_ok = if (app.file_clip.items.len > 0)
        app.menu_dest != null
    else
        w.running() and w.sync != .follower and c.SDL_HasClipboardText();
    menu.addCode(.{ .label = "Paste", .key = file_keys.paste, .enabled = paste_ok }, file_paste);
    if (c.gtty_trash_supported()) menu.addCode(.{ .label = "Move to Trash", .key = file_keys.trash }, file_trash);
    menu.addCode(.{ .label = "Delete…", .key = file_keys.delete }, file_delete);
    app.popMenu(menu);
    return true;
}

fn freeMenuFiles(app: *App) void {
    if (app.menu_files) |p| app.freePaths(p);
    app.menu_files = null;
    if (app.menu_dest) |d| app.gpa.free(d);
    app.menu_dest = null;
}

/// A row of the file menu.
fn fileMenuPick(app: *App, uid: ids_mod.Id, code: i32) void {
    const paths = app.menu_files orelse return;
    app.menu_files = null; // taken over here
    const w = app.jobByUid(uid) orelse return app.freePaths(paths);
    switch (code) {
        file_open => {
            defer app.freePaths(paths);
            app.execGtty(.{ .show = .{ .path = paths[0], .pick = false } });
        },
        // No default app: the system's app chooser.
        file_open_with => {
            defer app.freePaths(paths);
            app.chooseApp(paths[0]);
        },
        file_cd => {
            defer app.freePaths(paths);
            if (w.atPrompt()) w.cdTo(paths[0]);
        },
        file_reveal => {
            defer app.freePaths(paths);
            if (c.getenv("GTTY_SHOW_DRY") != null) return app.sayFmt("would open {s}", .{paths[0]}, app.theme.dim);
            if (c.gtty_open_with(paths[0].ptr, null) != 0) {
                beep.beep();
                app.say("could not open the folder", app.theme.stderr_accent);
            }
        },
        file_rename => {
            defer app.freePaths(paths);
            app.askRename(paths[0], w, app.menu_anchor);
        },
        file_copy, file_cut => app.fileClip(paths, code == file_cut, w, app.menu_range),
        file_copy_name => {
            defer app.freePaths(paths);
            app.copyNames(paths, w, app.menu_range);
        },
        file_paste => {
            defer app.freePaths(paths);
            if (app.file_clip.items.len > 0) {
                if (app.menu_dest) |d| app.askPaste(d, w);
            } else if (w.running()) app.pasteInto(w);
        },
        file_trash => app.fileTrash(paths, w, app.menu_range),
        file_delete => app.askDelete(paths, w),
        else => app.freePaths(paths),
    }
}

/// The ⌘-clicked names: a light box over each (windows area only).
fn drawFileSel(app: *App) void {
    for (app.file_sel.items) |f| {
        const w = app.jobByUid(f.window) orelse continue;
        const i = app.indexOfWindow(w) orelse continue;
        if (!app.isShown(i) or w.anim_from != null or w.grid_r != null) continue;
        if (app.maximizedShown()) |m| if (m != i) continue;
        var rects: [8]Rect = undefined;
        app.gfx.clip(w.out_r);
        defer app.gfx.clip(null);
        for (w.rangeRects(f.range, &rects)) |r| {
            app.gfx.fillAlpha(r, app.theme.focus, 70);
            app.gfx.outline(r, app.theme.focus, @max(@round(app.scale.ui), 1));
        }
    }
}

/// The status line while files wait on gtty's file clipboard.
fn clipHelp(app: *App, buf: []u8) []const u8 {
    if (app.file_clip.items.len == 0) return "";
    var wbuf: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {s}: {s} over a folder name or a window pastes there", .{
        if (app.file_clip_move) "moving" else "copy",
        whatPaths(app.file_clip.items, &wbuf),
        file_keys.paste,
    }) catch "";
}

/// Folder coloring turned on / off (settings): new output follows; off
/// also takes the blue off the names already colored.
fn setColorFolders(app: *App, on: bool) void {
    JobWindow.color_folders = on;
    if (!on) for (app.jobs.items) |w| w.out.clearNames();
    app.dirty = true;
}

/// The file opener turned on / off (settings): every window drops its
/// outline.
fn setFileOpener(app: *App, on: bool) void {
    FileOpener.enabled = on;
    if (!on) for (app.jobs.items) |w| {
        _ = w.opener.reset();
    };
    app.sendHover();
    app.dirty = true;
}

/// Each frame: the "can't connect" notice; the copy in progress.
fn tickRemote(app: *App) void {
    for (app.jobs.items) |w| {
        // gtty can't reach that machine: say once that the remote helpers
        // are off for this session.
        if (w.link_off and !w.link_off_said) {
            w.link_off_said = true;
            app.sayFmt("can't connect to {s}: file opener and git chip off until this ssh session ends", .{w.remoteDest()}, app.theme.stderr_accent);
        }
    }
    app.tickFetch();
}

/// A remote file being copied to a read-only local copy.
const Fetching = struct {
    window: ids_mod.Id,
    /// The user's ssh it came through: when that session ends, the copy
    /// stops (and its files go).
    link_pid: c_int,
    pick: bool,
    job: RemoteLink.Fetch,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    dest_buf: [128]u8 = undefined,
    dest_len: usize = 0,
    /// The modal and its Cancel button (screen pixels; set when drawn).
    box: Rect = .{},
    cancel_r: Rect = .{},
};

/// The file opener asks: copy remote `path` of window `w`'s session, then
/// open the copy (`show`, or `show -a` with `pick`).
fn fetchRemote(app: *App, w: *JobWindow, rpath: []const u8, pick: bool) void {
    if (app.fetch != null) {
        beep.beep();
        return app.say("a copy is already running", app.theme.stderr_accent);
    }
    const id = w.uid;
    var lbuf: [4400]u8 = undefined;
    const local = w.newCopyPath(&lbuf, rpath) orelse {
        beep.beep();
        return app.say("copy: no temp folder", app.theme.stderr_accent);
    };
    var argv: [64][]const u8 = undefined;
    const job = RemoteLink.Fetch.start(app.gpa, w.linkSpec(&argv), rpath, local) catch |e| {
        beep.beep();
        return app.sayFmt("copy: could not start ({s})", .{@errorName(e)}, app.theme.stderr_accent);
    };
    var f: Fetching = .{ .window = id, .link_pid = w.link_pid, .pick = pick, .job = job };
    const name = std.fs.path.basename(rpath);
    f.name_len = @min(name.len, f.name_buf.len);
    @memcpy(f.name_buf[0..f.name_len], name[0..f.name_len]);
    const dest = w.remoteDest();
    f.dest_len = @min(dest.len, f.dest_buf.len);
    @memcpy(f.dest_buf[0..f.dest_len], dest[0..f.dest_len]);
    app.fetch = f;
    app.dirty = true;
}

fn tickFetch(app: *App) void {
    const f = if (app.fetch) |*f| f else return;
    app.dirty = true; // the modal: progress, the sliding block
    // The session (or the window) went away: stop.
    const w = app.jobByUid(f.window);
    if (w == null or w.?.link_pid != f.link_pid) return app.cancelFetch("copy stopped: the ssh session ended");
    if (!f.job.poll()) return;
    app.dirty = true;
    switch (f.job.state) {
        .running => {},
        .done => {
            const pick = f.pick;
            var buf: [4400]u8 = undefined;
            const local = std.fmt.bufPrint(&buf, "{s}", .{f.job.local}) catch return;
            f.job.deinit(app.gpa);
            app.fetch = null;
            app.execGtty(.{ .show = .{ .path = local, .pick = pick } });
        },
        .failed => {
            beep.beep();
            app.sayFmt("could not copy {s} from {s}", .{ f.name_buf[0..f.name_len], f.dest_buf[0..f.dest_len] }, app.theme.stderr_accent);
            f.job.deinit(app.gpa);
            app.fetch = null;
        },
    }
}

/// Stop the copy, delete what came so far, say why.
fn cancelFetch(app: *App, why: []const u8) void {
    var f = app.fetch orelse return;
    f.job.deinit(app.gpa);
    app.fetch = null;
    app.say(why, app.theme.dim);
    app.dirty = true;
}

/// The copy's modal, centered over its job window (or the windows area
/// when the window isn't there): title, file, progress bar, Cancel.
fn drawFetch(app: *App) void {
    const f = if (app.fetch) |*f| f else return;
    const t = &app.theme;
    const ui = app.scale.ui;
    const font, _ = app.promptFaces();
    const sf = app.statusFace();
    var area = app.desktop_r;
    if (app.jobByUid(f.window)) |w| if (app.indexOfWindow(w)) |i| if (app.isShown(i)) {
        area = w.rect;
    };
    const pad = @round(14 * ui);
    const bw = @min(area.w - 2 * pad, @round(440 * ui));
    const title_h = @round(sf.cell_h * 1.8);
    const bh = title_h + pad + font.cell_h + pad * 0.8 + @round(8 * ui) + pad * 0.6 + sf.cell_h + pad + @round(font.cell_h * 1.6) + pad;
    const box: Rect = .{ .x = @round(area.x + (area.w - bw) / 2), .y = @round(area.y + (area.h - bh) / 2), .w = bw, .h = bh };
    f.box = box;
    app.gfx.fill(.{ .x = box.x + @round(3 * ui), .y = box.y + @round(4 * ui), .w = box.w, .h = box.h }, t.desktop); // shadow
    app.gfx.fill(box, t.bg);
    app.gfx.fill(.{ .x = box.x, .y = box.y, .w = box.w, .h = title_h }, t.title_bg);
    app.gfx.outline(box, t.focus, @max(@round(ui), 1));
    var tbuf: [200]u8 = undefined;
    const title = std.fmt.bufPrint(&tbuf, "Copying from {s}", .{f.dest_buf[0..f.dest_len]}) catch "Copying";
    app.gfx.clip(box);
    defer app.gfx.clip(null);
    _ = app.gfx.text(sf, box.x + pad, box.y + @round((title_h - sf.cell_h) / 2), title, t.title_fg);
    var y = box.y + title_h + pad;
    _ = app.gfx.text(font, box.x + pad, y, f.name_buf[0..f.name_len], t.prompt_fg);
    y += font.cell_h + pad * 0.8;
    // Progress bar (full width; unknown size: a sliding block).
    const bar: Rect = .{ .x = box.x + pad, .y = y, .w = box.w - 2 * pad, .h = @round(8 * ui) };
    app.gfx.fill(bar, t.prompt_bg);
    if (f.job.size) |size| {
        const frac: f32 = if (size == 0) 1 else @as(f32, @floatFromInt(f.job.got)) / @as(f32, @floatFromInt(size));
        app.gfx.fill(.{ .x = bar.x, .y = bar.y, .w = @round(bar.w * @min(frac, 1)), .h = bar.h }, t.focus);
    } else {
        const phase: f32 = @floatFromInt(c.SDL_GetTicks() % 1200);
        const bx = bar.x + (bar.w * 0.75) * (phase / 1200);
        app.gfx.fill(.{ .x = bx, .y = bar.y, .w = bar.w * 0.25, .h = bar.h }, t.focus);
    }
    y += bar.h + pad * 0.6;
    var pbuf: [96]u8 = undefined;
    var g1: [24]u8 = undefined;
    var g2: [24]u8 = undefined;
    const progress = if (f.job.size) |size|
        std.fmt.bufPrint(&pbuf, "{s} of {s}  ·  a read-only copy", .{ humanBytes(&g1, f.job.got), humanBytes(&g2, size) }) catch ""
    else
        "starting…";
    _ = app.gfx.text(sf, box.x + pad, y, progress, t.dim);
    y += sf.cell_h + pad;
    const label = "Cancel";
    const btn_w = Gfx.textWidth(font, label) + 2 * pad;
    const btn: Rect = .{ .x = box.x + box.w - pad - btn_w, .y = y, .w = btn_w, .h = @round(font.cell_h * 1.6) };
    f.cancel_r = btn;
    const over = if (app.mouse) |m| btn.contains(m[0], m[1]) else false;
    app.gfx.fill(btn, if (over) t.title_bg.mix(t.focus, 0.3) else t.title_bg);
    app.gfx.outline(btn, t.divider, @max(@round(ui), 1));
    _ = app.gfx.text(font, btn.x + pad, btn.y + @round((btn.h - font.cell_h) / 2), label, t.title_fg);
    _ = app.gfx.text(sf, box.x + pad, btn.y + @round((btn.h - sf.cell_h) / 2), "Esc cancels", t.dim);
}

fn humanBytes(buf: []u8, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    return (if (n < 1024)
        std.fmt.bufPrint(buf, "{d} B", .{n})
    else if (n < 1024 * 1024)
        std.fmt.bufPrint(buf, "{d:.1} KB", .{f / 1024})
    else if (n < 1024 * 1024 * 1024)
        std.fmt.bufPrint(buf, "{d:.1} MB", .{f / (1024 * 1024)})
    else
        std.fmt.bufPrint(buf, "{d:.2} GB", .{f / (1024 * 1024 * 1024)})) catch "?";
}

/// Mouse over a git chip (null: over none, or over the peek): start the
/// timer that opens its peek; leaving the chip stops it.
fn hoverChip(app: *App, pt: ?[2]f32) void {
    const now: ?Tip = blk: {
        const p = pt orelse break :blk null;
        const i = app.windowAt(p[0], p[1]) orelse break :blk null;
        const w = app.jobs.items[i];
        const part = w.hit(p[0], p[1]);
        if (part != .git_chip and part != .folder_chip) break :blk null;
        const kind: Peek.Kind = if (part == .folder_chip) .folder else .git;
        if (app.peek) |pk| if (pk.uid == w.uid and pk.kind == kind) break :blk null;
        break :blk .{ .uid = w.uid, .hit = part, .since = c.SDL_GetTicks() };
    };
    if (app.chip_hover) |h| if (now) |n| if (h.uid == n.uid and h.hit == n.hit) return;
    app.chip_hover = now;
}

/// The window under the mouse, as a click would find it.
fn windowAt(app: *App, x: f32, y: f32) ?usize {
    if (app.maximizedShown()) |m| return if (app.jobs.items[m].hit(x, y) != .none) m else null;
    if (app.grid_head_r.contains(x, y)) return null;
    const in_grid = app.grid_r.contains(x, y);
    for (app.jobs.items, 0..) |w, i| {
        const here = if (app.isShown(i)) !in_grid else in_grid;
        if (here and w.hit(x, y) != .none) return i;
    }
    return null;
}

/// Over a title-bar action with a tooltip: start (or keep) its timer;
/// anywhere else: no tooltip.
fn updateTip(app: *App, x: f32, y: f32) void {
    const now: ?Tip = blk: {
        const i = app.windowAt(x, y) orelse break :blk null;
        const w = app.jobs.items[i];
        const h = w.hit(x, y);
        if (w.kill_menu or w.tip(h) == null) break :blk null;
        break :blk .{ .uid = w.uid, .hit = h, .since = c.SDL_GetTicks() };
    };
    if (app.tip) |t| if (now) |n| if (t.uid == n.uid and t.hit == n.hit) return;
    app.hideTip();
    app.tip = now;
}

fn hideTip(app: *App) void {
    if (app.tip_drawn) app.dirty = true;
    app.tip = null;
    app.tip_drawn = false;
}

/// The tooltip box under its button (above it if there is no room),
/// kept on screen.
fn drawTip(app: *App) void {
    const t = app.tip orelse return;
    if (c.SDL_GetTicks() -| t.since < app.tip_delay_ms) return;
    const w = for (app.jobs.items) |j| {
        if (j.uid == t.uid) break j;
    } else return;
    if (w.anim_from != null) return;
    const tp = w.tip(t.hit) orelse return;
    const ui = app.scale.ui;
    const f = app.statusFace();
    const pad = @round(6 * ui);
    const bw = Gfx.textWidth(f, tp.text) + 2 * pad;
    const bh = f.cell_h + pad;
    const gap = @round(4 * ui);
    var bx = tp.r.x;
    var by = tp.r.y + tp.r.h + gap;
    if (by + bh > app.height_px) by = tp.r.y - gap - bh;
    bx = @max(@min(bx, app.width_px - bw - gap), gap);
    const box: Gfx.Rect = .{ .x = bx, .y = by, .w = bw, .h = bh };
    app.gfx.fill(box, app.theme.prompt_bg);
    app.gfx.outline(box, app.theme.divider, 1 * ui);
    _ = app.gfx.text(f, bx + pad, by + pad / 2, tp.text, app.theme.prompt_fg);
    app.tip_drawn = true;
}

// ------------------------------------------------------------ link hover

const LinkHover = struct {
    window: ids_mod.Id,
    range: Screen.TextRange,
    target: [4096]u8 = undefined,
    target_len: usize = 0,
    folder: bool,
    broken: bool,
    since: u64,
    /// Where the box was drawn (null: not shown yet).
    box: ?Rect = null,
    /// The mouse left the name and the box (0: it is on one): the box
    /// stays `link_grace_ms` more, time to reach it.
    leave_ms: u64 = 0,

    fn targetPath(h: *const LinkHover) []const u8 {
        return h.target[0..h.target_len];
    }

    /// The folder a click cd's to: the target itself when it is a
    /// folder, else the one the target is in.
    fn cdDir(h: *const LinkHover) []const u8 {
        if (h.folder and !h.broken) return h.targetPath();
        return std.fs.path.dirname(h.targetPath()) orelse "/";
    }
};

/// How long a shown link box waits for the mouse after it left the name
/// (on its way to the box, over the gap or other names).
const link_grace_ms: u64 = 1500;

/// Mouse moved: the link name under it (a new one starts the delay), or
/// the box itself keeps it. A shown box the mouse left stays
/// `link_grace_ms` (`tickLinkHover` hides it); one not shown yet goes.
fn updateLinkHover(app: *App, x: f32, y: f32, blocked: bool) void {
    if (app.link_hover) |*h| if (h.box) |b| {
        // The box, with the arrow's gap around it.
        const m = @round(10 * app.scale.ui);
        if (x >= b.x - m and x < b.x + b.w + m and y >= b.y - m and y < b.y + b.h + m) {
            h.leave_ms = 0;
            return;
        }
    };
    const found: ?struct { w: *JobWindow, l: *const JobWindow.Link } = blk: {
        if (blocked or app.modal != null or app.peek != null) break :blk null;
        const i = app.textWindowAt(x, y) orelse break :blk null;
        if (!app.isShown(i)) break :blk null;
        const w = app.jobs.items[i];
        const l = w.linkAt(x, y) orelse break :blk null;
        break :blk .{ .w = w, .l = l };
    };
    if (app.link_hover) |*h| {
        const same = if (found) |f| h.window == f.w.uid and std.meta.eql(h.range, f.l.range) else false;
        if (same) {
            h.leave_ms = 0;
            return;
        }
        // Shown: give the mouse time to reach it (another name on the
        // way doesn't take over).
        if (h.box != null and !blocked) {
            if (h.leave_ms == 0) h.leave_ms = c.SDL_GetTicks();
            return;
        }
    }
    const f = found orelse return app.hideLinkHover();
    app.hideLinkHover();
    var h: LinkHover = .{ .window = f.w.uid, .range = f.l.range, .folder = f.l.folder, .broken = f.l.broken, .since = c.SDL_GetTicks() };
    h.target_len = @min(f.l.target.len, h.target.len);
    @memcpy(h.target[0..h.target_len], f.l.target[0..h.target_len]);
    app.link_hover = h;
}

/// Each frame: a shown box the mouse left long enough ago goes (the
/// mouse may be over another link name by then: that one starts).
fn tickLinkHover(app: *App) void {
    const h = app.link_hover orelse return;
    if (h.leave_ms == 0 or c.SDL_GetTicks() -| h.leave_ms < link_grace_ms) return;
    app.hideLinkHover();
    if (app.mouse) |pt| app.updateLinkHover(pt[0], pt[1], false);
}

fn hideLinkHover(app: *App) void {
    if (app.link_hover) |h| if (h.box != null) {
        app.dirty = true;
    };
    app.link_hover = null;
}

/// A click on the link box: cd to the folder the target is in (the shell
/// at its prompt), else say why not.
fn linkHoverClick(app: *App) void {
    const h = app.link_hover orelse return;
    app.hideLinkHover();
    const w = app.jobByUid(h.window) orelse return;
    const dir = h.cdDir();
    if (w.sync == .follower) return app.readOnly(w);
    if (!w.atPrompt()) {
        beep.beep();
        return app.say("the shell is busy", app.theme.stderr_accent);
    }
    var dbuf: [4096]u8 = undefined;
    const ddir = w.folder(&dbuf);
    if (std.mem.eql(u8, std.mem.trimEnd(u8, ddir, "/"), std.mem.trimEnd(u8, dir, "/"))) {
        return app.say("already there", app.theme.dim);
    }
    w.cdTo(dir);
    if (app.indexOfWindow(w)) |i| app.setFocus(i);
    app.sayFmt("cd {s}", .{dir}, app.theme.dim);
}

/// The link box, over the name (under it when there is no room above),
/// with a small arrow pointing at it, kept inside gtty's window: the
/// name's target ("→ /real/path") and what a click does.
fn drawLinkHover(app: *App) void {
    const h = if (app.link_hover) |*hp| hp else return;
    if (c.SDL_GetTicks() -| h.since < app.tip_delay_ms) return;
    // Its window gone, moved, or the name out of view: no box.
    const w = app.jobByUid(h.window) orelse return app.hideLinkHover();
    if (w.anim_from != null or w.grid_r != null) return app.hideLinkHover();
    var rects: [8]Rect = undefined;
    const rs = w.rangeRects(h.range, &rects);
    if (rs.len == 0) return app.hideLinkHover();
    const name_r = rs[0];
    const ui = app.scale.ui;
    const f, _ = app.promptFaces();
    const small = app.statusFace();
    const pad = @round(8 * ui);
    const gap = @round(4 * ui);
    const arrow = @round(6 * ui);
    const max_w = app.width_px - 2 * gap;
    // Line 1: "→ <target>" (the start cut when too long); line 2: the hint.
    const t = app.theme;
    var lbuf: [4200]u8 = undefined;
    var target = h.targetPath();
    const head = if (h.broken) "→ (missing) " else "→ ";
    while (target.len > 1 and Gfx.textWidth(f, head) + Gfx.textWidth(f, "…") + Gfx.textWidth(f, target) + 2 * pad > max_w) {
        target = target[1..];
        while (target.len > 1 and (target[0] & 0xC0) == 0x80) target = target[1..];
    }
    const cut = target.len < h.target_len;
    const line1 = std.fmt.bufPrint(&lbuf, "{s}{s}{s}", .{ head, if (cut) "…" else "", target }) catch return;
    var sbuf: [128]u8 = undefined;
    var nbuf: [4096]u8 = undefined;
    const dir_name = std.fs.path.basename(h.cdDir());
    const busy = !w.atPrompt();
    const line2 = if (busy)
        "the shell is busy: cd when it waits at its prompt"
    else
        std.fmt.bufPrint(&sbuf, "click: cd to {s}", .{Menu.oneLine(&nbuf, if (dir_name.len > 0) dir_name else "/", 40)}) catch "click: cd there";
    const bw = @min(@max(Gfx.textWidth(f, line1), Gfx.textWidth(small, line2)) + 2 * pad, max_w);
    const bh = f.cell_h + small.cell_h + pad * 1.5;
    var above = true;
    var by = name_r.y - arrow - bh;
    if (by < gap) {
        above = false;
        by = name_r.y + name_r.h + arrow;
    }
    by = @min(by, app.height_px - bh - gap);
    const bx = @max(@min(name_r.x, app.width_px - bw - gap), gap);
    const box: Rect = .{ .x = bx, .y = by, .w = bw, .h = bh };
    const border = if (h.folder) t.focus.mix(t.link, 0.35) else t.fg.mix(t.link, 0.35);
    app.gfx.fill(box, t.prompt_bg);
    app.gfx.outline(box, border, @max(@round(1.5 * ui), 1));
    // The arrow: a small triangle from the box to the name.
    const ax = @max(@min(name_r.x + @min(name_r.w / 2, @round(12 * ui)), bx + bw - arrow * 2), bx + arrow);
    var k: f32 = 0;
    while (k < arrow) : (k += 1) {
        const half = arrow - k;
        const ly = if (above) by + bh + k else by - k - 1;
        app.gfx.fill(.{ .x = ax - half, .y = ly, .w = half * 2, .h = 1 }, border);
    }
    const target_col = if (h.broken) t.stderr_accent else if (h.folder) t.focus.mix(t.link, 0.35) else t.fg.mix(t.link, 0.35);
    app.gfx.clip(box);
    defer app.gfx.clip(null);
    const x1 = app.gfx.text(f, bx + pad, by + pad / 2, head, t.prompt_fg);
    _ = app.gfx.text(f, x1, by + pad / 2, line1[head.len..], target_col);
    _ = app.gfx.text(small, bx + pad, by + pad / 2 + f.cell_h + pad / 2, line2, if (busy) t.stderr_accent else t.dim);
    h.box = box;
}

fn onMouseLeave(app: *App) void {
    app.mouse = null;
    app.hideLinkHover();
    app.sendLeave();
    app.hideTip();
    app.chip_hover = null;
    if (app.peek) |*pk| if (pk.leave_ms == 0) {
        pk.leave_ms = c.SDL_GetTicks();
    };
    for (app.jobs.items) |w| if (w.hover(null)) {
        app.dirty = true;
    };
}

fn onWheel(app: *App, x: f32, y: f32, dy: f32) void {
    if (app.modal != null) return;
    app.closeMenu();
    if (app.peek) |*pk| if (pk.contains(x, y)) {
        pk.wheel(dy);
        app.dirty = true;
        return;
    };
    // Over the job grid: scroll it.
    if (app.grid_r.contains(x, y)) {
        app.grid_scroll -= dy * 40 * app.scale.ui;
        return app.relayout();
    }
    const w = for (app.jobs.items, 0..) |j, i| {
        if (app.isShown(i) and j.hit(x, y) != .none) break j;
    } else return;
    if (c.SDL_GetModState() & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI) != 0) {
        w.setZoom(&app.gfx, if (dy > 0) w.zoom * 1.1 else w.zoom / 1.1);
    } else {
        const lines: isize = @intFromFloat(@round(dy * 3));
        w.scrollAt(lines);
    }
    app.dirty = true;
}

// ------------------------------------------------------------ rendering

/// Windows in transition, over everything: each is drawn at its new place
/// on the canvas, then that picture is stretched to where it is on the way.
/// The one coming into the windows area is drawn last (on top).
fn drawMoving(app: *App) void {
    const now = c.SDL_GetTicks();
    const pw: c_int = @intFromFloat(@max(app.width_px, 1));
    const ph: c_int = @intFromFloat(@max(app.height_px, 1));
    if (app.anim_canvas) |cv| if (cv.*.w != pw or cv.*.h != ph) {
        c.SDL_DestroyTexture(cv);
        app.anim_canvas = null;
    };
    var order: [64]usize = undefined;
    var n: usize = 0;
    for (app.jobs.items, 0..) |w, i| if (w.anim_from != null and !app.isShown(i)) {
        order[n] = i;
        n += 1;
    };
    for (app.jobs.items, 0..) |w, i| if (w.anim_from != null and app.isShown(i)) {
        order[n] = i;
        n += 1;
    };
    for (order[0..n]) |i| {
        const w = app.jobs.items[i];
        const r = w.animRect(now) orelse {
            w.draw(&app.gfx, &app.theme); // just finished: in place
            continue;
        };
        if (app.anim_canvas == null) {
            app.anim_canvas = c.SDL_CreateTexture(app.renderer, c.SDL_PIXELFORMAT_ARGB8888, c.SDL_TEXTUREACCESS_TARGET, pw, ph);
            if (app.anim_canvas) |cv| {
                _ = c.SDL_SetTextureScaleMode(cv, c.SDL_SCALEMODE_LINEAR);
                _ = c.SDL_SetTextureBlendMode(cv, c.SDL_BLENDMODE_BLEND);
            }
        }
        const cv = app.anim_canvas orelse return w.draw(&app.gfx, &app.theme);
        _ = c.SDL_SetRenderTarget(app.renderer, cv);
        _ = c.SDL_SetRenderDrawColor(app.renderer, 0, 0, 0, 0);
        _ = c.SDL_RenderClear(app.renderer);
        // Leaving the windows area (now in the grid, coming from a bigger
        // rect): use its full-size picture, so it shrinks instead of a
        // grid cell blown up.
        const from = w.anim_from.?;
        const b = if (w.grid_r) |g| (if (from.w > g.w) w.drawFullAt(&app.gfx, &app.theme, from.x, from.y) else blk: {
            w.draw(&app.gfx, &app.theme);
            break :blk g;
        }) else blk: {
            w.draw(&app.gfx, &app.theme);
            break :blk w.rect;
        };
        _ = c.SDL_SetRenderTarget(app.renderer, null);
        const src: c.SDL_FRect = .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
        const dst: c.SDL_FRect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        _ = c.SDL_RenderTexture(app.renderer, cv, &src, &dst);
    }
}

/// The job grid's header: the title on the left, the sort button on the
/// right, a hairline under it.
fn drawGridHead(app: *App) void {
    const t = &app.theme;
    const ui = app.scale.ui;
    const h = app.grid_head_r;
    if (h.w <= 0 or h.h <= 0) return;
    app.gfx.fill(h, t.desktop);
    const f, _ = app.promptFaces();
    const ck = app.grid_check_r;
    const look: JobWindow.CheckLook = if (app.head_err_until != 0) .err else if (app.extras.items.len == 0) .off else if (app.grid_r.w > 0 and app.gridCount() > 0) .partial else .on;
    JobWindow.checkIcon(&app.gfx, ck, t, ui, look);
    _ = app.gfx.text(f, ck.x + ck.w + @round(6 * ui), h.y + @round((h.h - f.cell_h) / 2), "Jobs", t.title_fg);
    app.gfx.fill(.{ .x = h.x, .y = h.y + h.h - @max(@round(ui), 1), .w = h.w - @round(4 * ui), .h = @max(@round(ui), 1) }, t.divider);
    const b = app.grid_sort_r;
    const sf = app.statusFace();
    app.gfx.fill(b, if (app.over_grid_sort) t.title_bg.mix(t.fg, 0.12) else t.title_bg);
    const label = sort_labels[@intFromBool(app.grid_oldest_first)];
    _ = app.gfx.text(sf, b.x + @round((b.w - Gfx.textWidth(sf, label)) / 2), b.y + @round((b.h - sf.cell_h) / 2), label, t.title_fg);
}

/// The job grid's scroll bar (only when it doesn't all fit): a track with
/// the thumb, thin until the mouse is on it; blue while dragged.
fn drawGridBar(app: *App) void {
    const th = app.gridThumb() orelse return;
    const t = &app.theme;
    const r = app.grid_bar_r;
    const active = app.over_grid_bar or app.grid_drag;
    const w = if (active) r.w else @max(@round(4 * app.scale.ui), 2);
    const x = r.x + @round((r.w - w) / 2);
    app.gfx.fill(.{ .x = x, .y = r.y, .w = w, .h = r.h }, t.desktop.mix(t.divider, 0.6));
    const col = if (app.grid_drag) t.focus else if (active) t.title_fg else t.dim;
    app.gfx.fill(.{ .x = x, .y = th.y, .w = w, .h = th.h }, col);
}

fn render(app: *App) void {
    const t = &app.theme;
    app.gfx.fill(.{ .x = 0, .y = 0, .w = app.width_px, .h = app.height_px }, t.desktop);

    const f, const hf = app.promptFaces();
    if (app.jobs.items.len == 0) {
        const plain = [_][]const u8{ "gtty", "", "type a command and press Enter — it opens in its own window", "s      open your shell", "help   gtty's commands" };
        const with_ai = [_][]const u8{ "gtty", "", "say what to do, or type a command, and press Enter", "s      open your shell", "help   gtty's commands" };
        const lines = if (app.aiReady()) with_ai else plain;
        var y = app.desktop_r.y + app.desktop_r.h / 2 - f.cell_h * 3;
        for (lines, 0..) |l, i| {
            const w = Gfx.textWidth(f, l);
            _ = app.gfx.text(f, app.desktop_r.x + (app.desktop_r.w - w) / 2, y, l, if (i == 0) t.focus else t.dim);
            y += f.cell_h * 1.3;
        }
    }

    // The job grid (clipped to its area), then the current job window.
    if (app.grid_r.w > 0 and app.grid_r.h > 0) {
        app.gfx.clip(app.grid_r);
        const sf = app.statusFace();
        for (app.grid_labels, [_][]const u8{ "running", "history" }) |ly, name| {
            if (ly) |y| _ = app.gfx.text(sf, app.grid_r.x + @round(2 * app.scale.ui), y + @round(4 * app.scale.ui), name, t.dim);
        }
        for (app.jobs.items, 0..) |w, i| if (!app.isShown(i) and w.anim_from == null) w.draw(&app.gfx, t);
        app.gfx.clip(null);
        app.drawGridBar();
        app.drawGridHead();
    }
    for (app.jobs.items, 0..) |w, i| if (app.isShown(i) and !w.maximized and w.anim_from == null) w.draw(&app.gfx, t);

    if (app.help_visible) app.drawHelp(hf);
    app.drawMenuBar();

    // Prompt
    var label_buf: [96]u8 = undefined;
    var label: []const u8 = "gtty ›";
    var label_col = t.dim;
    var hint: ?[]const u8 = null;
    const ai_on = app.aiReady();
    if (app.ai_req != null) {
        const dots = [_][]const u8{ "✦ thinking   ›", "✦ thinking.  ›", "✦ thinking.. ›", "✦ thinking... ›" };
        label = dots[@intCast((c.SDL_GetTicks() / 400) % 4)];
        label_col = t.mark_ai;
        hint = "Esc cancels";
    } else if (app.ai_plan != null) {
        label = "✦ running ›";
        label_col = t.mark_ai;
        hint = "Esc stops the rest of the plan";
    } else if (ai_on) {
        label = "✦ ›";
        label_col = t.mark_ai;
        hint = "say what to do, or type a command   (!cmd runs it as typed)";
    } else {
        // Not in recorded demo frames: the README leaves the AI out for now.
        if (app.rec == null) hint = "type a command — or turn on AI in Settings → AI to ask in plain words";
    }
    const job = app.focusedJob();
    const peek_keys = if (app.peek) |pk| pk.wantsKeys() else false;
    if (peek_keys) {
        label = if (app.peek.?.kind == .folder) "typing goes to the folder filter — Esc closes it" else "typing goes to the branch filter — Esc closes it";
    } else if (job) |w| {
        label = std.fmt.bufPrint(&label_buf, "typing goes to #{d} — click here or Ctrl+Tab for the gtty prompt", .{w.serial}) catch "›";
    }
    if (job != null or peek_keys) {
        label_col = t.dim;
        hint = null;
    }
    app.prompt.draw(&app.gfx, t, f, app.scale.ui, .{
        .label = label,
        .label_color = label_col,
        .hint = hint,
        .cursor_visible = job == null and !peek_keys,
        .text_color = if (app.reject_until != 0) t.stderr_accent else null,
    });
    var help_buf: [512]u8 = undefined;
    const help = app.helpLine(&help_buf);
    StatusBar.draw(&app.gfx, app.statusFace(), app.prompt.status_r, help, t.dim, app.msg_buf[0..app.msg_len], app.msg_color);
    if (app.maximizedShown()) |m| if (app.jobs.items[m].anim_from == null) app.jobs.items[m].draw(&app.gfx, t);
    app.drawFileSel();
    app.drawLinkHover();
    app.drawFetch();
    app.drawMoving();
    // The peek over everything but tooltips (not while its window moves).
    if (app.peekWindow()) |w| if (w.anim_from == null) {
        app.layoutPeek();
        app.peek.?.draw(&app.gfx, t, f, app.statusFace(), app.scale.ui, c.SDL_GetTicks());
    };
    // The right-click menu on top (gone with its window).
    if (app.menu) |*m| {
        const alive = switch (m.purpose) {
            .edit, .paste_history => |target| switch (target) {
                .prompt => true,
                .job => |uid| app.jobByUid(uid) != null,
            },
            .folder_history, .files => |uid| app.jobByUid(uid) != null,
            .open_with, .bar => true,
        };
        if (alive) {
            m.draw(&app.gfx, t, f, app.scale.ui);
            if (app.sub_menu) |*sm| sm.draw(&app.gfx, t, f, app.scale.ui);
        } else {
            app.menu = null;
            app.sub_menu = null;
            app.freeMenuFiles();
        }
    }
    if (app.modal) |*m| {
        // Over the window it is about, when that one is in the windows area.
        var area = app.desktop_r;
        if (app.modal_job.window()) |uid| if (app.jobByUid(uid)) |w| if (app.indexOfWindow(w)) |i| if (app.isShown(i)) {
            area = w.rect;
        };
        const screen: Rect = .{ .x = 0, .y = 0, .w = app.width_px, .h = app.height_px };
        m.draw(&app.gfx, t, f, app.statusFace(), screen, area, app.mouse, app.scale.ui, c.SDL_GetTicks());
    }
    if (app.about_visible) app.drawAbout(f);
    app.drawTip();
    if (app.rec != null) {
        app.drawPointer();
        app.saveFrame();
    }

    if (app.pending_shot) |path| {
        app.saveShot(path);
        app.gpa.free(path);
        app.pending_shot = null;
    }
    _ = c.SDL_RenderPresent(app.renderer);
}

fn drawHelp(app: *App, f: *Gfx.Face) void {
    const t = &app.theme;
    const ui = app.scale.ui;
    var it = std.mem.splitScalar(u8, commands.help_text, '\n');
    var n: f32 = 0;
    var maxw: f32 = 0;
    while (it.next()) |l| {
        n += 1;
        maxw = @max(maxw, Gfx.textWidth(f, l));
    }
    const pad = @round(14 * ui);
    const w = maxw + pad * 2;
    const h = n * f.cell_h * 1.25 + pad * 2;
    const r: Rect = .{ .x = app.desktop_r.x + (app.desktop_r.w - w) / 2, .y = app.desktop_r.y + app.desktop_r.h - h - @round(12 * ui), .w = w, .h = h };
    app.gfx.fill(r, t.title_bg);
    app.gfx.outline(r, t.focus, @max(ui, 1));
    it = std.mem.splitScalar(u8, commands.help_text, '\n');
    var y = r.y + pad;
    while (it.next()) |l| {
        _ = app.gfx.text(f, r.x + pad, y, l, t.prompt_fg);
        y += f.cell_h * 1.25;
    }
}

/// What the About box and `gtty --version` say.
pub const copyright = "Copyright 2026 Sagi Forbes Nagar";
pub const license_line = "License: GPL-3.0-or-later";
// TODO: the repository doesn't exist there yet; keep in step with README.
pub const source_url = "codeberg.org/gttyterm/gtty";

/// The About box: name, version, copyright, license, source; centered
/// over a dimmed screen.
fn drawAbout(app: *App, f: *Gfx.Face) void {
    const t = &app.theme;
    const ui = app.scale.ui;
    const Line = struct { text: []const u8, col: Rgb };
    const lines = [_]Line{
        .{ .text = "gtty " ++ @import("build_options").version, .col = t.focus },
        .{ .text = "True Graphic Virtual Terminal", .col = t.dim },
        .{ .text = "", .col = t.dim },
        .{ .text = copyright, .col = t.prompt_fg },
        .{ .text = license_line, .col = t.prompt_fg },
        .{ .text = "Source: " ++ source_url, .col = t.prompt_fg },
        .{ .text = "", .col = t.dim },
        .{ .text = "click or press any key to close", .col = t.dim },
    };
    var maxw: f32 = 0;
    for (lines) |l| maxw = @max(maxw, Gfx.textWidth(f, l.text));
    const pad = @round(22 * ui);
    const lh = f.cell_h * 1.35;
    const w = maxw + pad * 2;
    const h = lines.len * lh + pad * 2;
    app.gfx.fillAlpha(.{ .x = 0, .y = 0, .w = app.width_px, .h = app.height_px }, .{ .r = 0, .g = 0, .b = 0 }, 140);
    const r: Rect = .{ .x = @round((app.width_px - w) / 2), .y = @round((app.height_px - h) / 2), .w = w, .h = h };
    app.gfx.fill(r, t.title_bg);
    app.gfx.outline(r, t.focus, @max(ui, 1));
    var y = r.y + pad;
    for (lines) |l| {
        _ = app.gfx.text(f, r.x + (w - Gfx.textWidth(f, l.text)) / 2, y, l.text, l.col);
        y += lh;
    }
}

fn saveShot(app: *App, path: []const u8) void {
    const surf = c.SDL_RenderReadPixels(app.renderer, null) orelse {
        app.sayFmt("screenshot failed: {s}", .{c.SDL_GetError()}, app.theme.stderr_accent);
        return;
    };
    defer c.SDL_DestroySurface(surf);
    const z = app.gpa.dupeZ(u8, path) catch return;
    defer app.gpa.free(z);
    if (c.SDL_SaveBMP(surf, z.ptr)) {
        app.sayFmt("saved {s}", .{path}, app.theme.ok);
    } else {
        app.sayFmt("screenshot failed: {s}", .{c.SDL_GetError()}, app.theme.stderr_accent);
    }
}

// ------------------------------------------------------------ demo recording

/// Script hooks: where the script's mouse is now (window coordinates);
/// `press`: a button went down (the click ring starts).
fn notePointer(app: *App, x: f32, y: f32, press: bool) void {
    app.script_ptr = .{ x * app.density, y * app.density };
    if (press) app.script_press_ms = c.SDL_GetTicks();
    app.dirty = true;
}

/// `/slow`: the next character, if it's time. True while text is left.
fn tickSlow(app: *App) bool {
    const text = app.slow_text orelse return false;
    const now = c.SDL_GetTicks();
    if (app.slow_pos >= text.len) {
        app.gpa.free(text);
        app.slow_text = null;
        app.script_next = now + app.script_gap_ms;
        return false;
    }
    if (now < app.slow_next) return true;
    const n = @min(std.unicode.utf8ByteSequenceLength(text[app.slow_pos]) catch 1, text.len - app.slow_pos);
    const ch = text[app.slow_pos .. app.slow_pos + n];
    app.slow_pos += n;
    if (app.scriptSettings()) |sw| sw.onText(ch) else app.onText(ch);
    app.slow_next = now + @as(u64, if (ch[0] == ' ') 80 else 50);
    app.dirty = true;
    return true;
}

/// `/glide`: the mouse a step further along. True while it moves.
fn tickGlide(app: *App) bool {
    const g = app.glide orelse return false;
    const now = c.SDL_GetTicks();
    const t = @min(@as(f32, @floatFromInt(now -| g.start)) / @as(f32, @floatFromInt(g.ms)), 1);
    const e = if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f32, -2 * t + 2, 3) / 2; // ease in-out cubic
    const x = g.from[0] + (g.to[0] - g.from[0]) * e;
    const y = g.from[1] + (g.to[1] - g.from[1]) * e;
    app.notePointer(x, y, false);
    pushMouse(app.scriptWindow(), c.SDL_EVENT_MOUSE_MOTION, x, y, app.script_btn);
    if (t >= 1) {
        app.glide = null;
        app.script_next = now + app.script_gap_ms;
    }
    return true;
}

/// Script hooks `/dropover`, `/drop`: a drop event as another app's drag
/// would send it (window coordinates).
fn pushDrop(kind: u32, x: f32, y: f32, data: ?[*:0]const u8) void {
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    ev.type = kind;
    ev.drop.x = x;
    ev.drop.y = y;
    ev.drop.data = data;
    _ = c.SDL_PushEvent(&ev);
}

fn startRecord(app: *App, dir: []const u8, fps: u32) void {
    app.stopRecord();
    const dz = app.gpa.dupeZ(u8, dir) catch return;
    _ = c.mkdir(dz.ptr, 0o755);
    var buf: [4096]u8 = undefined;
    const list_path = std.fmt.bufPrintZ(&buf, "{s}/frames.txt", .{dir}) catch {
        app.gpa.free(dz);
        return;
    };
    const fp = c.fopen(list_path.ptr, "w") orelse {
        app.gpa.free(dz);
        return app.sayFmt("/record: can't write {s}", .{list_path}, app.theme.stderr_accent);
    };
    const now = c.SDL_GetTicks();
    app.rec = .{ .dir = dz, .list = fp, .every_ms = 1000 / fps, .start = now, .next = now };
    app.dirty = true;
}

fn stopRecord(app: *App) void {
    const r = app.rec orelse return;
    _ = c.fclose(r.list);
    app.gpa.free(r.dir);
    app.rec = null;
    app.dirty = true;
}

/// While recording: the frame just drawn, scaled to the window's size
/// (so a HiDPI screen gives the same pictures), if one is due.
fn saveFrame(app: *App) void {
    if (app.rec == null) return;
    const rec = &app.rec.?;
    const now = c.SDL_GetTicks();
    if (now < rec.next) return;
    rec.next = @max(rec.next + rec.every_ms, now);
    const surf = c.SDL_RenderReadPixels(app.renderer, null) orelse return;
    defer c.SDL_DestroySurface(surf);
    var ww: c_int = 0;
    var wh: c_int = 0;
    _ = c.SDL_GetWindowSize(app.window, &ww, &wh);
    const out = if (ww != surf.*.w or wh != surf.*.h) c.SDL_ScaleSurface(surf, ww, wh, c.SDL_SCALEMODE_LINEAR) orelse return else surf;
    defer if (out != surf) c.SDL_DestroySurface(out);
    // PPM: quick to write, and img2webp reads it as it is.
    const rgb = c.SDL_ConvertSurface(out, c.SDL_PIXELFORMAT_RGB24) orelse return;
    defer c.SDL_DestroySurface(rgb);
    rec.n += 1;
    var buf: [4096]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buf, "{s}/frame-{d:0>5}.ppm", .{ rec.dir, rec.n }) catch return;
    const fp = c.fopen(name.ptr, "wb") orelse return;
    defer _ = c.fclose(fp);
    var head: [64]u8 = undefined;
    const h = std.fmt.bufPrintZ(&head, "P6\n{d} {d}\n255\n", .{ rgb.*.w, rgb.*.h }) catch return;
    _ = c.fputs(h.ptr, fp);
    const px: [*]const u8 = @ptrCast(rgb.*.pixels orelse return);
    const row: usize = @intCast(rgb.*.w * 3);
    for (0..@intCast(rgb.*.h)) |y| _ = c.fwrite(px + y * @as(usize, @intCast(rgb.*.pitch)), 1, row, fp);
    var line: [64]u8 = undefined;
    const l = std.fmt.bufPrintZ(&line, "frame-{d:0>5}.ppm {d}\n", .{ rec.n, now - rec.start }) catch return;
    _ = c.fputs(l.ptr, rec.list);
}

/// While recording: an arrow pointer where the script's mouse is (the OS
/// pointer isn't in the frames), and a ring growing from a press.
fn drawPointer(app: *App) void {
    const p = app.script_ptr orelse return;
    const ui = app.scale.ui;
    const now = c.SDL_GetTicks();
    const ring_ms: u64 = 450;
    if (app.script_press_ms != 0 and now -| app.script_press_ms < ring_ms) {
        const t = @as(f32, @floatFromInt(now - app.script_press_ms)) / @as(f32, @floatFromInt(ring_ms));
        const rad = (8 + 18 * t) * ui;
        const segs = 32;
        var prev: [2]f32 = .{ p[0] + rad, p[1] };
        for (1..segs + 1) |k| {
            const a = @as(f32, @floatFromInt(k)) * 2 * std.math.pi / segs;
            const q: [2]f32 = .{ p[0] + rad * @cos(a), p[1] + rad * @sin(a) };
            app.gfx.line(prev[0], prev[1], q[0], q[1], app.theme.focus, 3 * ui);
            prev = q;
        }
        app.dirty = true;
    }
    // The classic arrow, tip at the mouse; star-shaped around the tip, so
    // a triangle fan from it fills it.
    const shape = [_][2]f32{ .{ 0, 0 }, .{ 0, 17 }, .{ 4.2, 13.2 }, .{ 7, 19.5 }, .{ 9.8, 18.4 }, .{ 7, 12.2 }, .{ 12.4, 12.2 } };
    const sz = 1.25 * ui;
    var v: [shape.len]c.SDL_Vertex = undefined;
    for (shape, 0..) |s, k| v[k] = .{
        .position = .{ .x = p[0] + s[0] * sz, .y = p[1] + s[1] * sz },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .tex_coord = .{ .x = 0, .y = 0 },
    };
    var idx: [(shape.len - 2) * 3]c_int = undefined;
    for (0..shape.len - 2) |k| {
        idx[k * 3] = 0;
        idx[k * 3 + 1] = @intCast(k + 1);
        idx[k * 3 + 2] = @intCast(k + 2);
    }
    _ = c.SDL_RenderGeometry(app.renderer, null, &v, v.len, &idx, idx.len);
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    for (0..shape.len) |k| {
        const a = v[k].position;
        const b = v[(k + 1) % shape.len].position;
        app.gfx.line(a.x, a.y, b.x, b.y, black, 1.2 * ui);
    }
}

// ------------------------------------------------------------ test scripts

/// `gtty --script file`: each line is typed into the prompt and submitted,
/// one every 400 ms. `/wait <ms>` adds a pause, `/shot x.bmp` saves a
/// screenshot, `/quit` ends the run. Lines starting with # are comments.
fn loadScript(app: *App, path: []const u8) !void {
    const z = try app.gpa.dupeZ(u8, path);
    defer app.gpa.free(z);
    const fp = c.fopen(z.ptr, "r") orelse {
        std.debug.print("cannot open script {s}\n", .{path});
        return error.ScriptOpen;
    };
    defer _ = c.fclose(fp);
    var buf: [4096]u8 = undefined;
    while (c.fgets(&buf, buf.len, fp) != null) {
        const line = std.mem.trimEnd(u8, std.mem.sliceTo(&buf, 0), "\r\n");
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or t[0] == '#') continue;
        try app.script.append(app.gpa, try app.gpa.dupe(u8, line));
    }
    app.script_next = c.SDL_GetTicks() + 600;
}

/// The start-up command (`-c`, default `s`): typed into the prompt and
/// submitted once, as if the user had. A word only the user's shell knows
/// (an alias, a function) waits until gtty has the shell's names (at most
/// ShellNames' timeout); programs and gtty's own commands run at once.
fn tickStartup(app: *App) void {
    const line = app.startup orelse return;
    if (app.shell_names.busy()) {
        const known = oscmd.knows(line) or switch (commands.parse(line)) {
            .line => |cmd| commands.parseGtty(cmd, false) != .unknown,
            else => true,
        };
        if (!known) return;
    }
    app.startup = null;
    defer app.gpa.free(line);
    app.prompt.clear();
    app.prompt.insertUtf8(line);
    app.submit();
}

fn tickScript(app: *App) void {
    if (app.startup != null) return; // the start-up command goes first
    // `/slow` and `/glide` finish before the next line.
    if (app.tickSlow() or app.tickGlide()) return;
    if (app.script_pos >= app.script.items.len) return;
    const now = c.SDL_GetTicks();
    if (now < app.script_next) return;
    const line = app.script.items[app.script_pos];
    app.script_pos += 1;
    app.script_next = now + app.script_gap_ms;
    // Test hooks run directly, without touching the prompt (so a shot shows
    // the prompt as the user would see it); everything else is typed in.
    switch (commands.parse(line)) {
        .wait, .shot, .click, .rclick, .dclick, .down, .up, .type, .text, .key, .resize, .menu, .target, .mods, .record, .slow, .glide, .pace, .dropover, .drop => return app.exec(line),
        else => {},
    }
    app.prompt.clear();
    app.prompt.insertUtf8(line);
    app.submit();
}
