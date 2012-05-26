local ffi = require "ffi"
local bit = require "bit"
require "common"

require "include.stdio"
require "include.strings"
require "include.sys.signalfd"
require "include.sys.timerfd"
local time = require "include.time"
local epoll_lib = require "include.epoll"

local sigfds_to_epoll_obs = setmetatable ( { } , { __mode = "kv" } )
local signal_cb_table = {
	read = function ( fd )
		local self = sigfds_to_epoll_obs [ fd ]

		local info = ffi.new ( "struct signalfd_siginfo[1]" )
		local r = ffi.C.read ( fd.fd , info , ffi.sizeof ( info ) )
		if r == -1 then
			error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
		end
		assert ( r == ffi.sizeof ( info ) )

		local signum = info[0].ssi_signo
		local id = info[0].ssi_int
		local cb = self.sigcbs [ signum ] [ id ]
		cb ( info )
	end
}
local epoll_methods = { }
local epoll_mt = {
	__index = epoll_methods ;
}

local function new_epoll ( guesstimate )
	guesstimate = guesstimate or 10
	local epfd = ffi.C.epoll_create ( guesstimate )
	if epfd == -1 then
		error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
	end
	epfd = ffi.new ( "fd_t" , epfd )

	local mask = ffi.new ( "sigset_t[1]" )
	ffi.C.sigemptyset ( mask )
	local sigfd = ffi.C.signalfd ( -1 , mask , 0 )
	if sigfd == -1 then
		error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
	end
	sigfd = ffi.new ( "fd_t" , sigfd )

	local self = setmetatable ( {
			epfd = epfd ;
			-- Signal handling stuff
			sigfd = sigfd ;
			sigmask = mask ;
			sigcbs = { } ;

			-- Holds registered file descriptors, has maps to each one's callbacks
			registered = { } ;
		} , epoll_mt )
	sigfds_to_epoll_obs [ sigfd ] = self

	self:add_fd ( sigfd , signal_cb_table )

	return self
end

-- cbs is a table of callbacks: read,write
function epoll_methods:add_fd ( fd , cbs )
	local op
	if self.registered [ fd ] then
		op = epoll_lib.EPOLL_CTL_MOD
	else
		op = epoll_lib.EPOLL_CTL_ADD
	end

	local __events = ffi.new ( "struct epoll_event[1]" )
	__events[0].events = bit.bor (
		cbs.read and ffi.C.EPOLLIN or 0 ,
		cbs.write and ffi.C.EPOLLOUT or 0 ,
		cbs.oneshot and ffi.C.EPOLLONESHOT or 0 )
	__events[0].data.fd = fd.fd

	if ffi.C.epoll_ctl ( self.epfd.fd , op , fd.fd , __events ) ~= 0 then
		error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
	end
	self.registered [ fd ] = cbs
	self.registered [ fd.fd ] = fd
	return true
end

function epoll_methods:del_fd ( fd )
	if ffi.C.epoll_ctl ( self.epfd.fd , epoll_lib.EPOLL_CTL_DEL , fd.fd , nil ) ~= 0 then
		error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
	end
	self.registered [ fd ] = nil
	self.registered [ fd.fd ] = nil
	return true
end

