# gtty — work list (bugs first, then features, AI last)

Repo: `~/src/gtty/gtty`. Read `CLAUDE.md` first (build, script-mode testing, conventions) and the UX doc it points to. Work in this order. After each item: `zig build`, test it with a `--script` run (`/shot` to check visually), and update CLAUDE.md and the UX doc's "Implementation status" section. One commit per item.

## Already in the working tree (uncommitted, not compiled yet)

Item 1's fix is already written. Build and test it first:
- `src/App.zig`:
  - New `menuOwnsKey()`. At the top of `handle()`, a KEY_DOWN for ⌘C / ⌘V / ⌘A (no other modifiers) is dropped when the macOS menu bar's matching Edit row is enabled, because that row already fires for the same key press.
  - `menuPick` sends Paste and Select All to the files window when it has the keyboard (new `filesFocused()`). Copy is disabled while the files window has the keyboard.
- `src/core/shell_hooks.zig`: zsh `zle_highlight=(paste:none)` and bash `bind 'set enable-active-region off'`, both set before the user's config loads, so the user's own settings still win.


---

## Bugs

### 1. ⌘V pastes twice (macOS)
- ⌘V pastes the clipboard twice, and the second copy looks selected. The right-click menu's Paste works correctly.
- Cause: `onKey` handles ⌘V **and** the native Edit ▸ Paste key equivalent (`GTTY_MENU_PASTE` → `pasteKey`) also fires.
- Requirement: ⌘V and the context menu use **one** paste path. A paste only inserts the clipboard text and selects nothing.
- Check: ⌘V into a zsh shell, a bash shell, a `cat` window, the prompt, the settings window and the files window filter. Each must paste exactly once. ⌘A in the files window must still pick all files, and ⌘C must still copy.

### 2. Copy takes the first output chunk, not the last
- The title-bar copy in a running shell window copied the **first** command's output.
- The "last chunk" is everything from the last command the user entered to the last line of output (stdout and stderr together).
- Relevant code: `Screen.oscEnd` (OSC 133 C/D → `last_output`), `JobWindow.copyText`, `Tee.Log.readRange`. Not reproduced yet.
- Reproduce with a script (`s`, several `/type echo …`, click copy, paste into the prompt, `/shot`) in zsh and in bash.
- Suspects:
  - The C mark is printed only once: check `echo $PROMPT_COMMAND`, and whether the user's zsh config resets the hooks.
  - Tee-file offsets don't line up with `Screen.fed`.
- Add a unit test that feeds a multi-command session.

### 3. Emoji and icon characters show as `?`
- Examples: ✅ ❌ ✔ ✖. Copying them out gives the right characters, so the stored text is fine and only drawing is wrong.
- Fix in `Gfx`:
  - **Font fallback:** macOS Apple Color Emoji / Apple Symbols; Linux Noto Color Emoji via fontconfig. Bundled-SDL builds need the font files found at run time.
  - **Color glyphs:** draw them as color images, not tinted text.
  - **Double width:** emoji take 2 cells (wcwidth), so the cursor and the line layout stay correct in shells and editors.

### 4. Linux: the Tab-completion file list appears, then vanishes at once
- Suspects:
  - Key-up or auto-repeat events (X11/Wayland send a release; held keys repeat).
  - A focus or pointer event treated as "clicked elsewhere".
  - Shell output (the prompt being redrawn after Tab) closing it.
- Find out which window or popup this is, and whether it happens at gtty's prompt, in a shell window, or both.

---

## Quick features

### 5. Shell exit = close, with a runaway guard
- When a shell **exits for any reason** (`exit`, crash), treat it exactly like pressing × on its title bar: it goes to the job grid and a new shell starts immediately. Today only a close does this (`ensureShell`); a self-exit doesn't.
- Guard: if more than 5 shells were opened within 5 seconds, stop auto-restarting (something is closing them in a loop). Show a status notice. The next shell the user opens turns auto-restart back on.
- Open question for the user: does a new shell start even when another shell window is still running? Today's `ensureShell` says no (only when no shell is left).

### 6. Right-click menu: paste history
- Every copy to the clipboard **from a job window** (selection ⌘C, title-bar copy, menu Copy) pushes the **previous** clipboard value onto a last-in-first-out list.
- The menu row **Paste ▸**:
  - Clicking **Paste** pastes the current clipboard (the same path as ⌘V, see item 1).
  - Clicking **▸** opens a submenu of the **last 5** values. Each is one line: line breaks shown as `⏎` or a space, cut to **20 characters** with `…`.
  - Picking one pastes it into that job.

