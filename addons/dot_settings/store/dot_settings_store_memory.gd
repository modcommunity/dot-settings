class_name DotSettingsStoreMemory
extends DotSettingsStore

## A store that forgets when the process does. For suites, and for a demo build.
##
## Also the honest fallback when a browser refuses its storage quota: settings that work
## for this session and say so, rather than a save path that fails on every change.

var _docs: Dictionary = {}
var _read_only: bool = false


func _init(read_only: bool = false) -> void:
	_read_only = read_only


func _address(app_namespace: StringName, profile: StringName) -> String:
	return "%s/%s" % [app_namespace, profile]


func load_document(app_namespace: StringName, profile: StringName) -> DotResult:
	# Duplicated on the way out. A Dictionary is a reference in GDScript, and this family
	# has shipped that aliasing four times -- a scoped leaderboard sharing its template's
	# dictionary being the first.
	var d: Dictionary = _docs.get(_address(app_namespace, profile), {})
	return DotResult.success(d.duplicate(true))


func save_document(
	app_namespace: StringName, profile: StringName, document: Dictionary
) -> DotResult:
	if _read_only:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "this store is read-only")
	_docs[_address(app_namespace, profile)] = document.duplicate(true)
	return DotResult.success(null)


func clear_document(app_namespace: StringName, profile: StringName) -> DotResult:
	_docs.erase(_address(app_namespace, profile))
	return DotResult.success(null)


func writable() -> bool:
	return not _read_only


func store_name() -> String:
	return "memory"


## How many documents are held. For a suite.
func count() -> int:
	return _docs.size()
