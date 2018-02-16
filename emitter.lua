local N = ...
local log = require 'log'
local fiber = require 'fiber'
local clr = require 'devel.caller'

local function table_clear(t)
	local count = #t
	for i = 0, count do t[i]=nil end
end

-- local function assert(test,message)
-- 	if not test then
-- 		error(message,3)
-- 	end
-- end

local M = {}

setmetatable(M,{
	__index = function (self,k)
		-- autoload function. call to methodname(...) coerce into :event('methodname',...)
		self[k] = function(self, ...)
			self:event(k, ...)
		end
		return self[k]
	end
})

local ffi = require 'ffi'
local function guard(cb)
    return ffi.gc(ffi.new('char[1]'), function()
        local r,e  = pcall(cb)
        if not r then
        	log.error("Error during guard: %s", e)
        end
    end)
end

local function new_emitter(options)
	local inner = setmetatable({
		backlog   = options.backlog or 128,
		handlers  = {},
		callbacks = setmetatable({},{__mode = "kv"}),
		["\0"]    = setmetatable({},{__mode = "v"}), -- weird name for weakref to self table
	},{ __index = M })
	local self = setmetatable({},{
		__mygc = guard(function ()
			inner["\0"].self = nil
			-- print("unrefed")
			for event,h in pairs(inner.handlers) do
				-- print("clean", event, h)
				table_clear(h.chain)
				h.ch:close()
				-- print("done")
			end
		end),
		__index    = inner,
		__newindex = inner,
		__tostring = function(self)
			local inner = getmetatable(self).__index
			local events = {}
			for event,h in pairs(inner.handlers) do
				table.insert(events, event .. ":" .. #h.chain)
			end
			return string.format("%s(%s)", N, table.concat( events,", " ))
		end
	});
	inner["\0"].self = self
	return self
end

local function track_cb( self, cb, event )
	if not self.callbacks[ cb ] then
		self.callbacks[ cb ] = {}
	end
	self.callbacks[ cb ][ event ] = true
end

local function untrack_cb( self, cb, event )
	if self.callbacks[ cb ] then
		self.callbacks[ cb ][ event ] = nil
		for _ in pairs(self.callbacks[ cb ]) do
			return
		end
		self.callbacks[ cb ] = nil
	else
		-- ???
	end
	
end

function M:on(event,cb)
	local rec = { cb = cb; }
	return self:_on(event,rec)
end

function M:once(event,cb,alias)
	local rec = { cb = cb; limit = 1; }
	return self:_on(event,rec)
end

function M:_on(event,rec)
	local inner = getmetatable(self).__index
	rec.clr = clr(1)
	local h = self.handlers[event]
	if h then
		table.insert(h.chain,1,rec)
	else
		h = { chain = { rec }, event = event }
		self.handlers[event] = h
		h.ch = fiber.channel( self.backlog )
		h.working = true
		h.fiber = fiber.create(function()
			local name = string.format("%s.%s",N,event)
			fiber.name(name)
			while #h.chain > 0 and inner["\0"].self do
				-- print("fiber sleep")
				local event = h.ch:get()
				-- print("fiber wakeup", event)
				if event then
					-- print("received event in fiber ",unpack(event))
					h.handled = false
					local ctx = setmetatable({},{ __index = inner["\0"].self })
					ctx.stop = function() h.handled = true end
					local rem = {}
					for i,rec in ipairs(h.chain) do
						-- print("apply event for ",i," ",rec.alias or rec.cb)
						local r,e = pcall(rec.cb,ctx,unpack(event))
						if not r then
							log.error("callback #%d %s failed: %s (defined at %s)",i, tostring(rec.cb), e, rec.clr)
						end
						if rec.limit then
							rec.limit = rec.limit - 1
							if rec.limit == 0 then
								table.insert(rem,1,i)
							end
						end
						if h.handled then break end
					end
					if #rem > 0 then
						for _,i in ipairs(rem) do
							local rec = table.remove( h.chain, i )
							untrack_cb( inner, rec.cb, event )
						end
					end
					h.handled = nil
				elseif h.ch:is_closed() then
					break
				-- else
				-- 	print("no event")
				end
			end
			-- print("fiber "..name.." gone")
			h.fiber = nil
			h.ch:close()
			inner.handlers[event] = nil
		end)
	end
	track_cb( inner, rec.cb, event )
	-- self.callbacks[ rec.cb ] = self.handlers[event]
	return function()
		if #h.chain > 0 then
			local h = self.handlers[event]
			for i,r in ipairs(h.chain) do
				if rec == r then
					table.remove( h.chain, i )
					-- self.callbacks[ rec.cb ] = nil -- ??
					break
				end
			end
		end
	end
end

function M:no(arg)
	if type(arg) == 'function' or (debug.getmetatable(arg) and debug.getmetatable(arg).__call) then
		-- print("unreg ",arg)
		if self.callbacks[ arg ] then
			local events = self.callbacks[ arg ]
			for event in pairs(events) do
				-- print("unregistering cb for ",event)
				-- if self.handlers[event] then
					local h = self.handlers[event]
					for i = #h.chain,1,-1 do
						if h.chain[i].cb == arg then
							-- print("found cb, remove")
							table.remove( h.chain, i )
						end
					end
					if #h.chain == 0 then
						h.ch:close()
					end
				-- end
			end
			self.callbacks[ arg ] = nil -- all at once
		else
			log.warn("No listener registered by callback '%s'", arg)
		end
	elseif type(arg) == 'string' then
		if self.handlers[arg] then
			local h = self.handlers[arg]
			h.ch:close()
			self.handlers[arg] = nil
			for i = #h.chain,1,-1 do
				untrack_cb( self, h.chain[i].cb, arg )
				h.chain[i] = nil
			end
		else
			log.warn("No handlers registered for event '%s'", arg)
		end
	else
		error("Unknown arg for `no': "..tostring(arg),2)
	end
end

function M:event(event, ...)
	if not self.handlers[event] then return end
	-- log.info("dispatch event `%s'",event)
	-- channel may block in case of slow processing
	return self.handlers[event].ch:put({...})
end
M.emit = M.event

function M:handles(event)
	if not self.handlers[event] then return false end
	return #self.handlers[event].chain
end

return setmetatable({
	new = new_emitter
},{
	__call = function(_, ...)
		return new_emitter(...)
	end
})
