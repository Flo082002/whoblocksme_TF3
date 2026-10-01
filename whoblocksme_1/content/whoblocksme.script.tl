local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local button_react_util = ug_require "::/gui/main/button_react_util.tl" as ButtonReactUtil
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local entity_window_util = ug_require "::/gui/entity_window/entity_window_util.tl" as EntityWindowUtil
local react = ug_require "::/gui/main/react.lua" as React
local gui_react_util = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local mod_entry_point = ug_require "::/gui/main/mod_entry_point.tl" as ModEntryPoint

local whoblocksme : any = {}

local CACHE_SECONDS = 1
local MAX_LOOKAHEAD = 1000 -- safety cap; effectively the whole remaining path
local MAX_CHAIN = 20 -- search steps; at most MAX_CHAIN - 1 names are shown, a last step is shown as ...
local ROW_CHARS = 28
local MAX_VEHICLE_CALLS = 100
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

-- set DEBUG = true to log (on change only) what the search finds per train
local DEBUG = false
local diagLast : {string : string} = {}
local diag = function(train : Engine.Entity, text : string)
	local key = tostring(train)
	if DEBUG and diagLast[key] ~= text then
		diagLast[key] = text
		log.message("WHOBLOCKSME " .. key .. " " .. text)
	end
end

local isWaiting = function(trainEntity : Engine.Entity) : boolean
	return api.engine.getComponent(trainEntity, api.type.ComponentType.TRANSPORT_VEHICLE) ~= nil
		and api.engine.system.landVehicleMoveSystem.isTrainWaitingForFreePath(trainEntity)
end

-- edge key -> train occupying it (all trains, built once per search)
local buildOccupiedBy = function() : {string : Engine.Entity}
	local occupiedBy : {string : Engine.Entity} = {}
	for __, train in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.TRANSPORT_VEHICLE)) do
		if api.engine.getComponent(train, api.type.ComponentType.TRAIN) then
			local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH) as Engine.Component.MovePath
			if mp then
				for i = mp.occupiedBackIndex, mp.occupiedFrontIndex do
					local edge = mp.path.edges[i + 1]
					if edge then
						occupiedBy[edgeKey(edge)] = train
					end
				end
			end
		end
	end
	return occupiedBy
end

-- first other train occupying an edge on the path ahead (indices assumed zero-based)
-- getBlockedTrains() is useless here, it is empty for normal waiting
local blockerOf = function(train : Engine.Entity, occupiedBy : {string : Engine.Entity}, visited : {string : boolean}) : Engine.Entity
	local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH) as Engine.Component.MovePath
	if not mp then
		return -1
	end
	local first = mp.occupiedFrontIndex + 1
	local last = math.min(#mp.path.edges - 1, first + MAX_LOOKAHEAD - 1)
	for i = first, last do
		local other = occupiedBy[edgeKey(mp.path.edges[i + 1])]
		if other and other ~= train then
			diag(train, "back=" .. mp.occupiedBackIndex .. " front=" .. mp.occupiedFrontIndex .. " pathLen=" .. #mp.path.edges .. " scanned=" .. first .. ".." .. last .. " -> occupancy blocker=" .. tostring(other) .. " at " .. i)
			return other
		end
	end

	-- fallback: transportVehicleSystem.getVehicles also reports reserving vehicles
	-- (per transport network entity, so coarser than the edge map)
	local seen : {string : boolean} = {}
	local lines : {string} = {}
	local calls = 0
	for i = first, #mp.path.edges - 1 do
		local tnEntity = (mp.path.edges[i + 1] as {string : any}).edgeId.entity as Engine.Entity
		local tnKey = tostring(tnEntity)
		if not seen[tnKey] and calls < MAX_VEHICLE_CALLS then
			seen[tnKey] = true
			calls = calls + 1
			local vehicles = api.engine.system.transportVehicleSystem.getVehicles({ tnEntity }, false)
			if DEBUG and #lines < 10 then
				local ids : {string} = {}
				for __, v in ipairs(vehicles) do
					table.insert(ids, tostring(v))
				end
				table.insert(lines, tnKey .. "={" .. table.concat(ids, ",") .. "}")
			end
			for __, v in ipairs(vehicles) do
				if v ~= train and not visited[tostring(v)] and api.engine.getComponent(v, api.type.ComponentType.TRAIN) then
					diag(train, "occupancy none; getVehicles -> blocker=" .. tostring(v) .. " at edge " .. i .. " | " .. table.concat(lines, " "))
					return v
				end
			end
		end
	end
	diag(train, "back=" .. mp.occupiedBackIndex .. " front=" .. mp.occupiedFrontIndex .. " pathLen=" .. #mp.path.edges .. " scanned=" .. first .. ".." .. last .. " -> none | getVehicles: " .. table.concat(lines, " "))
	return -1
end

local unsafeSearchChain = function(ownTrain : Engine.Entity) : Chain
	local chain : Chain = { blockers = {} }
	local occupiedBy = buildOccupiedBy()
	local visited : {string : boolean} = { [tostring(ownTrain)] = true }
	local current = ownTrain
	while #chain.blockers < MAX_CHAIN do
		if current ~= ownTrain and not isWaiting(current) then
			diag(current, "not waiting -> chain stops")
			break
		end
		local blocker = blockerOf(current, occupiedBy, visited)
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
			table.insert(entries, { "↺ ", chain.cycleTo })
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
