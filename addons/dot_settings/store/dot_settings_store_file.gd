class_name DotSettingsStoreFile
extends DotSettingsStore

## JSON under [code]user://[/code], written atomically, flushed on every write.
##
## Three details are load-bearing and each one is a bug this family has already paid for
## somewhere:
##
## [b]1. The write is atomic.[/b] [method DotPaths.write_json] writes a temporary file and
## renames it. A settings file truncated by a crash mid-write is a player who lost every
## setting, and the moment a game is most likely to crash is while it is shutting down —
## which is exactly when the naive implementation writes.
##
## [b]2. [code]user://[/code] on the web is an IndexedDB mirror.[/b] It needs an explicit
## flush or the write is in memory only and is gone when the tab closes. [method
## DotPaths.replace_file] calls [method DotWeb.sync_filesystem] for us, and this store
## calls it again after a clear, because a removal is a write too.
##
## [b]3. The filename is sanitised with an explicit alphabet.[/b] Not
## [method String.is_valid_ascii_identifier], which is false for a digit — it answers "may
## this begin an identifier". dot-timer replaced every digit in a map id with an
## underscore that way, and two maps whose names differed only by a trailing number shared
## one records file.

const CHANNEL := "settings"

## Directory under [code]user://[/code].
var directory: String = "user://settings"

var _last_error: String = ""


func _init(p_directory: String = "user://settings") -> void:
	directory = p_directory


func _path(app_namespace: StringName, profile: StringName) -> String:
	return "%s/%s.%s.json" % [
		directory.rstrip("/"), _safe(String(app_namespace)), _safe(String(profile))
	]


## Reduces a name to something that is a filename on every platform this family targets.
##
## An explicit allow-list rather than a rejection list: Windows reserves device names,
## macOS folds case, and a colon is legal on one of the three. What is left is unambiguous
## everywhere, and two names that reduce to the same thing are a collision the manager
## reports rather than a silent merge.
func _safe(s: String) -> String:
	var out := ""
	for i in range(s.length()):
		var c := s[i]
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-":
			out += c
		elif c >= "A" and c <= "Z":
			out += c.to_lower()
		else:
			out += "_"
	if out.is_empty():
		out = "default"
	return out.substr(0, 64)


func load_document(app_namespace: StringName, profile: StringName) -> DotResult:
	var path := _path(app_namespace, profile)
	if not FileAccess.file_exists(path):
		# A first run is not a failure. A store that says otherwise makes every caller
		# write the same special case, and that is the one somebody gets wrong.
		return DotResult.success({})

	var res := DotPaths.read_json(path)
	if not res.ok:
		# A corrupt settings file must not stop a game booting. It is renamed rather than
		# deleted, because the one thing worse than losing a settings file is losing it
		# and being unable to show anybody what was in it.
		_last_error = res.error.message
		var salvage := path + ".broken"
		var dir := DirAccess.open(directory)
		if dir != null:
			dir.remove(salvage)
			dir.rename(path, salvage)
			DotWeb.sync_filesystem()
		DotLog.warn(
			CHANNEL,
			"settings file unreadable, kept aside and starting from defaults",
			{"path": path, "kept": salvage, "why": res.error.message}
		)
		return DotResult.success({})

	var doc: Variant = res.value
	if not (doc is Dictionary):
		return DotResult.success({})
	return DotResult.success(doc)


func save_document(
	app_namespace: StringName, profile: StringName, document: Dictionary
) -> DotResult:
	var res := DotPaths.write_json(_path(app_namespace, profile), document, true, true)
	if not res.ok:
		_last_error = res.error.message
		return res.wrap("saving settings")
	return DotResult.success(null)


func clear_document(app_namespace: StringName, profile: StringName) -> DotResult:
	var path := _path(app_namespace, profile)
	if not FileAccess.file_exists(path):
		return DotResult.success(null)
	var dir := DirAccess.open(path.get_base_dir())
	if dir == null:
		return DotResult.failure(
			DotError.from_engine(DirAccess.get_open_error(), "opening the settings directory")
		)
	var err := dir.remove(path)
	if err != OK:
		return DotResult.failure(DotError.from_engine(err, "removing '%s'" % path))
	# A removal is a write, and on the web an unflushed removal comes back on the next
	# load.
	DotWeb.sync_filesystem()
	return DotResult.success(null)


func writable() -> bool:
	# Asked rather than assumed. A browser can refuse its storage quota outright, and a
	# read-only medium is a real deployment -- the answer decides whether the game tells
	# the player their settings will not be kept, which is better than failing on every
	# change in silence.
	var probe := DotPaths.ensure_dir(directory)
	return probe.ok


func store_name() -> String:
	return "file:%s" % directory


func last_error() -> String:
	return _last_error
