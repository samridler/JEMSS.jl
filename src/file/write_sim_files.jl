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

# write sim object and output files

function writeAmbsFile(filename::String, ambulances::Vector{Ambulance}; writeOutputFields::Bool = false)
	header = ["index", "stationIndex", "class"]
	row1(a::Ambulance) = [a.index, a.stationIndex, Int(a.class)]
	
	if writeOutputFields
		header = vcat(header, ["totalTravelDuration", "totalTravelDistance", "totalBusyDuration", "totalWorkingDuration", "numCallsTreated", "numCallsTransported", "numDispatches", "numDispatchesFromStation", "numDispatchesOnRoad", "numDispatchesOnFree", "numRedispatches", "numMoveUps", "numMoveUpsFromStation", "numMoveUpsOnRoad", "numMoveUpsOnFree", "numMoveUpsReturnToPrevStation"])
		row2(a::Ambulance) = [a.totalTravelDuration, a.totalTravelDistance, a.totalBusyDuration, a.totalWorkingDuration, a.numCallsTreated, a.numCallsTransported, a.numDispatches, a.numDispatchesFromStation, a.numDispatchesOnRoad, a.numDispatchesOnFree, a.numRedispatches, a.numMoveUps, a.numMoveUpsFromStation, a.numMoveUpsOnRoad, a.numMoveUpsOnFree, a.numMoveUpsReturnToPrevStation]
		# skipped: statusDurations (dict), statusDistances (dict), statusTransitionCounts (array)
	end
	
	row(a::Ambulance) = writeOutputFields ? vcat(row1(a), row2(a)) : row1(a)
	table = Table("ambulances", header; rows = [row(a) for a in ambulances])
	writeTablesToFile(filename, table)
end

function writeArcsFile(filename::String, arcs::Vector{Arc}, travelTimes::Array{Float,2}, arcForm::String)
	@assert(arcForm == "directed" || arcForm == "undirected")
	numModes = size(travelTimes,1)
	miscTable = Table("miscData", ["arcForm", "numModes"]; rows = [[arcForm, numModes]])
	mainHeaders = ["index", "fromNode", "toNode", "distance", ["mode_$i" for i = 1:numModes]...]
	fieldNames = setdiff(collect(keys(arcs[1].fields)), mainHeaders) # assume fields are same for all arcs
	arcsTable = Table("arcs", [mainHeaders..., fieldNames...];
		rows = [vcat(a.index, a.fromNodeIndex, a.toNodeIndex, a.distance, travelTimes[:,a.index]..., [a.fields[f] for f in fieldNames]...) for a in arcs])
	writeTablesToFile(filename, [miscTable, arcsTable])
end

function writeCallsFile(filename::String, startTime::Float, calls::Vector{Call}; writeOutputFields::Bool = false)
	@assert(length(calls) >= 1)
	miscTable = Table("miscData", ["startTime"]; rows = [[startTime]])
	
	header = ["index", "priority", "x", "y", "arrivalTime", "dispatchDelay", "onSceneDuration", "transport", "hospitalIndex", "handoverDuration"]
	row1(c::Call) = [c.index, Int(c.priority), c.location.x, c.location.y, c.arrivalTime, c.dispatchDelay, c.onSceneDuration, Int(c.transport), c.hospitalIndex, c.handoverDuration]
	
	if writeOutputFields
		header = vcat(header, ["dispatchTime", "ambArrivalTime", "hospitalArrivalTime", "numBumps", "wasQueued", "ambDispatchLoc.x", "ambDispatchLoc.y", "ambStatusBeforeDispatch", "chosenHospitalIndex", "queuedDuration", "bumpedDuration", "waitingForAmbDuration", "responseDuration", "ambGoingToCallDuration", "transportDuration", "serviceDuration"])
		row2(c::Call) = [c.dispatchTime, c.ambArrivalTime, c.hospitalArrivalTime, c.numBumps, Int(c.wasQueued), c.ambDispatchLoc.x, c.ambDispatchLoc.y, string(c.ambStatusBeforeDispatch), c.chosenHospitalIndex, c.queuedDuration, c.bumpedDuration, c.waitingForAmbDuration, c.responseDuration, c.ambGoingToCallDuration, c.transportDuration, c.serviceDuration]
	end
	
	row(c::Call) = writeOutputFields ? vcat(row1(c), row2(c)) : row1(c)
	callsTable = Table("calls", header; rows = [row(c) for c in calls])
	writeTablesToFile(filename, [miscTable, callsTable])
end

