# Claude Terminal for Godot 4.7+

Adds a **Claude** tab to the bottom panel of the Godot editor that runs Claude Code in this project.

## Install
1. Copy `addons/claude_terminal/` into your project's `addons/` folder.
2. Project → Project Settings → Plugins → enable **Claude Terminal**.
3. Claude Code must be installed and logged in (run `claude` once in a terminal).

## Use
- Type a message, press **Enter** (Shift+Enter = new line).
- **Send editor context** tells Claude your open scene, selected nodes and open script.
- **Permission mode**: Auto-accept edits (default), Plan only (read-only), or Bypass all (also allows shell commands).
- **Live status**: spinner, current step and timer at the top; Claude's reply streams in as it is written.
- **Activity list** (right): every tool call with its run time (✓ done, ✗ failed), subagent work nested under its parent, and your MCP servers with their status.
- **MCP** checkbox: untick if MCP servers clash with other Claude sessions (e.g. busy ports); Claude still edits files directly.
- **New chat** starts fresh. **Stop** cancels. **Open terminal** opens the full interactive Claude Code in this project.
- Any MCP servers you set up for Claude Code (e.g. Godot MCP Pro) work from the panel too.

## Settings (Editor Settings → claude_terminal)
- `claude_path` – full path to `claude` if it isn't found automatically.
- `model` – optional model name.
- `use_mcp_servers` – same as the MCP checkbox.
