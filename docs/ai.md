# Asking the AI (not released yet)

Kept out of the README and the user guide until the feature is ready.

Turn it on in **Settings → AI**: pick a provider (click the button to go
through **Anthropic (Claude)**, **Google Gemini**, **xAI Grok**,
**OpenAI-compatible** and **Ollama (local)**), and paste your API key,
unless it is already in `$ANTHROPIC_API_KEY`, `$GEMINI_API_KEY`,
`$XAI_API_KEY` or `$OPENAI_API_KEY`. OpenAI-compatible also covers
OpenAI, Mistral, Groq, DeepSeek, OpenRouter and local servers (LM Studio,
llama.cpp): set the endpoint, e.g. `https://api.mistral.ai/v1`. Ollama needs no key, and nothing
leaves your computer. Model and endpoint can stay empty: the provider's
defaults are shown greyed out. Until it is set up, gtty works as before,
and the empty prompt reminds you that the AI is there.

With the AI on, the prompt shows **✦ ›** and whatever you type goes to the
AI. Say what you want in plain words, e.g.:

```
copy all doc files to ~/docs -r
show me the 10 biggest files in my downloads
convert the png pictures here to jpg
connect to the build server
```

The AI answers with **one script and runs it right away**, without asking
you questions, in the shell window you're working in (or a new one when
none is waiting at its prompt). The shell's line shows your request
(`gtty-ai 3 'copy all doc files to ~/docs -r'`), and the request and its
output are marked **purple** on the left edge.

- **Commands still work.** gtty's own commands (`s`, `list`, `close 3`,
  `focus 2`, …) run at once, without the AI. A command for the shell
  (`ls -la`, `git status`) goes to the AI, which hands it back unchanged.
  To skip the AI, start the line with **`!`** (`!make`).
- **Risky scripts ask first.** A script that deletes, moves, overwrites,
  edits files in place, kills programs, uses `sudo` or sends anything over
  the network is printed in the shell, followed by `Run it? [y/N]`. The window
  takes the keyboard for your answer. gtty checks every script for
  these itself, even when the AI didn't flag it.
- **Flags:** `-r` everything below the current folder (not only the
  folder itself), `-a` include hidden files, `-n` dry run (only list what
  would be done), `-x` show the script before it runs.
- **Esc** at the prompt cancels a request that is still waiting for an
  answer.
- **Your files stay yours.** Each request sends your words, the folder
  names, the list of windows and gtty's memory, never what is inside your
  files. The AI is told never to upload or send your files anywhere unless
  you ask for exactly that, and such a script always asks first.
- **Local memory.** gtty remembers the folders your shells visit (and the
  kinds of files in them), the ssh hosts you use, and short notes the AI
  keeps ("tax papers are in ~/Documents/Finance"). That's how "my photos"
  or "the build server" can be found. It lives in
  `~/.local/state/gtty/ai-memory` (`$XDG_STATE_HOME`), a text file you can
  read or edit. Turn it off, or **Forget** it, in Settings → AI.

The left-edge marks show what the AI ran in **purple** (`GTTY_MARK_AI`); `GTTY_AI_PROVIDER=anthropic GTTY_AI_KEY=… gtty` turns it on for one run (also `GTTY_AI_MODEL`, `GTTY_AI_ENDPOINT`).