function writeDemandFile(filename::String, demand::Demand)
	demandRastersTable = Table("demandRasters", ["rasterIndex", "rasterFilename"];
		rows = [[i, demand.rasterFilenames[i]] for i = 1:demand.numRasters])
	
	demandModesTable = Table("demandModes", ["modeIndex", "rasterIndex", "priority", "arrivalRate"];
		rows = [[m.index, m.rasterIndex, string(m.priority), m.arrivalRate] for m in demand.modes])
	@assert(all(i -> demand.modes[i].index == i, 1:demand.numModes))
	
	# demand sets table
	dml = demand.modeLookup # shorthand
	@assert(size(dml) == (demand.numSets, numPriorities)) # should have value for each combination of demand mode and priority
	demandSetsTable = Table("demandSets", ["setIndex", "modeIndices"];
		rows = [[i, hcat(dml[i,:]...)] for i = 1:demand.numSets])
	
	# demand sets timing table
	startTimes = demand.setsStartTimes # shorthand
	setIndices = demand.setsTimeOrder # shorthand
	demandSetsTimingTable = Table("demandSetsTiming", ["startTime", "setIndex"];
		rows = [[startTimes[i], setIndices[i]] for i = 1:length(startTimes)])
	
	writeTablesToFile(filename, [demandRastersTable, demandModesTable, demandSetsTable, demandSetsTimingTable])
end

function writeDemandCoverageFile(filename::String, demandCoverage::DemandCoverage)
	dc = demandCoverage # shorthand
	coverTimesTable = Table("coverTimes", ["demandPriority", "coverTime"];
		rows = [[string(priority), coverTime] for (priority, coverTime) in dc.coverTimes])
	
	demandRasterCellNumPointsTable = Table("demandRasterCellNumPoints", ["rows", "cols"];
		rows = [[dc.rasterCellNumRows, dc.rasterCellNumCols]])
	
	writeTablesToFile(filename, [coverTimesTable, demandRasterCellNumPointsTable])
end

function writeHospitalsFile(filename::String, hospitals::Vector{Hospital}; writeOutputFields::Bool = false)
	header = ["index", "x", "y"]
	row1(h::Hospital) = [h.index, h.location.x, h.location.y]
	
	if writeOutputFields
		header = vcat(header, ["numCalls"])
		row2(h::Hospital) = [h.numCalls]
	end
	
	row(h::Hospital) = writeOutputFields ? vcat(row1(h), row2(h)) : row1(h)
	table = Table("hospitals", header, rows = [row(h) for h in hospitals])
	writeTablesToFile(filename, table)
end

function writeMapFile(filename::String, map::Map)
	table = Table("map", ["xMin", "xMax", "yMin", "yMax", "xScale", "yScale"];
		rows = [[map.xMin, map.xMax, map.yMin, map.yMax, map.xScale, map.yScale]])
	writeTablesToFile(filename, table)
end

function writeNodesFile(filename::String, nodes::Vector{Node})
	mainHeaders = ["index", "x", "y", "offRoadAccess"]
	fieldNames = setdiff(collect(keys(nodes[1].fields)), mainHeaders) # assume fields are same for all nodes
	table = Table("nodes", [mainHeaders..., fieldNames...];
		rows = [[n.index, n.location.x, n.location.y, Int(n.offRoadAccess), [n.fields[f] for f in fieldNames]...] for n in nodes])
	writeTablesToFile(filename, table)
end

function writeRedispatchFile(filename::String, redispatch::Redispatch)
	miscTable = Table("miscData", ["allowRedispatch"], rows = [[Int(redispatch.allow)]])
	conditionsTable = Table("redispatchConditions", ["fromCallPriority", "toCallPriority", "allowRedispatch"],
		rows = [[[string(p1), string(p2), Int(redispatch.conditions[Int(p1),Int(p2)])] for p1 in priorities, p2 in priorities]...])
	writeTablesToFile(filename, [miscTable, conditionsTable])
end

function writeRNetTravelsFile(filename::String, rNetTravels::Vector{NetTravel})
	n = length(rNetTravels)
	@assert(all(i -> rNetTravels[i].isReduced, 1:n))
	@assert(all(i -> rNetTravels[i].modeIndex == i, 1:n))
	# save only some field values to file
	rNetTravelsSave = [NetTravel(true) for i = 1:n]
	for i = 1:n, fname in (:modeIndex, :arcTimes, :arcDists, :spTimes, :spDists, :spFadjIndex, :spNodePairArcIndex, :spFadjArcList)
		setfield!(rNetTravelsSave[i], fname, getfield(rNetTravels[i], fname))
	end
	serializeToFile(filename, rNetTravelsSave)
end

