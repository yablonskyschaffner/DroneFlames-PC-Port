class_name PerfOpt
extends RefCounted

## Оптимизация поздней игры для слабых CPU (одиночная партия).
## Подключается вставками в game/game_world.gd.
## Всё выключается константами ниже — можно откатить без удаления файла.

const ENABLED: bool = true
const PRUNE_FAC: bool = true      # чистка давно мёртвых построек
const THROTTLE_AI: bool = true    # ИИ думает реже, но с накопленным dt

const FAC_KEEP_S: float = 600.0   # руина остаётся восстанавливаемой 10 игровых минут
const FAC_PRUNE_DT: float = 30.0  # период чистки, игровых секунд
const FAC_MIN: int = 64           # не трогаем маленькие списки
const FAC_MAX_PASS: int = 64      # лимит удалений за проход (без фриза)
const AI_DT: float = 0.4          # период раздумий ИИ, игровых секунд

static var _world_id: int = 0
static var _last_t: float = -1.0
static var _fac_t: float = 0.0
static var _ai_acc: float = 0.0
static var removed_total: int = 0
static var last_removed: int = 0


static func _check_world(gw) -> void:
	var wid: int = gw.get_instance_id()
	if wid != _world_id or float(gw.game_time) < _last_t - 1.0:
		_world_id = wid
		_fac_t = 0.0
		_ai_acc = 0.0
		removed_total = 0
		last_removed = 0
	_last_t = float(gw.game_time)


static func _solo(gw) -> bool:
	# в мультиплеере ничего не меняем — там нужен детерминизм
	return not bool(gw.net_driven) and not bool(gw.net_sim)


## Возвращает dt для ai.update() или 0.0, если этот тик ИИ пропускаем.
static func ai_dt(gw, dt: float) -> float:
	if not ENABLED or not THROTTLE_AI or not _solo(gw):
		return dt
	_check_world(gw)
	_ai_acc += dt
	if _ai_acc < AI_DT:
		return 0.0
	var out: float = _ai_acc
	_ai_acc = 0.0
	return out


static func _mark_used(used: Dictionary, o) -> void:
	if o != null and is_instance_valid(o):
		used[int(o.id)] = true


static func prune_facilities(gw, dt: float) -> void:
	if not ENABLED or not PRUNE_FAC or not _solo(gw):
		return
	_check_world(gw)
	_fac_t += dt
	if _fac_t < FAC_PRUNE_DT:
		return
	_fac_t = 0.0
	var mil = gw.mil
	var army = gw.army
	if mil == null or army == null:
		return
	var facs: Array = mil.facilities
	if facs.size() < FAC_MIN:
		return
	var now: float = float(gw.game_time)

	# всё, на что ещё есть живые ссылки, удалять нельзя
	var used: Dictionary = {}
	for u in army.units:
		if u == null:
			continue
		_mark_used(used, u.home)
		_mark_used(used, u.post)
	for c in gw.countries:
		for g in c.army_groups:
			for fid in g["fids"]:
				used[int(fid)] = true
	if gw.ops != null:
		for k in gw.ops.list:
			_mark_used(used, k)
	if army.tac != null:
		for k in army.tac.ops:
			_mark_used(used, k)
	_mark_used(used, gw.get("selected_facility"))
	_mark_used(used, gw.get("selected_drone"))

	var removed: int = 0
	for i in range(facs.size() - 1, -1, -1):
		if removed >= FAC_MAX_PASS:
			break
		var f = facs[i]
		if f == null:
			continue
		if mil.alive(f):
			continue
		if float(f.ruined_at) < 0.0 or now - float(f.ruined_at) < FAC_KEEP_S:
			continue
		if float(f.restore_t) > 0.0 or used.has(int(f.id)):
			continue
		facs.remove_at(i)
		removed += 1
	if removed > 0:
		removed_total += removed
		last_removed = removed
		mil.forts_changed.emit()


## Для строки [Perf] в логе.
static func stat_line(gw) -> String:
	if gw == null or gw.mil == null:
		return ""
	var dead: int = 0
	for f in gw.mil.facilities:
		if not gw.mil.alive(f):
			dead += 1
	return " fac=%d dead=%d pruned=%d" % [gw.mil.facilities.size(), dead, removed_total]
