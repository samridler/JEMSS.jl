##########################################################################
# Copyright 2017 Samuel Ridler.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################

# run simulation

"""
	function simulate!(sim::Simulation;
		time::Float = Inf, duration::Float = Inf, numEvents::Int = -1,
		doPrint::Bool = false, printingInterval::Float = 1.0)
Run the simulation to completion, or to any specified stopping point (according to `time`, `duration`, or `numEvents`), whichever comes first. Returns `true` if simulation is complete; `false` otherwise.

# Keyword arguments
- `time` is the maximum time to simulate to; will stop if time of next event is greater
- `duration` is the maximum duration to simulate for; equivalent to setting `time = sim.time + duration`
- `numEvents` is the maximum number of events to simulate
- `doPrint` controls whether any lines are printed while simulating
- `printingInterval` is the time interval (seconds) between printing while simulating, if `doPrint = true`
"""
function simulate!(sim::Simulation;
	time::Real = Inf, duration::Real = Inf, numEvents::Real = Inf,
	doPrint::Bool = false, printingInterval::Real = 1.0)
	
	@assert(time == Inf || duration == Inf, "can only set one of: time, duration")
	@assert(time >= sim.time)
	@assert(duration >= 0)
	@assert(numEvents >= 0)
	@assert(printingInterval >= 1e-2, "printing too often can slow the simulation")
	
	duration != Inf && (time = sim.time + duration) # set end time based on duration
	
	# for printing progress
	startTime = Base.time()
	doPrint || (printingInterval = Inf)
	nextPrintTime = startTime + printingInterval
	eventCount = 0
	printProgress() = doPrint && print(@sprintf("\rsim time: %-9.2f sim duration: %-9.2f events simulated: %-9d real duration: %.2f seconds", sim.time, sim.time - sim.startTime, eventCount, Base.time() - startTime))
	
	# simulate
	stats = sim.stats # shorthand
	while !sim.complete && sim.eventList[end].time <= time && eventCount < numEvents
		if stats.doCapture && stats.nextCaptureTime <= sim.eventList[end].time
			captureSimStats!(sim, stats.nextCaptureTime)
		end
		
		simulateNextEvent!(sim)
		eventCount += 1
		
		if doPrint && Base.time() >= nextPrintTime
			printProgress()
			nextPrintTime += printingInterval
		end
	end
	
	printProgress()
	doPrint && println()
	
	if stats.doCapture && sim.complete
		captureSimStats!(sim, sim.endTime)
		populateSimStats!(sim)
	end
	
	return sim.complete
end

# simulate up to last event with time <= given time
# similar to calling simulate!(sim, time = time), but does not record statistics
# kept this for animation, to avoid problems with animating as an asynchronous task
function simulateToTime!(sim::Simulation, time::Float)
	while !sim.complete && sim.eventList[end].time <= time # eventList must remain sorted by non-increasing time
		simulateNextEvent!(sim)
	end
end

# run simulation to end
# similar to calling simulate!(sim), but does not record statistics
function simulateToEnd!(sim::Simulation)
	while !sim.complete
		simulateNextEvent!(sim)
	end
end

# set sim.backup to copy of sim (before running)
# note that for reducing memory usage, sim.backup does not contain backups of all fields
function backup!(sim::Simulation)
	@assert(!sim.used)
	
	# remove certain fields from sim before copying sim
	(net, travel, grid, resim, demand, demandCoverage) = (sim.net, sim.travel, sim.grid, sim.resim, sim.demand, sim.demandCoverage)
	(sim.net, sim.travel, sim.grid, sim.resim, sim.demand, sim.demandCoverage) = (Network(), Travel(), Grid(), Resimulation(), Demand(), DemandCoverage())
	
	sim.backup = deepcopy(sim)
	
	(sim.net, sim.travel, sim.grid, sim.resim, sim.demand, sim.demandCoverage) = (net, travel, grid, resim, demand, demandCoverage)
end
backupSim!(sim::Simulation) = backup!(sim) # compat

