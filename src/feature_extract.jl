meta = Dict{(Int,Symbol), Float64}() # (carid, fsym) -> value
clearmeta() = empty!(meta)

function get(F::AbstractFeature, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	
	key = (carind, symbol(F))
	if haskey(meta, key)
		return meta[key]
	end

	value = _get(F, log, road, carind, frameind)::Float64
	@assert(!isnan(value))
	meta[key] = value
	value
end
function _get(F::AbstractFeature, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	warn(@sprintf("get not implemented for feature %s", string(symbol(F))))
	return 0.0
end

# NOTE(tim): get() is used for fast lookups
#            _get() is used for caching caluclations
function get(F::Features.Feature_PosFx, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	log[frameind, logindexbase(carind) + LOG_COL_X]
end
function get(F::Features.Feature_PosFy, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	log[frameind, logindexbase(carind) + LOG_COL_Y]
end
function get(F::Features.Feature_Yaw, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	log[frameind, logindexbase(carind) + LOG_COL_ϕ]
end
function get(F::Features.Feature_Speed, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	log[frameind, logindexbase(carind) + LOG_COL_V]
end
function get(F::Features.Feature_VelFx, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	base = logindexbase(carind)
	v = log[frameind, base + LOG_COL_V]
	ϕ = log[frameind, base + LOG_COL_ϕ]
	v * cos(ϕ)
end
function get(F::Features.Feature_VelFy, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	base = logindexbase(carind)
	v = log[frameind, base + LOG_COL_V]
	ϕ = log[frameind, base + LOG_COL_ϕ]
	v * sin(ϕ)
end

function _get(F::Features.Feature_CL, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	posFy = get(POSFY, log, road, carind, frameind)
	# generate the lane centerlines
	nlanes = road.nlanes
	lanewidth = road.lanewidth
	lane_centers = [0:(nlanes-1)].*lanewidth # [0,lw,2lw,...]
	float64(indmin(abs(lane_centers .- posFy)))
end
function _get(F::Features.Feature_D_CL, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	# y - cl_y
	lane = get(CL, log, road, carind, frameind)
	posFy = get(POSFY, log, road, carind, frameind)
	posFy - (lane-1)*road.lanewidth
end
function _get(F::Features.Feature_D_ML, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	d_cl = get(D_CL, log, road, carind, frameind)
	if abs(d_cl) > 0.5road.lanewidth && d_cl > 0.0
		return NA_ALIAS
	end
	0.5road.lanewidth - d_cl
end
function _get(F::Features.Feature_D_MR, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	d_cl = get(D_CL, log, road, carind, frameind)
	if abs(d_cl) > 0.5road.lanewidth && d_cl < 0.0
		return NA_ALIAS
	end
	0.5road.lanewidth + d_cl
end

function _get(F::Features.Feature_N_LANE_L, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	lane = get(CL, log, road, carind, frameind)
	float64(road.nlanes - lane)
end
function _get(F::Features.Feature_N_LANE_R, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	get(CL, log, road, carind, frameind) - 1.0
end
function _get(F::Features.Feature_TurnRate, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	if frameind <= 1
		return NA_ALIAS
	end

	indϕ = logindexbase(carind) + LOG_COL_ϕ
	curr = log[frameind, indϕ]
	past = log[frameind-1, indϕ]
	Features.deltaangle(curr, past) / SEC_PER_FRAME
end
function _get(F::Features.Feature_AccFx, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	if frameind <= 1
		return NA_ALIAS
	end

	curr = get(VELFX, log, road, carind, frameind)
	past = get(VELFX, log, road, carind, frameind-1)
	(curr - past) / SEC_PER_FRAME
end
function _get(F::Features.Feature_AccFy, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	if frameind <= 1
		return NA_ALIAS
	end

	curr = get(VELFY, log, road, carind, frameind)
	past = get(VELFY, log, road, carind, frameind-1)
	(curr - past) / SEC_PER_FRAME
end

function get(::Features.Feature_A_REQ_StayInLane, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
	velFy = get(VELFY, log, road, carind, frameind)
	d_mr = get(D_MR, log, road, carind, frameind)
	if d_mr > 0.0
		return -min(0.5velFy*velFy / d_mr, Features.THRESHOLD_A_REQ)
	end
	d_ml = get(D_ML, log, road, carind, frameind)
	d_ml > 0.0 ?  -min(0.5velFy*velFy / d_ml, Features.THRESHOLD_A_REQ) : NA_ALIAS
end


# FRONT
	function _get(F::Features.Feature_IndFront, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
		
		base = logindexbase(carind)
		mylane = get(CL, log, road, carind, frameind)
		myFx = log[frameind, base+LOG_COL_X]
		myFy = log[frameind, base+LOG_COL_Y]

		frontcar_ind = 0
		frontcar_dist = Inf
		for i = 1 : ncars(log)
			if i == carind
				continue
			end

			base2 = logindexbase(i)
			dy = abs(log[frameind, base2+LOG_COL_Y] - myFy)
			dlane = get(CL, log, road, i, frameind) - mylane
			if isapprox(dlane, 0.0) || dy < Features.THRESHOLD_DY_CONSIDERED_IN_FRONT
				dx = log[frameind, base2+LOG_COL_X] - myFx
				if 0 < dx < frontcar_dist
					frontcar_dist, frontcar_ind = dx, i
				end
			end
		end

		if frontcar_ind != 0
			@assert(frontcar_ind != carind)

			# compute extra stats
			myϕ  = log[frameind, base+LOG_COL_ϕ]
			myv  = log[frameind, base+LOG_COL_V]
			myVx = myv * cos(myϕ)
			myVy = myv * sin(myϕ)

			base2 = logindexbase(frontcar_ind)
			othϕ = log[frameind, base2+LOG_COL_ϕ]
			othv = log[frameind, base2+LOG_COL_V]
			othVx = othv * cos(othϕ)
			othVy = othv * sin(othϕ)

			meta[(carind, :d_x_front)] = frontcar_dist
			meta[(carind, :v_x_front)] = othVx - myVx
			meta[(carind, :v_y_front)] = othVy - myVy
			return float64(frontcar_ind)
		end

		meta[(carind, :d_x_front)] = Features.NA_ALIAS
		meta[(carind, :v_x_front)] = Features.NA_ALIAS
		meta[(carind, :v_y_front)] = Features.NA_ALIAS
		return Features.NA_ALIAS
	end
	function _get(F::Features.Feature_D_X_FRONT, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
		get(INDFRONT, log, road, carind, frameind)
		meta[(carind, :d_x_front)]
	end
	function _get(F::Features.Feature_V_X_FRONT, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
		get(INDFRONT, log, road, carind, frameind)
		meta[(carind, :v_x_front)]
	end
	function _get(F::Features.Feature_V_Y_FRONT, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
		get(INDFRONT, log, road, carind, frameind)
		meta[(carind, :v_y_front)]
	end

# REAR
	function _get(F::Features.Feature_IndRear, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
		
		base = logindexbase(carind)
		mylane = get(CL, log, road, carind, frameind)
		myFx = log[frameind, base+LOG_COL_X]
		myFy = log[frameind, base+LOG_COL_Y]

		rearcar_ind = 0
		rearcar_dist = Inf
		for i = 1 : ncars(log)
			if i == carind
				continue
			end

			base2 = logindexbase(i)
			dy = abs(log[frameind, base2+LOG_COL_Y] - myFy)
			dlane = get(CL, log, road, i, frameind) - mylane
			if isapprox(dlane, 0.0) || dy < Features.THRESHOLD_DY_CONSIDERED_IN_REAR
				dx = log[frameind, base2+LOG_COL_X] - myFx
				if rearcar_dist < dx < 0
					rearcar_dist, rearcar_ind = dx, i
				end
			end
		end

		if rearcar_ind != 0
			@assert(rearcar_ind != carind)

			# compute extra stats
			myϕ  = log[frameind, base+LOG_COL_ϕ]
			myv  = log[frameind, base+LOG_COL_V]
			myVx = myv * cos(myϕ)
			myVy = myv * sin(myϕ)

			base2 = logindexbase(rearcar_ind)
			othϕ = log[frameind, base2+LOG_COL_ϕ]
			othv = log[frameind, base2+LOG_COL_V]
			othVx = othv * cos(othϕ)
			othVy = othv * sin(othϕ)

			meta[(carind, :d_x_rear)] = abs(rearcar_dist)
			meta[(carind, :v_x_rear)] = othVx - myVx
			meta[(carind, :v_y_rear)] = othVy - myVy
			return float64(rearcar_ind)
		end

		meta[(carind, :d_x_rear)] = Features.NA_ALIAS
		meta[(carind, :v_x_rear)] = Features.NA_ALIAS
		meta[(carind, :v_y_rear)] = Features.NA_ALIAS
		return Features.NA_ALIAS
	end
	function _get(F::Features.Feature_D_X_REAR, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
		get(INDREAR, log, road, carind, frameind)
		meta[(carind, :d_x_rear)]
	end
	function _get(F::Features.Feature_V_X_REAR, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
		get(INDREAR, log, road, carind, frameind)
		meta[(carind, :v_x_rear)]
	end
	function _get(F::Features.Feature_V_Y_REAR, log::Matrix{Float64}, road::Roadway, carind::Int, frameind::Int)
		get(INDREAR, log, road, carind, frameind)
		meta[(carind, :v_y_rear)]
	end