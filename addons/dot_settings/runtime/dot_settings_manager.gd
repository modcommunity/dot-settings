class_name DotSettingsManager
extends Node

## The one node a game holds. Reads, writes, migrates and shares a settings document.
##
## [codeblock]
## var settings := DotSettingsManager.new()
## settings.schema = my_schema
## settings.local_store = DotSettingsStoreFile.new()
## settings.app_namespace = &"my_game"
## add_child(settings)
## settings.setup()
##
## settings.get_value(&"master_volume")
## settings.set_value(&"master_volume", 0.4)   # saved, debounced, atomically
## [/codeblock]
##
## Three things about it are decisions rather than implementation:
##
## [b]It writes on change, not on quit.[/b] Debounced by a few hundred milliseconds so
## dragging a slider is one write, and flushed on [method Node._notification] for
## [constant NOTIFICATION_WM_CLOSE_REQUEST] as a backstop rather than as the mechanism.
## A game that saves settings on exit loses them whenever it crashes, and the moment a
## game is most likely to crash is while it is shutting down.
##
## [b]Unknown keys are kept.[/b] A player who runs a newer build, changes a setting it
## added and goes back to an older one would otherwise lose it silently — and lose it
## again every time. The unknown half is stored beside the known half and written back
## untouched.
##
## [b]Account settings are a second document, not a merged one.[/b] [member
## shared_namespace] is where [constant DotSettingsDef.Scope.ACCOUNT] keys live, so two
## games that opt into the same name genuinely share one sensitivity and one crosshair,
## and a game that does not opt in is unaffected by either.

const SERVICE := &"dot_settings"
const CHANNEL := "settings"

## The document's record of the default each value was saved under.
const DEFAULTS_SECTION := "defaults"

## One setting changed. Fired for a load, a reset and a server clamp as well as for a
## direct set, because every consumer wants to know either way.
signal changed(key: StringName, value: Variant, reason: StringName)

## The document was replaced wholesale — loaded, reset, or migrated.
signal reloaded()

## A server clamped something, or released a clamp.
signal clamped(key: StringName, bound: Variant, applied: bool)

## Something was saved, or could not be.
signal saved(res: DotResult)

@export var schema: DotSettingsSchema = null

@export var policy: DotSettingsPolicy = null

## The game's own name, and the address of its document.
@export var app_namespace: StringName = &"game"

## Where [constant DotSettingsDef.Scope.ACCOUNT] keys live.
##
## Empty means "with everything else", which keeps a single game self-contained. Set it
## to a name several titles share and a player configures their sensitivity once.
@export var shared_namespace: StringName = &""

## Who these settings belong to. A pseudonymous id, or [code]&"local"[/code].
##
## [b]Not an account id, and never a display name.[/b] It is part of a filename, and a
## filename derived from a name changes when the name does. dot-user's per-scope
## pseudonymous id is the right thing to pass.
@export var profile: StringName = &"local"

## Milliseconds to wait after the last change before writing.
##
## Enough that dragging a slider across its range is one write rather than two hundred,
## short enough that a player who changes one thing and pulls the plug keeps it.
@export_range(0, 60000, 10) var write_delay_ms: int = 400

## Whether to write at all. Off makes the whole thing a session-local scratchpad.
@export var persist: bool = true

@export var register_as_service: bool = true

## Where the document is stored. A [DotSettingsStoreFile] in nearly every deployment.
var local_store: DotSettingsStore = null

## Where account-scoped settings are stored, when they are not local.
##
## Any [DotSettingsStore]. An HTTP-backed one against a backbone is the deployment that
## makes settings follow a player between machines, and this addon deliberately does not
## ship one — whose backbone it is, is not its decision.
var remote_store: DotSettingsStore = null

## A migration per version step. [code](document: Dictionary) -> Dictionary[/code].
##
## Keyed by the version being migrated [i]from[/i], so the step from 2 to 3 is under 2.
var migrations: Dictionary = {}

var _values: Dictionary = {}
var _unknown: Dictionary = {}
var _clamps: Dictionary = {}
var _dirty := false
var _dirty_since_ms := 0

