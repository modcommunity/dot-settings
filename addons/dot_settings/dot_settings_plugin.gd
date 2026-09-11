@tool
extends EditorPlugin

## Editor entry point for dot-settings. Registers inspector types only.
##
## No autoloads: a launcher and the game it launches are two settings managers in one
## process, on two different namespaces, and a global would make them one.

const _ICON := "res://addons/dot_settings/icon_placeholder.svg"

const _TYPES := [
	[
		"DotSettingsManager",
		"Node",
		"res://addons/dot_settings/runtime/dot_settings_manager.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
