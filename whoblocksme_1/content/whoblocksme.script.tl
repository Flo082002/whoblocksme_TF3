local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local button_react_util = ug_require "::/gui/main/button_react_util.tl" as ButtonReactUtil
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local entity_window_util = ug_require "::/gui/entity_window/entity_window_util.tl" as EntityWindowUtil
local react = ug_require "::/gui/main/react.lua" as React
local gui_react_util = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local mod_entry_point = ug_require "::/gui/main/mod_entry_point.tl" as ModEntryPoint

local whoblocksme : any = {}

local CACHE_SECONDS = 1
local MAX_CHAIN = 20 -- search steps; at most MAX_CHAIN - 1 names are shown, a last step is shown as ...
local ROW_CHARS = 28
local RESHOW_SECONDS = 1

-- Opening another window "shelves" (hides) unpinned windows. Windows of one chain session are
-- shown again for a moment after each click. A click from a window outside the set starts a new session.
local keepVisible : {string : boolean} = {}
local reshowUntil = 0

local startReshow = function(fromTrain : Engine.Entity, toTrain : Engine.Entity)
	if not keepVisible[tostring(fromTrain)] then
		keepVisible = {}
	end
	keepVisible[tostring(fromTrain)] = true
	keepVisible[tostring(toTrain)] = true
	reshowUntil = os.clock() + RESHOW_SECONDS
end

local reshowWindows = function()
	if os.clock() < reshowUntil then
		for train in pairs(keepVisible) do
			pcall(api.gui.byId.setVisible, "temp.view.entity_" .. train, true)
		end
	end
end

local record Chain
	blockers : {Engine.Entity}
	cycleTo : Engine.Entity -- set when the chain runs back into a train already in it (or our own)
end

local record Cached
	time : number
	chain : Chain
end
local cache : {string : Cached} = {}
local loggedError : {string : boolean} = {}

-- path entries are EdgeIdDir userdata: .edgeId (entity, index) and .dir
local edgeKey = function(pathEdge : any) : string
	local id = (pathEdge as {string : any}).edgeId as {string : any}
	return tostring(id.entity) .. ":" .. tostring(id.index)
end

-- set DEBUG = true to log (on change only) one line per search and train
local DEBUG = false
local diagLast : {string : string} = {}
local diag = function(train : Engine.Entity, text : string)
	local key = tostring(train)
	if DEBUG and diagLast[key] ~= text then
		diagLast[key] = text
		log.message("WHOBLOCKSME " .. key .. " " .. text)
	end
end

-- read a field of engine userdata without throwing ("no member named ...")
local field = function(o : any, name : string) : any
	local ok, value = pcall(function() return (o as {string : any})[name] end)
	return ok and value or nil
end

-- the tealdef says servedFrom/servedTo, the real MovePath fields are reservedFrom/reservedTo
local reservedTo = function(mp : Engine.Component.MovePath) : integer
	local to = field(mp, "reservedTo")
	return type(to) == "number" and to as integer or mp.occupiedFrontIndex
end

local isWaiting = function(trainEntity : Engine.Entity) : boolean
	return api.engine.getComponent(trainEntity, api.type.ComponentType.TRANSPORT_VEHICLE) ~= nil
		and api.engine.system.landVehicleMoveSystem.isTrainWaitingForFreePath(trainEntity)
end

-- waypoints do not end a reservation, only real signals do; unreadable type counts as signal
local isWaypoint = function(signalId : {string : any}) : boolean
	local ok, signalType = pcall(function() : any
		local list = api.engine.getComponent(signalId.entity as Engine.Entity, api.type.ComponentType.SIGNAL_LIST) as {string : any}
		return ((list.signals as {any})[(signalId.index as integer) + 1] as {string : any}).type
	end)
	if not ok then
		return false
	end
	-- the base game has two enums with a WAYPOINT member, compare against both
	local typeEnums = api.type as {string : any}
	for __, getWaypoint in ipairs({
		function() : any return (typeEnums.enum as {string : any}).SignalType.WAYPOINT end,
		function() : any return (typeEnums.Signal as {string : any}).Type.WAYPOINT end,
	}) do
		local okEnum, waypoint = pcall(getWaypoint)
		if okEnum and waypoint ~= nil and signalType == waypoint then
			return true
		end
	end
	return false
