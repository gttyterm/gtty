# gtty — notes for Claude Code

gtty is a graphical terminal written in Zig: every command gets its own
on-screen job window (stdout and stderr together, as in a normal terminal).
The user's own shell (zsh/bash) runs the commands; gtty is the terminal, not
the shell. Users expect it to behave like a shell in a terminal.

## The app today (what the user sees)

- **Screen:** (Linux: a thin drawn menu bar on top,) windows area, a 2 px
  divider, the **prompt** (2 lines), and the **status bar** (the file opener's
  help line on the left, short notices on the right; the chips moved into
  the job windows, see "Chips" below).
- **Compose / run mode:** Enter at the prompt runs the line in a new job
  window that takes the keyboard (run mode). Back to the prompt: click it,
  click empty space, Ctrl+Tab (cycles running jobs, then the prompt), or the
  job exits. The prompt label says where typing goes.
- **Window system:** the **current job window** fills the windows area
  (full height); every other job window is minimized into the **job grid**.
  **A window coming into the windows area joins it** (`setFocus` on a
  window not shown: a new one from `openJob`, a click on a grid window,
  Ctrl+Tab, `focus N`, maximize; decided 2026-10-06): it becomes the
  current one and the one that was current goes into `extras` (front); when they don't all fit
  (`capacityWith(gridCount())`), the last extras (finished, oldest) go
  to the grid (`unshow`).
  Maximize (button / F11) covers the whole gtty screen. Borders: blue
  focused running, gray running, green exit 0, red error + exit code.
- **Job grid** (one grid only; the old top running-jobs grid and separate
  history grid are gone): one column on the right, a ninth of the width (windows area : grid = 8 : 1)
  (at least one 150 px cell, `min_cell_w`), full height, shown only when not empty.
  - Fixed header on top (`grid_head_r`; the windows scroll under it):
    title **Jobs** and a sort button (`grid_sort_r`) toggling **↓ newest**
    / **↑ oldest** (`grid_oldest_first`, `toggleGridSort`:
    animated relayout, scroll back to top).
  - Two labeled groups: **running** above **history** (`gridJobs`). A job
    that finishes moves to history; a window being closed or killed counts
    as history at once (before it has exited).
  - Inside each group: **last window activity, newest first** (or oldest
    first with the sort button) —
    `JobWindow.last_activity_ms`, a ms timestamp (SDL_GetTicks, monotonic)
    set by `touch()` on open, focus, moving into / out of the windows area
    (minimize, swap), maximize / restore, close / kill, finish (a close /
    kill request stays the last activity even if the exit comes later).
    Ties: higher `#N` first. `App.shown` tracks the window in the windows
    area to touch both windows of a swap.
  - Grid windows keep a normal-size title bar over a live scaled-down
    copy: checkbox, copy, `#N`, state dot, title (cut first), × — no
    minimize / maximize there (`layoutTitle`: zero-width `min_r` /
    `max_r`). Click one to
    bring it to the windows area: it joins the windows shown there (see
    below).
  - Scroll bar on the grid's right edge (only when it overflows; drag the
    thumb, click the track to jump; thin, wider on hover, blue while
    dragged; no counter) plus the mouse wheel.
