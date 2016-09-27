--[[
	At present, default.lua is not used
--]]

local haPrefix = "/usr/syno/synoha"
local rsyncBinary = "/usr/bin/rsync"
local rsyncPassWordFile = haPrefix .. "/etc/confsync/rsync.pw"
local rsyncPort = "874"

local consistencyCheckInterval = 3600 -- 1 Hour
local monitorInterval = 60 -- 1min
-----
-- referenced by runner, must be global
settings = {
	logfile         = haPrefix .. "/var/log/cluster/lsyncd.log",
	logMaxEntries   = 2000,
	logMaxFiles     = 4,
	--logident        =
	--logfacility     =
	--statusFile      = haPrefix .. "/var/log/cluster/lsyncd.stat",
	--statusInterval  = 10, --Minimum seconds between two writes of a status file

	nodaemon        = false,
	pidfile         = haPrefix .. "/var/run/ha/lsyncd.pid",
	delay           = 2, -- delay time for event aggregation
	maxProcesses    = 1. -- global maximum processes
}

local rsync_errcode = {
	[  0] = "ok",		-- success
	[  1] = "drop",		-- syntax or usage error
	[  2] = "drop",		-- protocol incompatibility
	[  3] = "retry",	-- errors selecting input/output files, dirs
	[  4] = "drop",		-- requested action not supported
	[  5] = "retry",	-- error starting client-server protocol (target path do not exist)
	[  6] = "retry",	-- deamon unable to append to log-file

	[ 10] = "retry",	-- error in socket IO
	[ 11] = "retry",	-- error in file IO
	[ 12] = "retry",	-- error in rsync protocol data stream
	[ 13] = "retry",	-- error with program diagnostics
	[ 14] = "retry",	-- error in IPC code
	[ 15] = "retry",	-- sibling crashed
	[ 16] = "retry",	-- sibling terminated abnormally

	[ 19] = "retry",	-- status returned when sent SIGUSR1
	[ 20] = "retry",	-- status returned when sent SIGINT, SIGTERM, SIGHUP
	[ 21] = "retry",	-- some error returned by waitpid()
	[ 22] = "retry",	-- error allocating core memory buffers
	[ 23] = "ok",		-- partial transfers are ok, since Lsyncd has registered the event that
	[ 24] = "ok",		-- caused the transfer to be partial and will recall rsync.
	[ 25] = "drop",		--  skipped some deletes due to --max-delete

	[ 30] = "retry",	-- timeout in data send/receive
	[ 35] = "retry",	-- timeout waiting for daemon connection
	-----
	--synology error code
	[ 40] = "retry",	-- system error
	[ 41] = "retry",	-- no space on remote server
	[ 42] = "wait",		-- connection failed, Fix BUG #1309
	[ 43] = "wait",		-- rsync service is no running
	[ 44] = "drop",		-- wrong password
	[ 45] = "drop",		-- file path too long
	[ 46] = "drop",		-- file path too long
	[ 47] = "drop",		-- the system can't find the netbackup module in the remote machine
	[ 48] = "drop",		-- the remote machine doesn't support the option
	[ 49] = "drop",		-- remote machine has not supported ssh or ssh service hasn't been enable
	[ 50] = "drop",		-- IP is denied by remote machine
	[ 51] = "drop",		-- Unrecongized customized command
	[ 52] = "drop",		-- service of user is disabled
	[ 53] = "drop",		-- user don't have permision to the share
	[ 54] = "drop",		-- user quota is exceeded
	[255] = "retry",	-- command failed
}

local systemSync = {
	maxProcesses = 1, -- Must be 1 for simplify to implement retry/wait machanise
	maxDelays = 5000, -- this is not hard constriant
	delay = 10,	 -- overrided by settings.delay
	retryDelay = 5,

	retryCount = 0,
	retryCountMax = 5,
	fullsync = false,
	startUpFullSync = true, -- lsyncd.lua will inserts an init event when create sync
	haveCheckEvent = false
}

----
-- This table is used for manipulate/coordinate syncs.
synoSyncs = {
	supressInconsistencyNotify = false,
	waitCount = 0,
	waitCountMax = 720, --log every 1 hour,  retryDelay * 720 = 1hour
	waitRemote = false,

	remoteRsyncOnline = true,
	startUpFullSync = true, -- set to false when all syncs' start up full sync is done.
	abondonedLog = true,
	abondonedMax = 5000,
	abondonedEnable = true,
	abondonedEvents = {}
}

-----
-- helper function for synoSyncs.getStatus
local function getStatusString(condition, str)
	local s

	if condition then
		s = str .. ":true\n"
	else
		s = str .. ":false\n"
	end
	return s
end