function writePrioritiesFile(filename::String, targetResponseDurations::Vector{Float})
	table = Table("priorities", ["priority", "name", "targetResponseDuration"];
		rows = [[i, string(Priority(i)), targetResponseDurations[i]] for i = 1:length(targetResponseDurations)])
	writeTablesToFile(filename, table)
end

function writeStationsFile(filename::String, stations::Vector{Station})
	table = Table("stations", ["index", "x", "y", "capacity"];
		rows = [[s.index, s.location.x, s.location.y, s.capacity] for s in stations])
	writeTablesToFile(filename, table)
end

function writeTravelFile(filename::String, travel::Travel)
	# travel modes table
	travelModesTable = Table("travelModes", ["travelModeIndex", "offRoadSpeed"];
		rows = [[tm.index, tm.offRoadSpeed] for tm in travel.modes])
	
	# travel sets table
	tml = travel.modeLookup # shorthand
	@assert(size(tml) == (length(travel.modes), numPriorities)) # should have value for each combination of travel mode and priority
	travelSetsTable = Table("travelSets", ["travelSetIndex", "priority", "travelModeIndex"];
		rows = [[[i, string(Priority(j)), tml[i,j]] for i = 1:size(tml,1), j = 1:size(tml,2)]...])
	
	# travel sets timing table
	startTimes = travel.setsStartTimes # shorthand
	setIndices = travel.setsTimeOrder # shorthand
	travelSetsTimingTable = Table("travelSetsTiming", ["startTime", "travelSetIndex"];
		rows = [[startTimes[i], setIndices[i]] for i = 1:length(startTimes)])
	
	writeTablesToFile(filename, [travelModesTable, travelSetsTable, travelSetsTimingTable])
end

# opens output files for writing during simulation
# note: should have field sim.resim.use set/fixed before calling this function
function openOutputFiles!(sim::Simulation)
	if !sim.writeOutput; return; end
	
	println("output path: ", sim.outputPath)
	outputFilePath(name::String) = sim.outputFiles[name].path
	
	# create output path if it does not already exist
	if !isdir(sim.outputPath)
		mkdir(sim.outputPath)
	end
	
	# open output files for writing
	# currently, only need to open events file
	if !sim.resim.use # otherwise, existing events file is used for resimulation
		sim.outputFiles["events"].iostream = open(outputFilePath("events"), "w")
		sim.eventsFileIO = sim.outputFiles["events"].iostream # shorthand
		
		# save checksum of input files
		inputFiles = sort([name for (name, file) in sim.inputFiles])
		fileChecksumStrings = [string("'", sim.inputFiles[name].checksum, "'") for name in inputFiles]
		writeTablesToFile!(sim.eventsFileIO, Table("inputFiles", ["name", "checksum"]; cols = [inputFiles, fileChecksumStrings]))
		
		# save events with a key, to reduce file size
		eventForms = instances(EventForm)
		eventKeys = [Int(eventForm) for eventForm in eventForms]
		eventNames = [string(eventForm) for eventForm in eventForms]
		writeTablesToFile!(sim.eventsFileIO, Table("eventDict", ["key", "name"]; cols = [eventKeys, eventNames]))
		
		# write events table name and header
		writeDlmLine!(sim.eventsFileIO, "events")
		writeDlmLine!(sim.eventsFileIO, "index", "parentIndex", "time", "eventKey", "ambIndex", "callIndex", "stationIndex")
	end
end

function writeOutputFiles(sim::Simulation)
	writeMiscOutputFiles(sim)
	writeStatsFiles(sim)
end

function writeMiscOutputFiles(sim::Simulation)
	outputFileKeys = keys(sim.outputFiles)
	outputFilePath(name::String) = sim.outputFiles[name].path
	if in("ambulances", outputFileKeys) writeAmbsFile(outputFilePath("ambulances"), sim.ambulances; writeOutputFields = true) end
	if in("calls", outputFileKeys) writeCallsFile(outputFilePath("calls"), sim.startTime, sim.calls; writeOutputFields = true) end
	if in("hospitals", outputFileKeys) writeHospitalsFile(outputFilePath("hospitals"), sim.hospitals; writeOutputFields = true) end
end

function closeOutputFiles!(sim::Simulation)
	if !sim.writeOutput; return; end
	
	if !sim.resim.use
		writeDlmLine!(sim.eventsFileIO, "end")
		close(sim.eventsFileIO)
	end
end

function writeEventToFile!(sim::Simulation, event::Event)
	if !sim.writeOutput || sim.resim.use; return; end
	
	writeDlmLine!(sim.eventsFileIO, event.index, event.parentIndex, @sprintf("%0.5f", event.time), Int(event.form), event.ambIndex, event.callIndex, event.stationIndex)
	
	# flush(sim.eventsFileIO)