end

local hasSignal = function(pathEdge : any) : boolean
	local e = pathEdge as {string : any}
	local signal = api.engine.system.signalSystem.getSignal(e.edgeId as EdgeId, not (e.dir as boolean)) as {string : any}
	return signal ~= nil and signal.entity ~= nil and (signal.entity as integer) >= 0 and not isWaypoint(signal)
end

-- Keys of a path edge: the edge itself and, for switches/crossings (BASE_NODE entities), the node entity,
-- because trains crossing each other share the node entity, not an edge.
local nodeEntities : {string : boolean} = {}
local keysOf = function(pathEdge : any) : {string}
	local entity = ((pathEdge as {string : any}).edgeId as {string : any}).entity as Engine.Entity
	local entityKey = tostring(entity)
	if nodeEntities[entityKey] == nil then
		nodeEntities[entityKey] = api.engine.getComponent(entity, api.type.ComponentType.BASE_NODE) ~= nil
	end
	if nodeEntities[entityKey] then
		return { edgeKey(pathEdge), "node:" .. entityKey }
	end
	return { edgeKey(pathEdge) }
end

-- key -> trains holding it: every train holds path[occupiedBack .. reservedTo] (built once per search)
local buildHeldBy = function() : {string : {Engine.Entity}}
	local heldBy : {string : {Engine.Entity}} = {}
	for __, train in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.TRANSPORT_VEHICLE)) do
		if api.engine.getComponent(train, api.type.ComponentType.TRAIN) then
			local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH) as Engine.Component.MovePath
			if mp then
				for i = mp.occupiedBackIndex, math.min(reservedTo(mp), #mp.path.edges - 1) do
					for __, key in ipairs(keysOf(mp.path.edges[i + 1])) do
						local holders = heldBy[key] or {}
						if holders[#holders] ~= train then
							table.insert(holders, train)
						end
						heldBy[key] = holders
					end
				end
			end
		end
	end
	return heldBy
end

-- TEMP (DEBUG only): why was no blocker found? logs on change only
local explainNone = function(train : Engine.Entity, mp : Engine.Component.MovePath, first : integer, last : integer, signals : string)
	local tv = api.engine.getComponent(train, api.type.ComponentType.TRANSPORT_VEHICLE) as {string : any}
	local lines : {string} = {}
	local add = function(text : string)
		table.insert(lines, text)
	end
	add("NONE '" .. api.engine.util.getEntityName(train) .. "' state=" .. tostring(tv and tv.state) .. " line=" .. tostring(tv and tv.line)
		.. " stopIndex=" .. tostring(tv and tv.stopIndex) .. " back=" .. mp.occupiedBackIndex .. " front=" .. mp.occupiedFrontIndex
		.. " reserved=" .. tostring(field(mp, "reservedFrom")) .. ".." .. tostring(field(mp, "reservedTo")) .. " edges=" .. #mp.path.edges
		.. " needs=" .. first .. ".." .. last .. " signals=" .. signals)
	local parts : {string} = {}
	for i = first, math.min(last, first + 19) do
		local edge = mp.path.edges[i + 1]
		table.insert(parts, i .. ":" .. edgeKey(edge) .. (#keysOf(edge) > 1 and "[NODE]" or ""))
	end
	add("needed edges " .. table.concat(parts, " "))

	-- edge entity -> first index on this train's whole path
	local entityIndex : {string : integer} = {}
	for i = 0, #mp.path.edges - 1 do
		local entityKey = tostring(((mp.path.edges[i + 1] as {string : any}).edgeId as {string : any}).entity)
		if entityIndex[entityKey] == nil then
			entityIndex[entityKey] = i
		end
	end
	local count = 0
	for __, other in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.TRANSPORT_VEHICLE)) do
		if other ~= train and api.engine.getComponent(other, api.type.ComponentType.TRAIN) then
			local omp = api.engine.getComponent(other, api.type.ComponentType.MOVE_PATH) as Engine.Component.MovePath
			if omp and count < 10 then
				local heldTo = math.min(reservedTo(omp), #omp.path.edges - 1)
				local shared = ""
				local near = ""
				for i = omp.occupiedBackIndex, heldTo do
					local edge = omp.path.edges[i + 1]
					local entityKey = tostring(((edge as {string : any}).edgeId as {string : any}).entity)
					local mine = entityIndex[entityKey]
					if mine ~= nil then
						if shared == "" then
							shared = "SHARED entity " .. entityKey .. " its " .. edgeKey(edge) .. "@" .. i .. " / own " .. edgeKey(mp.path.edges[mine + 1]) .. "@" .. mine
						end
						if i <= omp.occupiedFrontIndex and near == "" and math.abs(mine - mp.occupiedFrontIndex) <= 3 then
							near = " NEAR-FRONT(own idx " .. mine .. ")"
						end
					end
				end
				if shared ~= "" then
					count = count + 1
					add("other " .. tostring(other) .. " '" .. api.engine.util.getEntityName(other) .. "' waiting=" .. tostring(isWaiting(other))
						.. " back=" .. omp.occupiedBackIndex .. " front=" .. omp.occupiedFrontIndex .. " reserved=" .. tostring(field(omp, "reservedFrom"))
						.. ".." .. tostring(field(omp, "reservedTo")) .. " " .. shared .. near)
				end
			end
		end
	end
	if count == 0 then
		add("no other train holds any edge entity of this train's whole path")
	end
	local text = table.concat(lines, "\n    ")
	local key = "none" .. tostring(train)
	if diagLast[key] ~= text then
		diagLast[key] = text
		log.message("WHOBLOCKSME " .. tostring(train) .. " " .. text)
	end
end

-- The area a waiting train needs: path[reservedTo+1 .. second real signal ahead] (a train passes a signal only
-- if the block behind it is free too), or to the path end. Blocker = the other train holding a key of that
-- area at the smallest path index. (Indices are zero-based.)
local blockerOf = function(train : Engine.Entity, heldBy : {string : {Engine.Entity}}) : Engine.Entity
	local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH) as Engine.Component.MovePath
	if not mp then
		return -1
	end
	local first = reservedTo(mp) + 1
	local last = #mp.path.edges - 1
	local signalIndices : {string} = {}
	for i = first, last do
		local edge = mp.path.edges[i + 1]
		for __, key in ipairs(keysOf(edge)) do
			for __, holder in ipairs(heldBy[key] or {}) do
				if holder ~= train then
					diag(train, "needs " .. first .. ".." .. i .. " signals=" .. table.concat(signalIndices, ",") .. " -> blocker=" .. tostring(holder)
						.. " '" .. api.engine.util.getEntityName(holder) .. "' key=" .. key .. " idx=" .. i)
					return holder
				end
			end
		end
		if hasSignal(edge) then
			table.insert(signalIndices, tostring(i))
			if #signalIndices >= 2 then
				last = i
				break
			end
		end
	end
	local signals = #signalIndices > 0 and table.concat(signalIndices, ",") or "none"
	diag(train, "needs " .. first .. ".." .. last .. " signals=" .. signals .. " -> none")
	if DEBUG then
		explainNone(train, mp, first, last, signals)
	end
	return -1
end

local unsafeSearchChain = function(ownTrain : Engine.Entity) : Chain
	local chain : Chain = { blockers = {} }
	nodeEntities = {}
	local heldBy = buildHeldBy()
	local visited : {string : boolean} = { [tostring(ownTrain)] = true }
	local current = ownTrain
	while #chain.blockers < MAX_CHAIN do
		if current ~= ownTrain and not isWaiting(current) then
			break
		end
		local blocker = blockerOf(current, heldBy)
		if blocker < 0 then
			break
		end
		if visited[tostring(blocker)] then
			chain.cycleTo = blocker
			break
		end
		visited[tostring(blocker)] = true
		table.insert(chain.blockers, blocker)
		current = blocker
	end
	return chain
end

-- never let a failure break the vehicle window
local searchChain = function(ownTrain : Engine.Entity) : Chain
	local ok, result = pcall(unsafeSearchChain, ownTrain)
	if ok then
		return result as Chain
	end
	local key = tostring(ownTrain)
	if not loggedError[key] then
		loggedError[key] = true
		log.error("WHOBLOCKSME " .. tostring(result))
	end
	return { blockers = {} }
end

local findChain = function(ownTrain : Engine.Entity) : Chain
	-- sim persons also use SpeedIndicator
	if not isWaiting(ownTrain) then
		return { blockers = {} }
	end
	local key = tostring(ownTrain)
	local now = os.clock()
	local entry = cache[key]
	if not entry or now - entry.time > CACHE_SECONDS then
		entry = { time = now, chain = searchChain(ownTrain) }
		cache[key] = entry
	end
	return entry.chain
end

local original = entity_window_util.SpeedIndicator

local BlockerSpeedIndicator = react.RegisterRecipe("WhoBlocksMeSpeedIndicator", function(entityId : Engine.Entity) : TreeNodeId
	local chainState = engine_react_util.useStepState(function() : Chain
		reshowWindows()
		return findChain(entityId)
	end)

	local makeButton = function(prefix : string, train : Engine.Entity) : TreeNodeId
		return button_react_util.makeTextButton(
			"primary",
			prefix .. api.engine.util.getEntityName(train),
			function()
				startReshow(entityId, train)
				api.gui.fireReactEvent("selectEntity", { entity = train, stack = true })
			end,
			_("whoblocksme_blocked_by")
		)
	end

	local children = { original(entityId) }
	local chain = chainState:old()
	if chain then
		-- no wrapping layout for buttons that fits the overlay: build right-aligned rows by character budget
		local entries : {{string, Engine.Entity}} = {}
		for i, train in ipairs(chain.blockers) do
			if i >= MAX_CHAIN then
				table.insert(entries, { "…", -1 })
			elseif api.engine.entityExists(train) then
				table.insert(entries, { "→ ", train })
			end
		end
		if chain.cycleTo and api.engine.entityExists(chain.cycleTo) then
			table.insert(entries, { "∞ ", chain.cycleTo })
		end

		local row : {TreeNodeId} = {}
		local rowChars = 0
		local flushRow = function()
			-- create the spacer only when the row is used: recipe nodes not attached to the tree cause warnings
			if #row > 0 then
				table.insert(row, 1, gui_react_util.makeHorizontalSpacer())
				table.insert(children, builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = row })
			end
			row = {}
			rowChars = 0
		end
		for __, entry in ipairs(entries) do
			local isMore = entry[2] < 0
			local label = isMore and entry[1] or (entry[1] .. api.engine.util.getEntityName(entry[2]))
			if rowChars > 0 and rowChars + #label > ROW_CHARS then
				flushRow()
			end
			table.insert(row, isMore and builtin.TextView{ meta = { class = "font-scale-body" }, text = entry[1] }
				or makeButton(entry[1], entry[2]))
			rowChars = rowChars + #label + 2
		end
		flushRow()
	end

	-- recipe child must be a layout, also without blocker
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end)

entity_window_util.SpeedIndicator = BlockerSpeedIndicator

-- plugin only exists so this script is loaded at UI start/reload, before any window renders
whoblocksme.WhoBlocksMePlugin = react.RegisterPluginRecipe(mod_entry_point.ModEntryPointExtension, "WhoBlocksMePlugin", function() : TreeNodeId
	return builtin.BoxLayout{}
end)

return whoblocksme