# Keys changed since this process loaded whose definition says a restart is needed.
#
# Not cleared by saving. Saving is what makes the value survive; the RUNNING process is
# still showing the old one, which is the whole point of the flag -- and a list cleared on
# save is a notice that disappears the moment the player presses Apply.
var _restart_pending: Dictionary = {}
var _loaded := false


func setup() -> DotResult:
	if schema == null:
		return DotResult.fail(DotError.CODE_INVALID, "a settings manager with no schema")
	var res := schema.validate()
	if not res.ok:
		return res.wrap("settings schema")
	if policy == null:
		policy = DotSettingsPolicy.new()
	if local_store == null:
		local_store = DotSettingsStoreMemory.new()

	_values = schema.defaults()
	var loaded := load_now()
	if register_as_service:
		DotRegistry.register(SERVICE, self)
	return loaded


func _exit_tree() -> void:
	# The backstop, not the mechanism. If this is the only thing that ever saves, a crash
	# loses everything a player did this session.
	if _dirty:
		flush()
	if register_as_service:
		DotRegistry.unregister_instance(SERVICE, self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _dirty:
		flush()


func _process(_delta: float) -> void:
	if not _dirty or not persist:
		return
	if Time.get_ticks_msec() - _dirty_since_ms < write_delay_ms:
		return
	flush()


# --- Reading and writing ----------------------------------------------------

## The current value, or the declared default when nothing has been chosen.
func get_value(key: StringName) -> Variant:
	if _clamps.has(key):
		return _clamped_value(key, _values.get(key))
	return _values.get(key, _default_of(key))


func get_bool(key: StringName, fallback: bool = false) -> bool:
	var v: Variant = get_value(key)
	return bool(v) if v != null else fallback


func get_int(key: StringName, fallback: int = 0) -> int:
	var v: Variant = get_value(key)
	return int(v) if v != null else fallback


func get_float(key: StringName, fallback: float = 0.0) -> float:
	var v: Variant = get_value(key)
	return float(v) if v != null else fallback


func get_string(key: StringName, fallback: String = "") -> String:
	var v: Variant = get_value(key)
	return str(v) if v != null else fallback


## Sets a value, coercing it. Returns what was actually stored, or a failure.
func set_value(key: StringName, value: Variant, reason: StringName = &"user") -> DotResult:
	var def := schema.find(key) if schema != null else null
	if def == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' is not a declared setting" % key,
			"a setting nothing declares is a setting nothing can validate or show"
		)
	var res := def.coerce(value)
	if not res.ok:
		return res

	var stored: Variant = res.value
	# Not `==`. The stored value and the coerced one are both Variants whose types the
	# caller does not control -- a value read from JSON against one read from a
	# declaration -- and GDScript's comparison between two mismatched types is an error.
	if DotValue.same(_values.get(key), stored):
		return DotResult.success(stored)

	_values[key] = stored
	_dirty = true
	_dirty_since_ms = Time.get_ticks_msec()
	if def.requires_restart:
		_restart_pending[key] = true
	changed.emit(key, get_value(key), reason)
	return DotResult.success(stored)


## Puts one setting back to its declared default.
func reset_value(key: StringName) -> DotResult:
	var def := schema.find(key) if schema != null else null
	if def == null:
		return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a declared setting" % key)
	return set_value(key, def.default_value, &"reset")


## Puts everything back, and keeps unknown keys.
##
## The unknown half survives a reset deliberately: they belong to a build this one does
## not know about, and throwing them away is destroying somebody else's settings on their
## behalf.
func reset_all() -> void:
	_values = schema.defaults()
	_dirty = true
	_dirty_since_ms = Time.get_ticks_msec()
	for k in _values.keys():
		changed.emit(k, get_value(k), &"reset")
	reloaded.emit()


func has_unsaved_changes() -> bool:
	return _dirty


## Whether anything changed this session only takes effect after a restart.
##
## [b]`DotSettingsDef.requires_restart` was declared, documented and read by nothing.[/b]
## A game holds a manager, never a def, so "which of the things I just changed need a
## restart" had no answer anywhere -- and the symptom is the one every options screen with
## this bug has: a renderer setting that appears to apply and does not, with no notice.
func needs_restart() -> bool:
	return not _restart_pending.is_empty()


