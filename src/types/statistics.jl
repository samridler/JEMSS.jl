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

@info("Todo: check correctness of statistics.")

# Capture statistics at current time.
# Mutates: sim.stats, sim.time
function captureSimStats!(sim::Simulation, currentTime::Float)
	if sim.complete currentTime = min(currentTime, sim.endTime) end
	
	if !sim.complete @assert(currentTime == sim.stats.nextCaptureTime) end
	@assert(sim.time <= currentTime)
	@assert(isempty(sim.eventList) || currentTime <= sim.eventList[end].time) # currentTime should be before next event
	
	sim.time = currentTime
	
	capture = SimPeriodStats()
	capture.startTime = sim.startTime
	capture.endTime = currentTime
	capture.duration = capture.endTime - capture.startTime
	capture.ambulances = [AmbulanceStats(sim, a) for a in sim.ambulances]
	capture.hospitals = [HospitalStats(h) for h in sim.hospitals]
	capture.stations = [StationStats(sim, s) for s in sim.stations]
	capture.ambulance = sum(capture.ambulances)
	capture.hospital = sum(capture.hospitals)
	capture.station = sum(capture.stations)
	
	push!(sim.stats.captures, capture)
	
	# determine next capture time
	nextPeriodDuration = isempty(sim.stats.periodDurationsIter) ? Inf : first(sim.stats.periodDurationsIter)
	@assert(nextPeriodDuration > 0)
	sim.stats.nextCaptureTime += nextPeriodDuration
end

# For statistics that should be calculated at sim end.
# Mutates: sim.stats
function populateSimStats!(sim::Simulation)
	@assert(sim.complete)
	
	# shorthand
	stats = sim.stats
	captures = stats.captures
	
	@assert(all(s -> s.startTime == sim.startTime, captures))
	@assert(issorted(captures, by = s -> s.endTime))
	@assert(captures[end].endTime == sim.endTime)
	
	# timestamps
	stats.simStartTime = sim.startTime
	stats.simEndTime = sim.endTime
	stats.warmUpEndTime = sim.startTime + stats.warmUpDuration
	stats.lastCallArrivalTime = sim.calls[end].arrivalTime
	
	# populate call statistics
	callsByPriority = Dict([p => filter(c -> c.priority == p, sim.calls) for p in priorities])
	for i = 1:length(captures)
		period = i == 1 ? captures[i] : captures[i] - captures[i-1]
		period.call = CallStats(sim, sim.calls, period.startTime, period.endTime)
		for priority in priorities
			period.callPriorities[priority] = CallStats(sim, callsByPriority[priority], period.startTime, period.endTime)
		end
		push!(stats.periods, period)
		
		captures[i].call = i == 1 ? period.call : period.call + captures[i-1].call
		captures[i].callPriorities = i == 1 ? period.callPriorities : period.callPriorities + captures[i-1].callPriorities
	end
end