end

# write deployments to file
function writeDeploymentsFile(filename::String, deployments::Vector{Deployment}, numStations::Int)
	numAmbs = length(deployments[1])
	@assert(numStations >= maximum([maximum(d) for d in deployments]))
	numDeployments = length(deployments)
	
	miscTable = Table("miscData", ["numStations", "numDeployments"]; rows = [[numStations, numDeployments]])
	deploymentsTable = Table("deployments",
		["ambIndex", ["deployment_$i stationIndex" for i = 1:numDeployments]...];
		cols = [collect(1:numAmbs), deployments...])
	writeTablesToFile(filename, [miscTable, deploymentsTable])
end

# save batch mean response durations to file
function writeBatchMeanResponseDurationsFile(filename::String, batchMeanResponseDurations::Array{Float,2};
	batchTime = nullTime, startTime = nullTime, endTime = nullTime, responseDurationUnits::String = "minutes")
	@assert(batchTime != nullTime && startTime != nullTime && endTime != nullTime)
	x = batchMeanResponseDurations # shorthand
	(numRows, numCols) = size(x) # numRows = numSims, numCols = numBatches
	miscTable = Table("misc_data",
		["numSims", "numBatches", "batchTime", "startTime", "endTime", "response_duration_units"];
		rows=[[numRows, numCols, batchTime, startTime, endTime, responseDurationUnits]])
	avgBatchMeansTable = Table("avg_batch_mean_response_durations",
		["sim_index", "avg_batch_mean_response_duration", "standard_error"];
		rows = [[i, mean(x[i,:]), sem(x[i,:])] for i = 1:numRows])
	batchMeansTable = Table("batch_mean_response_durations",
		["batch_index", ["sim_$i" for i = 1:numRows]...];
		rows = [[i, x[:,i]...] for i = 1:numCols])
	writeTablesToFile(filename, [miscTable, avgBatchMeansTable, batchMeansTable])
end

function writeStatsFiles(sim::Simulation)
	outputFileKeys = keys(sim.outputFiles)
	outputFilePath(name::String) = sim.outputFiles[name].path
	stats = sim.stats # shorthand
	if in("ambulancesStats", outputFileKeys) writeAmbsStatsFile(outputFilePath("ambulancesStats"), stats) end
	if in("callsStats", outputFileKeys) writeCallsStatsFile(outputFilePath("callsStats"), stats) end
	if in("hospitalsStats", outputFileKeys) writeHospitalsStatsFile(outputFilePath("hospitalsStats"), stats) end
	if in("stationsStats", outputFileKeys) writeStationsStatsFile(outputFilePath("stationsStats"), stats) end
end

function simStatsTimestampsTable(stats::SimStats)::Table
	return Table("timestamps", ["simStartTime", "warmUpEndTime", "lastCallArrivalTime", "simEndTime"];
		rows = [[stats.simStartTime, stats.warmUpEndTime, stats.lastCallArrivalTime, stats.simEndTime]])
end

function simStatsPeriodsTable(periods::Vector{SimPeriodStats})::Table
	periodsTable = Table("periods", ["periodIndex", "startTime", "endTime", "duration"];
		rows = [[i, p.startTime, p.endTime, p.duration] for (i,p) in enumerate(periods)])
	return periodsTable
end