# reset sim from sim.backup
function reset!(sim::Simulation)
	@assert(!sim.backup.used)
	
	if sim.used
		resetCalls!(sim) # reset calls from sim.backup, need to do this before resetting sim.time
		
		fnames = Set(fieldnames(Simulation))
		fnamesDontCopy = Set([:backup, :net, :travel, :grid, :resim, :calls, :demand, :demandCoverage, :animating]) # will not (yet) copy these fields from sim.backup to sim
		# note that sim.backup does not contain a backup of all fields
		setdiff!(fnames, fnamesDontCopy) # remove fnamesDontCopy from fnames
		for fname in fnames
			try
				setfield!(sim, fname, deepcopy(getfield(sim.backup, fname)))
			catch e
				error(e)
			end
		end
		
		# reset resimulation state
		sim.resim.prevEventIndex = 0
		
		# reset travel and demand state
		sim.travel.recentSetsStartTimesIndex = 1
		sim.demand.recentSetsStartTimesIndex = 1
	end
end
resetSim!(sim::Simulation) = reset!(sim) # compat

# simulate next event in list
function simulateNextEvent!(sim::Simulation)
	# get next event, update event index and sim time
	event = getNextEvent!(sim.eventList)
	if event.form == nullEvent
		error()
	end
	sim.used = true
	sim.eventIndex += 1
	event.index = sim.eventIndex
	sim.time = event.time
	
	if sim.resim.use
		resimCheckCurrentEvent!(sim, event)
	elseif sim.writeOutput
		writeEventToFile!(sim, event)
	end
	
	simulateEvent!(sim, event)
	
	if length(sim.eventList) == 0
		# simulation complete
		@assert(sim.endTime == nullTime)
		@assert(sim.complete == false)
		sim.endTime = sim.time
		sim.complete = true
	end
end

# simulate event
function simulateEvent!(sim::Simulation, event::Event)
	# format:
	# next event may change relevant ambulance / call fields at event.time
	# event may then trigger future events / cancel scheduled events
	
	@assert(sim.time == event.time)
	
	eventForm = event.form
	if eventForm == nullEvent
		error("null event")
		
################
	
	elseif eventForm == ambGoesToSleep
		ambulance = sim.ambulances[event.ambIndex]
		@assert(ambulance.status == ambIdleAtStation) # ambulance should be at station before sleeping
		@assert(event.callIndex == nullIndex)
		
		setAmbStatus!(sim, ambulance, ambSleeping, sim.time)
		
		station = sim.stations[ambulance.stationIndex]
		updateStationStats!(station; numIdleAmbsChange = -1, time = sim.time)
		
		addEvent!(sim.eventList; parentEvent = event, form = ambWakesUp, time = sim.time + sleepDuration, ambulance = ambulance, station = station)
		
################
	
	elseif eventForm == ambWakesUp
		ambulance = sim.ambulances[event.ambIndex]
		@assert(ambulance.status == ambSleeping) # ambulance should have been sleeping
		@assert(event.callIndex == nullIndex)
		
		setAmbStatus!(sim, ambulance, ambIdleAtStation, sim.time)
		ambulance.event = Event() # no event currently
		
		updateStationStats!(sim.stations[ambulance.stationIndex]; numIdleAmbsChange = +1, time = sim.time)
		
################
	
	elseif eventForm == callArrives
		@assert(event.ambIndex == nullIndex) # no ambulance should be assigned yet
		call = sim.calls[event.callIndex]
		@assert(call.status == callNullStatus)
		
		push!(sim.currentCalls, sim.calls[event.callIndex])
		setCallStatus!(call, callScreening, sim.time)
		
		addEvent!(sim.eventList; parentEvent = event, form = considerDispatch, time = sim.time + call.dispatchDelay, call = call)
		
		# add next call arrival to event queue
		if call.index < sim.numCalls
			addEvent!(sim.eventList, sim.calls[call.index + 1])
		end
		
