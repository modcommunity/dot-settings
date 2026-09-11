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


## Builds a schema from an existing [DotConfig], by reflection.
##
## [b]This is the anti-duplication path and it is the one most existing code wants.[/b]
## Several projects in this family already have a [DotConfig] full of player-facing
## settings — a volume, a camera follow time, whether to show names — which dot-ui already
## generates a panel from. Writing a schema beside one would be two copies of one list, and
## this tree's most repeated bug is a list that went stale.
##
## So: the config keeps being the declaration, and this reads it. What the config cannot
## say is the part a schema adds — which scope a key belongs to, and which ones a server
## may clamp — so those arrive as [param scopes], keyed by name, defaulting to
## [constant DotSettingsDef.Scope.DEVICE].
##
## [codeblock]
## var schema := DotSettingsSchema.from_config(my_config, {
##     &"sensitivity": DotSettingsDef.Scope.ACCOUNT,
##     &"field_of_view": DotSettingsDef.Scope.SERVER_CLAMPED,
## })
## [/codeblock]
##
## Ranges and enum options come from the property hints, so an `@export_range` is a slider
## with the right bounds and an `@export_enum` is a list with the right options — which
## means a setting whose range is tightened in the config is tightened everywhere at once.
static func from_config(
	config: DotConfig, scopes: Dictionary = {}, categories: Dictionary = {}
) -> DotSettingsSchema:
	var schema := DotSettingsSchema.new()
	if config == null:
		return schema

	for prop in config.get_property_list():
		var name := StringName(str(prop.get("name", "")))
		if not config.has_key(String(name)):
			continue

		var def := DotSettingsDef.new()
		def.key = name
		def.default_value = config.get(name)
		def.scope = scopes.get(name, DotSettingsDef.Scope.DEVICE)
		def.category = categories.get(name, &"general")

		var hint := int(prop.get("hint", PROPERTY_HINT_NONE))
		var hint_string := str(prop.get("hint_string", ""))

		match int(prop.get("type", TYPE_NIL)):
			TYPE_BOOL:
				def.kind = DotSettingsDef.Kind.BOOL
			TYPE_INT:
				if hint == PROPERTY_HINT_ENUM:
					# An @export_enum on an int is an index into a list of names. It is
					# stored here as the NAME rather than the index, because an index is a
					# number whose meaning changes the day somebody inserts an option --
					# and every saved document then means something different with nothing
					# saying so.
					def.kind = DotSettingsDef.Kind.ENUM
					var options: Array[StringName] = []
					for part in hint_string.split(","):
						options.append(StringName(part.split(":")[0]))
					def.options = options
					var index := int(config.get(name))
					def.default_value = (
						options[index] if index >= 0 and index < options.size()
						else (options[0] if not options.is_empty() else &"")
					)
				else:
					def.kind = DotSettingsDef.Kind.INT
					_apply_range(def, hint, hint_string)
			TYPE_FLOAT:
				def.kind = DotSettingsDef.Kind.FLOAT
				_apply_range(def, hint, hint_string)
			_:
				def.kind = DotSettingsDef.Kind.STRING
				def.default_value = str(config.get(name))

		# Whatever the config refuses from the environment and argv is private here too.
		# Two answers to one question is how a secret ends up in one of them.
		if config.sensitive_keys().has(String(name)):
			def.private = true

		schema.add(def)

	return schema


static func _apply_range(def: DotSettingsDef, hint: int, hint_string: String) -> void:
	if hint != PROPERTY_HINT_RANGE:
		# No declared range. Left at the resource's defaults rather than invented: a
		# made-up maximum is a slider that silently refuses a value the config accepts.
		def.min_value = 0.0
		def.max_value = 0.0
		return
	var parts := hint_string.split(",")
	if parts.size() >= 2:
		def.min_value = parts[0].to_float()
		def.max_value = parts[1].to_float()
	if parts.size() >= 3 and parts[2].is_valid_float():
		def.step = parts[2].to_float()


## Writes this schema's values back into the [DotConfig] they came from.
##
## The other half of [method from_config], and the reason both exist: the config is what
## the game already reads, so a settings document that does not reach it is a document
## nothing consumes — which is this family's single most repeated bug.
func apply_to_config(config: DotConfig, values: Dictionary) -> PackedStringArray:
	var written := PackedStringArray()
	if config == null:
		return written
	for d in defs:
		if not values.has(d.key) or not config.has_key(String(d.key)):
			continue
		var value: Variant = values[d.key]
		if d.kind == DotSettingsDef.Kind.ENUM:
			# Back to the index the config wants, from the name the document stores.
			var index := d.options.find(StringName(str(value)))
			if index < 0:
				continue
			value = index
		if DotValue.differs(config.get(d.key), value):
			config.set(d.key, value)
			written.append(String(d.key))
	return written


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
