local _, ns = ...

ns.MinimapProjection = {
	Diameters = {
		indoor = { [0] = 300, 240, 180, 120, 80, 50 },
		outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
	},
}

function ns.MinimapProjection.Project(dx, dn, cosF, sinF, scale, limit, square)
	local sx = (dx * cosF + dn * sinF) * scale
	local sy = (-dx * sinF + dn * cosF) * scale
	if square then
		if math.abs(sx) <= limit and math.abs(sy) <= limit then return sx, sy end
	elseif sx * sx + sy * sy <= limit * limit then
		return sx, sy
	end
end
