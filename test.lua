local fiber = require 'fiber'
fiber.yield()

local tap = require('tap')
local test = tap.test("Event emitter")
test:plan(17)
do
	local ee = require 'emitter' {}

	local sum = 0

	local function callback(ctx, arg1)
		print("# callback",arg1)
		sum = sum + arg1
	end

	test:is(ee:handles("event"),false,"handles - false")

	ee:on("event",callback)

	test:is(ee:handles("event"),1,"handles - 1")

	ee:event("event",1)
	fiber.yield()
	test:is(sum,1,"1st event")

	ee:event("event",2)
	fiber.yield()
	test:is(sum,3,"2nd event")

	local cxl = ee:on("event",callback) -- keep retval fot cancel

	test:is(ee:handles("event"),2,"handles - 2")

	ee:event("event",3)
	fiber.yield()
	test:is(sum,9,"3rd event (twice)")

	ee:once("event",callback)

	ee:event("event",1,0)
	fiber.yield()
	test:is(sum,12,"4th event (3 times)")

	ee:event("event",1,0)
	fiber.yield()
	test:is(sum,14,"5th event (2 times)")

	cxl() -- cancel one handler

	ee:event("event",3,0)
	fiber.yield()
	test:is(sum,17,"5th event (1 time)")

	ee:on("event",callback)
	ee:on("other",callback)
	print("# "..tostring(ee))

	ee:no(callback) -- cancel all by callback

	ee:event("event",3,0)
	ee:event("other",4,0)
	fiber.yield()
	test:is(sum,17,"6th event (no calls)")

	ee:on("event",function (ctx, arg) sum = sum + arg end)
	ee:on("event",function (ctx, arg) sum = sum + arg end)
	ee:on("event",function (ctx, arg) sum = sum + arg end)
	ee:on("event",callback)

	print("# "..tostring(ee))

	ee:event("event",1,0)
	fiber.yield()
	test:is(sum,21,"7th event (4 calls)")

	ee:no(callback) -- cancel by callback

	ee:event("event",1,0)
	fiber.yield()
	test:is(sum,24,"8th event (3 calls)")

	ee:no("event") -- cancel all by name

	ee:event("event",1,0)
	fiber.yield()
	test:is(sum,24,"9th event (no calls)")

	ee:no("thing") -- cancel all by name

	ee:on("event",function (ctx, arg) sum = sum + 1 end)
	ee:on("event",function (ctx, arg)
		test:is(ctx.zzz,42,"ctx pass")
		sum = sum + 2
		ctx:stop()
	end) -- stop propagation
	ee:on("event",function (ctx, arg) sum = sum + 3 ctx.zzz = 42 end)

	ee:event("event")
	fiber.yield()
	test:is(sum,29,"10th event (2 calls)")
	-- test:diag("%s",rawget(ee,"zzz"))
	test:ok(rawget(ee,"zzz") == nil,"no ctx pollution")

	print("# "..tostring(ee))

	sum = 0

	local clock = require 'clock'
	local start = clock.proc()
	ee:on('bench',function(ctx, arg) sum = sum + arg end)
	local cnt = 1e5
	for i = 1,cnt do
		ee:event("bench",1)
	end
	fiber.yield() -- give fiber a chance to work
	local run = clock.proc() - start
	print(string.format("# Bench: %0.4fs, %0.1f RPS, %0.3fus/call",run, cnt/run, run/cnt*1e6))
	test:is(sum,cnt,"bench")

end

fiber.yield()
collectgarbage('collect')
fiber.yield()

test:check()