@tool
class_name DotSettingsPolicy
extends DotConfig

## What a server is allowed to do to a player's settings.
##
## [b]A server may clamp, and may never read.[/b] That asymmetry is the whole class, and
## it is the same reasoning dot-spectate's force-camera policy runs on: capping field of
## view is a legitimate competitive rule, and asking a client to report its key bindings,
## its audio device or its screen resolution is a fingerprint — a stable identifier
## assembled from settings, which survives a new account and every ban a moderator issues.
##
## So there is no "read" direction in this addon at all. A server sends a request; the
## client decides whether its policy allows it and answers with nothing.
##
## The second rule is that a clamp is [b]a bound, not a value[/b]. A server that sets
## somebody's field of view to 90 has taken their setting; a server that caps it at 90
## leaves a player who prefers 75 with 75. Every game that gets this wrong gets it wrong
## in the same direction, and the player-visible symptom is a setting that silently resets
## every time they join.

## Whether to honour server requests at all.
##
## On by default, because the settings a server may touch are exactly the ones that are a
## competitive advantage, and a client that refuses every clamp is a client a server has
## to kick instead.
@export var accept_server_clamps: bool = true

## Keys a server may clamp regardless of their declared scope.
##
## Empty means "whatever the schema says", which is the right default. This exists for a
## game that wants to open one extra key to its own servers without changing a shared
## schema.
@export var extra_clamped_keys: Array[StringName] = []

## Keys no server may ever touch, whatever the schema says.
##
## Checked after [member extra_clamped_keys], so this always wins.
@export var never_clamped_keys: Array[StringName] = []

## Whether a clamp survives leaving the server.
##
## Off, and it is not a preference: a clamp that persists is a server permanently editing
## a player's settings, and the player has no way to tell which of their values came from
## a server they played on once.
@export var clamps_persist: bool = false


func env_prefix() -> String:
	return "DOT_SETTINGS_POLICY_"


## Whether [param key] may be clamped by a server.
func may_clamp(schema: DotSettingsSchema, key: StringName) -> bool:
	if not accept_server_clamps:
		return false
	if never_clamped_keys.has(key):
		return false
	if extra_clamped_keys.has(key):
		return true
	var def := schema.find(key) if schema != null else null
	if def == null:
		return false
	if def.private:
		return false
	return def.scope == DotSettingsDef.Scope.SERVER_CLAMPED


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("policy: server clamps %s" % ("accepted" if accept_server_clamps else "refused"))
	if not extra_clamped_keys.is_empty():
		out.append("  also clampable: %s" % ", ".join(_names(extra_clamped_keys)))
	if not never_clamped_keys.is_empty():
		out.append("  never clampable: %s" % ", ".join(_names(never_clamped_keys)))
	out.append("  clamps %s" % ("persist" if clamps_persist else "are dropped on leaving"))
	return out


func _names(keys: Array[StringName]) -> PackedStringArray:
	var out := PackedStringArray()
	for k in keys:
		out.append(String(k))
	return out
