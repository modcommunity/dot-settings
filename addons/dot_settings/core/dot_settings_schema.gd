@tool
class_name DotSettingsSchema
extends Resource

## Every setting a game has, declared once, with a version and the migrations between.
##
## [b]The schema is the only list.[/b] A screen enumerates it, a console completes
## against it, a store validates against it and a migration rewrites against it — so a
## setting that is added appears in all four without anybody editing four files. The bug
## this prevents is the one this family has shipped five times: two copies of one list,
## one of which goes stale.

## Bumped whenever a stored document would need rewriting. Migrations run between.
@export var version: int = 1

@export var defs: Array[DotSettingsDef] = []

## How large a stored document may be, in keys.
##
## Bounded for the reason dot-loadout and dot-user-avatar are: a document that travels is
## a document somebody will try to make enormous, and "the server ran out of memory" is a
## worse answer than "that is too many keys".
@export_range(1, 100000, 1) var max_keys: int = 512

var _by_key: Dictionary = {}


func add(def: DotSettingsDef) -> DotSettingsSchema:
	defs.append(def)
	_by_key.clear()
	return self


func find(key: StringName) -> DotSettingsDef:
	_ensure_index()
	return _by_key.get(key)


func has(key: StringName) -> bool:
	_ensure_index()
	return _by_key.has(key)


func keys() -> Array[StringName]:
	var out: Array[StringName] = []
	for d in defs:
		out.append(d.key)
	return out


func keys_in_category(category: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	for d in defs:
		if d.category == category:
			out.append(d.key)
	return out


func categories() -> Array[StringName]:
	var out: Array[StringName] = []
	for d in defs:
		if not out.has(d.category):
			out.append(d.category)
	return out


func keys_in_scope(scope: DotSettingsDef.Scope) -> Array[StringName]:
	var out: Array[StringName] = []
	for d in defs:
		if d.scope == scope:
			out.append(d.key)
	return out


func _ensure_index() -> void:
	if _by_key.size() == defs.size():
		return
	_by_key.clear()
	for d in defs:
		_by_key[d.key] = d


## Every default, as a fresh dictionary.
func defaults() -> Dictionary:
	var out := {}
	for d in defs:
		out[d.key] = d.default_value
	return out


## Checks the schema itself, at boot.
func validate() -> DotResult:
	if defs.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "a schema with no settings in it")
	var seen := {}
	for d in defs:
		if d == null:
			return DotResult.fail(DotError.CODE_INVALID, "a null entry in the schema")
		var res := d.validate()
		if not res.ok:
			return res
		if seen.has(d.key):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"'%s' is declared twice" % d.key,
				"two declarations of one key means one of them is never read"
			)
		seen[d.key] = true
	if defs.size() > max_keys:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"the schema declares more keys than it allows",
			"%d declared, %d allowed" % [defs.size(), max_keys]
		)
	return DotResult.success(null)


## Validates and corrects a whole stored document.
##
## Returns [code]{"values", "unknown", "corrected", "refused"}[/code] and never fails: a
## settings file is the file players edit by hand, and refusing the lot because one line is
## wrong is a player who lost every other setting they had. What goes wrong is reported,
## not thrown away.
##
## [b]Corrected and refused are separate lists because they are separate messages.[/b]
## "your volume was above the maximum, so it is at the maximum" tells a player their value
## survived; "'nonsense' is not one of the quality options, so this is back to high" tells
## them it did not. One list makes a screen say the same thing for both.
##
## [b]Unknown keys are kept.[/b] That is not sloppiness — it is the downgrade path. A
## player who runs a newer build, changes a setting it added, then goes back to an older
## one would otherwise lose it silently, and would lose it again every single time. The
## unknown half is stored beside the known half and written back untouched.
func coerce_document(raw: Dictionary) -> Dictionary:
	var values := defaults()
	var unknown := {}
	var corrected := PackedStringArray()
	var refused := PackedStringArray()

	for k in raw.keys():
		var key := StringName(str(k))
		var def := find(key)
		if def == null:
			unknown[String(key)] = raw[k]
			continue
		var res := def.coerce(raw[k])
		if not res.ok:
			refused.append("%s: %s" % [key, res.error.message])
			continue
		# Two hazards in one line, and the first one cost a whole section of this addon's
		# own suite before anybody noticed.
		#
		# 1. `res.value != raw[k]` is a runtime ERROR when the two have different Variant
		#    types -- an int a coercion produced against the String it came from -- rather
		#    than the `true` everybody expects. The expression is abandoned and the caller
		#    carries on. See DotValue, which exists because of this.
		# 2. A value that changed only its type is not a correction worth telling a player
		#    about: "fov: 110 -> 110" is noise, and noise is what stops the real lines
		#    being read. Comparing what they print is exactly the question being asked.
		if str(res.value) != str(raw[k]):
			corrected.append("%s: %s -> %s" % [key, str(raw[k]), str(res.value)])
		values[key] = res.value

	return {
		"values": values, "unknown": unknown, "corrected": corrected, "refused": refused
	}


## A [DotConfig] carrying this schema's current values.
##
## [b]This is the whole of "integrates with dot-ui".[/b] dot-ui's settings panel is
## generated from any [DotConfig], so handing one over means a new setting appears on a
## screen with nobody editing a screen — and this addon still does not know a [Control]
## exists.
##
## The config is a snapshot. Writing to it does not write here; [method
## DotSettingsManager.absorb_config] is the way back, and it is explicit because a screen
## with a Cancel button needs the two to be separable.
func to_config(values: Dictionary) -> DotSettingsConfig:
	var cfg := DotSettingsConfig.new()
	cfg.bind(self, values)
	return cfg


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("schema v%d, %d settings" % [version, defs.size()])
	for c in categories():
		out.append("  [%s]" % c)
		for d in defs:
			if d.category == c:
				out.append("    %s" % d.describe_line())
	return out
