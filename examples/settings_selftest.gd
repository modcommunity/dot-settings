extends Node

## Exercises dot-settings with no screen, no server and no disk except its own.
##
## The interesting checks are the ones about what a settings system does when something
## is wrong: a hand-edited file with one bad line, a build that is older than the document
## it is reading, a store that cannot be written to, and a server asking for something it
## may not have.
##
## [codeblock]
## godot --headless --path . res://examples/settings_selftest.tscn
## [/codeblock]

## [b]CHECKS is the guard the section counter cannot be.[/b] A script error inside a test
## aborts THAT TEST, not the run — and this suite proved it: a mismatched-type comparison
## in one section took eight checks out of a run that reported "0 failed" and exited 0.
## The section counter did not fire, because the section had already announced itself.
## A total does fire, and it is one line.
const SECTIONS := 8
const CHECKS := 71

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-settings self-test")
	_line("")

	_test_defs()
	_test_schema()
	_test_documents()
	_test_manager()
	_test_persistence()
	_test_migration()
	_test_clamps()
	_test_config_bridge()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if CHECKS > 0 and _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = 1
	s.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
	s.add(DotSettingsDef.integer(&"fov", 90, 70, 120, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.boolean(&"subtitles", true, &"gameplay").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.number(&"sensitivity", 2.5, 0.1, 20.0, &"gameplay").with_scope(
		DotSettingsDef.Scope.ACCOUNT
	))
	s.add(DotSettingsDef.choice(
		&"quality", &"high", [&"low", &"medium", &"high"] as Array[StringName], &"video"
	))
	s.add(DotSettingsDef.text(&"audio_device", "", &"audio").as_private())
	return s


# --- 1 ----------------------------------------------------------------------

func _test_defs() -> void:
	_section("A setting knows what it may be")

	var vol := DotSettingsDef.number(&"vol", 0.5, 0.0, 1.0)
	_check(vol.validate().ok, "a well-formed setting validates")
	_check(float(vol.coerce(2.0).value) == 1.0, "a number above the range is clamped, not refused")
	_check(float(vol.coerce("0.25").value) == 0.25, "and a string that is a number is read")
	_check(not vol.coerce("loud").ok, "while a string that is not one is refused")

	# The type of the corrected value matters: an int-typed clamp on a float setting is a
	# volume slider that can only be 0 or 1, and every property about it reads correctly.
	_check(vol.coerce(0.37).value is float, "a float setting stays a float through coercion")
	var count := DotSettingsDef.integer(&"count", 4, 0, 10)
	_check(count.coerce(3.7).value is int, "and an int setting comes back an int")
	_check(int(count.coerce(3.7).value) == 4, "snapped rather than truncated")

	var q := DotSettingsDef.choice(&"q", &"high", [&"low", &"high"] as Array[StringName])
	_check(not q.coerce(&"ultra").ok, "an unknown option is refused rather than defaulted")
	_check(q.coerce(&"low").ok, "and a known one is taken")

	var broken := DotSettingsDef.choice(&"b", &"nope", [&"low"] as Array[StringName])
	_check(not broken.validate().ok, "a default that is not one of the options fails at boot")

	var bad_key := DotSettingsDef.boolean(&"not a key", true)
	_check(not bad_key.validate().ok, "and so does a key that cannot be a filename")

	var b := DotSettingsDef.boolean(&"b", false)
	_check(bool(b.coerce("on").value), "'on' is true")
	_check(not bool(b.coerce("0").value), "'0' is false")
	_check(not b.coerce("maybe").ok, "and 'maybe' is refused")


# --- 2 ----------------------------------------------------------------------

func _test_schema() -> void:
	_section("A schema is the only list")

	var s := _schema()
	_check(s.validate().ok, "the schema validates")
	_check(s.keys().size() == 6, "and enumerates every setting")
	_check(s.categories().size() == 3, "grouped into categories a screen can use")
	_check(s.keys_in_category(&"video").size() == 2, "with the right members")
	_check(
		s.keys_in_scope(DotSettingsDef.Scope.ACCOUNT).size() == 2,
		"and knows which ones follow a player between machines"
	)

	var dupe := DotSettingsSchema.new()
	dupe.add(DotSettingsDef.boolean(&"x", true))
	dupe.add(DotSettingsDef.boolean(&"x", false))
	_check(
		not dupe.validate().ok,
		"a key declared twice is refused, because one of the two is never read"
	)
	_check(not DotSettingsSchema.new().validate().ok, "and so is a schema with nothing in it")

	var defaults := s.defaults()
	defaults[&"master_volume"] = 0.1
	_check(
		float(s.defaults()[&"master_volume"]) == 0.8,
		"defaults() hands out a fresh dictionary, not its own"
	)


# --- 3 ----------------------------------------------------------------------

func _test_documents() -> void:
	_section("A hand-edited file loses one line, not all of them")

	var s := _schema()
	var out := s.coerce_document({
		"master_volume": 5.0,
		"fov": "110",
		"quality": "nonsense",
		"subtitles": false,
		"a_setting_from_a_newer_build": 7,
	})
	var values: Dictionary = out["values"]
	var unknown: Dictionary = out["unknown"]
	var corrected: PackedStringArray = out["corrected"]
	var refused: PackedStringArray = out["refused"]

	_check(float(values[&"master_volume"]) == 1.0, "an out-of-range value is corrected")
	_check(int(values[&"fov"]) == 110, "a number written as text is read")
	_check(
		String(values[&"quality"]) == "high",
		"a value that is not a legal option falls back to the default"
	)
	_check(not bool(values[&"subtitles"]), "and everything else survives")
	_check(corrected.size() == 1, "with the correction reported rather than swallowed")
	_check(
		refused.size() == 1 and refused[0].begins_with("quality"),
		"and a value that could not be read at all reported separately, because it is a "
		+ "different thing to tell a player"
	)
	_check(
		not corrected[0].begins_with("fov"),
		"a value that changed only its Variant type is not reported as a correction"
	)

	# The downgrade path. A player who runs a newer build, changes a setting it added and
	# goes back would otherwise lose it silently -- and lose it again every time.
	_check(unknown.has("a_setting_from_a_newer_build"), "a key this build does not know is kept")


# --- 4 ----------------------------------------------------------------------

func _test_manager() -> void:
	_section("The manager a game holds")

	var m := DotSettingsManager.new()
	m.schema = _schema()
	m.local_store = DotSettingsStoreMemory.new()
	m.app_namespace = &"selftest"
	m.persist = false
	add_child(m)
	_check(m.setup().ok, "the manager sets up")
	_check(DotRegistry.has(DotSettingsManager.SERVICE), "and publishes itself")

	_check(is_equal_approx(m.get_float(&"master_volume"), 0.8), "an unset value is the default")

	var seen := []
	m.changed.connect(func(k: StringName, v: Variant, why: StringName) -> void:
		seen.append([k, v, why])
	)
	_check(m.set_value(&"master_volume", 0.3).ok, "a value sets")
	_check(is_equal_approx(m.get_float(&"master_volume"), 0.3), "and reads back")
	_check(seen.size() == 1 and seen[0][2] == &"user", "announcing itself with a reason")

	m.set_value(&"master_volume", 0.3)
	_check(seen.size() == 1, "and setting the same value again announces nothing")

	_check(
		not m.set_value(&"no_such_setting", 1).ok,
		"a setting nothing declares is refused, rather than quietly stored"
	)

	m.reset_value(&"master_volume")
	_check(is_equal_approx(m.get_float(&"master_volume"), 0.8), "a reset is the declared default")
	_check(seen.back()[2] == &"reset", "with its own reason")

	_check(m.describe_lines().size() > 4, "and it describes itself")
	m.queue_free()


# --- 5 ----------------------------------------------------------------------

func _test_persistence() -> void:
	_section("Written on change, and an account is a second document")

	var store := DotSettingsStoreMemory.new()
	var account := DotSettingsStoreMemory.new()

	var m := DotSettingsManager.new()
	m.schema = _schema()
	m.local_store = store
	m.remote_store = account
	m.app_namespace = &"game_one"
	m.shared_namespace = &"tmc_account"
	m.profile = &"player_a"
	add_child(m)
	m.setup()
	m.set_value(&"master_volume", 0.25)
	m.set_value(&"sensitivity", 4.0)
	m.flush()

	_check(store.count() == 1, "the game's own document is written")
	_check(account.count() == 1, "and the account's is a second document, not a merge")

	# The whole point of a shared namespace: a different game, the same person.
	var other := DotSettingsManager.new()
	other.schema = _schema()
	other.local_store = DotSettingsStoreMemory.new()
	other.remote_store = account
	other.app_namespace = &"game_two"
	other.shared_namespace = &"tmc_account"
	other.profile = &"player_a"
	other.register_as_service = false
	add_child(other)
	other.setup()
	_check(
		is_equal_approx(other.get_float(&"sensitivity"), 4.0),
		"a second game reads the account-scoped setting the first one wrote"
	)
	_check(
		is_equal_approx(other.get_float(&"master_volume"), 0.8),
		"and does not read the device-scoped one, which is the whole point of the scopes"
	)

	var read_only := DotSettingsManager.new()
	read_only.schema = _schema()
	read_only.local_store = DotSettingsStoreMemory.new(true)
	read_only.register_as_service = false
	add_child(read_only)
	read_only.setup()
	var refusals := []
	read_only.saved.connect(func(r: DotResult) -> void: refusals.append(r))
	read_only.set_value(&"fov", 100)
	var res := read_only.flush()
	_check(not res.ok, "a store that cannot be written to says so")
	_check(
		res.code() == DotError.CODE_FORBIDDEN,
		"with a code a game can turn into 'your settings will not be kept'"
	)
	_check(refusals.size() == 1, "and announces it, rather than failing silently on every change")

	m.queue_free()
	other.queue_free()
	read_only.queue_free()


# --- 6 ----------------------------------------------------------------------

func _test_migration() -> void:
	_section("A document older than the build")

	var store := DotSettingsStoreMemory.new()
	# Written by an imaginary version 1, which spelled the volume 0-100.
	store.save_document(&"mig", &"p", {"version": 1, "values": {"master_volume": 60}})

	var s := _schema()
	s.version = 2

	var m := DotSettingsManager.new()
	m.schema = s
	m.local_store = store
	m.app_namespace = &"mig"
	m.profile = &"p"
	m.persist = false
	m.register_as_service = false
	m.migrations = {
		1: func(doc: Dictionary) -> Dictionary:
			var out := doc.duplicate()
			if out.has("master_volume"):
				out["master_volume"] = float(out["master_volume"]) / 100.0
			return out
	}
	add_child(m)
	m.setup()
	_check(
		is_equal_approx(m.get_float(&"master_volume"), 0.6),
		"a migration runs on the way in"
	)

	# A document with no version at all is a document from before there were versions,
	# which is version 1 by definition rather than an error.
	var old := DotSettingsStoreMemory.new()
	old.save_document(&"mig", &"p", {"master_volume": 40})
	var m2 := DotSettingsManager.new()
	m2.schema = s
	m2.local_store = old
	m2.app_namespace = &"mig"
	m2.profile = &"p"
	m2.persist = false
	m2.register_as_service = false
	m2.migrations = m.migrations
	add_child(m2)
	m2.setup()
	_check(
		is_equal_approx(m2.get_float(&"master_volume"), 0.4),
		"and an unversioned document is read as the first version rather than refused"
	)

	m.queue_free()
	m2.queue_free()


# --- 7 ----------------------------------------------------------------------

func _test_clamps() -> void:
	_section("A server may clamp, and may never read")

	var m := DotSettingsManager.new()
	m.schema = _schema()
	m.local_store = DotSettingsStoreMemory.new()
	m.persist = false
	m.register_as_service = false
	add_child(m)
	m.setup()
	m.set_value(&"fov", 115)
	m.set_value(&"sensitivity", 9.0)

	var applied := m.apply_server_clamps({"fov": 90, "sensitivity": 1.0, "audio_device": "theirs"})
	_check(applied.size() == 1 and applied[0] == "fov", "only a server-clamped setting is clamped")
	_check(int(m.get_value(&"fov")) == 90, "and the clamp takes effect")
	_check(
		is_equal_approx(m.get_float(&"sensitivity"), 9.0),
		"an account-scoped setting is not a server's business"
	)
	_check(
		m.get_string(&"audio_device") == "",
		"and a private one is refused whatever its scope says"
	)

	# A clamp is a bound, not a value. Every game that gets this wrong gets it wrong in
	# the same direction, and the symptom is a setting that resets itself on every join.
	m.set_value(&"fov", 75)
	_check(int(m.get_value(&"fov")) == 75, "a player below the cap keeps their own value")
	_check(int(m.chosen_value(&"fov")) == 75, "and their own value is what a screen shows")

	m.set_value(&"fov", 115)
	_check(int(m.chosen_value(&"fov")) == 115, "their choice is remembered under the cap")
	_check(int(m.get_value(&"fov")) == 90, "while the game still gets the capped one")

	var doc := m.to_document()
	_check(
		int(doc["values"]["fov"]) == 115,
		"and what is saved is the choice, not the cap, so leaving a server does not edit it"
	)

	m.release_clamps()
	_check(int(m.get_value(&"fov")) == 115, "releasing the clamps gives the player theirs back")
	_check(not m.is_clamped(&"fov"), "and nothing is clamped any more")

	var strict := DotSettingsManager.new()
	strict.schema = _schema()
	strict.policy = DotSettingsPolicy.new()
	strict.policy.accept_server_clamps = false
	strict.local_store = DotSettingsStoreMemory.new()
	strict.persist = false
	strict.register_as_service = false
	add_child(strict)
	strict.setup()
	_check(
		strict.apply_server_clamps({"fov": 90}).is_empty(),
		"and a client that refuses clamps refuses them"
	)

	m.queue_free()
	strict.queue_free()


# --- 8 ----------------------------------------------------------------------

func _test_config_bridge() -> void:
	_section("A settings screen, without knowing a screen exists")

	var m := DotSettingsManager.new()
	m.schema = _schema()
	m.local_store = DotSettingsStoreMemory.new()
	m.persist = false
	m.register_as_service = false
	add_child(m)
	m.setup()

	var cfg := m.to_config()
	# DotConfig discovers its keys by reflection, so a config that answers
	# _get_property_list with a schema's keys is a generated settings panel -- and the
	# obvious spelling, assigning a property that does not exist, is refused by Godot
	# outright. This family shipped that once: a game descriptor that named no module.
	_check(cfg.config_keys().size() == 6, "the config exposes every declared setting")
	_check(is_equal_approx(float(cfg.get("master_volume")), 0.8), "and reads through")
	cfg.set("master_volume", 2.0)
	_check(is_equal_approx(float(cfg.get("master_volume")), 1.0), "clamping as it goes")
	_check(
		cfg.sensitive_keys().has("audio_device"),
		"a private setting is refused from the environment and the command line"
	)

	var applied := cfg.apply_dictionary({"quality": "low"})
	_check(applied.size() == 1, "a layered override applies to it like any other config")

	_check(
		is_equal_approx(m.get_float(&"master_volume"), 0.8),
		"and none of that has touched the manager, which is what a Cancel button is made of"
	)

	var changed_keys := m.absorb_config(cfg)
	_check(changed_keys.size() == 2, "absorbing takes the changes back")
	_check(is_equal_approx(m.get_float(&"master_volume"), 1.0), "and they are live")
	_check(m.get_string(&"quality") == "low", "for every kind, including an enum")

	m.queue_free()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
