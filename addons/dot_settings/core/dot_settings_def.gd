@tool
class_name DotSettingsDef
extends Resource

## One setting: what it is called, what it may be, and who is allowed to touch it.
##
## [b]A setting is declared once and read everywhere.[/b] The alternative — a dictionary
## of whatever somebody happened to store — is what makes a settings system rot: nobody
## can enumerate it, nothing can validate it, a typo'd key is indistinguishable from a
## setting that has not been chosen yet, and a screen that lists them has to carry a
## second copy of the list. This family has shipped "two copies of one list" five times
## and it is the bug it guards hardest against.
##
## The declaration is also the whole of the user interface. dot-ui's settings panel is
## generated from a [DotConfig]; a [DotSettingsSchema] hands one over for exactly that
## reason, so a new setting appears on screen without anybody editing a screen.

enum Kind {
	BOOL,
	INT,
	FLOAT,
	STRING,
	## One of [member options]. Stored as the option's own string, not its index.
	ENUM,
	## An input binding, stored as text. Opaque to this addon.
	BINDING,
}

## Who owns this setting, which decides where it is stored and what may change it.
enum Scope {
	## This machine. Resolution, audio device, thread count, whether to use a gamepad.
	##
	## [b]Never synchronised.[/b] A player's laptop and their desktop disagree about
	## resolution on purpose, and a synchronised one is a setting that breaks itself every
	## time they switch machines.
	DEVICE,
	## This person, everywhere they play. Sensitivity, crosshair, subtitles, language.
	##
	## What [member DotSettingsManager.shared_namespace] carries between games.
	ACCOUNT,
	## This person, but a server may clamp it.
	##
	## Field of view, view models, third person. A competitive server capping FOV is a
	## legitimate rule; the same server reading a player's key bindings is a fingerprint.
	## See [DotSettingsPolicy].
	SERVER_CLAMPED,
}

## The key, in lower_snake_case. Unique within a schema.
@export var key: StringName = &""

@export var kind: Kind = Kind.BOOL

@export var scope: Scope = Scope.DEVICE

## The value when nothing has been chosen. Typed to match [member kind].
@export var default_value: Variant = false

## Bounds for INT and FLOAT. Ignored otherwise.
@export var min_value: float = 0.0
@export var max_value: float = 1.0

## Zero means "no step", which is what a continuous slider wants.
@export var step: float = 0.0

## The legal values for [constant Kind.ENUM].
@export var options: Array[StringName] = []

## Longest accepted string, for STRING and BINDING.
##
## Bounded because a settings document travels: it is written to disk, it may be
## synchronised to an account, and an unbounded string field is how a settings file
## becomes a storage bill.
@export_range(1, 8192, 1) var max_length: int = 256

## A grouping for a generated screen. Free text — "Video", "Audio", "Gameplay".
@export var category: StringName = &"general"

## A hint for a screen, and for a console's help.
@export var description: String = ""

## Whether changing it only takes effect after a restart.
##
## Informational, and it exists because the alternative is a player toggling something,
## seeing nothing happen, and toggling it back.
@export var requires_restart: bool = false

## Whether this value must never be synchronised, logged, or sent anywhere.
##
## Not "secret" in the credential sense — [DotConfig.sensitive_keys] covers that — but
## "this is nobody else's business". A device name, a microphone id, a save directory.
@export var private: bool = false


## Coerces [param value] to this setting's type and bounds.
##
## Returns the corrected value rather than refusing wherever a correction is obvious, and
## refuses only what is genuinely not this setting. A settings file is edited by hand more
## often than any other file in a game, and a whole file rejected because one slider is
## out of range is a player who lost every other setting they had.
func coerce(value: Variant) -> DotResult:
	match kind:
		Kind.BOOL:
			if value is bool:
				return DotResult.success(value)
			if value is int or value is float:
				return DotResult.success(float(value) != 0.0)
			if value is String or value is StringName:
				var s := String(value).to_lower()
				if s in ["1", "true", "yes", "on"]:
					return DotResult.success(true)
				if s in ["0", "false", "no", "off"]:
					return DotResult.success(false)
			return _refuse(value, "a true/false value")

		Kind.INT:
			if value is bool:
				return DotResult.success(1 if value else 0)
			if value is int or value is float:
				return DotResult.success(_clamp_number(float(value)))
			if value is String and String(value).is_valid_int():
				return DotResult.success(_clamp_number(float(String(value).to_int())))
			return _refuse(value, "a whole number")

		Kind.FLOAT:
			if value is int or value is float:
				return DotResult.success(float(_clamp_number(float(value))))
			if value is String and String(value).is_valid_float():
				return DotResult.success(float(_clamp_number(String(value).to_float())))
			return _refuse(value, "a number")

		Kind.ENUM:
			var want := StringName(str(value))
			if options.has(want):
				return DotResult.success(want)
			# An unknown option is the one case worth refusing outright: silently
			# substituting the default means a renamed option puts everybody back to
			# "low" with nothing said.
			return DotResult.fail(
				DotError.CODE_INVALID,
				"'%s' is not one of %s's options" % [str(value), key],
				", ".join(_option_strings())
			)

		_:
			var s := str(value)
			if s.length() > max_length:
				s = s.substr(0, max_length)
			return DotResult.success(s)


