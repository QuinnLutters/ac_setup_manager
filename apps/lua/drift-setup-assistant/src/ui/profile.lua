-- F2: driver profile. Four questions, editable later from the settings window.

local K = require('src/ui/kit')

local M = {}

M.QUESTIONS = {
  { key = 'experience', q = 'How much have you drifted in sims?', options = {
    { id = 'beginner', label = 'New to it' }, { id = 'intermediate', label = 'Can link corners' },
    { id = 'experienced', label = 'Comfortable' } } },
  { key = 'device', q = 'What do you drive with?', options = {
    { id = 'wheel', label = 'Wheel' }, { id = 'controller', label = 'Controller' } } },
  { key = 'style', q = 'How do you drift?', options = {
    { id = 'solo', label = 'Solo' }, { id = 'lead', label = 'Lead' }, { id = 'chase', label = 'Chase' } } },
  { key = 'goal', q = 'What do you want from the car?', options = {
    { id = 'angle', label = 'More angle' }, { id = 'stability', label = 'More stability' },
    { id = 'speed', label = 'More speed' } } },
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
  if firstRun then
    K.title('Welcome to Drift Setup Assistant')
    K.muted('Four quick questions so the advice fits you. You can change these later in the settings.')
    K.gap(6)
  end
  for i, q in ipairs(M.QUESTIONS) do
    K.colored(i .. '. ' .. q.q, K.C.text)
    draft[q.key] = K.choice(q.options, draft[q.key], 120)
    K.gap(6)
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
    K.disabledButton(firstRun and 'Start' or 'Save profile', 160, 28, 'Answer all four questions first.')
  end
  return false
end

return M
