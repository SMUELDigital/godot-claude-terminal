@tool
extends VBoxContainer
## Claude Code chat panel for the Godot editor.
## Runs one long-lived `claude -p --input-format stream-json` process per chat,
## streams Claude's reply live and shows running tools, subagents and MCP servers.

const SETTING_PATH := "claude_terminal/claude_path"
const SETTING_MODE := "claude_terminal/permission_mode"
const SETTING_MODEL := "claude_terminal/model"
const SETTING_MCP := "claude_terminal/use_mcp_servers"

const MODES := ["acceptEdits", "plan", "bypassPermissions"]
const MODE_LABELS := ["Auto-accept edits", "Plan only (read-only)", "Bypass all permissions"]

const C_USER := "#7aa2f7"
const C_CLAUDE := "#e0af68"
const C_DIM := "#8a8f98"
const C_ERR := "#f7768e"
const C_WARN := "#ff9e64"
const C_OK := "#9ece6a"
const C_RUN := "#7dcfff"

const SPIN := ["◐", "◓", "◑", "◒"]
const MAX_ACTIVITY := 40

var _output: RichTextLabel
var _input: TextEdit
var _status: Label
var _stats: Label
var _send_btn: Button
var _stop_btn: Button
var _mode_opt: OptionButton
var _ctx_check: CheckBox
var _mcp_check: CheckBox
var _tree: Tree
var _mcp_root: TreeItem
var _act_root: TreeItem
var _ticker: Timer

var _pid := -1
var _stdio: FileAccess
var _stderr: FileAccess
var _threads: Array[Thread] = []
var _session_id := ""
var _busy := false
var _claude_path := ""

# live state
var _state := "Idle"
var _run_start := 0
var _spin := 0
var _tools := {}          # tool_use_id -> {item, start, label, done}
var _streamed := {}       # message ids whose text was already streamed
var _cur_msg_id := ""
var _in_text := false
var _mcp_warned := {}
var _turn_tools := 0
var _tok_in := 0
var _tok_out := 0


# ---------------------------------------------------------------- UI

func _ready() -> void:
	custom_minimum_size = Vector2(0, 260)

	var top := HBoxContainer.new()
	add_child(top)

	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	top.add_child(_status)

	_stats = Label.new()
	_stats.add_theme_color_override("font_color", Color(C_DIM))
	top.add_child(_stats)

	_ctx_check = CheckBox.new()
	_ctx_check.text = "Editor context"
	_ctx_check.tooltip_text = "Tell Claude which scene, nodes and script you have open."
	_ctx_check.button_pressed = true
	top.add_child(_ctx_check)

	_mcp_check = CheckBox.new()
	_mcp_check.text = "MCP"
	_mcp_check.tooltip_text = "Let Claude start your MCP servers (e.g. Godot MCP Pro).\nUntick if they clash with other Claude sessions; Claude still edits files directly."
	_mcp_check.button_pressed = bool(_get_setting(SETTING_MCP, true))
	_mcp_check.toggled.connect(_on_mcp_toggled)
	top.add_child(_mcp_check)

	_mode_opt = OptionButton.new()
	for i in MODE_LABELS.size():
		_mode_opt.add_item(MODE_LABELS[i], i)
	_mode_opt.select(max(0, MODES.find(_mode())))
	_mode_opt.tooltip_text = "What Claude may do without asking.\nShell commands need 'Bypass all permissions'."
	_mode_opt.item_selected.connect(_on_mode_selected)
	top.add_child(_mode_opt)

	var new_btn := Button.new()
	new_btn.text = "New chat"
	new_btn.pressed.connect(_on_new_chat)
	top.add_child(new_btn)

	var term_btn := Button.new()
	term_btn.text = "Open terminal"
	term_btn.tooltip_text = "Open the full interactive Claude Code in a system terminal, in this project."
	term_btn.pressed.connect(_on_open_terminal)
	top.add_child(term_btn)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)

	_output = RichTextLabel.new()
	_output.bbcode_enabled = true
	_output.scroll_following = true
	_output.selection_enabled = true
	_output.context_menu_enabled = true
	_output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(_output)

	_tree = Tree.new()
	_tree.custom_minimum_size = Vector2(300, 0)
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	split.add_child(_tree)
	var root := _tree.create_item()
	_mcp_root = _tree.create_item(root)
	_mcp_root.set_text(0, "MCP servers")
	_mcp_root.set_selectable(0, false)
	_act_root = _tree.create_item(root)
	_act_root.set_text(0, "Activity")
	_act_root.set_selectable(0, false)
	_reset_tree()

	var bottom := HBoxContainer.new()
	add_child(bottom)

	_input = TextEdit.new()
	_input.placeholder_text = "Ask Claude…  (Enter to send, Shift+Enter for a new line)"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size = Vector2(0, 56)
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input.gui_input.connect(_on_input_gui)
	bottom.add_child(_input)

	var btns := VBoxContainer.new()
	bottom.add_child(btns)
	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.pressed.connect(_on_send)
	btns.add_child(_send_btn)
	_stop_btn = Button.new()
	_stop_btn.text = "Stop"
	_stop_btn.disabled = true
	_stop_btn.pressed.connect(_on_stop)
	btns.add_child(_stop_btn)

	_ticker = Timer.new()
	_ticker.wait_time = 0.15
	_ticker.timeout.connect(_tick)
	add_child(_ticker)
	_ticker.start()

	_get_setting(SETTING_PATH, "", PROPERTY_HINT_GLOBAL_FILE)
	_get_setting(SETTING_MODEL, "")
	_set_busy(false)
	_update_stats()
	_welcome()


