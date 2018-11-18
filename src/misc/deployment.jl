# deployment (allocation) of ambulances to stations

# make a single random deployment
# assumes ambulances are homogeneous
function makeRandDeployment(numAmbs::Int, numStations::Int;
	stationCapacities::Union{Vector{Int},Void} = nothing,
	rng::AbstractRNG = Base.GLOBAL_RNG)::Deployment
	
	@assert(numStations > 0)
	if stationCapacities == nothing
		return sort(rand(rng, 1:numStations, numAmbs))
	else
		@assert(numStations == length(stationCapacities))
		@assert(numAmbs <= sum(stationCapacities))
		remainingCapacity = copy(stationCapacities)
		unfilledStations = Set(find(remainingCapacity))
		deployment = zeros(Int, numAmbs)
		for i = 1:numAmbs
			j = rand(rng, unfilledStations) # station index
			deployment[i] = j
			remainingCapacity[j] -= 1
			if remainingCapacity[j] == 0
				delete!(unfilledStations, j)
			end
		end
		return sort(deployment)
	end
end

# generate a number of unique random deployments
# ignores station capacities, assumes ambulances are homogeneous
function makeRandDeployments(numAmbs::Int, numStations::Int, numDeployments::Int;
	rng::AbstractRNG = Base.GLOBAL_RNG)
	@assert(numAmbs >= 1)
	@assert(numStations >= 1)
	@assert(numDeployments >= 1)
	@assert(numDeployments <= binomial(numAmbs + numStations - 1, numStations - 1))
	
	deployments = Set{Deployment}()
	while length(deployments) < numDeployments
		push!(deployments, makeRandDeployment(numAmbs, numStations; rng = rng))
	end
	deployments = collect(deployments)
	
	return deployments
end
function makeRandDeployments(sim::Simulation, numDeployments::Int;
	rng::AbstractRNG = Base.GLOBAL_RNG)
	return makeRandDeployments(sim.numAmbs, sim.numStations, numDeployments; rng = rng)
end

function deploymentToStationsNumAmbs(deployment::Deployment, numStations::Int)
	# deployment[i] gives the station index for ambulance i
	stationsNumAmbs = zeros(Int, numStations)
	for stationIndex in deployment
		stationsNumAmbs[stationIndex] += 1
	end
	return stationsNumAmbs
end

function stationsNumAmbsToDeployment(stationsNumAmbs::Vector{Int})
	# stationsNumAmbs[i] gives the number of ambulances for station i
	# will assume that all ambulances are equivalent
	deployment = Deployment() # deployment[i] gives the station index for ambulance i
	for (stationIndex, numAmbs) in enumerate(stationsNumAmbs), i = 1:numAmbs
		push!(deployment, stationIndex)
	end
	return deployment
end

# set ambulance to be located at given station
# this is hacky, expects ambulance will only need changing, this may not always be true
# mutates: ambulance
function setAmbStation!(ambulance::Ambulance, station::Station)
	ambulance.stationIndex = station.index
	ambulance.route.endLoc = station.location
	ambulance.route.endFNode = station.nearestNodeIndex
end

# apply deployment 'deployment' for sim.ambulances and sim.stations
# mutates: sim.ambulances
function applyDeployment!(sim::Simulation, deployment::Deployment)
	n = length(deployment)
	@assert(n == sim.numAmbs)
	@assert(all(d -> in(d, 1:sim.numStations), deployment))
	# @assert(all(1 .<= deployment .<= sim.numStations))
	for i = 1:n
		setAmbStation!(sim.ambulances[i], sim.stations[deployment[i]])
	end
end

function applyStationsNumAmbs!(sim::Simulation, stationsNumAmbs::Vector{Int})
	applyDeployment!(sim, stationsNumAmbsToDeployment(stationsNumAmbs))
end

# runs simulation for the deployment
# mutates: sim
function simulateDeployment!(sim::Simulation, deployment::Deployment)
	resetSim!(sim)
	applyDeployment!(sim, deployment)
	simulateToEnd!(sim)
end

# runs simulation for each deployment
# returns vector of function applied to end of each simulation run
# mutates: sim
function simulateDeployments!(sim::Simulation, deployments::Vector{Deployment}, f::Function;
	showEta::Bool = false)
	numDeployments = length(deployments)
	results = Vector{Any}(numDeployments)
	t = time() # for estimating expected time remaining
	for i = 1:numDeployments
		simulateDeployment!(sim, deployments[i])
		results[i] = f(sim)
		if showEta
			remTime = (time() - t) / i * (numDeployments - i) / 60 # minutes
			print(rpad(string(" remaining run time (minutes): ", ceil(remTime,1)), 100, " "), "\r")
		end
	end
	resetSim!(sim)
	return results
end