# Return ambulance stats for given ambulance.
# Accounts for durations and distances of partially completed travelling and processes.
function AmbulanceStats(sim::Simulation, ambulance::Ambulance)::AmbulanceStats
	stats = AmbulanceStats()
	
	# copy some fields
	stats.ambIndex = ambulance.index
	stats.numCallsTreated = ambulance.numCallsTreated
	stats.numCallsTransported = ambulance.numCallsTransported
	stats.numDispatches = ambulance.numDispatches
	stats.numDispatchesFromStation = ambulance.numDispatchesFromStation
	stats.numDispatchesOnRoad = ambulance.numDispatchesOnRoad
	stats.numDispatchesOnFree = ambulance.numDispatchesOnFree
	stats.numRedispatches = ambulance.numRedispatches
	stats.numMoveUps = ambulance.numMoveUps
	stats.numMoveUpsFromStation = ambulance.numMoveUpsFromStation
	stats.numMoveUpsOnRoad = ambulance.numMoveUpsOnRoad
	stats.numMoveUpsOnFree = ambulance.numMoveUpsOnFree
	stats.numMoveUpsReturnToPrevStation = ambulance.numMoveUpsReturnToPrevStation
	stats.statusTransitionCounts = deepcopy(ambulance.statusTransitionCounts)
	
	stats.statusDurations = deepcopy(ambulance.statusDurations)
	stats.statusDurations[ambulance.status] += sim.time - ambulance.statusSetTime # to make sure that sum of statusDurations equals the sim duration
	
	# calculate travel distance, accounting for any partially completed route
	stats.totalTravelDistance = ambulance.totalTravelDistance # ambulance.totalTravelDistance is for routes completed before sim.time
	if sim.time < ambulance.route.endTime # have not finished route
		stats.totalTravelDistance += calcRouteDistance!(sim, ambulance.route, sim.time)
	end
	
	ambStatuses = collect(instances(AmbStatus))
	busyStatuses = filter(s -> isBusy(s), ambStatuses)
	travelStatuses = filter(s -> isTravelling(s), ambStatuses)
	workingStatuses = filter(s -> isWorking(s), ambStatuses)
	stats.totalBusyDuration = sum(status -> stats.statusDurations[status], busyStatuses) # >= ambulance.totalBusyDuration
	stats.totalTravelDuration = sum(status -> stats.statusDurations[status], travelStatuses) # >= ambulance.totalTravelDuration
	stats.totalWorkingDuration = sum(status -> stats.statusDurations[status], workingStatuses) # >= ambulance.totalWorkingDuration
	
	if checkMode
		@assert(stats.numDispatches == stats.numDispatchesFromStation + stats.numDispatchesOnRoad + stats.numDispatchesOnFree) # numRedispatches already included in numDispatchesOnRoad
		@assert(stats.numMoveUps == stats.numMoveUpsFromStation + stats.numMoveUpsOnRoad + stats.numMoveUpsOnFree)
		
		@assert(isapprox(sum(values(stats.statusDurations)), sim.time - sim.startTime))
		@assert(stats.totalBusyDuration >= ambulance.totalBusyDuration || isapprox(stats.totalBusyDuration, ambulance.totalBusyDuration))
		@assert(stats.totalTravelDuration >= ambulance.totalTravelDuration || isapprox(stats.totalTravelDuration, ambulance.totalTravelDuration))
		@assert(stats.totalWorkingDuration >= ambulance.totalWorkingDuration || isapprox(stats.totalWorkingDuration, ambulance.totalWorkingDuration))
		
		# statusTransitionCounts
		@assert(stats.numCallsTreated == sum(stats.statusTransitionCounts[:, Int(ambAtCall)]))
		@assert(stats.numCallsTransported == stats.statusTransitionCounts[Int(ambGoingToHospital), Int(ambAtHospital)])
		@assert(stats.numDispatches == sum(stats.statusTransitionCounts[:, Int(ambGoingToCall)]))
		@assert(stats.numDispatchesFromStation == stats.statusTransitionCounts[Int(ambIdleAtStation), Int(ambGoingToCall)])
		@assert(stats.numDispatchesOnRoad == sum(s -> stats.statusTransitionCounts[Int(s), Int(ambGoingToCall)], travelStatuses))
		@assert(stats.numDispatchesOnFree == stats.statusTransitionCounts[Int(ambFreeAfterCall), Int(ambGoingToCall)])
		@assert(stats.numRedispatches == stats.statusTransitionCounts[Int(ambGoingToCall), Int(ambGoingToCall)])
		@assert(stats.numMoveUps == sum(stats.statusTransitionCounts[:, Int(ambMovingUpToStation)]))
		@assert(stats.numMoveUpsFromStation == stats.statusTransitionCounts[Int(ambIdleAtStation), Int(ambMovingUpToStation)])
		@assert(stats.numMoveUpsOnRoad == sum(s -> stats.statusTransitionCounts[Int(s), Int(ambMovingUpToStation)], travelStatuses))
		@assert(stats.numMoveUpsOnFree == stats.statusTransitionCounts[Int(ambFreeAfterCall), Int(ambMovingUpToStation)])
	end
	
	return stats
end

