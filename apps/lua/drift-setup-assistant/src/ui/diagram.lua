-- Draws the glossary's short diagrams (see src/core/glossary.lua for primitives).

local K = require('src/ui/kit')

local M = {}

local function color(name)
  return K.C[name or 'muted'] or K.C.muted
end

local function arrowHead(a, b, c, size)
  local d = b - a
  local len = math.sqrt(d.x * d.x + d.y * d.y)
  if len < 1 then return end
  local ux, uy = d.x / len, d.y / len
  local left = vec2(b.x - ux * size - uy * size * 0.6, b.y - uy * size + ux * size * 0.6)
  local right = vec2(b.x - ux * size + uy * size * 0.6, b.y - uy * size - ux * size * 0.6)
  if ui.drawTriangleFilled then ui.drawTriangleFilled(b, left, right, c) end
end

local function car(origin, size, x, y, angleDeg)
  local cx, cy = origin.x + x * size.x, origin.y + y * size.y
  local hw, hh = size.x * 0.08, size.y * 0.2
  local a = math.rad(angleDeg or 0)
  local cs, sn = math.cos(a), math.sin(a)
  local function rot(px, py) return vec2(cx + px * cs - py * sn, cy + px * sn + py * cs) end
  local p1, p2, p3, p4 = rot(-hw, -hh), rot(hw, -hh), rot(hw, hh), rot(-hw, hh)
  local body = rgbm(0.85, 0.85, 0.9, 0.9)
  if ui.drawQuadFilled then
    ui.drawQuadFilled(p1, p2, p3, p4, body)
  else
    ui.drawLine(p1, p2, body, 2); ui.drawLine(p2, p3, body, 2); ui.drawLine(p3, p4, body, 2); ui.drawLine(p4, p1, body, 2)
  end
  -- Nose marker so the direction is obvious.
  local n1, n2 = rot(-hw * 0.6, -hh * 0.8), rot(hw * 0.6, -hh * 0.8)
  ui.drawLine(n1, n2, K.C.accent, 3)
end

function M.draw(prims, height)
  if not prims or not ui.getCursor or not ui.drawLine then return end
  local w = math.min(K.width(), 340)
  local h = height or 150
  local origin = ui.getCursor()
  local size = vec2(w, h)
  ui.drawRectFilled(origin, origin + size, rgbm(1, 1, 1, 0.04))
  local function p(x, y) return vec2(origin.x + x * w, origin.y + y * h) end
  for _, prim in ipairs(prims) do
    local kind = prim[1]
    if kind == 'car' then
      car(origin, size, prim[2], prim[3], prim[4])
    elseif kind == 'arrow' then
      local a, b, c = p(prim[2], prim[3]), p(prim[4], prim[5]), color(prim[6])
      ui.drawLine(a, b, c, 2.5)
      arrowHead(a, b, c, 9)
    elseif kind == 'line' then
      ui.drawLine(p(prim[2], prim[3]), p(prim[4], prim[5]), color(prim[6]), 2)
    elseif kind == 'box' then
      ui.drawRectFilled(p(prim[2], prim[3]), p(prim[4], prim[5]), color(prim[6]))
    end
  end
  -- Text last, positioned with the cursor so it uses the normal font.
  for _, prim in ipairs(prims) do
    if prim[1] == 'text' and ui.setCursor then
      ui.setCursor(p(prim[2], prim[3]))
      K.colored(prim[4], color(prim[5]))
    end
  end
  if ui.setCursor then ui.setCursor(origin) end
  ui.dummy(size)
end

return M