## Which settings are waiting for a restart, sorted.
##
## Sorted because an options screen lists them to a player, and `Dictionary.keys()` is in
## insertion order -- so the same two settings would be listed in a different order
## depending on which one the player touched first.
func restart_pending() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _restart_pending.keys():
		out.append(String(k))
	out.sort()
	return out


# --- Loading and saving -----------------------------------------------------

## Reads from the stores and replaces everything in memory.
func load_now() -> DotResult:
	if schema == null:
		return DotResult.fail(DotError.CODE_STATE, "no schema")

	var raw := {}
	if local_store != null:
		var res := local_store.load_document(app_namespace, profile)
		if not res.ok:
			return res.wrap("reading settings")
		raw = (res.value as Dictionary).duplicate(true)

	# The account half, read second so it wins for the keys it owns. Reading it first
	# would let a stale local copy of an account setting overwrite the shared one, which
	# is the direction that loses the change a player just made on another machine.
	if _account_store() != null and shared_namespace != &"":
		var res := _account_store().load_document(shared_namespace, profile)
		if res.ok:
			var shared: Dictionary = res.value
			for k in shared.keys():
				var def := schema.find(StringName(str(k)))
				if def != null and def.scope == DotSettingsDef.Scope.ACCOUNT:
					raw[k] = shared[k]

	# The defaults each value was saved under: not a setting, and not an unknown key either
	# (an unknown key is written back untouched, and this one must be rewritten every save).
	var saved_under: Dictionary = {}
	if raw.get(DEFAULTS_SECTION) is Dictionary:
		saved_under = raw[DEFAULTS_SECTION]
	raw.erase(DEFAULTS_SECTION)

	var doc := _migrate(raw)
	var coerced := schema.coerce_document(doc)
	_values = coerced["values"]
	_unknown = coerced["unknown"]
	_loaded = true
	_dirty = false
	# A load is what a restart looks like from here: the values in memory now ARE the ones
	# on disk, so nothing is waiting any more.
	_restart_pending.clear()

	var followed := _follow_defaults(saved_under)
	if not followed.is_empty():
		# Saved soon, so the document records the default it is under now and this runs once.
		_dirty = true
		_dirty_since_ms = Time.get_ticks_msec()
		DotLog.info(
			CHANNEL,
			"%d stored settings were on an old default and follow the new one" % followed.size(),
			{"what": ", ".join(followed)}
		)

	var corrected: PackedStringArray = coerced["corrected"]
	if not corrected.is_empty():
		DotLog.info(
			CHANNEL,
			"corrected %d stored settings" % corrected.size(),
			{"what": ", ".join(corrected)}
		)
	var refused: PackedStringArray = coerced["refused"]
	if not refused.is_empty():
		# A warning rather than info: a refused value is one a player chose and did not
		# get, which is the half they would want to be told about.
		DotLog.warn(
			CHANNEL,
			"%d stored settings could not be read and are back at their defaults" % refused.size(),
			{"what": ", ".join(refused)}
		)
	if not _unknown.is_empty():
		# Not a warning. A newer build's settings are the expected reason, and a red line
		# about a condition that is normal is how a real one stops being read.
		DotLog.debug(
			CHANNEL, "keeping %d settings this build does not declare" % _unknown.size()
		)

	reloaded.emit()
	return DotResult.success(null)


## Writes now, whatever the debounce says.
func flush() -> DotResult:
	_dirty = false
	if not persist or local_store == null:
		return DotResult.success(null)
	if not local_store.writable():
		var refused := DotResult.fail(
			DotError.CODE_FORBIDDEN, "settings cannot be saved on this machine"
		)
		saved.emit(refused)
		return refused

	var doc := to_document()
	var res := local_store.save_document(app_namespace, profile, doc)
	if res.ok and _account_store() != null and shared_namespace != &"":
		var shared := {}
		for k in schema.keys_in_scope(DotSettingsDef.Scope.ACCOUNT):
			shared[String(k)] = _values.get(k)
		if not shared.is_empty():
			var sres := _account_store().save_document(shared_namespace, profile, shared)
			if not sres.ok:
				DotLog.warn(CHANNEL, "account settings not saved", {"why": sres.error.message})
	saved.emit(res)
	return res