function CallStats(sim::Simulation, calls::Vector{Call})::CallStats
	if isempty(calls) return CallStats() end
	@assert(all(c -> c.status == callProcessed, calls))
	stats = CallStats()
	stats.numCalls = length(calls)
	if stats.numCalls == 1 stats.callIndex = calls[1].index end
	
	# counts
	stats.numQueued = count(c -> c.wasQueued, calls)
	stats.numBumped = count(c -> c.numBumps > 0, calls)
	stats.numBumps = sum(c -> c.numBumps, calls)
	stats.numTransports = count(c -> c.transport, calls)
	stats.numResponsesInTime = count(c -> c.responseDuration <= sim.targetResponseDurations[Int(c.priority)], calls)
	
	# durations
	stats.totalDispatchDelay = sum(c -> c.dispatchDelay, calls)
	stats.totalOnSceneDuration = sum(c -> c.onSceneDuration, calls)
	stats.totalHandoverDuration = sum(c -> c.handoverDuration, calls)
	stats.totalQueuedDuration = sum(c -> c.queuedDuration, calls)
	stats.totalBumpedDuration = sum(c -> c.bumpedDuration, calls)
	stats.totalWaitingForAmbDuration = sum(c -> c.waitingForAmbDuration, calls)
	stats.totalResponseDuration = sum(c -> c.responseDuration, calls)
	stats.totalAmbGoingToCallDuration = sum(c -> c.ambGoingToCallDuration, calls)
	stats.totalTransportDuration = sum(c -> c.transportDuration, calls)
	
	if checkMode
		@assert(all(c -> c.wasQueued || c.queuedDuration == 0, calls))
		@assert(all(c -> c.numBumps > 0 || c.bumpedDuration == 0, calls))
		@assert(all(c -> c.dispatchDelay >= 0, calls))
		@assert(all(c -> c.transport || c.transportDuration == 0, calls)) # calls not taken to hospital should have transportDuration == 0
		@assert(all(c -> c.transport || c.handoverDuration == 0, calls)) # calls not taken to hospital should have handoverDuration == 0
		@assert(isapprox(stats.totalWaitingForAmbDuration, stats.totalAmbGoingToCallDuration + stats.totalBumpedDuration))
		@assert(isapprox(stats.totalResponseDuration, stats.totalDispatchDelay + stats.totalQueuedDuration + stats.totalBumpedDuration + stats.totalAmbGoingToCallDuration))
	end
	
	return stats
end

function CallStats(sim::Simulation, calls::Vector{Call}, startTime::Float, endTime::Float)::CallStats
	# filter calls by arrivalTime within [startTime, endTime)
	i = findfirst(c -> c.arrivalTime >= startTime, calls)
	if i == nothing return CallStats() end # no calls in time period
	j = something(findnext(c -> c.arrivalTime >= endTime, calls, i), length(calls) + 1) - 1
	return CallStats(sim, calls[i:j])
end

function HospitalStats(hospital::Hospital)::HospitalStats
	stats = HospitalStats()
	stats.hospitalIndex = hospital.index
	stats.numCalls = hospital.numCalls
	return stats
end

function StationStats(sim::Simulation, station::Station)::StationStats
	stats = StationStats()
	stats.stationIndex = station.index
	
	stats.numIdleAmbsTotalDuration = deepcopy(station.numIdleAmbsTotalDuration)
	@assert(sim.time >= station.currentNumIdleAmbsSetTime)
	stats.numIdleAmbsTotalDuration[station.currentNumIdleAmbs] += sim.time - station.currentNumIdleAmbsSetTime
	
	if checkMode
		@assert(isapprox(sum(stats.numIdleAmbsTotalDuration), sim.time - sim.startTime))
	end
	
	return stats
end

# for ambulance statusDurations:
Base.:+(a::Dict{AmbStatus,Float}, b::Dict{AmbStatus,Float}) = merge(+, a, b)
Base.:-(a::Dict{AmbStatus,Float}, b::Dict{AmbStatus,Float}) = merge(-, a, b)