## Clamps and snaps, returning an [int] for [constant Kind.INT] and a [float] otherwise.
##
## Typed [Variant] because the two branches genuinely return different types, and
## declaring it [int] silently truncates every float setting in the schema — a volume
## slider that can only be 0 or 1, with nothing erroring.
func _clamp_number(v: float) -> Variant:
	var out := v
	if max_value > min_value:
		out = clampf(out, min_value, max_value)
	if step > 0.0:
		out = snappedf(out - min_value, step) + min_value
		if max_value > min_value:
			out = clampf(out, min_value, max_value)
	return int(round(out)) if kind == Kind.INT else out


func _refuse(value: Variant, wanted: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INVALID,
		"%s wants %s" % [key, wanted],
		"got %s" % type_string(typeof(value))
	)


func _option_strings() -> PackedStringArray:
	var out := PackedStringArray()
	for o in options:
		out.append(String(o))
	return out


func validate() -> DotResult:
	if key == &"":
		return DotResult.fail(DotError.CODE_INVALID, "a setting with no key")
	if not String(key).is_valid_ascii_identifier():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' is not a usable key" % key,
			"keys become filenames, JSON keys and console names, so they are identifiers"
		)
	if kind == Kind.ENUM:
		if options.is_empty():
			return DotResult.fail(DotError.CODE_INVALID, "%s is an enum with no options" % key)
		if not options.has(StringName(str(default_value))):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"%s defaults to '%s', which is not one of its options" % [key, str(default_value)]
			)
	if (kind == Kind.INT or kind == Kind.FLOAT) and max_value < min_value:
		return DotResult.fail(DotError.CODE_INVALID, "%s has a maximum below its minimum" % key)
	var d := coerce(default_value)
	if not d.ok:
		return d.wrap("%s's own default" % key)
	return DotResult.success(null)


## Convenience constructors, so a schema reads as a list rather than as eight lines each.
static func boolean(
	p_key: StringName, p_default: bool, p_category: StringName = &"general"
) -> DotSettingsDef:
	var d := DotSettingsDef.new()
	d.key = p_key
	d.kind = Kind.BOOL
	d.default_value = p_default
	d.category = p_category
	return d


static func number(
	p_key: StringName,
	p_default: float,
	p_min: float,
	p_max: float,
	p_category: StringName = &"general",
	p_step: float = 0.0
) -> DotSettingsDef:
	var d := DotSettingsDef.new()
	d.key = p_key
	d.kind = Kind.FLOAT
	d.default_value = p_default
	d.min_value = p_min
	d.max_value = p_max
	d.step = p_step
	d.category = p_category
	return d


static func integer(
	p_key: StringName,
	p_default: int,
	p_min: int,
	p_max: int,
	p_category: StringName = &"general"
) -> DotSettingsDef:
	var d := DotSettingsDef.new()
	d.key = p_key
	d.kind = Kind.INT
	d.default_value = p_default
	d.min_value = float(p_min)
	d.max_value = float(p_max)
	d.step = 1.0
	d.category = p_category
	return d


static func choice(
	p_key: StringName,
	p_default: StringName,
	p_options: Array[StringName],
	p_category: StringName = &"general"
) -> DotSettingsDef:
	var d := DotSettingsDef.new()
	d.key = p_key
	d.kind = Kind.ENUM
	d.options = p_options
	d.default_value = p_default
	d.category = p_category
	return d


static func text(
	p_key: StringName, p_default: String, p_category: StringName = &"general"
) -> DotSettingsDef:
	var d := DotSettingsDef.new()
	d.key = p_key
	d.kind = Kind.STRING
	d.default_value = p_default
	d.category = p_category
	return d


## An input binding, stored as the text form [DotInputBinding] reads and writes.
##
## [b]Text rather than a keycode.[/b] A settings document is written to disk, may be
## synchronised to an account and is edited by hand more than any other file in a game.
## [code]"Y"[/code] survives all three; [code]89[/code] survives none of them, and is also
## a number that means a different key on a different layout.
##
## This addon never interprets it. dot-settings does not depend on dot-ui and has no
## opinion about input; what it guarantees is the same thing it guarantees for any string —
## that it is declared, bounded, scoped and enumerable.
static func binding(
	p_key: StringName, p_default: String, p_category: StringName = &"controls"
) -> DotSettingsDef:
	var d := DotSettingsDef.new()
	d.key = p_key
	d.kind = Kind.BINDING
	d.default_value = p_default
	d.category = p_category
	# Long enough for "Shift+Kp Subtract" and nothing like long enough to be a payload.
	d.max_length = 32
	return d


## Returns self, so the constructors chain.
func with_scope(p_scope: Scope) -> DotSettingsDef:
	scope = p_scope
	return self


func with_description(p_text: String) -> DotSettingsDef:
	description = p_text
	return self


func as_private() -> DotSettingsDef:
	private = true
	return self


func needing_restart() -> DotSettingsDef:
	requires_restart = true
	return self


func describe_line() -> String:
	var scopes := ["device", "account", "server"]
	return "%-28s %-8s %-8s default %s" % [
		String(key),
		["bool", "int", "float", "string", "enum", "binding"][kind],
		scopes[scope],
		str(default_value),
	]