func _account_store() -> DotSettingsStore:
	return remote_store if remote_store != null else local_store


## The document as it is stored: version, values, and the keys this build does not know.
func to_document() -> Dictionary:
	var values := {}
	for k in _values.keys():
		# The clamp is deliberately not written. A server's bound is not the player's
		# choice, and persisting it is a server permanently editing settings for somebody
		# who has left.
		values[String(k)] = _values[k]
	var doc := {"version": schema.version, "values": values}
	# Beside every value, the default it was saved under. A value equal to it was never
	# chosen, so it follows the default when a later build moves it (see `_follow_defaults`).
	var under := {}
	for k in _values.keys():
		var def := schema.find(k)
		if def != null:
			under[String(k)] = def.default_value
	doc[DEFAULTS_SECTION] = under
	for k in _unknown.keys():
		if not doc.has(k):
			doc[k] = _unknown[k]
	return doc


## Moves every value still on the default it was saved under to the current default.
## Returns `"key: old -> new"` for each one moved.
##
## [b]A value equal to its default is a value nobody chose.[/b] Storing it as a plain value
## made it indistinguishable from a choice, so when a build moved a default (a key that had
## to make room for one the whole family shares), a returning player kept the old one and
## two actions shared a key. The document now records the default each value was saved
## under; one that still matches it follows. A document from before that record uses
## [member DotSettingsDef.previous_defaults] instead, once.
##
## The rest is a choice and is kept, even where it equals an old default somewhere else.
func _follow_defaults(saved_under: Dictionary) -> PackedStringArray:
	var moved := PackedStringArray()
	for def in schema.defs:
		if def == null or not _values.has(def.key):
			continue
		var value: Variant = _values[def.key]
		if DotValue.same(value, def.default_value):
			continue
		var was_default := false
		if saved_under.has(String(def.key)):
			var c := def.coerce(saved_under[String(def.key)])
			was_default = c.ok and DotValue.same(value, c.value)
		else:
			for old in def.previous_defaults:
				var c := def.coerce(old)
				if c.ok and DotValue.same(value, c.value):
					was_default = true
					break
		if was_default:
			_values[def.key] = def.default_value
			moved.append("%s: %s -> %s" % [def.key, str(value), str(def.default_value)])
	return moved


func _migrate(raw: Dictionary) -> Dictionary:
	# A document with no version is a document from before there were versions, which is
	# version 1 by definition rather than an error.
	var from := int(raw.get("version", 1))
	var body: Dictionary = raw.get("values", {}) if raw.has("values") else raw

	var guard := 0
	while from < schema.version and guard < 64:
		var step: Variant = migrations.get(from)
		if step is Callable and (step as Callable).is_valid():
			var out: Variant = (step as Callable).call(body)
			if out is Dictionary:
				body = out
			DotLog.info(CHANNEL, "migrated settings", {"from": from, "to": from + 1})
		from += 1
		guard += 1

	var merged := body.duplicate(true)
	for k in raw.keys():
		if k == "version" or k == "values":
			continue
		if not merged.has(k):
			merged[k] = raw[k]
	return merged


# --- Server clamps ----------------------------------------------------------

## Applies a server's requested bounds. Returns the keys that were actually clamped.
##
## [param request] is [code]{key: bound}[/code]. A bound is a maximum for a number and an
## exact value for anything else — which is the honest reading of what a server can want
## from a boolean.
##
## [b]Nothing is read back.[/b] There is no reply and no report: a server that can ask
## what a player's settings are can assemble a fingerprint that survives a new account.
func apply_server_clamps(request: Dictionary) -> PackedStringArray:
	var applied := PackedStringArray()
	for raw in request.keys():
		var key := StringName(str(raw))
		if not policy.may_clamp(schema, key):
			clamped.emit(key, request[raw], false)
			continue
		var def := schema.find(key)
		var res := def.coerce(request[raw])
		if not res.ok:
			clamped.emit(key, request[raw], false)
			continue
		_clamps[key] = res.value
		applied.append(String(key))
		clamped.emit(key, res.value, true)
		changed.emit(key, get_value(key), &"server")
	if not applied.is_empty():
		DotLog.info(CHANNEL, "a server clamped settings", {"keys": ", ".join(applied)})
	return applied


