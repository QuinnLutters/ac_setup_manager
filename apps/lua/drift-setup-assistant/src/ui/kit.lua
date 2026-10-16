-- Small widget kit over CSP's immediate-mode ui.* API. Keeps the screens
-- readable and puts every "does this build have X" check in one place.

local K = {}

K.C = {
  text = rgbm(0.95, 0.95, 0.95, 1),
  muted = rgbm(0.62, 0.64, 0.68, 1),
  accent = rgbm(1.0, 0.62, 0.2, 1),
  good = rgbm(0.42, 0.85, 0.48, 1),
  bad = rgbm(0.96, 0.38, 0.33, 1),
  warn = rgbm(0.98, 0.8, 0.3, 1),
  info = rgbm(0.48, 0.72, 1.0, 1),
  panel = rgbm(1, 1, 1, 0.05),
  rec = rgbm(0.95, 0.2, 0.2, 1),
}

local function has(fn) return ui[fn] ~= nil end

function K.width()
  if has('availableSpaceX') then return ui.availableSpaceX() end
  if has('windowWidth') then return ui.windowWidth() - 20 end
  return 400
end

function K.font(name, fn)
  local f = ui.Font and ui.Font[name]
  if f and has('pushFont') then
    ui.pushFont(f); fn(); ui.popFont()
  else
    fn()
  end
end

function K.title(s) K.font('Title', function() ui.text(s) end) end
function K.small(s) K.font('Small', function() K.muted(s) end) end
function K.text(s) ui.text(s) end

function K.colored(s, color)
  if has('textColored') then ui.textColored(s, color) else ui.text(s) end
end

function K.wrap(s, color)
  if color and has('pushStyleColor') and ui.StyleColor then
    ui.pushStyleColor(ui.StyleColor.Text, color)
    ui.textWrapped(s)
    ui.popStyleColor()
  else
    ui.textWrapped(s)
  end
end

function K.muted(s) K.wrap(s, K.C.muted) end

function K.heading(s)
  K.gap(4)
  K.colored(s, K.C.accent)
end

function K.label(name, value, color)
  K.colored(name, K.C.muted)
  ui.sameLine(0, 6)
  if color then K.colored(value, color) else ui.text(value) end
end

function K.bullet(s, color)
  if has('bullet') then ui.bullet(); ui.sameLine() end
  if color then K.wrap(s, color) else ui.textWrapped(s) end
end

function K.gap(px)
  if has('offsetCursorY') then ui.offsetCursorY(px or 6) else ui.text('') end
end

function K.sep()
  K.gap(2)
  ui.separator()
  K.gap(2)
end

function K.button(label, w, h)
  if w or h then return ui.button(label, vec2(w or 0, h or 0)) end
  return ui.button(label)
end

-- Highlighted call-to-action button.
function K.primary(label, w, h)
  local pushed = 0
  if has('pushStyleColor') and ui.StyleColor then
    ui.pushStyleColor(ui.StyleColor.Button, rgbm(0.85, 0.45, 0.1, 1))
    ui.pushStyleColor(ui.StyleColor.ButtonHovered, rgbm(0.95, 0.55, 0.15, 1))
    pushed = 2
  end
  local clicked = K.button(label, w, h)
  if pushed > 0 then ui.popStyleColor(pushed) end
  return clicked
end

function K.disabledButton(label, w, h, why)
  if has('pushStyleColor') and ui.StyleColor then
    ui.pushStyleColor(ui.StyleColor.Button, rgbm(0.3, 0.3, 0.3, 0.6))
    ui.pushStyleColor(ui.StyleColor.ButtonHovered, rgbm(0.3, 0.3, 0.3, 0.6))
    ui.pushStyleColor(ui.StyleColor.ButtonActive, rgbm(0.3, 0.3, 0.3, 0.6))
    K.button(label, w, h)
    ui.popStyleColor(3)
  else
    K.button(label, w, h)
  end
  K.tooltip(why)
end

function K.tooltip(s)
  if s and has('itemHovered') and ui.itemHovered() and has('setTooltip') then ui.setTooltip(s) end
end

function K.checkbox(label, value)
  if ui.checkbox(label, value) then return not value end
  return value
end

-- A row of buttons acting as a single choice. Returns the (possibly new) value.
function K.choice(options, current, width)
  local w = width or 0
  for i, o in ipairs(options) do
    if i > 1 then ui.sameLine(0, 4) end
    if o.id == current then
      K.primary(o.label, w)
    elseif K.button(o.label, w) then
      current = o.id
    end
  end
  return current
end

function K.bar(fraction, w, h, overlay, color)
  fraction = math.max(0, math.min(1, fraction or 0))
  if has('progressBar') and not color then
    ui.progressBar(fraction, vec2(w or K.width(), h or 6), overlay or '')
    return
  end
  local p = ui.getCursor()
  w, h = w or K.width(), h or 6
  ui.drawRectFilled(p, p + vec2(w, h), rgbm(1, 1, 1, 0.1))
  ui.drawRectFilled(p, p + vec2(w * fraction, h), color or K.C.accent)
  ui.dummy(vec2(w, h))
end

-- Simple two-column key/value table.
function K.table(rows, col)
  col = col or 190
  for _, r in ipairs(rows) do
    K.colored(r[1], K.C.muted)
    ui.sameLine(col)
    if r[3] then K.colored(r[2], r[3]) else ui.text(r[2]) end
  end
end

-- Draws children inside a padded, tinted panel.
function K.panel(id, fn)
  if has('beginGroup') then
    ui.beginGroup()
    fn()
    ui.endGroup()
  else
    fn()
  end
end

function K.tabs(id, tabs, selected)
  ui.tabBar(id, function()
    for _, t in ipairs(tabs) do
      local flags = (selected == t.id and ui.TabItemFlags) and ui.TabItemFlags.SetSelected or nil
      if flags then ui.tabItem(t.label, flags, t.fn) else ui.tabItem(t.label, t.fn) end
    end
  end)
end

function K.pct(x) return string.format('%d%%', math.floor((x or 0) * 100 + 0.5)) end

return K