- **Several windows in the windows area:** a checkbox at the far left of
  every grid title (grid titles show only checkbox + copy) adds that window
  next to the current one (`App.extras`, display order; `toggleCheck`). The
  header checkbox (`grid_check_r`, `toggleCheckAll`) selects as many as fit
  or clears. Room = 40 × 10 at gtty's text size (`JobWindow.minSize`,
  `src/ui/tiling.zig`: `capacity`, `arrange` — most-cramped window gets the
  most room, the top row holds fewer windows, current window top-left).
  Too many: red check 2 s (`flashCheck`) + beep + "room for N windows".
  Every selection change calls `restamp` (keeps order, current = now; then
  running before history) and the order stays while shown (focusing a
  shown window doesn't touch it). A resize that leaves less room drops the
  last ones (unchecked, `unshow`). `isShown(i)` = current or selected;
  `JobWindow.check` (hidden / off / on / locked) drives the title box.
- **Transitions** between windows: when windows change place through a user
  action (`relayoutAnimated`: swap, minimize, close, maximize / restore, a
  job finishing and changing group) each moved window animates from its old
  screen rect to its new one — 220 ms, ease-out cubic (`GTTY_ANIM_MS`; 0 =
  off). The window coming into the windows area grows out of its grid
  cell, the one leaving shrinks into its cell, reordered grid windows
  slide, a new window rises from the prompt. Scrolling and OS-window
  resizes are instant (plain `relayout`).
  - How: `relayout` records each window's `screenBox()` before placing;
    with `animate` set, changed ones get `animateFrom(old)`. `drawMoving`
    (after the prompt, over everything) draws each moving window at its
    new place on a screen-size canvas texture and stretches that region to
    `animRect(now)`; a window leaving the windows area is drawn from its
    full-size picture (`drawFullAt`, same size so the PTY isn't resized).
    `drawScaledContent` restores the previous render target, so it works
    on the canvas. `tick()` keeps redrawing while `anim_from` is set.
  - Testing: script lines are ≥ 400 ms apart, so catch a transition with
    `GTTY_ANIM_MS=2000` and `/focus N` followed by `/shot`.
- **Title bar:** title font 1.03× the text size (`chromePx`), icons sized
  from it. Left = content actions (copy when finished or a running shell, A−/A+ text size, the
  **color** pill: the word in colored letters, struck-through gray when
  off, the **sync** checkbox (box + the word, blue when checked; sync
  typing, see below), the **files** folder icon), then serial badge `#N`, state dot, title; right =
  status text, minimize, maximize, gap, red ×. After any close (×,
  `close`, ⌘W; `App.closeWindow` sets `want_shell`), if no shell window is
  running any more (one being ended doesn't count), gtty opens a new one
  on the next frame (`ensureShell`). A shell that ends by itself (`exit`,
  a crash; not killed from its kill menu, `kill_ms == 0`) counts as a
  close too: its window closes (after the run loop's pass), `want_shell`. Guard: more than 5 shells opened within 5 s
  (`shell_opens` ring) → `auto_shell` off + notice + beep; the user's own
  `s` turns it back on. **Quit on last shell** (config
  `quit-on-last-shell`, default on; Settings → General;
  `App.quit_on_last_shell`): instead of a new shell, gtty quits once no
  other job is running either (`want_shell` stays set until then; off in
  a script run without `GTTY_CONFIG`). **Closing never sends a window to the job grid; only
  minimize does** (decided 2026-10-06; `closeOrKillMenu`): × on a finished
  window, or on a shell waiting at its prompt (`atPrompt`), closes it
  (a running shell is hung up); on a job still working (a command, or a
  shell running one) it opens the kill menu (only the skull kills:
  SIGHUP, SIGKILL after 2 s; Esc closes it; the killed window stays, red).
  `close [N|all]` closes outright (running jobs hung up).
- **Copy in a shell window:** a running shell's title-bar copy takes only
  the last command's output (so far, if it still runs); a finished window
  copies everything (`JobWindow.copyText`). zsh/bash get hooks
  (`src/core/shell_hooks.zig`, files written into the tee folder) that
  print OSC 133 C / D; `Screen.last_output` holds the byte range, read back
  from the tee file (`Log.readRange`). Other shells: copy all. A command
  still running that the user types into (ssh: the remote shell has no
  hooks; python, …): the answer to the last typed line
  (`Screen.typedOutput`: from that line's echoed line feed, `typed_end`,
  to the last line feed, `lf_end`, so the remote prompt is left out). The hooks
  go in **after** the user's config (zsh: gtty's `.zprofile` / `.zshrc` /
  `.zlogin` source the user's, then `__gtty_hooks`; bash: through
  bash-preexec if loaded, else a DEBUG trap chained after the user's), so
  a config can't drop them. Test such configs with `ZDOTDIR=…` / `HOME=…`
  pointing at a scratch folder.
- **Chips** live in a **footer strip** at the bottom of every job window
  (drawn in the windows area only; a grid copy shows just the text, but
  the strip always takes its room so the PTY size doesn't change). The
  **git chip** (branch of the folder the window's process is
  in, `gtty_proc_cwd` in `src/sys/gtty_pty.c`: libproc on macOS,
  /proc/<pid>/cwd on Linux; refreshed once a second while shown and
  running; hidden outside a repo and once the job finished), then the
  **folder chip** (`folder_chip_r`: folder icon + the folder's name,
  `JobWindow.folderName`; hidden in a remote session). The exit-code
  badge of a failed window sits in the strip's right end.
  - **Folder chip peek** (`Peek.kind` folder, `Peek.openFolder`,
    `App.openFolderPeek`): hover = the compact peek (copy, full path);
    a click opens it expanded at once: the folders above (`/` on top, the
    parent at the bottom by the chip, selected), filter + keys as the
    branch list. A pick returns `Action.cd` → `JobWindow.cdTo` when the
    shell is at its prompt (green "cd sent", closes after 1 s; that feeds
    the History ▸ list), else red "the shell is busy" + beep. Closes when
    the folder changes some other way.
  - **Peek** (`src/ui/Peek.zig`, one at a time, `App.peek`): opens after
    0.5 s hover (`chip_hover_ms`) or a click; [copy] [expand ^] full branch
    [×]; grows up from the chip in the normal text size. Mouse away → 5 s
    countdown on the thicker bottom border; any click elsewhere closes it
    (and still acts).
  - **Expanded peek:** `git for-each-ref` list (current marked green),
    filter box with the keyboard (prompt label says so), ↑/↓/PgUp/PgDn/
    Enter/Esc, wheel; picking runs `git switch` in the background
    (`git.Run`, on a PTY): green border, closes after 1 s; failure: red
    border + git's last lines inside the peek + status notice + beep.
  - Testing: `/move` onto the chip (about x 45, y 620 at the default size),
    `/wait 900`; the expand icon is ~25 px right of the copy icon.
- **Folder button** (the title bar's folder icon, `JobWindow.files_r`,
  windows area only; `App.openFolder`): the folder the window's program
  is in at the click (`JobWindow.folder`) in the system's file manager
  (`gtty_open_with(dir, NULL)`: macOS LaunchServices → Finder; Linux
  `xdg-open`). In an ssh / mosh window the icon is dimmed and the click
  only says it's not supported yet. `GTTY_SHOW_DRY=1`: only says which
  folder. (Replaced gtty's own files window, 2026-10-06.)
- **Sync typing** (added 2026-10-07; like Terminator's / iTerm2's
  broadcast input; gtty menu "Sync Typing", a check mark while on —
  macOS `menuChecked`, the drawn bar a ✓ in the row's key column —
  `GTTY_MENU_SYNC_TYPING`, `/menu sync-typing`; the title bar's **sync**
  checkbox (`JobWindow.sync_r`, after color, windows area only: a box +
  the word, never struck through; checked = blue box and word like the
  focus border, `syncIcon`; red was rejected: it reads as an error);
  `App.toggleSync`; any window's checkbox or the menu turns it off): the source
  window (`App.sync_src`, a uid: the checkbox's window, or `currentJob`) gets
  the keyboard; whatever it's typed (`JobWindow.typeBytes` / `send` →
  `sync_hook` → `App.syncMirror` → `syncBytes`) goes to every other
  running window in the windows area (`JobWindow.sync` = `.follower`,
  set each frame by `App.updateSync`: joins / leaves with the windows
  area; the source closed / ended / minimized → off). Followers are
  read-only: purple-red thick frame (`Theme.sync`), `setFocus` refuses
  them (one from the grid still comes in, `bringIn`, keyboard stays),
  Ctrl+Tab = source ↔ prompt, `typeBytes` drops anything else
  (`sync_refused` → `readOnly`: beep + notice), right-click Paste /
  History dimmed, drops refused, `aiTarget` skips them. The gtty prompt
  isn't synced; a window it opens (or ⌘T) joins as read-only and the
  keyboard stays where it was. Maximize still works on a follower (no
  keyboard). Not saved in the config (a mode, off at start). **Rule:**
  user input to a job must go through `typeBytes` / `send` so it is
  mirrored and gated (`runAi` still writes the PTY directly; the AI
  never targets a follower). Test: `test/sync.gt`.
- **Tooltips** on the left title-bar actions (checkbox, copy, A−, A+,
  color, sync, files) after 0.5 s hover (`JobWindow.tip`, `App.updateTip`/`drawTip`).
- **Text:** mouse selection (drag, double/triple click), ⌘C (Ctrl+Shift+C on
  Linux) copies it; plain Ctrl+C goes to the job. Scroller mark
  (draggable) on the right, "↑ N" label for 2 s after scrolling. Text
  reflows when the width changes.
- **Left-edge marks** (replace the old hover mark / gutter): frame, 3 px
  (`mark_gap`, measured from the 2 px focused / finished frame,
  `frameWidth`), then the marks strip (`JobWindow.marks_r`, `mark_pt` = 4, `marks_on`):
  green rows the user typed, purple AI (request line + output of an AI
  run, `Screen.ai`); output and prompt rows get no
  mark (`drawMarks`, `Screen.rowZone`). Each cell records its `Attrs.zone` when written; `Screen.zone`
  follows the hooks' marks (B → input, C → output, D / A → prompt; B is
  appended to PS1 by `__gtty_prompt_end`, last in precmd). Programs
  without marks, or one running in a shell: their echo right after the
  user typed (`Screen.echo`, until the next line feed or 400 ms) is
  input. Settings: General tab (on/off, width, 3 colors; config `marks`,
  `mark-width`, `mark-input`, `mark-ai`); env `GTTY_MARKS=0`,
  `GTTY_MARK_WIDTH`, `GTTY_MARK_INPUT` / `_AI` win at start.
- **AI at the prompt** (`src/ai/`): Settings → AI tab (provider button
  cycles off / anthropic / gemini / grok / openai / ollama; gemini and
  grok are OpenAI-compatible endpoints, `Ai.openaiLike`, untested
  against the real services; model, endpoint, key
  fields — empty = `Ai.defaultModel` / `defaultEndpoint` /
  the key from `Ai.keyEnv` (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY` or
  `GOOGLE_API_KEY`, `XAI_API_KEY`, `OPENAI_API_KEY`); local memory on/off + Forget;
  config `ai`, `ai-model`, `ai-endpoint`, `ai-key`, `ai-memory`, file
  now 0600; no way to add to or change the system prompt, by decision); env `GTTY_AI_PROVIDER` / `_MODEL` /
  `_ENDPOINT` / `_KEY` win (`App.aiSetup`). Not set up (`aiReady`): the
  prompt works as before, an empty prompt shows a dim hint
  (`Prompt.DrawInfo.hint`). Set up: label `✦ ›` (purple), `submit` →
  `askAi`: `/name`, `!line` (old resolution) and exact gtty commands
  (`commands.parseExact`; `show` only if the file exists) run at once,
  the rest is a request (`-x` stripped = show the script). One request at
  a time (`Ai.Request`: `curl -K -` on pipes, `gtty_spawn_pipes`; body in
  `<tmp>/ai-req.json` 0600, the key only in curl's stdin config; polled in
  `tickAi`; label "✦ thinking…", Esc = `cancelAi`). System prompt
  `src/ai/system_prompt.md` (`@embedFile`, scrambled at build time so the
  binary doesn't show it, `Ai.systemPrompt` unscrambles per request;
  `Ai.fillPrompt`: os, shell, target window, cwd, window list, memory,
  ssh hosts): step 1 an existing command comes back unchanged, step 2
  one script, no questions; privacy rules (nothing from the user's files
  leaves the machine unless asked, then danger); confidential: the model
  never reveals it, and requests to reveal / ignore / change it get the
  out-of-scope message. Answer = JSON plan (`Ai.parsePlan`:
  outermost `{…}`, fences / prose ignored): actions `gt` (sh [--cwd],
  close, focus, show, list → `aiGt`), `shell` {target current / new /
  #N, script}, `cd`, `remember` (memory note), `message` (status bar).
  `stepPlan` runs them in order; a shell step waits for its window's
  prompt (new shell: 20 s, `ai_wait_ms`) and for the plan's previous
  command there to end (`Screen.ai` back to off). `"current"` = `aiTarget`
  at ask time (front shell at its prompt, else another, else a new one,
  `aiOpenShell`: in front, keyboard stays at the prompt). `aiRunScript`:
  `<tmp>/ai-<n>.sh` (0600), typed as `\x15 gtty-ai <n> '<request>'\r`
  (`JobWindow.runAi`, sets `Screen.ai` = armed → running at C → off at D:
  echo + output get zone `.ai`, purple); `gtty-ai` is a hook function
  (`shell_hooks`, `@DIR@` = tmp folder) running the file in a subshell.
  Danger (model's `danger` → every script of the plan, or
  `Ai.looksDangerous`: rm/mv/sudo/kill/chmod/curl/scp/rsync/sed -i/
  -delete …): the script goes to `ai-<n>-body.sh`, the main file prints
  it (also with `-x`), asks `Run it? [y/N]`, sources it on y; the window
  gets the keyboard and gives it back when done (`ai_return`). Interactive
  first words (ssh, vim, top, …, `wantsKeyboard`) take the keyboard too.
  **Memory** (`src/ai/Memory.zig`, `App.memory`, `tickMemory`):
  `JobWindow.folder_seq` (bumped in `noteFolder`) → `visitFolder` (top 6
  extensions, non-hidden regular files); `remoteDest` → `usedHost`;
  `remember` → `addNote`; saved ≤ every 10 s + at exit to
  `$GTTY_AI_MEMORY` / `$XDG_STATE_HOME/gtty/ai-memory` /
  `~/.local/state/gtty/ai-memory` (tab-separated lines); in a script run
  only with `GTTY_AI_MEMORY`. ssh hosts for the prompt: memory +
  `~/.ssh/config` `Host` names. Tests: `test/ai.gt` with
  `GTTY_AI_REPLY=test/ai-reply.json` (the file's text is the answer, no
  network); a fake HTTP server + `GTTY_AI_ENDPOINT=http://127.0.0.1:…`
  tests the curl path.
- **Paste:** ⌘V, Ctrl+Shift+V or Shift+Insert (`App.pasteKey`): into the
  focused running job (`JobWindow.paste`: replaces a keyboard selection,
  line ends as CR, ESC bytes dropped, wrapped in `ESC[200~ … ESC[201~` when
  the program turned on bracketed paste, `Screen.bracketed_paste` from
  `ESC[?2004h/l`), else the prompt (line ends dropped), or an expanded
  peek's filter. Plain Ctrl+V goes to the job. One press = one paste:
  every route (key, right-click menu, menu bar) ends in `pasteInto`; on
  macOS the Edit menu's key equivalent fires too, so `menuOwnsKey` drops
  the key down while that row is enabled; auto-repeats of a copy / paste
  key are dropped (`clipboardKey`). The shell hooks turn off the paste
  highlight (zsh `zle_highlight=(paste:none)`, bash
  `enable-active-region off`; the user's config wins).
- **Right-click menu** (`src/ui/Menu.zig`, `App.menu`, `openMenu` /
  `menuClick`): right click on a job window's text or footer in the windows
  area, or on the prompt → **Copy** (the window's selection; dimmed with
  none), **Copy last output** / **Copy all output** (job windows: the
  title-bar copy, `copyJob`, with its flash; rows carry codes,
  `Menu.edit_*`), **Paste** (dimmed for a finished job or an empty clipboard),
  shortcut shown per row. Right-clicking a running window focuses it; the
  selection stays. **Paste ▸** (paste history): every copy from a job
  window (`App.toClipboard`: ⌘C, title-bar copy, menu Copy) goes on top
  of `App.paste_history` (this session's copies, newest first, 5, no
  repeats; the clipboard from before gtty started isn't in it). Paste's ▶ box (`Row.sub`, `Menu.arrowAt`) opens
  `App.sub_menu` (purpose `paste_history`) next to the row: one line per
  value (`Menu.oneLine`: ⏎ for line breaks, 20 characters, …); a pick
  pastes it into the menu's target. All pastes end in `App.pasteText`.
  **Paste preview** (`src/ui/PastePreview.zig`, `App.paste_preview`,
  `updatePreview`): while the mouse is on a Paste ▸ row, that entry's
  whole text in a floating window right of the submenu (left when no
  room): thin top bar with only ×, text wrapped (≤ 72 cols × 18 rows,
  CR LF → LF, tabs → 4 spaces), wheel / ↑↓ / PgUp / PgDn / Home / End
  scroll, typing searches (any case; matches highlighted, Enter / ↓
  next, Shift+Enter / ↑ previous, Backspace, Esc clears then closes).
  Another row: swapped at once; the mouse off both the rows and the
  preview, or the menu closing: gone. Keys and wheel go to it before the
  menu's "any key closes" rule. **History ▸**
  (job windows): the folders the shell left (`JobWindow.folders_left`,
  newest first, 10, not the current one; `noteFolder`), from the hooks'
  OSC 7 report at each prompt (`Screen.reportedFolder`, `%XX` decoded),
  else the process folder seen by `refreshChips`. The submenu (purpose
  `folder_history`, `Menu.shortPath`: `~`, `…` + the end) types `cd` via
  `JobWindow.cdTo` (shared with the file opener) when the shell is at its
  prompt; dimmed rows + "(the shell is busy)" otherwise. Closes on any click outside (that click does nothing
  else; a right click reopens it there), any key (Esc only closes), the
  wheel, a resize, or its window going away.
- **Input-line editing in a shell** (`App.editKey`, `JobWindow.editMove`):
  while a zsh/bash window waits at its prompt (`Screen.at_prompt`, between
  OSC 133 D and C), Ctrl/⌥ + ←/→ jump words, ⌘ + ←/→ / Home / End go to
  the line's ends: gtty sends `ESC[1;5D/C`, `ESC[H/F`, which the hooks
  bind (zsh `bindkey`, bash `bind`, emacs + vi-insert, before the user's
  config so theirs win). Shift selects: a keyboard selection
  (`JobWindow.key_sel`) whose head follows the shell's cursor after each
  pump; Backspace/Delete erase it (cursor to its right end + N × DEL),
  typing / paste replace it, other keys drop it. A **mouse** selection
  inside the line being typed works the same (`JobWindow.inputSel`: the
  cells with zone `.input` on the cursor's row and the rows it wraps
  over; cut at the typed text's end; one reaching into the prompt or
  earlier output is left alone): `deleteSel` moves the shell's cursor to
  its right end (← / → from where it is), then N × DEL. Not at a prompt
  (programs, other shells): xterm modified sequences `ESC[1;<mod>D`.
- **Colors:** SGR colors (16 / 256 / truecolor, inverse, dim, underline) on
  the dark body; 16 colors = xterm's default table; bold makes colors 0–7
  bright; unreadable colors are lightened. Per window, colors can be turned
  off (title-bar button or `colors [on|off]`): plain text, no escape codes
  shown; it is draw-time only, so turning them on restores everything.
  Blink (SGR 5/6) is ignored: steady text.
- **Wide characters and emoji:** `src/core/wcwidth.zig` (generated from
  Unicode 16: 0 = combining / format / VS / ZWJ, 2 = East Asian wide +
  emoji shown as emoji). `Screen`: a wide character sets `Attrs.wide`, the
  next cell is a spacer (`cp` 0); one that doesn't fit in the last
  column wraps and leaves a pad (`cp` 0); a zero-width character is kept
  in the cell before (`Cell.extra`) so copy gives back what was printed;
  reflow never splits a pair. `Gfx`: characters JetBrains Mono lacks come
  from `fallback_fonts` (macOS Menlo, Apple Symbols, Arial Unicode, Apple
  Color Emoji; Linux DejaVu, Noto Symbols 2, Noto CJK, Noto Color Emoji,
  else `fc-match`), opened per size when first needed; wide or U+FE0F
  characters try the emoji font first and are drawn as color images,
  cropped to their pixels and fitted to their cells (`glyphCells`).
- **Commands:** gtty's own names are `s`/`sh`/`shell`, `run`, `close [N|all]`,
  `focus N`, `s --cwd DIR`, `zoom in|out|150%`, `colors [on|off]`, `/clear`, `list`,
  `help`, `quit`, `show [-a] file`, `settings`. Everything else the user's shell knows
  runs as a job.
- **`show <file>`** (`App.showFile`, `src/sys/gtty_open.c`): opens a file
  with its default app, no job window (macOS LaunchServices; Linux
  `xdg-mime` + `xdg-open`). No default app, or `-a`: the **app picker**, a
  `Menu` (purpose `open_with`) over the prompt: title "Open X with", the
  apps (default first, marked), at most 16; the data in `App.picker_path` /
  `picker_apps`, freed with the menu. Missing file / no app: notice + beep.
  `~` expanded; relative = gtty's folder. `GTTY_SHOW_DRY=1` only says what
  it would open (`test/show.gt`). Linux side compiles but is untested
  (picker: mimeinfo.cache, `gio launch` / `gtk-launch`).
- **Menu bar** (mouse; shortcuts could clash with the jobs' keys): menus
  **gtty** (About gtty, Settings…, New Window, New Shell, Run command, Sync Typing) and **Edit** (Copy,
  Paste, Select All). **About gtty** (`GTTY_MENU_ABOUT`; macOS: SDL's
  About row, re-targeted in `gtty_menu.m`; Linux: the drawn bar's first
  row; `/menu about`): gtty's own box (`App.drawAbout`, `about_visible`;
  any click or key closes it): name + version, tagline,
  `App.copyright`, `App.license_line`, `App.source_url` (codeberg, TODO
  until the repo exists); `gtty --version` prints the same copyright and
  license lines. **New Shell** (`App.newShell`, `GTTY_MENU_NEW_SHELL`;
  also ⌘T / Ctrl+Shift+T in `onKey` — on macOS the native menu owns ⌘T,
  `menuOwnsKey` — and the right-click menu's last row): the user's shell
  in the folder of the current window (`currentJob`: focused, else the
  current one; the right-click menu: the window clicked), else home.
  **New Window** (`App.newWindow`, `GTTY_MENU_NEW_WINDOW`, ⌘N /
  Ctrl+Shift+N, as GNOME Terminal's New Window / New Tab): another gtty process (`gtty_open_new_instance` in
  `gtty_open.c`: own executable, double fork, no args → opens a shell) in
  the current window's folder, else home; its window cascades from this
  one (`App.cascade`: same size, +28 pt right / down, back to the usable
  area's top-left when it would leave it), passed as env `GTTY_WINDOW`
  "x,y,w,h" (`windowGeometry`, read and unset at start; window created
  hidden, placed, shown; Wayland can't place windows). It comes to the
  front (`tickFront`): the old gtty yields to the new pid (returned
  through a pipe by the double fork) once `NSRunningApplication` knows it
  (`gtty_app_yield_to`, macOS 14+ cooperative activation), the new one
  calls `gtty_app_activate` + `SDL_RaiseWindow` until active (≤ 3 s). `GTTY_SHOW_DRY=1`
  only says so (folder + geometry). macOS = the system menu bar
  (`src/sys/gtty_menu.m`: SDL's Preferences… row becomes Settings… ⌘,;
  Edit ⌘C/⌘V/⌘A inserted; enabled states asked through
  `menuEnabled` → `App.menuRowEnabled`, check marks through
  `menuChecked` (`gtty_menu_install`'s third argument, applied in
  `validateMenuItem`); picks arrive as an SDL user
  event, `App.menu_event` → `menuPick`). Linux = a drawn bar on top
  (`App.menubar_r`, `menubar_btns`, `Menu.bar` with per-row codes,
  `barRows`; `GTTY_MENU_BAR=1` shows it on macOS).
- **Help line:** the file opener of the window under the mouse
  (`FileOpener.help`: what double-click / hold-and-drag do on the
  outlined name); drawn on the left of the status bar (`StatusBar.draw`),
  notices on the right.
- **Settings window** (`src/ui/SettingsWindow.zig`, `App.settings`, also
  the `settings` command): a second OS window (own renderer + Gfx; App
  routes SDL events by window id, `eventWindow`), tabs General / Colors /
  Timing / AI (row labels wrap before the controls column, the row
  grows: `rowLabel`). It edits `App.cfg`
  (`src/core/Config.zig`), queues `Change`s; `tickSettings` applies them
  live (`applyChange`) and saves. File: `$GTTY_CONFIG`, else
  `$XDG_CONFIG_HOME/gtty/config`, else `~/.config/gtty/config`; flags and
  `GTTY_*` win at start. Script runs read / write it only with
  `GTTY_CONFIG`. Settable timing: `JobWindow.anim_len_ms`,
  `JobWindow.hard_kill_ms`, `Peek.dismiss_ms`, `App.tip_delay_ms`,
  `App.chip_hover_ms`.
- **File opener (FO)** — a plain job window feature, no dispatcher, no
  modifier keys (`src/ui/FileOpener.zig`, the window's `opener`; path
  finding in `src/ui/file_path.zig`, unit-tested). App calls the window
  under the mouse (`App.hover_src`, `textWindowAt`): `JobWindow.fileHover`
  on every mouse move over its text (`sendHover`), `opener.leave` when the
  mouse leaves. `JobWindow.textChanged` (App, each frame) drops the outline
  when the text version changed, then App hovers again. Hover → candidates
  → resolved against the window's folder → existing regular
  non-executable file → `mark` (text range), drawn dashed by the window
  (`drawFileMark`, windows area only; none while selecting text,
  `w.drag`), hand pointer. Folders only in a shell at its prompt
  (`atPrompt`).
  - **Double-click** inside the mark (`onClick`, clicks 2,
    `JobWindow.fileOpen` → `FileOpener.Action` none / done / show /
    fetch): `show` (Shift: `show -a`) or `fetchRemote`; a folder → `cdTo`.
  - **Press on the mark** (clicks 1): `App.file_press` (no selection yet,
    window focused). Released without moving → a plain click
    (`mouseDown` + `mouseUp` at the press). Held `FileOpener.hold_ms`
    (300) → `opener.held` (`tickFilePress`; outline drawn solid). Moved
    ≥ 4 px: held → `App.dragFile` (`gtty_drag_file`,
    `src/sys/gtty_drag.m`: NSDraggingSession from the SDL window's
    contentView with the file URL + Finder icon, operations copy / move /
    link / generic outside gtty, copy / generic inside; `gtty_drag.c` (Linux, Wayland only: own wl_seat / wl_pointer /
    wl_data_device on SDL's wl_display, private event queue dispatched by
    `gtty_drag_tick`, the pointer's button serial for `start_drag`,
    `text/uri-list`, copy | move; libwayland-client via dlopen, no headers:
    opcodes from wayland.xml; X11: off, one line on stderr at start,
    `gtty_drag_supported` false → no hold, no drop); not held → a text selection from the
    press (`mouseDown` there, then the usual drag). Remote marks: no drag
    (notice). `GTTY_DRAG_DRY=1`: only says what it would drag.
  - **Drop in** (`App.onDrop`, SDL drop events):
    files from another app; `FileOpener.drop_mode` outlines folder names
    only (anywhere); the status bar says where it goes (`helpLine`,
    `dropTarget`: outlined folder, else the window's `folder`; ssh
    window: not yet). On the drop `startCopy` → `gtty_copy_start`
    (`src/sys/gtty_copy.c`: child runs `cp -Rp` per item, a taken name
    gets " 2", " 3"… before the extension, a folder never into itself),
    polled in `tickCopies` (notice).
  - **Between job windows:** gtty's own drag dropped on gtty
    (`drop_inside`, set when `gtty_drag_active` at the drop's start): the
    file is `App.drag_path` (SDL's data ignored: on Wayland SDL can't read
    the URI list, the source's send waits for `gtty_drag_tick`);
    DROP_COMPLETE only stores the target (`insideTarget`: window, outlined
    folder or the shell's own), `tickInsideDrop` acts once
    `gtty_drag_take_drop(&move)` says the session ended in a drop on gtty
    (macOS: operation inside the window frame; Wayland: gtty's own data
    device's `drop`): `JobWindow.typeFileCommand` types
    `\x15cp -i -- '<file>' .` (outlined folder instead of `.`) into the
    target shell, **not run**; the window takes the keyboard. Move key
    held at the drop (`gtty_drag_move_key`: macOS ⌘ from `[NSEvent
    modifierFlags]`, Linux Shift) → `mv -i`. Status line while dragging:
    `insideHelp`. The file's own folder: "already in X"; shell not at
    its prompt: "busy" + beep; ssh window: not yet.
  - On / off: Settings → General ("File names: mark on hover,
    double-click opens"), config `file-opener` (old `sub.file-opener`
    still read), `FileOpener.enabled`. Help line only on a mark (or why
    the remote helpers are off).
  - Text API it uses: `Screen.TextPos {line, col}` logical lines
    (`line_base`, `head_partial` survive trimming), `textPos`, `rowsOf`,
    `lineChars`, `physPos`; `JobWindow.textPosAt`, `lineChars`, `folder`,
    `rangeRects`. Remote checks go over the window's own link (`RemoteLink`
    owner `.files`, replies drained in `JobWindow.tickRemote`; the same
    name isn't asked twice while moving along it, `opener.asked`).
  - Test: `/move`, `/dclick`, `/down` + `/move` + `/up`, `/drag`
    (`test/fileopener.gt`, with `GTTY_SHOW_DRY=1 GTTY_DRAG_DRY=1`).
- **Remote sessions (ssh / mosh):** gtty must stay **transparent**: never
  wrap or add options to the user's ssh, never touch their env / config;
  only watch. `gtty_fg_args` (`src/sys/gtty_pty.c`: tcgetpgrp + argv via
  KERN_PROCARGS2 / /proc) → `src/core/remote.zig` (`sessionOf`: ssh /
  mosh / mosh-client, destination) → `JobWindow.remoteNow`,
  `remote_buf` (checked with the chips). **gtty's own connection**
  (`src/core/RemoteLink.zig`, owned by the JobWindow: `link`,
  `startRemote` / `endRemote`): the user's ssh **argv + env + folder**
  (`gtty_proc_args` / `gtty_proc_env` / `gtty_proc_cwd`) + BatchMode,
  ClearAllForwardings, ControlMaster=no (`remote.linkArgv`), spawned on
  pipes (`gtty_spawn_pipes`); a remote `sh`, requests with an id + marker
  line; `Fetch` = one file (size line + bytes). Every 2 s
  `remote.infoScript` (user's local port `gtty_proc_tcp_lport`) → remote
  folder `remoteCwd`, `remote_idle`, branch → the git chip shows the
  **remote** branch (its peek is blocked). FO in a remote window: checks
  via `RemoteLink.request(.files, …)` → `FileOpener.remoteReply` (stale
  ids dropped); file → `App.fetchRemote` → `Fetching` + modal centered over the window
  (progress, Cancel / Esc) → read-only (0444) copy in
  `<tmp>/remote-<serial>-<ssh pid>/<n>/` → `show`; folder → `cd` when
  remote idle. Copies deleted on session end / error / window close.
  Can't connect (or the link breaks): `link_off` → file opener + git chip
  off until that ssh session ends (no retry; notice once). Remote front
  program is another hop / container shell / another user → `away=1`
  (`remote_away`) → off until back.
  Tests: `test/remote.gt`, `test/remote-off.gt` with the stand-in
  `test/fake-ssh/ssh.c` (`FAKE_SSH_NOLINK`, `FAKE_SSH_NESTED`; build it
  with `cc` first, see the script's header).
- **Start-up command:** `-c cmd` / `--command cmd` (default `s`; `""` =
  none) is typed into the prompt and submitted once at start
  (`App.tickStartup`), as if the user had: same resolution, history, and a
  reject puts it back in the prompt. A word only the shell knows (alias,
  function) waits for `ShellNames` (`busy()`, ≤ 15 s). With `--script` the
  default is none (scripts open their own windows); the script waits until
  an explicit `-c` has run.
- **Options:** `-c cmd`, `--script file`, `--scrollback N` (or `GTTY_SCROLLBACK`),
  `GTTY_FONT_SIZE`, `GTTY_ANIM_MS`, `GTTY_CONFIG`, `GTTY_MENU_BAR`, `--version`, `--help`;
  `GTTY_TRACE=file` (debug, `src/core/trace.zig`): key / text events,
  window events, PTY resizes and the bytes sent to each job, with ms
  times; read it next to the job's tee log for "what did the program get
  and print back";
  the settings file sets the same (lower priority).

## UX concept (read first for any UI work)

The design concept, terminology and on-screen description of the app live
outside the repo, in Google Drive:
`~/Library/CloudStorage/GoogleDrive-feralkeep.studios@gmail.com/My Drive/GTTY/`
(main doc: `gtty-ux-and-features.md`). Use its glossary for names
(windows area, prompt, status bar, dock, chip, peek, job window, job grid,
kill menu, compose / run mode, …) and follow its
decisions; items marked *open* are undecided.
- The doc is revised often: re-read it before UI work. Where sections
  disagree, the newer section wins ("Window system" replaces all earlier
  window-arrangement descriptions).
- **Subscriber model: dropped for now** (decision 2026-10-06: overshoot
  for what gtty needs today). The code had a dispatcher, a Subs menu and
  the file opener as the only subscriber; the file opener is now plain job
  window code, and the dispatcher, the Subs menu and `GTTY_MENU_SUB` are
  gone. The UX doc's "Service windows: dispatcher and subscribers"
  sections stay as a possible future extension; don't build toward them
  unless the user brings them back. Find will be a job window command.
- Its last section, **"Implementation status (gtty code)"**, records what the
  code does, including provisional answers to open questions. Update it when
  a feature lands (the user wants doc + code kept in step).

## Build & test

- Zig **0.16.0** (pinned in build.zig.zon). Std APIs changed a lot in 0.15/0.16:
  `std.ArrayList` is unmanaged (`.empty`, `append(gpa, x)`), `main` takes
  `std.process.Init.Minimal` for args, `std.os.argv` is gone.
- Dependencies: SDL3 + SDL3_ttf. macOS: `brew install sdl3 sdl3_ttf`
  (build.zig points at /opt/homebrew, override with `-Dbrew-prefix=`; links
  AudioToolbox for the beep). Linux: pkg-config.
- `zig build run` · `zig build test` · `zig build run -- --script test/smoke.gt`.
  `zig build test` does **not** reinstall `zig-out/bin/gtty` — run `zig build`
  before testing the binary.
- Release binaries: `scripts/build-bin.sh` (`-Dstrip`, no debug info) → `bin/macos/gtty` (arm64,
  macOS 13+) and `bin/linux/gtty` (x86_64, glibc 2.31+), self-contained:
  `-Dbundled-sdl` builds SDL3 (castholm/SDL), SDL3_ttf and freetype (with
  libpng + zlib, for the PNG color emoji fonts; SDL3_ttf without the C
  sanitizer: its color blending reads unaligned) from source (lazy deps in build.zig.zon, unpacked into `zig-pkg/`) and links
  them statically; macOS cross-targets need `-Dmacos-sdk=$(xcrun
  --show-sdk-path)`. `bin/` is not in git.
- Packages: `scripts/package.sh` (needs `brew install nfpm`; runs
  build-bin.sh, `SKIP_BUILD=1` skips it) → `dist/`: `gtty-<v>-macos.dmg`
  (gtty.app, `packaging/macos/Info.plist`, `src/assets/AppIcon.icns`;
  the usual drag-to-Applications window: Finder lays it out via
  osascript over `packaging/macos/dmg-background.tiff`, drawn by
  `dmg-background.swift`),
  `.deb` + `.rpm` (`packaging/linux/nfpm.yaml`: `/usr/bin/gtty`,
  `gtty.desktop`, hicolor icons resized from `src/assets/gtty-icon.png`)
  and a `.tar.gz` with `install.sh`. Version = build.zig.zon (also
  `build_options.version`). Every package carries `LICENSE` and
  `THIRD_PARTY.md` (gtty.app: `Contents/Resources`; Linux:
  `share/doc/gtty`). Signing: `GTTY_SIGN_ID`, notarizing:
  `GTTY_NOTARY_PROFILE` (keychain profile) or `GTTY_NOTARY_KEY` /
  `_KEY_ID` / `_ISSUER` (API key); else ad hoc.
- **Signed releases** (`scripts/sign-macos.sh`, bash; `--check` = only
  the checks): runs package.sh with identity "Developer ID Application:
  Sagi Nagar (N25UN9L94Q)" and the notarytool profile `gtty-notary`.
  Signing material lives **outside the repo** in `$GTTY_SIGNING_DIR`
  (default `$HOME/tmp`): `gtty.p12` (certificate + private key),
  `AuthKey_<KEYID>.p8` (App Store Connect API key; the Key ID is in the
  name), `gtty_key_id.txt` (lines `Issuer Id: …` and `Key Id: …`; parsed by the
  `key_file_*` functions, the same in both scripts: labels in any
  case, CRLF ok, a bare Issuer ID still works; the Key Id falls back to
  the .p8's name and must match it). Never copy them into the repo or
  print their contents. Preflight, stops at the first problem: identity
  not in the keychain → `security import "$GTTY_SIGNING_DIR/gtty.p12"`
  (or which file to copy); profile broken (`notarytool history` fails) →
  the exact `notarytool store-credentials gtty-notary --key … --key-id …
  --issuer …` (or which file to copy); certificate expiring within 30
  days → warning with the date (current one: 1 Feb 2027). Overrides for
  testing: `GTTY_SIGN_IDENTITY`, `GTTY_NOTARY_PROFILE_NAME`,
  `GTTY_CERT_WARN_DAYS`. In CI (`MACOS_CERT_P12` set) no checks: the
  certificate goes into a temporary keychain (removed on exit), the API
  key into a temp file, `GTTY_NOTARY_KEY*` for package.sh.
- **`scripts/set-github-secrets.sh`** (bash, re-run after the yearly
  certificate renewal): `gh secret set --env release` on gttyterm/gitty
  (`GTTY_GITHUB_REPO`; creates the environment if needed): needs `gh`
  logged in and the three files (names each missing one); asks the .p12
  password hidden and tries it on a throwaway keychain; sets
  MACOS_CERT_P12 (base64), MACOS_CERT_PASSWORD, APPLE_API_KEY_P8,
  APPLE_API_KEY_ID (from the .p8 name), APPLE_API_ISSUER_ID,
  APPLE_TEAM_ID (N25UN9L94Q), KEYCHAIN_PASSWORD (random); values only
  through stdin, prints only the names. A .p12 written by OpenSSL 3
  needs `-legacy`, or `security import` can't read it. The binary also embeds
  `gtty-icon.png` as its window / Dock icon (`App.setIcon`) and sets the
  SDL app id `gtty` (matches the .desktop file on Wayland / X11).
  `dist/` is not in git (`packaging/` is: CI needs it); the packages are also copied to
  the Google Drive `GTTY/packages` folder (`GTTY_PKG_DIST`).
- **Script mode** (`gtty --script file`) is how to test UI changes: each line
  is typed into the prompt; hooks run directly: `/wait ms`, `/shot x.bmp`
  (screenshot; convert with `sips -s format png`), `/type text` (text + Enter
  through the real keyboard path), `/click x y` (real mouse event, window coords), `/dclick x y` (double click), `/down x y` / `/up x y` (left button), `/rclick x y` (right click), `/move x y` (mouse move, no button: hover / tooltips), `/drag x1 y1 x2 y2` (press, move, release), `/text text` (typed, no Enter),
  `/key ctrl+shift+left` (a key with modifiers: ctrl shift alt cmd + left right up down home end backspace delete enter escape tab c v insert a n t period pageup pagedown), `/resize w h`
  (gtty's OS window), `/menu run|settings|copy|paste|select-all|new-shell|new-window|sync-typing|about` (a menu pick; macOS
  menus can't be clicked from a script), `/target main|settings` (where
  the next /click /move /drag /text /key /type /shot go), `/mods
  cmd+shift|none` (modifier keys held, via SDL_SetModState), `/quit`. macOS blocks synthetic keystrokes (osascript), so use
  these. A shell window needs ~1.5 s (`/wait 1500`) before typing into it.
  Demo hooks (for the README animations): `/record start DIR [fps]` …
  `/record stop` (every frame, at most fps per second, scaled to the window
  size, as `frame-NNNNN.ppm` + `frames.txt` "file ms"; `App.rec`,
  `saveFrame`; while recording the script's mouse is drawn as an arrow
  with a ring on presses, `drawPointer`, and the empty prompt's AI hint
  is hidden), `/slow text` (typed one character every 50 ms, 80 after a
  space; no Enter), `/glide x y [ms]` (smooth mouse move, default 400 ms,
  keeps the button of the last `/down`), `/pace ms` (gap between script
  lines, default 400), `/dropover x y` / `/drop x y path` (SDL drop events
  as another app's drag would send: hover, then drop a file).
- **README animations** (`docs/images/*.webp`, animated WebP, loop
  forever): `docs/demo/make.sh [name…]` re-records them (all, or the
  named `docs/demo/<name>.gt`). It rebuilds the demo world with
  `docs/demo/setup.sh` (`$GTTY_DEMO_ROOT`, default /tmp/gtty-demo: a home
  with a neutral zsh prompt, the `shop` git project with branches,
  `Downloads/` for drops), runs gtty from `shop` with `HOME` / `ZDOTDIR`
  there, `GTTY_FONT_SIZE=16`, `GIT_PAGER=cat`, `GTTY_SHOW_DRY=1`,
  `GTTY_DRAG_DRY=1`, fills `@FRAMES@` / `@ROOT@` in the script, merges
  identical frames, holds the last 1.5 s, encodes with img2webp (lossy,
  q 80; `GTTY_DEMO_QUALITY`). Sizes: hero 1200×520, the rest 1200×760.
  Needs a display (the window shows while it records; keep the mouse off
  it) and overwrites the clipboard. After UI changes, check the
  coordinates in the scripts (title-bar copy ~25,24; chips y ~646 and the
  branch peek's expand ~52,638 at 1200×760; the folder chip moves right
  when the branch name is longer). The README shows no AI (not ready).
- Color test lines: use `\033`, not `\e` — macOS `/bin/bash` is 3.2 and its
  `echo -e` doesn't know `\e`. E.g. `/s bash` then
  `/type echo -e "\033[31mred \033[1;31mbold\033[0m"`; `/click` on the color
  pill (about x 88, y 21 for the current window at default size) toggles it.
- Other screenshots live in `docs/images/`. Take them with a neutral prompt
  (`ZDOTDIR` pointing at a dir whose `.zshrc` sets `PROMPT='%1~ %# '`), save
  with relative `/shot` paths (the status bar shows the path), and avoid
  output with user names (`ls -l`).
- Primary dev machine is macOS (Apple Silicon); Linux must keep working.

## Architecture

- `src/App.zig` — OS window, window system (current job window + job grid
  on the right), input routing (keys go to the
  focused running job, else the prompt), close rules (`closeWindow`,
  `closeOrKillMenu`), command resolution: `/name` → gtty;
  else something the shell knows → job; else a bare gtty name; else beep +
  red flash (text stays in the prompt).
- `src/ui/JobWindow.zig` — the job window object. It **owns** its process and
  PTY, **draws itself**, and **handles its own scaling** (resize / zoom /
  HiDPI → recompute grid → resize PTY). In a grid it keeps a normal-size title
  bar over its content rendered offscreen and scaled down (the PTY size never
  changes). Keep that ownership there.
- `src/ui/Prompt.zig` — 2-line command area; `src/ui/StatusBar.zig` — status
  bar: the file opener's help line on the left, short notices on the right.
- `src/ui/Peek.zig` — a chip's peek / expanded peek (git branches: filter,
  switch); App owns it and routes mouse / keys to it.
- `src/ui/Menu.zig` — pop-up menus: generic rows (label, key / note,
  enabled) + optional dim title; `purpose` = `edit` (right-click Copy /
  Paste), `open_with` (`show`'s app picker) or `bar` (a menu of the drawn
  menu bar: gtty / Edit, each row a `gtty_menu.h` code). App opens
  it and acts on the row picked.
- `src/sys/gtty_drag.{m,c}` — drag files out (macOS / Wayland);
  `src/sys/gtty_copy.c` — copying dropped files in the background.
- `src/ui/SettingsWindow.zig` — the settings window; `src/core/Config.zig`
  — settings file (parse / format unit-tested); `src/sys/gtty_menu.m` / `.c` — native menu (macOS) /
  none.
- `src/ui/FileOpener.zig` + `src/ui/file_path.zig` — the job window's
  file opener.
- `src/core/remote.zig` — ssh / mosh sessions (pure: argv parsing, gtty's
  connection argv, remote scripts); `src/core/RemoteLink.zig` — gtty's own
  connection to the remote machine (+ `Fetch`, one file).
- `src/sys/gtty_open.c` — default app / app list / open-with for `show`
  (macOS LaunchServices, needs CoreServices; Linux freedesktop tools).
- `src/core/git.zig` — branch from .git/HEAD (no git process; worktrees);
  `git.Run`: a git command in the background on a PTY, polled.
- `src/ui/commands.zig` — gtty command parser (pure, unit-tested). Names are
  short (`s`, `list`, `focus`, `close`, `zoom`, `colors`, `quit`, `help`); the OS wins on
  a clash (`clear`), `/name` reaches gtty's. Test hooks need the slash.
- `src/core/oscmd.zig` — does the OS know a command ($PATH, executable paths,
  common shell keywords/builtins). `src/core/ShellNames.zig` — the user's
  aliases/functions/builtins, asked from the real shell (`$SHELL -i -c …`) at
  startup on a PTY, polled from the main loop; refreshed when an `s` shell
  window exits. Commands that are aliases/functions run with `$SHELL -i -c`.
- `src/ui/ids.zig` — unique window ids; `src/ui/beep.zig` — error beep
  (`src/sys/gtty_beep.c` on macOS, SDL tone elsewhere).
- `src/ai/Ai.zig` — AI setup / request (curl) / answer parsing / danger
  check; `src/ai/system_prompt.md` — the system prompt; `src/ai/Memory.zig`
  — the AI's local memory.
- `src/core/Process.zig` + `src/sys/gtty_pty.c` — spawn on a PTY (stdin,
  stdout, stderr all on it). The C side still supports a separate stderr PTY,
  but the UX doc rules out split views, so it is unused.
- `src/core/Screen.zig` — scrollback + VT escape parser ("terminal-lite").
  A memory window (last `max_lines` rows, `--scrollback`); rows that wrapped
  at the edge are flagged so a width change reflows the text. Selection
  lives here too (line positions, adjusted on trim/reflow).
- `src/core/Tee.zig` — every job's full raw output in
  `$TMPDIR/gtty-<pid>/job-<serial>.log`; deleted with the window / on exit,
  stale folders swept at start. Copy-all rebuilds from it after rows drop.
- `src/core/color.zig` — theme (xterm 16-color table + 256 cube); colors
  stored as sent, resolved at draw time (`resolveBold`: bold → bright);
  contrast fix for unreadable colors. The per-window colors on/off flag
  (`JobWindow.colors`) is applied in `drawPane`, never to the stored cells.
- `src/render/Gfx.zig` — SDL_Renderer helpers (Metal on macOS), glyph cache per
  pixel size, lines/discs for icons, embedded JetBrains Mono.

## Conventions

- Repo: git.foodineat.com, org GTTY, repo gtty (Forgejo); public:
  GitHub `git@github.com:gttyterm/gitty.git` (repo name **gitty**). Local:
  ~/src/gtty/gtty.
- **GitHub Actions** (`.github/workflows/`): `ci.yml` (push to main,
  pull requests: build + unit tests on ubuntu-24.04 with `-Dbundled-sdl`
  and macos-15 with Homebrew SDL3; `contents: read`); `release.yml` (tag
  `v<version>`, must match build.zig.zon: macos-15, environment
  `release` with the signing secrets, runs `scripts/sign-macos.sh`
  (CI path: temporary keychain, API-key notarization) → build-bin.sh +
  package.sh, checks the dmg (codesign, stapler, spctl), SHA256SUMS,
  `gh release create` with the dmg, .deb, .rpm, .tar.gz; workflow-level
  `permissions: {}`, the job asks for `contents: write` explicitly; run by
  hand = the same build as an artifact, no release). The Finder layout
  of the dmg needs Automation access on the runner; if it fails the dmg
  is unarranged (warning only).
- Keep platform-specific C in `src/sys/`; keep `@cImport` only in `src/c.zig`.
- Every window gets a unique id (`ids.Id`, u32, shown as 8 hex digits);
  job windows also get a serial number (#1, #2, …): the label the user sees
  and the number gtty commands take (`focus 3`).
- Title bars: content actions on the left (copy, text size A−/A+ — never
  below 100%, colors on/off), window actions on the right (minimize,
  maximize, gap, red ×; × on a job still working opens the kill menu with a skull
  — only the skull kills; × on a finished window or a shell waiting at
  its prompt closes it; only minimize sends a window to the job grid).
- README: the project's advert: tagline, hero animation, install, one
  short animation per feature, no AI (not ready yet). The full user guide
  is `docs/guide.md`, the AI's docs wait in `docs/ai.md` (not linked),
  building / testing / source layout in `HACKING.md`.

## License

gtty is GPL-3.0-or-later (`LICENSE`), copyright Sagi Forbes Nagar
(exactly this name). Every new source file we write (.zig, .zon, .c,
.m, .h, .swift, shell scripts, .gt scripts) starts with:

```
// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later
```

(`#` for shell and .gt; after the `#!` line). Not in `src/ai/system_prompt.md`
(embedded in the binary). Never add code copied from elsewhere without
checking its license first; record third-party components in
`THIRD_PARTY.md`. Contributions: `CONTRIBUTING.md` (DCO sign-off,
`git commit -s`).

## Next up (not done yet)

- **AI, rest of work list item 10:** the target chip at the prompt
  (`✦ → #3 zsh`, pick a window / new / all), the ✦ in the marks strip that
  shows the generated code (read-only, copy icon), the footer AI chip
  (`✦ N`, its peek lists the scripts; a pick pastes one into the shell),
  hiding the `gtty-ai N '…'` line. AI in a remote (ssh) window: today it
  goes to a local shell. A real provider not yet tried (only the fake
  server and `GTTY_AI_REPLY`).

- Remote sessions, open: switching branches from the remote git chip;
  several copies at once / big-file warning; remotes without ps / lsof /
  /proc. Not yet tried against a real server (only the stand-in ssh).
- Find: a future job window command, not a subscriber.
- Running border lights ("snakes") for running jobs; maximized thin title bar.
- More chips; folder chip: siblings, a remote folder; peek shrink
  animation, selecting text inside a peek;
  modals, the ⋯ menu.
- Full-screen programs (vim, htop, less): alternate screen grid.
- Blinking text (SGR 5/6 is ignored today; nice-to-have, low priority;
  color-off should stop it too). Blinking cursor.
- Bold/italic faces; scrolling back past the memory window
  (older output is only in the tee file).
- New jobs started from the prompt still run in gtty's own folder (the git
  chip follows each window's process folder already).
- Readable minimum scale for grid content; default size 120×30 / font 15.
- Packages: Linux arm64; a Developer ID to sign + notarize the dmg.