func _welcome() -> void:
	_append("[color=%s]Claude Code in Godot — project: %s\nEnter sends, Shift+Enter adds a line. Claude works on the files in this project.[/color]\n" % [C_DIM, _esc(_project_dir())])


func _reset_tree() -> void:
	_clear_children(_mcp_root)
	_clear_children(_act_root)
	var none := _tree.create_item(_mcp_root)
	none.set_text(0, "(starts with the first message)")
	none.set_custom_color(0, Color(C_DIM))
	_tools.clear()


func _on_input_gui(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo \
			and (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) \
			and not k.shift_pressed:
		_input.accept_event()
		_on_send()


# ---------------------------------------------------------------- live status

func _tick() -> void:
	if not _busy:
		return
	_spin = (_spin + 1) % SPIN.size()
	var now := Time.get_ticks_msec()
	_status.text = "%s  %s   %ds" % [SPIN[_spin], _state, (now - _run_start) / 1000]
	for id in _tools:
		var t: Dictionary = _tools[id]
		if not t["done"]:
			var item: TreeItem = t["item"]
			item.set_text(0, "%s %s · %ds" % [SPIN[_spin], t["label"], (now - int(t["start"])) / 1000])


func _set_state(s: String) -> void:
	_state = s
	if _busy:
		_status.text = "%s  %s   %ds" % [SPIN[_spin], _state, (Time.get_ticks_msec() - _run_start) / 1000]


func _set_busy(b: bool) -> void:
	if b and not _busy:
		_run_start = Time.get_ticks_msec()
		_turn_tools = 0
		_state = "Starting Claude…" if _pid <= 0 else "Thinking…"
	_busy = b
	if _send_btn:
		_send_btn.disabled = b
		_stop_btn.disabled = not b
		if b:
			_set_state(_state)
		elif _pid > 0:
			_status.text = "●  Ready — session open"
		else:
			_status.text = "○  Idle"


func _update_stats() -> void:
	_stats.text = "%s in · %s out " % [_fmt_k(_tok_in), _fmt_k(_tok_out)]
	_stats.tooltip_text = "Tokens used in this chat"


# ---------------------------------------------------------------- actions

func _on_send() -> void:
	var text := _input.text.strip_edges()
	if text.is_empty() or _busy:
		return
	_input.text = ""
	_end_text_line()
	_append("\n[color=%s][b]You:[/b][/color] %s\n" % [C_USER, _esc(text)])

	var prompt := text
	if _ctx_check.button_pressed:
		var ctx := _editor_context()
		if ctx != "":
			prompt = ctx + "\n\n" + text

	var was_running := _pid > 0 and OS.is_process_running(_pid)
	if not _ensure_process():
		return
	var msg := {
		"type": "user",
		"message": {"role": "user", "content": [{"type": "text", "text": prompt}]},
	}
	_stdio.store_string(JSON.stringify(msg) + "\n")
	_stdio.flush()
	_set_busy(true)
	_set_state("Thinking…" if was_running else "Starting Claude…")


func _on_stop() -> void:
	_kill_process()
	_end_text_line()
	_append("[color=%s]  — stopped[/color]\n" % C_DIM)


func _on_new_chat() -> void:
	_kill_process()
	_session_id = ""
	_tok_in = 0
	_tok_out = 0
	_mcp_warned.clear()
	_streamed.clear()
	_in_text = false
	_output.clear()
	_reset_tree()
	_update_stats()
	_welcome()


func _on_mode_selected(index: int) -> void:
	EditorInterface.get_editor_settings().set_setting(SETTING_MODE, MODES[index])
	if _pid > 0:
		_kill_process()  # next message restarts and resumes with the new mode
	_append("[color=%s]  Permission mode: %s[/color]\n" % [C_DIM, MODE_LABELS[index]])


func _on_mcp_toggled(on: bool) -> void:
	EditorInterface.get_editor_settings().set_setting(SETTING_MCP, on)
	if _pid > 0:
		_kill_process()
	_append("[color=%s]  MCP servers %s (applies from the next message)[/color]\n" % [C_DIM, "on" if on else "off"])


func _on_open_terminal() -> void:
	var dir := _project_dir()
	var claude := _resolve_claude()
	if claude == "":
		claude = "claude"
	match OS.get_name():
		"Windows":
			OS.create_process("cmd.exe", PackedStringArray(["/c", "start", "Claude Code", "/D", dir, "cmd", "/k", claude]))
		"macOS":
			var cmd := "cd %s && %s" % [_sh_quote(dir), _sh_quote(claude)]
			OS.create_process("osascript", PackedStringArray([
				"-e", 'tell application "Terminal" to do script "%s"' % cmd.replace("\\", "\\\\").replace("\"", "\\\""),
				"-e", 'tell application "Terminal" to activate',
			]))
		_:
			var inner := "cd %s && %s; exec bash" % [_sh_quote(dir), _sh_quote(claude)]
			var terms := [
				["gnome-terminal", ["--"]], ["konsole", ["-e"]], ["xfce4-terminal", ["-x"]],
				["kitty", []], ["alacritty", ["-e"]], ["x-terminal-emulator", ["-e"]], ["xterm", ["-e"]],
			]
			for t in terms:
				if OS.execute("which", PackedStringArray([t[0]])) == 0:
					OS.create_process(t[0], PackedStringArray(t[1] + ["bash", "-lc", inner]))
					return
			_append("[color=%s]No terminal emulator found.[/color]\n" % C_ERR)


# ---------------------------------------------------------------- process

func _ensure_process() -> bool:
	if _pid > 0 and OS.is_process_running(_pid):
		return true
	_kill_process()

	var claude := _resolve_claude()
	var cmd := _build_command(claude)
	var res: Dictionary = OS.execute_with_pipe(cmd[0], cmd[1], true)
	if res.is_empty():
		_append("[color=%s]Could not start Claude Code. Install it, or set its full path in Editor Settings → %s.[/color]\n" % [C_ERR, SETTING_PATH])
		return false

	_pid = res["pid"]
	_stdio = res["stdio"]
	_stderr = res["stderr"]
	_start_reader(_stdio, _pid, false)
	_start_reader(_stderr, _pid, true)
	_clear_children(_mcp_root)
	var wait := _tree.create_item(_mcp_root)
	wait.set_text(0, "connecting…")
	wait.set_custom_color(0, Color(C_DIM))
	return true


func _build_command(claude: String) -> Array:
	var flags := PackedStringArray([
		"-p", "--input-format", "stream-json", "--output-format", "stream-json",
		"--verbose", "--include-partial-messages", "--permission-mode", _mode(),
	])
	if _session_id != "":
		flags.append_array(PackedStringArray(["--resume", _session_id]))
	var model := str(_get_setting(SETTING_MODEL, ""))
	if model != "":
		flags.append_array(PackedStringArray(["--model", model]))
	if not bool(_get_setting(SETTING_MCP, true)):
		flags.append_array(PackedStringArray(["--strict-mcp-config", "--mcp-config", _empty_mcp_config()]))

	var dir := _project_dir()
	if OS.get_name() == "Windows":
		var exe := claude if claude != "" else "claude"
		var quoted := PackedStringArray()
		for f in flags:
			quoted.append('"%s"' % f if str(f).contains(" ") else str(f))
		var line := 'cd /d "%s" && "%s" %s' % [dir, exe, " ".join(quoted)]
		return ["cmd.exe", PackedStringArray(["/d", "/s", "/c", line])]

	var args: PackedStringArray
	var shell := "/bin/sh"
	if claude != "":
		args = PackedStringArray(["-c", 'cd "$1" || exit 1; shift; exec "$@"', "claude-godot", dir, claude])
	else:
		# Not found: let the user's login shell find it on PATH.
		shell = OS.get_environment("SHELL") if OS.get_environment("SHELL") != "" else "/bin/bash"
		args = PackedStringArray(["-lc", 'cd "$1" || exit 1; shift; exec claude "$@"', "claude-godot", dir])
	args.append_array(flags)
	return [shell, args]


func _empty_mcp_config() -> String:
	var path := "user://claude_terminal_no_mcp.json"
	if not FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string('{"mcpServers": {}}')
			f.close()
	var p := ProjectSettings.globalize_path(path)
	return p.replace("/", "\\") if OS.get_name() == "Windows" else p


func _start_reader(pipe: FileAccess, pid: int, is_err: bool) -> void:
	var t := Thread.new()
	_threads.append(t)
	t.start(_read_loop.bind(t, pipe, pid, is_err))


func _read_loop(t: Thread, pipe: FileAccess, pid: int, is_err: bool) -> void:
	while true:
		var line := pipe.get_line()
		if line.is_empty():
			if pipe.get_error() != OK or not OS.is_process_running(pid):
				break
			continue
		if is_err:
			_on_err_line.call_deferred(pid, line)
		else:
			_on_line.call_deferred(pid, line)
	if not is_err:
		_on_process_ended.call_deferred(pid)
	_on_thread_done.call_deferred(t)


func _on_thread_done(t: Thread) -> void:
	if t.is_started():
		t.wait_to_finish()
	_threads.erase(t)


func _kill_process() -> void:
	if _pid > 0:
		if OS.get_name() == "Windows":
			# /T also ends the MCP servers Claude started, so their ports are freed.
			OS.execute("taskkill", PackedStringArray(["/PID", str(_pid), "/T", "/F"]))
		else:
			OS.kill(_pid)
	_pid = -1
	_stdio = null
	_stderr = null
	_finish_running_tools("■ stopped")
	_set_busy(false)


func shutdown() -> void:
	_kill_process()
	var deadline := Time.get_ticks_msec() + 1500
	for t in _threads.duplicate():
		while t.is_alive() and Time.get_ticks_msec() < deadline:
			OS.delay_msec(20)
		if not t.is_alive():
			t.wait_to_finish()
			_threads.erase(t)


func _on_process_ended(pid: int) -> void:
	if pid != _pid:
		return
	if _busy:
		_end_text_line()
		_append("[color=%s]Claude Code exited. Check the messages above, or click \"Open terminal\" to log in.[/color]\n" % C_ERR)
	_pid = -1
	_stdio = null
	_stderr = null
	_finish_running_tools("■ ended")
	_set_busy(false)


# ---------------------------------------------------------------- stream-json events

func _on_err_line(pid: int, line: String) -> void:
	if pid == _pid:
		_end_text_line()
		_append("[color=%s]%s[/color]\n" % [C_DIM, _esc(line)])


func _on_line(pid: int, line: String) -> void:
	if pid != _pid:
		return
	var data = JSON.parse_string(line)
	if typeof(data) != TYPE_DICTIONARY:
		_end_text_line()
		_append("[color=%s]%s[/color]\n" % [C_DIM, _esc(line)])
		return

	var parent = data.get("parent_tool_use_id", null)
	match str(data.get("type", "")):
		"system":
			_on_system(data)
		"stream_event":
			if parent == null:
				_on_stream_event(data.get("event", {}))
		"assistant":
			_on_assistant(data, parent)
		"user":
			_on_tool_results(data, parent)
		"result":
			_on_result(data)


func _on_system(data: Dictionary) -> void:
	var subtype := str(data.get("subtype", ""))
	if subtype == "init":
		_session_id = str(data.get("session_id", _session_id))
		_set_state("Thinking…  (%s)" % str(data.get("model", "claude")))
		_show_mcp(data.get("mcp_servers", []))
	elif subtype.contains("task"):
		var item := _tree.create_item(_act_root)
		var desc := str(data.get("description", data.get("summary", "")))
		item.set_text(0, "◆ %s %s" % [subtype.replace("_", " "), _short(desc, 60)])
		item.set_custom_color(0, Color(C_DIM))
		_trim_activity()


func _show_mcp(servers) -> void:
	_clear_children(_mcp_root)
	if typeof(servers) != TYPE_ARRAY or servers.is_empty():
		var none := _tree.create_item(_mcp_root)
		none.set_text(0, "(none)" if _mcp_check.button_pressed else "(off)")
		none.set_custom_color(0, Color(C_DIM))
		return
	for s in servers:
		if typeof(s) != TYPE_DICTIONARY:
			continue
		var server_name := str(s.get("name", "?"))
		var status := str(s.get("status", "?"))
		var item := _tree.create_item(_mcp_root)
		var ok := status == "connected"
		item.set_text(0, "%s %s — %s" % ["●" if ok else "○", server_name, status])
		item.set_custom_color(0, Color(C_OK if ok else (C_ERR if status == "failed" else C_DIM)))
		if status == "failed" and not _mcp_warned.has(server_name):
			_mcp_warned[server_name] = true
			_end_text_line()
			_append("[color=%s]  MCP server '%s' could not start. Its port may be in use by another Claude session. Claude will still edit files directly; untick MCP to stop trying.[/color]\n" % [C_WARN, _esc(server_name)])


func _on_stream_event(ev) -> void:
	if typeof(ev) != TYPE_DICTIONARY:
		return
	match str(ev.get("type", "")):
		"message_start":
			_cur_msg_id = str(ev.get("message", {}).get("id", ""))
		"content_block_start":
			var cb = ev.get("content_block", {})
			match str(cb.get("type", "")):
				"text":
					_set_state("Writing…")
				"thinking":
					_set_state("Thinking…")
				"tool_use":
					_set_state("Preparing %s…" % _short_tool_name(str(cb.get("name", "tool"))))
		"content_block_delta":
			var d = ev.get("delta", {})
			match str(d.get("type", "")):
				"text_delta":
					if not _in_text:
						_append("[color=%s][b]Claude:[/b][/color] " % C_CLAUDE)
						_in_text = true
					_output.add_text(str(d.get("text", "")))
					_streamed[_cur_msg_id] = true
				"thinking_delta":
					_set_state("Thinking…")
		"content_block_stop":
			_end_text_line()


func _on_assistant(data: Dictionary, parent) -> void:
	var msg = data.get("message", {})
	var content = msg.get("content", [])
	if typeof(content) != TYPE_ARRAY:
		return
	var mid := str(msg.get("id", ""))
	for block in content:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		match str(block.get("type", "")):
			"text":
				if parent == null and not _streamed.has(mid):
					var txt := str(block.get("text", "")).strip_edges()
					if txt != "":
						_end_text_line()
						_append("[color=%s][b]Claude:[/b][/color] %s\n" % [C_CLAUDE, _esc(txt)])
			"tool_use":
				_tool_started(block, parent)


func _tool_started(block: Dictionary, parent) -> void:
	var id := str(block.get("id", ""))
	var label := _tool_summary(block)
	var under := _act_root
	if parent != null and _tools.has(str(parent)):
		under = _tools[str(parent)]["item"]
	var item := _tree.create_item(under)
	item.set_text(0, "%s %s" % [SPIN[_spin], label])
	item.set_tooltip_text(0, label)
	item.set_custom_color(0, Color(C_RUN))
	item.set_metadata(0, id)
	_tools[id] = {"item": item, "start": Time.get_ticks_msec(), "label": label, "done": false}
	_turn_tools += 1
	if parent == null:
		_end_text_line()
		_append("[color=%s]  ⚙ %s[/color]\n" % [C_DIM, _esc(label)])
		_set_state("Running %s…" % _short_tool_name(str(block.get("name", "tool"))))
	_trim_activity()
	_tree.scroll_to_item(item)


func _on_tool_results(data: Dictionary, parent) -> void:
	var content = data.get("message", {}).get("content", [])
	if typeof(content) != TYPE_ARRAY:
		return
	for block in content:
		if typeof(block) != TYPE_DICTIONARY or block.get("type", "") != "tool_result":
			continue
		var id := str(block.get("tool_use_id", ""))
		var is_err := bool(block.get("is_error", false))
		if _tools.has(id):
			var t: Dictionary = _tools[id]
			t["done"] = true
			var item: TreeItem = t["item"]
			var secs := (Time.get_ticks_msec() - int(t["start"])) / 1000.0
			item.set_text(0, "%s %s · %.1fs" % ["✗" if is_err else "✓", t["label"], secs])
			item.set_custom_color(0, Color(C_ERR if is_err else C_OK))
			item.collapsed = true
		if parent == null:
			if is_err:
				_end_text_line()
				_append("[color=%s]  ✗ %s[/color]\n" % [C_ERR, _esc(_short(_result_text(block), 200))])
			_set_state("Thinking…")


func _on_result(data: Dictionary) -> void:
	_end_text_line()
	_session_id = str(data.get("session_id", _session_id))
	if data.get("is_error", false):
		_append("[color=%s]%s[/color]\n" % [C_ERR, _esc(str(data.get("result", "Error")))])
	var denials = data.get("permission_denials", [])
	if typeof(denials) == TYPE_ARRAY and denials.size() > 0:
		var names := PackedStringArray()
		for d in denials:
			if typeof(d) == TYPE_DICTIONARY:
				names.append(str(d.get("tool_name", "?")))
		_append("[color=%s]  Blocked by permission mode: %s. Change the mode at the top to allow it.[/color]\n" % [C_WARN, ", ".join(names)])
	var usage = data.get("usage", {})
	if typeof(usage) == TYPE_DICTIONARY:
		_tok_in += int(usage.get("input_tokens", 0)) + int(usage.get("cache_read_input_tokens", 0)) + int(usage.get("cache_creation_input_tokens", 0))
		_tok_out += int(usage.get("output_tokens", 0))
		_update_stats()
	_append("[color=%s]  — done in %.1fs · %d tool calls[/color]\n" % [C_DIM, float(data.get("duration_ms", 0)) / 1000.0, _turn_tools])
	_finish_running_tools("■ ended")
	_set_busy(false)
	EditorInterface.get_resource_filesystem().scan()


func _finish_running_tools(mark: String) -> void:
	for id in _tools:
		var t: Dictionary = _tools[id]
		if not t["done"]:
			t["done"] = true
			var item: TreeItem = t["item"]
			item.set_text(0, "%s %s" % [mark, t["label"]])
			item.set_custom_color(0, Color(C_DIM))


func _trim_activity() -> void:
	while _act_root.get_child_count() > MAX_ACTIVITY:
		var first := _act_root.get_first_child()
		_forget_tools(first)
		first.free()


func _forget_tools(item: TreeItem) -> void:
	_tools.erase(str(item.get_metadata(0)))
	for c in item.get_children():
		_forget_tools(c)


func _end_text_line() -> void:
	if _in_text:
		_output.add_text("\n")
		_in_text = false


func _tool_summary(block: Dictionary) -> String:
	var tool_name := _short_tool_name(str(block.get("name", "tool")))
	var input = block.get("input", {})
	if typeof(input) == TYPE_DICTIONARY:
		for key in ["description", "file_path", "command", "pattern", "path", "url", "prompt"]:
			if input.has(key):
				return "%s: %s" % [tool_name, _short(str(input[key]), 90)]
	return tool_name


func _short_tool_name(n: String) -> String:
	# mcp__godot-mcp-pro__add_node -> godot-mcp-pro › add_node
	if n.begins_with("mcp__"):
		var parts := n.trim_prefix("mcp__").split("__", true, 1)
		if parts.size() == 2:
			return "%s › %s" % [parts[0], parts[1]]
	return n


func _result_text(block: Dictionary) -> String:
	var c = block.get("content", "")
	if typeof(c) == TYPE_ARRAY:
		var out := ""
		for part in c:
			if typeof(part) == TYPE_DICTIONARY:
				out += str(part.get("text", ""))
		return out
	return str(c)


# ---------------------------------------------------------------- helpers

func _editor_context() -> String:
	var parts := PackedStringArray()
	var root := EditorInterface.get_edited_scene_root()
	if root:
		parts.append("Open scene: " + (root.scene_file_path if root.scene_file_path != "" else "(unsaved)"))
		var names := PackedStringArray()
		for n in EditorInterface.get_selection().get_selected_nodes():
			names.append(str(root.get_path_to(n)))
		if names.size() > 0:
			parts.append("Selected nodes: " + ", ".join(names))
	var scr := EditorInterface.get_script_editor().get_current_script()
	if scr:
		parts.append("Open script: " + scr.resource_path)
	if parts.is_empty():
		return ""
	return "[Godot editor context]\n" + "\n".join(parts)


func _resolve_claude() -> String:
	var custom := str(_get_setting(SETTING_PATH, "")).strip_edges()
	if custom != "" and FileAccess.file_exists(custom):
		return custom
	if _claude_path != "" and FileAccess.file_exists(_claude_path):
		return _claude_path

	var candidates := PackedStringArray()
	var out := []
	if OS.get_name() == "Windows":
		var win_home := OS.get_environment("USERPROFILE")
		candidates.append(win_home.path_join(".local/bin/claude.exe"))
		candidates.append(OS.get_environment("APPDATA").path_join("npm/claude.cmd"))
		for c in candidates:
			if FileAccess.file_exists(c):
				_claude_path = str(c).replace("/", "\\")
				return _claude_path
		if OS.execute("where.exe", PackedStringArray(["claude"]), out) == 0 and out.size() > 0:
			for l in str(out[0]).split("\n", false):
				var p := str(l).strip_edges()
				if p.ends_with(".exe") or p.ends_with(".cmd"):
					_claude_path = p
					return p
		return ""

	var home := OS.get_environment("HOME")
	candidates.append_array(PackedStringArray([
		home.path_join(".local/bin/claude"), home.path_join(".claude/local/claude"),
		"/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude",
	]))
	for c in candidates:
		if FileAccess.file_exists(c):
			_claude_path = str(c)
			return _claude_path
	var shell := OS.get_environment("SHELL") if OS.get_environment("SHELL") != "" else "/bin/bash"
	if OS.execute(shell, PackedStringArray(["-lc", "command -v claude"]), out) == 0 and out.size() > 0:
		for l in str(out[0]).split("\n", false):
			var p := str(l).strip_edges()
			if p.begins_with("/"):
				_claude_path = p
	return _claude_path


func _project_dir() -> String:
	var d := ProjectSettings.globalize_path("res://")
	if d.length() > 3 and d.ends_with("/"):
		d = d.substr(0, d.length() - 1)
	if OS.get_name() == "Windows":
		d = d.replace("/", "\\")
	return d


func _mode() -> String:
	var m := str(_get_setting(SETTING_MODE, "acceptEdits"))
	return m if MODES.has(m) else "acceptEdits"


func _get_setting(key: String, default_value: Variant, hint := PROPERTY_HINT_NONE) -> Variant:
	var es := EditorInterface.get_editor_settings()
	if not es.has_setting(key):
		es.set_setting(key, default_value)
	es.set_initial_value(key, default_value, false)
	es.add_property_info({"name": key, "type": typeof(default_value), "hint": hint})
	return es.get_setting(key)


func _clear_children(item: TreeItem) -> void:
	for c in item.get_children():
		c.free()


func _append(bbcode: String) -> void:
	if _output:
		_output.append_text(bbcode)


func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func _short(s: String, n: int) -> String:
	s = s.replace("\n", " ")
	return s if s.length() <= n else s.substr(0, n) + "…"


func _fmt_k(n: int) -> String:
	return "%.1fk" % (n / 1000.0) if n >= 1000 else str(n)


func _sh_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"