################
	
	elseif eventForm == considerDispatch
		@assert(event.ambIndex == nullIndex) # no ambulance should be assigned yet
		call = sim.calls[event.callIndex]
		@assert(call.status == callScreening || call.status == callWaitingForAmb) # callWaitingForAmb if call bumped
		
		# find ambulance to respond
		if sim.resim.use
			ambIndex = resimFindAmbToDispatch(sim, call)
		else
			ambIndex = sim.findAmbToDispatch!(sim, call)
		end
		# if no ambulance found, add call to queue,
		# will respond when an ambulance becomes free
		if ambIndex == nullIndex
			sim.addCallToQueue!(sim.queuedCallList, call)
			setCallStatus!(call, callQueued, sim.time)
		else
			ambulance = sim.ambulances[ambIndex]
			
			# remove any previously scheduled events
			if isGoingToStation(ambulance.status)
				deleteEvent!(sim.eventList, ambulance.event)
			elseif ambulance.status == ambGoingToCall
				# if ambulance was going to call, redirect ambulance
				deleteEvent!(sim.eventList, ambulance.event)
				
				# bumped call has no ambulance assigned yet
				bumpedCall = sim.calls[ambulance.callIndex]
				bumpedCall.ambIndex = nullIndex
				bumpedCall.numBumps += 1 # stats
				
				# consider new dispatch for bumped call
				addEvent!(sim.eventList; parentEvent = event, form = considerDispatch, time = sim.time, call = bumpedCall)
			end
			
			# dispatch chosen ambulance
			addEvent!(sim.eventList; parentEvent = event, form = ambDispatched, time = sim.time, ambulance = ambulance, call = call)
		end
		
################
	
	elseif eventForm == ambDispatched
		ambulance = sim.ambulances[event.ambIndex]
		status = ambulance.status # shorthand
		@assert(isFree(status) || status == ambGoingToCall)
		call = sim.calls[event.callIndex]
		@assert(call.status == callScreening || call.status == callQueued || call.status == callWaitingForAmb) # callWaitingForAmb if call bumped
		
		setAmbStatus!(sim, ambulance, ambGoingToCall, sim.time)
		ambulance.callIndex = call.index
		changeRoute!(sim, ambulance.route, sim.responseTravelPriorities[call.priority], sim.time, call.location, call.nearestNodeIndex)
		
		setCallStatus!(call, callWaitingForAmb, sim.time)
		call.ambIndex = event.ambIndex
		call.ambDispatchLoc = ambulance.route.startLoc # same result as getRouteCurrentLocation!(sim.net, ambulance.route, sim.time)
		call.ambStatusBeforeDispatch = ambulance.prevStatus
		
		if ambulance.prevStatus == ambIdleAtStation
			updateStationStats!(sim.stations[ambulance.stationIndex]; numIdleAmbsChange = -1, time = sim.time)
		end
		
		addEvent!(sim.eventList; parentEvent = event, form = ambReachesCall, time = ambulance.route.endTime, ambulance = ambulance, call = call)
		
		if sim.moveUpData.useMoveUp
			m = sim.moveUpData.moveUpModule # shorthand
			if m == compTableModule || m == ddsmModule || m == zhangIpModule || m == temp0Module || m == temp1Module || m == temp2Module
				addEvent!(sim.eventList; parentEvent = event, form = considerMoveUp, time = sim.time, ambulance = ambulance, addEventToAmb = false)
			end
		end
		
################
	
	elseif eventForm == ambReachesCall
		ambulance = sim.ambulances[event.ambIndex]
		@assert(ambulance.status == ambGoingToCall)
		call = sim.calls[event.callIndex]
		@assert(call.status == callWaitingForAmb)
		
		setAmbStatus!(sim, ambulance, ambAtCall, sim.time)
		
		setCallStatus!(call, callOnSceneTreatment, sim.time)
		
		# transport call to hospital if needed, otherwise amb becomes free
		if call.transport
			# transport to hospital
			addEvent!(sim.eventList; parentEvent = event, form = ambGoesToHospital, time = sim.time + call.onSceneDuration, ambulance = ambulance, call = call)
		else
			# amb becomes free
			addEvent!(sim.eventList; parentEvent = event, form = ambBecomesFree, time = sim.time + call.onSceneDuration, ambulance = ambulance, call = call)
		end
		