function synoSyncs.getStatus()
	local report = ""
	local fullsync = false
	local nr = 0

	for _, s in ipairs(synoSyncs) do
		if s.config.startUpFullSync then
			fullsync = true
		end
	end

	report = report .. getStatusString(fullsync, "fullsync")
	report = report .. getStatusString(#lsyncdSyncErrs ~=0, "error")
	report = report .. getStatusString(synoSyncs.waitRemote, "wait")
	report = report .. getStatusString(#synoSyncs.abondonedEvents ~=0, "abondone")
	nr = 4

	for _, l in ipairs(lsyncdSyncErrs) do
		report = report .. "error desc:" .. l .. "\n"
		nr = nr + 1
	end

	report = tostring(nr) .. "\n" .. report
	return report
end

function synoSyncs.getEvents()
	local report = ""
	local nr = 0
	local syncPath = ""

	for _, s in ipairs(synoSyncs) do
		syncPath = string.match(s.source, "(.*)/$")
		for _, d in Queue.qpairs(s.delays) do
			report = report .. d.etype .. ":" .. syncPath .. d.path .. "\n"
			nr = nr + 1
		end
	end
	report = tostring(nr) .. "\n" .. report
	return report
end

function synoSyncs.getAbondonedEvents()
	local report = ""
	local nr = 0

	if synoSyncs.abondonedEnable then
		for _, event in ipairs(synoSyncs.abondonedEvents) do
			report = report .. event.etype .. ":" .. event.path .. "\n"
			nr = nr + 1
		end
	end
	report = tostring(nr) .. "\n" .. report
	return report
end

function synoSyncs.checkConsistency()
	synoSyncs.supressInconsistencyNotify = false
	for _, s in ipairs(synoSyncs) do
		s.addCheckDelay(s)
	end
	return true
end


function synoSyncs.clrAbondonedEvents()
	synoSyncs.abondonedEvents = {}
end


-----
-- init function is called by Sync.invokeActions
function systemSync.init(event)
	local config = event.config
	local excludes = event.inlet.getExcludes()

	-----
	-- spawn will mark event.status as 'active'
	if #excludes == 0 then
		spawn(event, rsyncBinary,
		      "-sac", "--port=" .. rsyncPort, "--delete", "--password-file=" .. rsyncPassWordFile,
		      config.source, config.target)
	else
		local exS = table.concat(excludes, "\n")
		spawn(event, rsyncBinary, "<", exS, "--exclude-from=-",
		      "-sac", "--port=" .. rsyncPort, "--delete", "--password-file=" .. rsyncPassWordFile,
		      config.source, config.target)
	end
end

-----
-- Check consistency
function systemSync.check(delay)
	local sync = delay.sync
	local config = sync.config
	local msg = ""
	local cmd = rsyncBinary .. " -i --dry-run -sac --port=" .. rsyncPort .. " --delete --password-file=" .. rsyncPassWordFile
	            .. " --exclude-from=" .. config.excludeFrom .. " " .. config.source .. " "  .. config.target
                .. " 2>/dev/null"

	-- TODO , popen error handling
	-- If we use popen, there have no way to get return code, unless we upgrade to Lua 5.2
	local f = io.popen(cmd)
	if not f then
		log("Warn", "Failed to do consistency check:\n", cmd)
		sync.removeDelay(sync, delay)
		config.haveCheckEvent = false
		return
	end

	local consistency = true
	local notify = false
	for line in f:lines() do
		-- filter out items that will not sync
		-- please refer itemize-changes in rsync manual
		if not string.match(line, "^skipping.*") and not string.match(line, "^%..*") then
			msg = msg .. line .. "\n"
			consistency = false
			if string.find(line, "%s") and not notify then
				local str = config.source .. string.sub(line, string.find(line, "%s")+1, -1)
				if lsyncd.check_modify(str, consistencyCheckInterval) == 1 then
					notify = true
				end
			end

		end
	end
	f:close()

	sync.removeDelay(sync, delay)
	config.haveCheckEvent = false

	if notify and not synoSyncs.supressInconsistencyNotify then
		-- notify conf sync error
		synoSyncs.supressInconsistencyNotify = true
		cmd = "/bin/logger -p warn 'Unsynchronized system configurations were detected. The system attempted to fix the errors by performing a full synchronization.'"
		local notifications = io.popen(cmd)
		notifications:close(); notifications=nil;
	end

	if not consistency then
		log("Warn", "Configuration Inconsistency:\n", msg)
		sync.addInitDelay(sync)
	end
end

-----
-- action function was called by Sync.invokeActions
function systemSync.action(inlet)
	local config = inlet.getConfig()
	local elist = inlet.getEvents(
		function(event)
			return event.etype ~= "Init" and event.etype ~= "Blanket" and event.etype ~= "Check"
		end
	)

	local paths = elist.getPaths(
		function(etype, path1, path2)
			if etype == "Delete" and string.byte(path1, -1) == 47 then
				return path1 .. "***", path2
			else
				return path1, path2
			end
		end)

	local filterI = {}
	local filterP = {}

	local function addToFilter(path)
		if filterP[path] then
			return
		end
		filterP[path]=true
		table.insert(filterI, path)
	end

	-- adds a path to the filter, for rsync this needs
	-- to have entries for all steps in the path, so the file
	-- d1/d2/d3/f1 needs filters
	-- "d1/", "d1/d2/", "d1/d2/d3/" and "d1/d2/d3/f1"
	for _, path in ipairs(paths) do
		if path and path ~="" then
			-- path = string.match(config.source,"(.*)/+") .. path -- for relative path
			addToFilter(path)
			local pp = string.match(path, "^(.*/)[^/]+/?")
			while pp do
				addToFilter(pp)
				pp = string.match(pp, "^(.*/)[^/]+/?")
			end
		end
	end

	local filterS = table.concat(filterI, "\n")
	log("Warn","Calling rsync with filter-list of new/modified files/dirs\n",filterS)

	spawn(elist, rsyncBinary,"<", filterS,
		"-sac", "--port=" .. rsyncPort, "--delete", "--password-file=" .. rsyncPassWordFile,
		"--include-from=-", "--exclude=*",
		config.source, config.target)
end

-----
-- override sync.collect
function systemSync.prepare1(s)
	-- collect dispatcher
	local function sync_collect(self, pid, exitcode)
		local delayOrList= self.processes[pid]
			if not delayOrList then return end

		if delayOrList.status then
			self.config.collectDelay(self, delayOrList, exitcode)
		else
			self.config.collectList(self, delayOrList, exitcode)
		end
		self.processes[pid] = nil
	end
	table.insert(synoSyncs, s) -- synoSyncs[1] = sync1, synoSyncs[2] = sync2 ...

	s.collect = sync_collect
end


local function getReport(delay)
	local report = {}
	table.insert(report, "Abandoned events:")

	if delay.status then -- event list
		table.insert(report, delay.etype .. "\t" .. delay.path)
	else
		for _, d in ipairs(delay) do
			table.insert(report, d.etype .. "\t" .. d.path)
		end
	end
	report = table.concat(report, "\n")
	return report
end


-----
-- TODO do not add duplicate event
-- TODO add abondoned time !?
local function AbondonedEventAdd(sync, delay)
	local syncPath = string.match(sync.source, "(.*)/$")
	if delay.status then -- full sync
		if #synoSyncs.abondonedEvents >= synoSyncs.abondonedMax then
			table.remove(synoSyncs.abondonedEvents, 1)
		end
		table.insert(synoSyncs.abondonedEvents,
			{ etype = delay.etype, path = syncPath .. delay.path })
	else
		for _, d in ipairs(delay) do
			if #synoSyncs.abondonedEvents >= synoSyncs.abondonedMax then
				table.remove(synoSyncs.abondonedEvents, 1)
			end
			table.insert(synoSyncs.abondonedEvents,
				{ etype = d.etype, path = syncPath .. d.path })
		end
	end
end


local function ProcessRsyncErrCode(sync, delayOrList, exitcode)
	local config = sync.config
	local rc = rsync_errcode[exitcode]
	local removeEvent = false
	local abondonedEvent = false

	if rc == 'ok' then
		if synoSyncs.waitRemote then
			synoSyncs.waitRemote = false
			synoSyncs.waitCount = 0
			log("Warn", "remote rsync daemon is ready")
		end
		removeEvent = true
	elseif rc == 'retry' then
		config.retryCount = config.retryCount + 1
		if config.retryCount >= config.retryCountMax then
			local report = getReport(delayOrList)
			removeEvent = true
			abondonedEvent = true
			if synoSyncs.abondonedLog then
				log("Warn", config.name, ": abandon retry, exitcode=", exitcode, "\n", report)
			else
				log("Warn", config.name, ": abandon retry, exitcode=", exitcode, "\n")
			end
		end
	elseif rc == 'wait' then
		if not synoSyncs.waitRemote then
			synoSyncs.waitRemote = true
			log("Warn", "waiting for remote rsync daemon ready")
		else
			synoSyncs.waitCount = synoSyncs.waitCount + 1
		end
		if synoSyncs.waitCount >= synoSyncs.waitCountMax then
			synoSyncs.waitCount = 0
			log("Warn", "waiting for remote rsync daemon ready")
		end
	else -- error code==drop or unknow
		local report = getReport(delayOrList)
		removeEvent = true
		abondonedEvent = true
		if synoSyncs.abondonedLog then
			log("Warn", config.name, ": rsync critical error, exitcode=", exitcode, "\n", report)
		else
			log("Warn", config.name, ": rsync critical error, exitcode=", exitcode, "\n")
		end
	end

	if removeEvent then
		config.retryCount = 0
		config.waitCount = 0
		if synoSyncs.abondonedEnable then
			if abondonedEvent then
				AbondonedEventAdd(sync, delayOrList)
			else
				--TODO remove abondoned event , when event is ok ??
			end
		end
	end

	-----
	-- postpone other syncs
	if synoSyncs.waitRemote then
		local alarm = now() + config.retryDelay
		for _, s in ipairs(synoSyncs) do
			if s == sync then
			elseif s.delays.size ~= 0 then
				if s.delays[s.delays.first].status == 'wait' then
					s.delays[s.delays.first].alarm = alarm
				end
			end
		end
	end

	return removeEvent
end

----
local function ConsistencyChecker()
	synoSyncs.checkConsistency()
	alarm( now()+consistencyCheckInterval, ConsistencyChecker)
end

-----
local function RemoteMonitor()
	local cmd = rsyncBinary .. " --dry-run -sac --port=" .. rsyncPort .. " --password-file=" .. rsyncPassWordFile
	            .. " --exclude=* " .. synoSyncs[1].config.source .. " " .. synoSyncs[1].config.target
	            .. " 2>&1"
	local online = true
	local errmsg = "rsync error: rsync service is no running"

	local f = io.popen(cmd)

	if f ~= nil then
		for line in f:lines() do
			if string.starts(line, errmsg) then
				online = false
			end
		end
		f:close()
		if online ~= synoSyncs.remoteRsyncOnline then
			synoSyncs.remoteRsyncOnline = online
			if online == true then
				log("Warn", "remote rsync online, send check event")
				synoSyncs.checkConsistency()
			end
		end
	end
	alarm( now()+monitorInterval, RemoteMonitor)
end

-----
--
function systemSync.collectList(sync, dlist, exitcode)
	local removeEvent = ProcessRsyncErrCode(sync, dlist, exitcode)

	if removeEvent then
		for _, d in ipairs(dlist) do
			if sync.source == "/etc/" and d.path == "/synoinfo.conf" then
				local cmd = "/usr/syno/synoha/sbin/synoha --synoinfo-change &"
				os.execute(cmd)
			end
			sync.removeDelay(sync, d)
		end
	else
		local alarm = now() + sync.config.retryDelay
		for _, d in ipairs(dlist) do
			d.alarm = alarm
			d.status = 'wait'
		end
	end
end

-----
--
function systemSync.collectDelay(sync, delay, exitcode)
	local removeEvent = ProcessRsyncErrCode(sync, delay, exitcode)
	local fullsync = false

	if not removeEvent then
		delay.status = 'wait' -- set delay status from active -> wait
		delay.alarm = now() + sync.config.retryDelay
		return
	end

	if delay.etype == 'Init' then
		sync.config.startUpFullSync = false
		sync.config.fullsync = false

		if synoSyncs.startUpFullSync == true then
			synoSyncs.startUpFullSync = false

			for _, s in ipairs(synoSyncs) do
				if s.config.startUpFullSync then
					synoSyncs.startUpFullSync = true
				end
			end
			if synoSyncs.startUpFullSync == false then
				-- start check configuration regularly
				alarm( now()+consistencyCheckInterval, ConsistencyChecker)
				alarm( now()+monitorInterval, RemoteMonitor)
				synoSyncs.remoteRsyncOnline = true
			end
		end
	end
	sync.removeDelay(sync, delay)
end


local f = assert(io.popen(haPrefix .. "/sbin/synoha --remote-drbdip", "r"))
local remote_address = assert(f:read("*l"))
if remote_address == "" then
	table.insert(earlyLogs, 'Unknown remote address')
	table.insert(lsyncdSyncErrs, 'Unknown remote address')
end
f:close(); f=nil;

local remote_target = "root@" .. remote_address .. "::synoha_root"

-----
-- sync is a function
sync {systemSync, source="/etc/", target=remote_target .. "/etc",
	excludeFrom=haPrefix .. "/etc.defaults/confsync/etc.filter"}
sync {systemSync, source="/etc.defaults/", target=remote_target .. "/etc.defaults",
	excludeFrom=haPrefix .. "/etc.defaults/confsync/etc.defaults.filter"}
sync {systemSync, source="/usr/", target=remote_target .. "/usr",
	excludeFrom=haPrefix .. "/etc.defaults/confsync/usr.filter"}
sync {systemSync, source="/var/", target=remote_target .. "/var",
	excludeFrom=haPrefix .. "/etc.defaults/confsync/var.filter"}
sync {systemSync, source="/tmp/", target=remote_target .. "/tmp",
	excludeFrom=haPrefix .. "/etc.defaults/confsync/tmp.filter"}
