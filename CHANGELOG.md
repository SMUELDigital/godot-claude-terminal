# Changelog

All notable changes to this project are listed here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-10-17

### Added
- Live status bar with spinner, current step and elapsed time.
- Streaming replies (Claude's text appears as it is written).
- Activity list showing every tool call with live run time and ✓/✗ result; subagent tool calls are nested under their parent.
- MCP server list with connected/failed status, and a clear warning when a server fails to start.
- **MCP** checkbox and `use_mcp_servers` setting to run the panel without MCP servers.
- Token counter for the current chat.
- Tool call count in the "done" line.

### Changed
- MCP tool names are shown in a readable form (`server › tool`).

## [1.0.0] - 2026-10-17

### Added
- Claude bottom panel in the Godot editor running Claude Code in stream-json mode.
- Persistent conversation per chat, resumed after restarts.
- Editor context (open scene, selected nodes, open script).
- Permission modes: auto-accept edits, plan only, bypass all permissions.
- New chat, Stop and Open terminal buttons.
- Automatic detection of the `claude` executable on Windows, macOS and Linux.
- Automatic file system rescan after each reply.