################
	
	elseif eventForm == ambGoesToHospital
		ambulance = sim.ambulances[event.ambIndex]
		@assert(ambulance.status == ambAtCall)
		call = sim.calls[event.callIndex]
		@assert(call.status == callOnSceneTreatment)
		@assert(call.transport)
		
		# if hospital not specified for call, find closest hospital
		hospitalIndex = call.hospitalIndex
		if hospitalIndex == nullIndex
			hospitalIndex = nearestHospitalToCall!(sim, call, lowPriority)
		end
		@assert(hospitalIndex != nullIndex)
		hospital = sim.hospitals[hospitalIndex]
		
		setAmbStatus!(sim, ambulance, ambGoingToHospital, sim.time)
		changeRoute!(sim, ambulance.route, lowPriority, sim.time, hospital.location, hospital.nearestNodeIndex)
		
		setCallStatus!(call, callGoingToHospital, sim.time)
		call.hospitalIndex = hospitalIndex
		
		addEvent!(sim.eventList; parentEvent = event, form = ambReachesHospital, time = ambulance.route.endTime, ambulance = ambulance, call = call)
		
################
	
	elseif eventForm == ambReachesHospital
		ambulance = sim.ambulances[event.ambIndex]
		@assert(ambulance.status == ambGoingToHospital)
		call = sim.calls[event.callIndex]
		@assert(call.status == callGoingToHospital)
		@assert(call.transport)
		
		setAmbStatus!(sim, ambulance, ambAtHospital, sim.time)
		
		setCallStatus!(call, callAtHospital, sim.time)
		sim.hospitals[call.hospitalIndex].numCalls += 1 # stats
		
		addEvent!(sim.eventList; parentEvent = event, form = ambBecomesFree, time = sim.time + call.handoverDuration, ambulance = ambulance, call = call)
		
################
	
	elseif eventForm == ambBecomesFree
		ambulance = sim.ambulances[event.ambIndex]
		@assert(ambulance.status == ambAtCall || ambulance.status == ambAtHospital)
		call = sim.calls[event.callIndex]
		@assert(call.status == callOnSceneTreatment || call.status == callAtHospital)
		
		# remove call, processing is finished
		delete!(sim.currentCalls, call)
		setCallStatus!(call, callProcessed, sim.time)
		
		setAmbStatus!(sim, ambulance, ambFreeAfterCall, sim.time)
		ambulance.callIndex = nullIndex
		
		# if queued call exists, respond
		# otherwise return to station
		if length(sim.queuedCallList) > 0
			call = getNextCall!(sim.queuedCallList)
			@assert(call != nothing)
			
			# dispatch ambulance
			addEvent!(sim.eventList; parentEvent = event, form = ambDispatched, time = sim.time, ambulance = ambulance, call = call)
		else
			# return to station (can be cancelled by move up)
			addEvent!(sim.eventList; parentEvent = event, form = ambReturnsToStation, time = sim.time, ambulance = ambulance, station = sim.stations[ambulance.stationIndex])
			
			# consider move up
			# note that this event is created after above ambReturnsToStation event, so that it will happen first and can delete the ambReturnsToStation event if needed
			if sim.moveUpData.useMoveUp
				m = sim.moveUpData.moveUpModule # shorthand
				if m == compTableModule || m == dmexclpModule || m == priorityListModule || m == zhangIpModule || m == temp0Module || m == temp1Module || m == temp2Module
					addEvent!(sim.eventList; parentEvent = event, form = considerMoveUp, time = sim.time, ambulance = ambulance, addEventToAmb = false)
				end
			end
		end
		
################
	
	elseif eventForm == ambReturnsToStation
		ambulance = sim.ambulances[event.ambIndex]
		@assert(ambulance.status == ambFreeAfterCall)
		@assert(event.callIndex == nullIndex)
		
		setAmbStatus!(sim, ambulance, ambReturningToStation, sim.time)
		station = sim.stations[ambulance.stationIndex]
		changeRoute!(sim, ambulance.route, lowPriority, sim.time, station.location, station.nearestNodeIndex)
		
		addEvent!(sim.eventList; parentEvent = event, form = ambReachesStation, time = ambulance.route.endTime, ambulance = ambulance, station = station)
		
################
	
	elseif eventForm == ambReachesStation
		ambulance = sim.ambulances[event.ambIndex]
		@assert(isGoingToStation(ambulance.status))
		@assert(event.callIndex == nullIndex)
		
		setAmbStatus!(sim, ambulance, ambIdleAtStation, sim.time)
		ambulance.event = Event() # no event currently
		
		updateStationStats!(sim.stations[ambulance.stationIndex]; numIdleAmbsChange = +1, time = sim.time)
		