## Drops every clamp. Called when leaving a server.
func release_clamps() -> void:
	var keys := _clamps.keys()
	_clamps.clear()
	for k in keys:
		changed.emit(k, get_value(k), &"server")
	if not keys.is_empty():
		DotLog.info(CHANNEL, "server clamps released", {"count": keys.size()})


## The player's own value, ignoring any clamp. What a settings screen shows.
##
## A screen that shows the clamped value has quietly replaced what the player chose: they
## set 110, a server capped them at 90, and when they leave the slider says 90 for ever.
func chosen_value(key: StringName) -> Variant:
	return _values.get(key, _default_of(key))


func is_clamped(key: StringName) -> bool:
	return _clamps.has(key)


func clamp_bound(key: StringName) -> Variant:
	return _clamps.get(key)


func _clamped_value(key: StringName, own: Variant) -> Variant:
	var bound: Variant = _clamps.get(key)
	var def := schema.find(key)
	if def == null or bound == null:
		return own
	# A clamp is a bound, not a value: a player who prefers 75 keeps 75 under a cap of 90.
	# Every game that gets this wrong gets it wrong in the same direction, and the symptom
	# is a setting that appears to reset itself on every join.
	if def.kind == DotSettingsDef.Kind.INT:
		return mini(int(own), int(bound))
	if def.kind == DotSettingsDef.Kind.FLOAT:
		return minf(float(own), float(bound))
	return bound


func _default_of(key: StringName) -> Variant:
	var def := schema.find(key) if schema != null else null
	return def.default_value if def != null else null


# --- dot-ui, without knowing dot-ui exists ----------------------------------

## A [DotConfig] a generated settings panel can be pointed at.
##
## A snapshot: writing to it does not write here. [method absorb_config] is the way back,
## and the two being separable is what a Cancel button is made of.
func to_config() -> DotSettingsConfig:
	return schema.to_config(_values)


## Takes every value back out of a config, coercing and announcing each one.
func absorb_config(cfg: DotSettingsConfig) -> PackedStringArray:
	var changed_keys := PackedStringArray()
	var incoming := cfg.values()
	for k in incoming.keys():
		var key := StringName(str(k))
		if DotValue.same(_values.get(key), incoming[k]):
			continue
		var res := set_value(key, incoming[k], &"panel")
		if res.ok:
			changed_keys.append(String(key))
	return changed_keys


# --- Reporting --------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"app_namespace": String(app_namespace),
		"shared": String(shared_namespace),
		"profile": String(profile),
		"store": local_store.store_name() if local_store != null else "none",
		"declared": schema.defs.size() if schema != null else 0,
		"unknown": _unknown.size(),
		"clamped": _clamps.size(),
		"dirty": _dirty,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("dot-settings  %s/%s" % [app_namespace, profile])
	out.append("  store    %s%s" % [
		local_store.store_name() if local_store != null else "none",
		"" if persist else "  (not persisted)",
	])
	if shared_namespace != &"":
		out.append("  shared   %s via %s" % [
			shared_namespace,
			remote_store.store_name() if remote_store != null else "the local store",
		])
	out.append("  loaded   %s%s" % [_loaded, "  (unsaved changes)" if _dirty else ""])
	if not _unknown.is_empty():
		out.append("  keeping  %d settings this build does not declare" % _unknown.size())
	for k in schema.keys() if schema != null else []:
		out.append("  %-28s %s%s" % [
			String(k),
			str(get_value(k)),
			"  (server capped at %s)" % str(_clamps[k]) if _clamps.has(k) else "",
		])
	return out
