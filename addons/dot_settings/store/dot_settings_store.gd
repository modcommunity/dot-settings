class_name DotSettingsStore
extends RefCounted

## Where a settings document lives. Subclass to put it somewhere else.
##
## Three implementations ship: [DotSettingsStoreMemory] for a suite,
## [DotSettingsStoreFile] for a player's own machine, and nothing for an account —
## because an account store is an HTTP client against somebody's backbone and this addon
## does not get to decide whose. [DotSettingsManager.remote_store] takes any subclass.
##
## [b]A document is addressed by (namespace, profile).[/b] The namespace is the game, or a
## name several games deliberately share; the profile is the person. Both are part of the
## address rather than of the document, so one store serves every game a launcher installs
## and a shared namespace is a path rather than a merge.
##
## The parameter is spelled [code]app_namespace[/code] throughout because
## [code]namespace[/code] is a reserved word in GDScript — and the error it produces is
## "Expected parameter name", which points at the punctuation rather than at the word.

## Reads a document. A missing one is an empty dictionary and a success, not a failure.
##
## [b]That distinction is the whole interface.[/b] "Nobody has ever saved settings here"
## is the first run of every installation, and a store that reports it as an error makes
## every caller write the same two-line special case — which is the case somebody gets
## wrong, and then a first run is a crash.
func load_document(_app_namespace: StringName, _profile: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "this store cannot read")


## Writes a document, replacing whatever was there.
func save_document(
	_app_namespace: StringName, _profile: StringName, _document: Dictionary
) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "this store cannot write")


## Forgets a document entirely.
func clear_document(_app_namespace: StringName, _profile: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "this store cannot clear")


## Whether this store can be written to at all.
##
## A read-only store is a legitimate deployment — a locked-down machine, a demo kiosk, a
## browser that refused its storage quota — and a manager that knows it is read-only can
## say "your settings will not be kept" once, instead of failing every save silently.
func writable() -> bool:
	return true


func store_name() -> String:
	return "none"