################
	
	elseif eventForm == considerMoveUp
		ambulance = sim.ambulances[event.ambIndex] # ambulance that triggered consideration of move up
		@assert(event.callIndex == nullIndex)
		mud = sim.moveUpData # shorthand
		@assert(mud.useMoveUp)
		
		# call move up function
		movableAmbs = [] # init
		ambStations = [] # init
		
		if sim.resim.use
			(movableAmbs, ambStations) = resimMoveUp(sim)
		else
			if mud.moveUpModule == compTableModule
				(movableAmbs, ambStations) = compTableMoveUp(sim)
			elseif mud.moveUpModule == ddsmModule
				(movableAmbs, ambStations) = ddsmMoveUp(sim)
			elseif mud.moveUpModule == dmexclpModule
				(movableAmbs, ambStations) = dmexclpMoveUp(sim, ambulance)
			elseif mud.moveUpModule == priorityListModule
				(movableAmbs, ambStations) = priorityListMoveUp(sim, ambulance)
			elseif mud.moveUpModule == zhangIpModule
				(movableAmbs, ambStations) = zhangIpMoveUp(sim)
			elseif mud.moveUpModule == temp0Module
				(movableAmbs, ambStations) = temp0MoveUp(sim)
			elseif mud.moveUpModule == temp1Module
				(movableAmbs, ambStations) = temp1MoveUp(sim)
			elseif mud.moveUpModule == temp2Module
				(movableAmbs, ambStations) = temp2MoveUp(sim)
			else
				error()
			end
		end
		
		for i = 1:length(movableAmbs)
			ambulance = movableAmbs[i]
			station = ambStations[i]
			
			# move up ambulance if ambulance station has changed
			if ambulance.stationIndex != station.index
				
				if isGoingToStation(ambulance.status) # ambulance.event.form == ambReachesStation
					# delete station arrival event for this ambulance
					deleteEvent!(sim.eventList, ambulance.event)
				elseif ambulance.status == ambFreeAfterCall && ambulance.event.form == ambReturnsToStation
					deleteEvent!(sim.eventList, ambulance.event)
				end
				
				addEvent!(sim.eventList; parentEvent = event, form = ambMoveUpToStation, time = sim.time, ambulance = ambulance, station = station)
			end
		end
		
################
	
	elseif eventForm == ambMoveUpToStation
		ambulance = sim.ambulances[event.ambIndex]
		@assert(event.callIndex == nullIndex)
		station = sim.stations[event.stationIndex] # station to move up to
		@assert(ambulance.stationIndex != station.index) # otherwise it is not move up
		
		setAmbStatus!(sim, ambulance, ambMovingUpToStation, sim.time)
		changeRoute!(sim, ambulance.route, lowPriority, sim.time, station.location, station.nearestNodeIndex)
		prevStationIndex = ambulance.stationIndex
		ambulance.stationIndex = station.index
		
		# stats
		if ambulance.moveUpFromStationIndex == station.index
			@assert(ambulance.prevStatus == ambMovingUpToStation)
			ambulance.numMoveUpsReturnToPrevStation += 1
		end
		if ambulance.prevStatus == ambIdleAtStation
			updateStationStats!(sim.stations[prevStationIndex]; numIdleAmbsChange = -1, time = sim.time)
			ambulance.moveUpFromStationIndex = prevStationIndex
		end
		if sim.stats.recordMoveUpStartLocCounts
			startLoc = getRouteCurrentLocation!(sim.net, route, sim.time) # startLoc should be same as ambulance.route.startLoc
			station.moveUpStartLocCounts[startLoc] = get(station.moveUpStartLocCounts, startLoc, 0) + 1
		end
		
		addEvent!(sim.eventList; parentEvent = event, form = ambReachesStation, time = ambulance.route.endTime, ambulance = ambulance, station = station)
		
################
	
	# elseif eventForm == ambRedirected
		# ambulance = sim.ambulances[event.ambIndex]
		# call = sim.calls[event.callIndex]
		# @assert(ambulance.status == ambGoingToCall)
		
		# # may alter ambDispatched event to deal with redirects
		
		# # not yet used
		# error()
		
################
	
	else
		# unspecified event
		error()
	end
	
end
