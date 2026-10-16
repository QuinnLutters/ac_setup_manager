-- F2: driver profile. Three questions, editable later from the settings window.
-- The input device is read from the game's settings instead of asked.

local K = require('src/ui/kit')

local M = {}

M.QUESTIONS = {
  { key = 'experience', q = 'How much have you drifted in sims?', options = {
    { id = 'beginner', label = 'New to it' }, { id = 'intermediate', label = 'Can link corners' },
    { id = 'experienced', label = 'Comfortable' } } },
  -- Only asked when the input method can't be read from the game's controls.ini.
  { key = 'device', detected = true, q = 'What do you drive with?', options = {
    { id = 'wheel', label = 'Wheel' }, { id = 'controller', label = 'Controller' },
    { id = 'keyboard', label = 'Keyboard' } } },
  { key = 'style', q = 'How do you drift?', options = {
    { id = 'solo', label = 'Solo' }, { id = 'lead', label = 'Lead' }, { id = 'chase', label = 'Chase' } } },
  { key = 'goal', q = 'What do you want from the car?', perRow = 4, options = {
    { id = 'angle', label = 'More angle' }, { id = 'stability', label = 'More stability' },
    { id = 'speed', label = 'More speed' }, { id = 'entries', label = 'Easier entries' },
    { id = 'transitions', label = 'Smoother transitions' }, { id = 'consistency', label = 'More consistency' },
    { id = 'forgiving', label = 'More forgiving' } } },
}

local draft

function M.complete(p)
  if not p then return false end
  for _, q in ipairs(M.QUESTIONS) do if not p[q.key] then return false end end
  return true
end

function M.label(key, id)
  for _, q in ipairs(M.QUESTIONS) do
    if q.key == key then
      for _, o in ipairs(q.options) do if o.id == id then return o.label end end
    end
  end
  return id or '—'
end

-- Draws the questionnaire. Returns true once saved.
function M.draw(app, firstRun)
  draft = draft or {}
  if app.profile and not draft._loaded then
    for k, v in pairs(app.profile) do draft[k] = v end
    draft._loaded = true
  end
  local detected = app.detectedDevice
  if detected then draft.device = detected end
  local questions = {}
  for _, q in ipairs(M.QUESTIONS) do
    if not (q.detected and detected) then questions[#questions + 1] = q end
  end
  if firstRun then
    K.title('Welcome to Drift Setup Assistant')
    K.muted(string.format('%s quick questions so the advice fits you. You can change these later in the settings.',
      #questions == 3 and 'Three' or 'Four'))
    K.gap(6)
  end
  for i, q in ipairs(questions) do
    K.colored(i .. '. ' .. q.q, K.C.text)
    -- Long option lists wrap onto several rows of buttons.
    local per = q.perRow or #q.options
    for first = 1, #q.options, per do
      local row = {}
      for j = first, math.min(first + per - 1, #q.options) do row[#row + 1] = q.options[j] end
      draft[q.key] = K.choice(row, draft[q.key], 140)
    end
    K.gap(6)
  end
  if detected then
    K.small('Input device: ' .. M.label('device', detected) .. ' (read from your Assetto Corsa controls settings).')
    K.gap(4)
  end
  local p = {}
  for _, q in ipairs(M.QUESTIONS) do p[q.key] = draft[q.key] end
  if M.complete(p) then
    if K.primary(firstRun and 'Start' or 'Save profile', 160, 28) then
      app:saveProfile(p)
      draft = nil
      return true
    end
  else
    K.disabledButton(firstRun and 'Start' or 'Save profile', 160, 28, 'Answer every question first.')
  end
  return false
end

return M