function Base.:+(a::AmbulanceStats, b::AmbulanceStats)::AmbulanceStats
	stats = AmbulanceStats()
	for fname in fieldnames(AmbulanceStats)
		setfield!(stats, fname, getfield(a, fname) + getfield(b, fname))
	end
	stats.ambIndex = a.ambIndex == b.ambIndex ? a.ambIndex : nullIndex
	return stats
end

function Base.:-(a::AmbulanceStats, b::AmbulanceStats)::AmbulanceStats
	stats = AmbulanceStats()
	for fname in fieldnames(AmbulanceStats)
		setfield!(stats, fname, getfield(a, fname) - getfield(b, fname))
	end
	stats.ambIndex = a.ambIndex == b.ambIndex ? a.ambIndex : nullIndex
	return stats
end

function Base.:+(a::CallStats, b::CallStats)::CallStats
	stats = CallStats()
	for fname in fieldnames(CallStats)
		setfield!(stats, fname, getfield(a, fname) + getfield(b, fname))
	end
	stats.callIndex = a.callIndex == b.callIndex ? a.callIndex : nullIndex
	return stats
end

function Base.:-(a::CallStats, b::CallStats)::CallStats
	stats = CallStats()
	for fname in fieldnames(CallStats)
		setfield!(stats, fname, getfield(a, fname) - getfield(b, fname))
	end
	stats.callIndex = a.callIndex == b.callIndex ? a.callIndex : nullIndex
	return stats
end

Base.:+(a::Dict{Priority,CallStats}, b::Dict{Priority,CallStats}) = merge(+, a, b)
Base.:-(a::Dict{Priority,CallStats}, b::Dict{Priority,CallStats}) = merge(-, a, b)

function Base.:+(a::HospitalStats, b::HospitalStats)::HospitalStats
	stats = HospitalStats()
	for fname in fieldnames(HospitalStats)
		setfield!(stats, fname, getfield(a, fname) + getfield(b, fname))
	end
	stats.hospitalIndex = a.hospitalIndex == b.hospitalIndex ? a.hospitalIndex : nullIndex
	return stats
end

function Base.:-(a::HospitalStats, b::HospitalStats)::HospitalStats
	stats = HospitalStats()
	for fname in fieldnames(HospitalStats)
		setfield!(stats, fname, getfield(a, fname) - getfield(b, fname))
	end
	stats.hospitalIndex = a.hospitalIndex == b.hospitalIndex ? a.hospitalIndex : nullIndex
	return stats
end

function Base.:+(a::StationStats, b::StationStats)::StationStats
	stats = StationStats()
	for fname in fieldnames(StationStats)
		setfield!(stats, fname, getfield(a, fname) + getfield(b, fname))
	end
	stats.stationIndex = a.stationIndex == b.stationIndex ? a.stationIndex : nullIndex
	return stats
end

function Base.:-(a::StationStats, b::StationStats)::StationStats
	stats = StationStats()
	for fname in fieldnames(StationStats)
		setfield!(stats, fname, getfield(a, fname) - getfield(b, fname))
	end
	stats.stationIndex = a.stationIndex == b.stationIndex ? a.stationIndex : nullIndex
	return stats
end

function Base.:+(a::SimPeriodStats, b::SimPeriodStats)::SimPeriodStats
	@assert(a.startTime == b.endTime || a.endTime == b.startTime)
	stats = SimPeriodStats()
	for fname in fieldnames(SimPeriodStats)
		setfield!(stats, fname, getfield(a, fname) + getfield(b, fname))
	end
	stats.startTime = min(a.startTime, b.startTime)
	stats.endTime = max(a.endTime, b.endTime)
	return stats
end

function Base.:-(a::SimPeriodStats, b::SimPeriodStats)::SimPeriodStats
	@assert(a.startTime == b.startTime)
	stats = SimPeriodStats()
	for fname in fieldnames(SimPeriodStats)
		setfield!(stats, fname, getfield(a, fname) - getfield(b, fname))
	end
	stats.startTime = b.endTime
	stats.endTime = a.endTime
	return stats
end
