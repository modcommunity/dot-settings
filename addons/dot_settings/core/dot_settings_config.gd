class_name DotSettingsConfig
extends DotConfig

## A [DotConfig] whose properties are a [DotSettingsSchema]'s keys, built at runtime.
##
## [b]This exists so that "integrates with dot-ui" costs this addon no dependency at
## all.[/b] dot-ui's settings panel is generated from any [DotConfig] by reflection, and
## [DotConfig] itself discovers its keys through [method Object.get_property_list]. So a
## config that answers [method Object._get_property_list] with a schema's keys is a
## settings screen, a layered configuration and a console's completion source at once —
## and nothing here names a [Control], a [Theme] or dot-ui.
##
## [b]The mechanism matters, because the obvious spelling does not work.[/b] Godot refuses
## a dynamic property on an [Object]: assigning [code]cfg.some_new_key = 1[/code] pushes
## an error and sets nothing. This family shipped exactly that once — a game descriptor
## whose [code]module[/code] was assigned that way named no module at all, and the failure
## was a scene with nothing behind it. Overriding [method Object._get],
## [method Object._set] and [method Object._get_property_list] is the supported way, and
## the properties are then real as far as every reflective caller is concerned.
##
## It is a [b]snapshot[/b]. Writing here does not write through to a
## [DotSettingsManager]; [method DotSettingsManager.absorb_config] is the way back, and it
## is explicit because a screen with a Cancel button needs the two to be separable.

var _schema: DotSettingsSchema = null
var _values: Dictionary = {}


func bind(schema: DotSettingsSchema, values: Dictionary) -> void:
	_schema = schema
	_values = values.duplicate()
	notify_property_list_changed()


func values() -> Dictionary:
	return _values.duplicate()


func env_prefix() -> String:
	return "DOT_SETTING_"


func cli_prefix() -> String:
	return "--set-"


## Keys a player's own machine must not take from the environment or the command line.
##
## Not credentials — a private setting is a device name or a directory, which is nobody
## else's business rather than secret — but the rule is the same one and so is the
## mechanism.
func sensitive_keys() -> PackedStringArray:
	var out := PackedStringArray()
	if _schema == null:
		return out
	for d in _schema.defs:
		if d.private:
			out.append(String(d.key))
	return out


func validate() -> DotResult:
	if _schema == null:
		return DotResult.success(null)
	for k in _values.keys():
		var def := _schema.find(StringName(str(k)))
		if def == null:
			continue
		var res := def.coerce(_values[k])
		if not res.ok:
			return res
	return DotResult.success(null)


# --- The reflective half ----------------------------------------------------

func _get_property_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _schema == null:
		return out
	for d in _schema.defs:
		out.append(_property_for(d))
	return out


func _property_for(d: DotSettingsDef) -> Dictionary:
	var entry := {
		"name": String(d.key),
		"type": _variant_type_for(d),
		# SCRIPT_VARIABLE and STORAGE together are what DotConfig's own filter looks for,
		# and EDITOR is what puts it in front of a person.
		"usage": (
			PROPERTY_USAGE_SCRIPT_VARIABLE | PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR
		),
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	}
	match d.kind:
		DotSettingsDef.Kind.INT, DotSettingsDef.Kind.FLOAT:
			if d.max_value > d.min_value:
				entry["hint"] = PROPERTY_HINT_RANGE
				entry["hint_string"] = (
					"%f,%f,%f" % [d.min_value, d.max_value, maxf(d.step, 0.001)]
				)
		DotSettingsDef.Kind.ENUM:
			entry["hint"] = PROPERTY_HINT_ENUM
			var names := PackedStringArray()
			for o in d.options:
				names.append(String(o))
			entry["hint_string"] = ",".join(names)
	return entry


func _variant_type_for(d: DotSettingsDef) -> int:
	match d.kind:
		DotSettingsDef.Kind.BOOL:
			return TYPE_BOOL
		DotSettingsDef.Kind.INT:
			return TYPE_INT
		DotSettingsDef.Kind.FLOAT:
			return TYPE_FLOAT
		_:
			return TYPE_STRING


func _get(property: StringName) -> Variant:
	if _schema != null and _schema.has(property):
		var v: Variant = _values.get(property)
		# A string-typed property list entry holding a StringName reads back as a
		# StringName, and an equality test against a String then fails for two values
		# that print identically. Normalising here is cheaper than every caller knowing.
		if v is StringName:
			return String(v)
		return v
	return null


func _set(property: StringName, value: Variant) -> bool:
	if _schema == null or not _schema.has(property):
		return false
	var def := _schema.find(property)
	var res := def.coerce(value)
	if not res.ok:
		# Refusing here rather than storing the bad value: an out-of-range slider on a
		# generated screen should snap, not poison the document that gets saved.
		DotLog.warn("settings", "refused a value", {"key": String(property), "why": res.error.message})
		return true
	_values[property] = res.value
	return true