### 7. Right-click menu: folder history
- A **History ▸** row in the same menu.
- Whenever the shell in a job window moves to a different folder, the folder it **left** is pushed onto a last-in-first-out list, up to **10** entries.
- How gtty learns the folder: add an OSC 7 hook (`printf '\e]7;file://%s%s\a'` with host and `$PWD`) in zsh `chpwd`/precmd and in bash `PROMPT_COMMAND`. Fall back to `gtty_proc_cwd`.
- Picking a folder in a running shell at its prompt types `\x15cd -- '<path>'\r`, the same as the file opener does.
- Each job window keeps its own list.

### 8. Folder chip in the job window footer
- Bring the folder chip back, in the footer strip next to the git chip. It shows the current folder name.
- Clicking it opens a peek that **grows upwards** listing every folder from the current one up to `/`. The **parent** of the current folder is closest to the chip and `/` is at the top.
- Picking a folder `cd`s there (running shell at its prompt only), and that also feeds item 7's history.

### 9. Left-border marks (replace the hover mark)
- **Remove** the blue hover mark and the hairline gutter; the hover mark isn't used.
- New left edge, from left to right: window border, **1 px space**, then a **marks strip** (default 3 px):
  - **green** `#25D366` (WhatsApp-like) on rows the **user typed** (the command line);
  - **gray** `#8A8A8A` on **output** rows;
  - **purple** on anything **AI-related** (item 10);
  - nothing on prompt rows, so each command reads as a green block followed by a gray block.
- Shells: add the OSC 133 **B** mark (end of prompt) to the hooks. Input = B → C, output = C → D.
- Other programs (no marks): rows echoed right after the user's keystrokes count as input; the rest is output.
- Configurable in Settings and env: `GTTY_MARK_INPUT`, `GTTY_MARK_OUTPUT`, `GTTY_MARK_AI`, `GTTY_MARK_WIDTH`, `GTTY_MARKS=0` (off).

---

## Big feature (last)

### 10. AI in gtty
- **Settings:** provider and endpoint (a local model such as Ollama, or an API), model, API key, auto-run on or off, "always show AI code expanded".
- **Where you type:** the **prompt**. An AI mode (a key such as Ctrl+Space, or a leading `?`) shows a **target chip** at the left of the prompt, e.g. `✦ → #3 zsh`. The target is the current job window by default; click the chip or press Ctrl+Tab to change it (a window, "new shell", "all").
- **System prompt:** the draft is `docs/ai-system-prompt.md`. Put it at `src/ai/system_prompt.md` and load it with `@embedFile`.
  - The AI is limited to gtty commands and shell commands or scripts that reach the goal.
  - It replies with JSON only: `summary`, `actions` (`gt` / `shell` / `message`) and `danger`.
  - Request flags: `-r` recursive from the current folder, `-n` dry run, `-a` include hidden files, `-x` show the code expanded (gtty handles `-x` itself and doesn't send it to the AI).
  - Hidden files and anything the user can't read are skipped. Scripts must work on both macOS and Linux and must not overwrite files by default.
  - Examples: "open a new shell at <folder>" → `gt sh --cwd <folder>`; "copy all doc files to <folder> -r" → a script that decides by `file --mime-type` (text, PDF, Office, ODF, RTF, EPUB, JSON, XML).
  - `danger: true` (delete, overwrite, move, kill, `sudo`) → gtty asks the user before running anything.
- **New gtty commands needed:** `sh --cwd <folder>` (and `focus #N` if it isn't there yet).
- **Running a script without showing it:** write it to `$TMPDIR/gtty-<pid>/ai-<n>.sh` and send the shell `. '<file>'`. gtty hides that line, using the marks, and shows **the user's request** in its place. Output shows normally.
- **AI marks:** the request line and its output get a **purple** left-border mark (item 9), with no extra symbol in the text. A **✦** in the marks strip on the request line toggles the **generated code**, shown expanded and read-only under the request with a copy icon, plus the exact line sent to the shell in small gray text. `-x` or the setting shows it expanded straight away. The expanded code is never written to the tee log, so copy (item 2) never includes it.
- **AI chip** in the job window footer: `✦ N` (scripts run in this window). Its peek lists them newest first with summary, time and exit status. Picking one **pastes the script into the shell's input** without running it.
