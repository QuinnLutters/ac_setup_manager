-- F7/F11: plain-language glossary. Diagrams are lists of simple primitives in a
-- 0..1 box (x right, y down), drawn by src/ui/diagram.lua:
--   { 'car', x, y, angleDeg }          car body seen from above, nose = up at 0°
--   { 'arrow', x1, y1, x2, y2, color }  color: 'accent' | 'good' | 'bad' | 'muted'
--   { 'line', x1, y1, x2, y2, color }
--   { 'text', x, y, 'label', color }
--   { 'box', x1, y1, x2, y2, color }    filled rectangle

local M = {}

M.terms = {
  {
    id = 'slip_angle', term = 'Slip angle',
    short = 'The angle between where a tyre points and where it is actually moving.',
    body = 'Every tyre needs a little slip angle to make grip. Grip rises with slip angle up to a peak, then falls off. Past the peak the tyre is sliding, which is what a drifting rear tyre does on purpose and what a washing-out front tyre does by accident.',
    diagram = {
      { 'line', 0.5, 0.85, 0.5, 0.15, 'muted' }, { 'text', 0.53, 0.12, 'tyre points here', 'muted' },
      { 'arrow', 0.5, 0.85, 0.78, 0.2, 'accent' }, { 'text', 0.68, 0.3, 'tyre moves here', 'accent' },
      { 'text', 0.53, 0.55, 'slip angle', 'good' },
    },
  },
  {
    id = 'body_slip', term = 'Drift angle (body slip)',
    short = 'How far the whole car is pointing away from the direction it is travelling.',
    body = 'This is the angle the app measures to detect drifting. Above about 15° the app counts it as a drift; below about 8° the drift is over.',
    diagram = {
      { 'car', 0.5, 0.5, -35 }, { 'arrow', 0.5, 0.5, 0.5, 0.08, 'accent' },
      { 'text', 0.53, 0.1, 'travel', 'accent' }, { 'text', 0.12, 0.2, 'car points here', 'muted' },
    },
  },
  {
    id = 'side_bite', term = 'Side bite',
    short = 'How much sideways grip the rear tyres have while sliding.',
    body = 'More side bite makes the rear hold the slide and resist spinning, but too much makes the car straighten up. Softer rear bar and lower rear pressure add side bite; stiffer bar and higher pressure take it away.',
    diagram = {
      { 'car', 0.5, 0.5, -30 }, { 'arrow', 0.38, 0.72, 0.18, 0.62, 'good' }, { 'arrow', 0.58, 0.8, 0.38, 0.7, 'good' },
      { 'text', 0.05, 0.85, 'sideways grip at the rear', 'good' },
    },
  },
  {
    id = 'forward_bite', term = 'Forward bite',
    short = 'How well the rear tyres turn wheelspin into forward speed.',
    body = 'With good forward bite the car keeps pushing through the drift. Without it the rears spin, the car slows down and feels bogged. Lower rear pressure, softer rear springs and a shorter gear all add forward bite.',
    diagram = {
      { 'car', 0.5, 0.5, -25 }, { 'arrow', 0.5, 0.75, 0.62, 0.35, 'good' }, { 'text', 0.65, 0.4, 'push forward', 'good' },
    },
  },
  {
    id = 'lsd', term = 'Limited-slip differential (diff power and coast)',
    short = 'How strongly the two rear wheels are locked together.',
    body = 'Power is the lock on throttle, coast is the lock off throttle. A drift car wants both high so the rear wheels spin together and break traction predictably. An open diff spins one wheel and the car won\'t slide.',
    diagram = {
      { 'box', 0.15, 0.4, 0.3, 0.6, 'muted' }, { 'box', 0.7, 0.4, 0.85, 0.6, 'muted' },
      { 'line', 0.3, 0.5, 0.7, 0.5, 'accent' }, { 'box', 0.45, 0.43, 0.55, 0.57, 'accent' },
      { 'text', 0.38, 0.65, 'locked together', 'accent' },
    },
  },
  {
    id = 'arb', term = 'Anti-roll bar (ARB)',
    short = 'A bar linking left and right suspension that controls body roll.',
    body = 'A stiffer bar on one axle reduces grip on that axle at the limit. A stiffer rear bar makes the rear slide more easily; a softer rear bar adds side bite. A stiffer front bar sharpens transitions.',
  },
  {
    id = 'weight_transfer', term = 'Weight transfer',
    short = 'Load shifting between tyres when you brake, accelerate or turn.',
    body = 'In a transition the weight swings from one side to the other. If it swings too fast the car feels twitchy. Stiffer rebound damping and a stiffer front bar slow the swing down.',
    diagram = {
      { 'car', 0.5, 0.5, 0 }, { 'arrow', 0.35, 0.5, 0.1, 0.5, 'accent' }, { 'arrow', 0.65, 0.5, 0.9, 0.5, 'muted' },
      { 'text', 0.05, 0.6, 'load moves', 'accent' },
    },
  },
  {
    id = 'steering_lock', term = 'Steering lock',
    short = 'The maximum angle the front wheels can turn.',
    body = 'Drift cars need a lot of lock to catch big angle. If you hit full lock while the car is still rotating, you run out of room and spin. Lock is only adjustable when the car exposes it as a setup item; otherwise it\'s a limit of the car.',
    diagram = {
      { 'line', 0.3, 0.3, 0.3, 0.7, 'muted' }, { 'line', 0.7, 0.3, 0.7, 0.7, 'muted' },
      { 'arrow', 0.3, 0.5, 0.12, 0.28, 'accent' }, { 'arrow', 0.7, 0.5, 0.52, 0.28, 'accent' },
      { 'text', 0.3, 0.8, 'front wheels at full lock', 'accent' },
    },
  },
  {
    id = 'countersteer', term = 'Countersteer (opposite lock)',
    short = 'Steering away from the corner to control a slide.',
    body = 'In a drift you steer in the direction the rear is sliding. If the rear keeps rotating while you\'re already at opposite lock, the car is about to spin.',
  },
  {
    id = 'power_band', term = 'Power band',
    short = 'The rev range where the engine makes most of its power.',
    body = 'Below the power band the engine can\'t keep the rears spinning and the car bogs down. A shorter gear (higher final drive ratio) keeps the revs up.',
    diagram = {
      { 'line', 0.1, 0.85, 0.3, 0.6, 'muted' }, { 'line', 0.3, 0.6, 0.6, 0.25, 'accent' },
      { 'line', 0.6, 0.25, 0.85, 0.3, 'accent' }, { 'line', 0.85, 0.3, 0.92, 0.5, 'muted' },
      { 'text', 0.42, 0.12, 'power band', 'accent' }, { 'text', 0.05, 0.92, 'rpm →', 'muted' },
    },
  },
  {
    id = 'pressure_window', term = 'Pressure window',
    short = 'The hot tyre pressure range where a tyre grips best.',
    body = 'Tyre pressure rises as tyres heat up. The app compares the hot pressure during your run with the car\'s ideal value and adjusts the cold pressure you set in the pits.',
    diagram = {
      { 'box', 0.1, 0.45, 0.9, 0.55, 'muted' }, { 'box', 0.4, 0.42, 0.6, 0.58, 'good' },
      { 'text', 0.38, 0.3, 'ideal window', 'good' }, { 'text', 0.08, 0.65, 'too low', 'bad' }, { 'text', 0.75, 0.65, 'too high', 'bad' },
    },
  },
  {
    id = 'suspension_travel', term = 'Suspension travel and bottoming',
    short = 'How far the suspension can compress before it hits the stops.',
    body = 'When the suspension runs out of travel the tyre load spikes and the car bounces or snaps. Stiffer springs or a higher ride height keep it off the stops.',
  },
  {
    id = 'brake_bias', term = 'Brake bias',
    short = 'How braking force is split between the front and rear.',
    body = 'More front bias makes a dab of brake mid-drift pull the nose in and add angle. Chase drivers use it to tighten up behind the lead car.',
  },
  {
    id = 'camber', term = 'Camber',
    short = 'The tilt of the wheel seen from the front.',
    body = 'Negative camber tilts the top of the wheel inwards. Drift cars run a lot of front negative camber so the front tyre stays flat at big steering angles, and little rear camber for forward bite.',
  },
  {
    id = 'toe', term = 'Toe',
    short = 'Whether the wheels point slightly in or out, seen from above.',
    body = 'A little front toe-out makes the car turn in more eagerly and gives the front more angle. Too much makes it nervous in a straight line.',
  },
  {
    id = 'damping', term = 'Bump and rebound damping',
    short = 'How fast the suspension compresses (bump) and extends (rebound).',
    body = 'Stiffer rebound slows how quickly the body rises again, which calms weight transfer in transitions.',
  },
}

local byId = {}
for _, t in ipairs(M.terms) do byId[t.id] = t end

function M.get(id) return byId[id] end

return M
