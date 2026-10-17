@tool
extends EditorPlugin

const ClaudePanel := preload("res://addons/claude_terminal/claude_panel.gd")

var _panel: Control


func _enter_tree() -> void:
	_panel = ClaudePanel.new()
	_panel.name = "Claude"
	add_control_to_bottom_panel(_panel, "Claude")


func _exit_tree() -> void:
	if _panel:
		_panel.shutdown()
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