local wait_size = 0
local wait_events -- One big shared array...
function epoll_methods:dispatch ( max_events , timeout )
	if max_events == nil then
		max_events = wait_size
	elseif max_events > wait_size then -- Expand the array
		wait_events = ffi.new ( "struct epoll_event[?]" , max_events )
		wait_size = max_events
	end
	if timeout then
		timeout = timeout * 1000
	else
		timeout = -1
	end
	local n = ffi.C.epoll_wait ( self.epfd.fd , wait_events , max_events , timeout )
	if n == -1 then
		error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
	end
	for i=1,n do
		local events = wait_events[i-1].events
		local fd = wait_events[i-1].data.fd
		fd = self.registered [ fd ]
		local cbs = self.registered [ fd ]
		if cbs.oneshot then
			if ffi.C.epoll_ctl ( self.epfd.fd , epoll_lib.EPOLL_CTL_DEL , fd.fd , nil ) ~= 0 then
				cbs.error ( fd , ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
			end
			self.registered [ fd ] = nil
			self.registered [ fd.fd ] = nil
		end
		if cbs.read and bit.band ( events , ffi.C.EPOLLIN ) ~= 0 then
			cbs.read ( fd )
		end
		if cbs.write and bit.band ( events , ffi.C.EPOLLOUT ) ~= 0 then
			cbs.write ( fd )
		end
		if cbs.error and bit.band ( events , ffi.C.EPOLLERR ) ~= 0 then
			cbs.error ( fd )
		end
		if cbs.close and bit.band ( events , ffi.C.EPOLLHUP ) ~= 0 then
			cbs.close ( fd )
		end
	end
end

--[[function watch_signal ( signum , cb )
	local action = ffi.new ( "struct sigaction" )
	action.__sigaction_handler.sa_sigaction = function ( signum , info , content )
		print("SIGNAL",signum,info,content)
	end
	--action.sa_mask
	action.sa_flags = signal.SA_SIGINFO
	ffi.C.sigaction ( signum , action , nil )
end--]]

function epoll_methods:add_signal ( signum , id , cb )
	local cbs = self.sigcbs [ signum ]
	if cbs then
		cbs [ id ] = cb
	else
		cbs = { [ id ] = cb }
		self.sigcbs [ signum ] = cbs

		ffi.C.sigaddset ( self.sigmask , signum )
		if ffi.C.signalfd ( self.sigfd.fd , self.sigmask , 0 ) == -1 then
			error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
		end
	end
end

local timerspec = ffi.new ( "struct itimerspec[1]" )
local timer_mt = {
	__index = {
		set = function ( timer , value , interval , flags )
			flags = flags or 0
			interval = interval or 0
			timerspec[0].it_interval.tv_sec = math.floor ( interval )
			timerspec[0].it_interval.tv_nsec = ( interval % 1 )*1e9
			timerspec[0].it_value.tv_sec = math.floor ( value )
			timerspec[0].it_value.tv_nsec = ( value % 1 )*1e9
			if ffi.C.timerfd_settime ( timer.fd.fd , flags , timerspec , nil ) == -1 then
				error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
			end
		end ;
		disarm = function ( timer )
			timer:set ( 0 , 0 )
		end ;
		status = function ( timer )
			if ffi.C.timerfd_gettime ( timer.fd.fd , timerspec ) == -1 then
				error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
			end
			return tonumber ( timerspec[0].it_value.tv_sec ) + tonumber ( timerspec[0].it_value.tv_nsec ) / 1e9 ,
				tonumber ( timerspec[0].it_interval.tv_sec ) + tonumber ( timerspec[0].it_interval.tv_nsec ) / 1e9
		end ;
	} ;
}
-- Return values from callback change the period
function epoll_methods:add_timer ( start , interval , cb )
	local timerfd = ffi.C.timerfd_create ( time.CLOCK_MONOTONIC , bit.bor ( ffi.C.TFD_NONBLOCK ) )
	if timerfd == -1 then
		error ( ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
	end
	timerfd = ffi.new ( "fd_t" , timerfd )
	local timer = setmetatable ( { fd = timerfd } , timer_mt )

	self:add_fd ( timerfd , {
		read = function ( fd )
			local expired = ffi.new ( "uint64_t[1]" )
			local c = ffi.C.read ( fd.fd , expired , ffi.sizeof ( expired ) )
			if c == -1 then
				cb ( nil , ffi.string ( ffi.C.strerror ( ffi.errno ( ) ) ) )
			end
			--assert ( c == ffi.sizeof ( expired ) )
			start , interval = cb ( timer , expired[0] )
			if start then
				timer:set ( start , interval )
			end
		end ;
	} )
	timer:set ( start , interval )

	return timer
end

function epoll_methods:del_signal ( signum )
	local fd = sigfds [ signum ]
	epoll_methods:del_fd ( fd )
	ffi.C.sigdelset ( self.sigmask , signum )
	sigfds [ signum ] = nil
end

return new_epoll