function writeAmbsStatsFile(filename::String, stats::SimStats)
	# shorthand
	periods = stats.periods
	numAmbs = length(periods[1].ambulances)
	
	miscTable = Table("miscData", ["numAmbs"]; rows = [[numAmbs]])
	
	timestampsTable = simStatsTimestampsTable(stats)
	periodsTable = simStatsPeriodsTable(periods)
	
	ambulanceTables = Table[]
	ambulanceStatusDurationsTables = Table[]
	ambulanceStatusDistancesTables = Table[]
	fnames = collect(setdiff(fieldnames(AmbulanceStats), (:ambIndex, :statusDurations, :statusDistances, :statusTransitionCounts))) # for ambulanceTables
	statuses = (setdiff(instances(AmbStatus), (ambNullStatus,))..., instances(AmbStatusSet)...) # for ambulanceStatusDurationsTables
	travelStatuses = (ambStatusSets[ambTravelling]..., instances(AmbStatusSet)...)
	getAmb(period::SimPeriodStats, ambIndex::Int) = ambIndex == 0 ? period.ambulance : period.ambulances[ambIndex]
	for i = 0:numAmbs
		name = i == 0 ? "ambulance" : "ambulances[$i]"
		
		ambulanceTable = Table(name, vcat("periodIndex", collect(string.(fnames)));
			rows = [vcat(j, [getfield(getAmb(p,i), fname) for fname in fnames]) for (j,p) in enumerate(periods)])
		push!(ambulanceTables, ambulanceTable)
		
		ambulanceStatusDurationsTable = Table("$name.statusDurations", vcat("periodIndex", string.(statuses)...);
			rows = [vcat(j, [getAmb(p,i).statusDurations[s] for s in statuses]) for (j,p) in enumerate(periods)])
		push!(ambulanceStatusDurationsTables, ambulanceStatusDurationsTable)
		
		ambulanceStatusDistancesTable = Table("$name.statusDistances", vcat("periodIndex", string.(travelStatuses)...);
			rows = [vcat(j, [getAmb(p,i).statusDistances[s] for s in travelStatuses]) for (j,p) in enumerate(periods)])
		push!(ambulanceStatusDistancesTables, ambulanceStatusDistancesTable)
		
		# skipped: statusTransitionCounts
	end
	
	writeTablesToFile(filename, [miscTable, timestampsTable, periodsTable, ambulanceTables..., ambulanceStatusDurationsTables..., ambulanceStatusDistancesTables...])
end

function writeCallsStatsFile(filename::String, stats::SimStats)
	periods = stats.periods # shorthand
	
	numCalls = stats.captures[end].call.numCalls
	miscTable = Table("miscData", ["numCalls"]; rows = [[numCalls]])
	
	timestampsTable = simStatsTimestampsTable(stats)
	periodsTable = simStatsPeriodsTable(periods)
	
	fnames = setdiff(fieldnames(CallStats), (:callIndex,))
	callTable = Table("call", vcat("periodIndex", collect(string.(fnames)));
		rows = [vcat(i, [getfield(p.call, fname) for fname in fnames]) for (i,p) in enumerate(periods)])
	
	callPrioritiesTables = Table[]
	for priority in priorities
		table = Table("callPriorities[$priority]", vcat("periodIndex", collect(string.(fnames)));
			rows = [vcat(i, [getfield(p.callPriorities[priority], fname) for fname in fnames]) for (i,p) in enumerate(periods)])
		push!(callPrioritiesTables, table)
	end
	
	writeTablesToFile(filename, [miscTable, timestampsTable, periodsTable, callTable, callPrioritiesTables...])
end

function writeHospitalsStatsFile(filename::String, stats::SimStats)
	# shorthand
	periods = stats.periods
	numHospitals = length(periods[1].hospitals)
	
	miscTable = Table("miscData", ["numHospitals"]; rows = [[numHospitals]])
	
	timestampsTable = simStatsTimestampsTable(stats)
	periodsTable = simStatsPeriodsTable(periods)
	
	hospitalTables = Table[]
	fnames = setdiff(fieldnames(HospitalStats), (:hospitalIndex,))
	getHospital(period::SimPeriodStats, hospitalIndex::Int) = hospitalIndex == 0 ? period.hospital : period.hospitals[hospitalIndex]
	for i = 0:numHospitals
		name = i == 0 ? "hospital" : "hospitals[$i]"
		hospitalTable = Table(name, vcat("periodIndex", collect(string.(fnames)));
			rows = [vcat(j, [getfield(getHospital(p,i), fname) for fname in fnames]) for (j,p) in enumerate(periods)])
		push!(hospitalTables, hospitalTable)
	end
	
	writeTablesToFile(filename, [miscTable, timestampsTable, periodsTable, hospitalTables...])
end

function writeStationsStatsFile(filename::String, stats::SimStats)
	# shorthand
	periods = stats.periods
	numStations = length(periods[1].stations)
	
	miscTable = Table("miscData", ["numStations"]; rows = [[numStations]])
	
	timestampsTable = simStatsTimestampsTable(stats)
	periodsTable = simStatsPeriodsTable(periods)
	
	getStation(period::SimPeriodStats, stationIndex::Int) = stationIndex == 0 ? period.station : period.stations[stationIndex]
	stationsNumIdleAmbsTotalDurationTable = Table("stations_numIdleAmbsTotalDuration", vcat("periodIndex", "station", ["stations[$i]" for i = 1:numStations]);
		rows = [vcat(j, [string(getStation(p,i).numIdleAmbsTotalDuration) for i = 0:numStations]) for (j,p) in enumerate(periods)])
	
	writeTablesToFile(filename, [miscTable, timestampsTable, periodsTable, stationsNumIdleAmbsTotalDurationTable])
end
