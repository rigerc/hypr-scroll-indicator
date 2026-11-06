-- Run from the repo root: lua .github/scripts/test_widget.lua
-- Deterministic host simulation: animation frames must never spawn Hyprland queries.
local function fixture(config, globalAnimations, speed)
  local f = { now = 0, queries = 0, visible = false, vertical = false }
  f.data = {
    { name = '10', tiledLayout = 'scrolling' }, { address = 'b' }, {
      { address = 'a', at = {0, 0}, workspace = {name = '10'}, mapped = true },
      { address = 'b', at = {100, 0}, workspace = {name = '10'}, mapped = true },
    },
  }
  local env = setmetatable({}, { __index = _G })
  env.noctalia = {
    getConfig = function(key) return config[key] end,
    getSetting = function(key)
      if key == 'shell.animation.enabled' then return globalAnimations ~= false end
      if key == 'shell.animation.speed' then return speed or 1 end
      error('unexpected setting: ' .. key)
    end,
    nowMs = function() return f.now end,
    setUpdateInterval = function(ms) f.interval = ms end,
    commandExists = function() return true end,
    log = function() end,
    runStream = function(_, callback) f.event = callback end,
    runAsync = function(_, callback)
      f.queries = f.queries + 1
      callback({exitCode = 0, stdout = 'fixture'})
    end,
    json = { decode = function() return f.data end },
    openSettings = function() f.opened = true end,
  }
  env.barWidget = {
    isVertical = function() return f.vertical end,
    setVisible = function(v) f.visible = v end,
    setTooltip = function(t) f.tooltip = t end,
    render = function(t) f.tree = t end,
  }
  env.ui = {}
  for _, kind in ipairs({'row', 'column', 'box', 'button'}) do
    env.ui[kind] = function(props, children) return {kind = kind, props = props, children = children} end
  end
  assert(loadfile('scroll-indicator/widget.luau', 't', env))()
  function f.tick(ms) f.now = ms; env.update() end
  function f.focus(address, ms)
    f.now = ms; f.data[2] = { address = address }; f.event('activewindowv2>>' .. address)
  end
  function f.hoverLayer()
    return f.tree.props.key == 'alignment-frame' and f.tree.children[1] or f.tree
  end
  function f.content() return f.hoverLayer().children[1] end
  function f.hoverCells() return f.hoverLayer().children[2].children end
  function f.hoverTargets()
    local targets = {}
    for _, cell in ipairs(f.hoverCells()) do table.insert(targets, cell.children[2]) end
    return targets
  end
  function f.hoverCover(index) return f.hoverCells()[index].children[1].children[1] end
  function f.hover(state, id) env.onSegmentHover(state, id) end
  function f.markers()
    local content = f.content()
    return content.props.key == 'slide-stack' and content.children[1].children or content.children
  end
  function f.overlay() return f.content().children[2] end
  function f.foreground(index)
    local children = f.markers()[index].children
    return children[1].props.key == 'background' and children[2] or children[1]
  end
  function f.weight(index) return f.foreground(index).props.opacity end
  return f
end

local function near(a, b) assert(math.abs(a - b) < 0.000001, tostring(a) .. ' ~= ' .. tostring(b)) end
local function settle(f, budget)
  local deadline = f.now + (budget or 1800)
  repeat f.tick(f.now + 16) until f.interval > 16 or f.now >= deadline
  assert(f.interval > 16, 'animation did not settle')
end
local function valid(node)
  if node.props.opacity then assert(node.props.opacity >= 0 and node.props.opacity <= 1) end
  if node.props.width then assert(node.props.width >= 0) end
  if node.props.height then assert(node.props.height >= 0) end
  for _, child in ipairs(node.children or {}) do valid(child) end
end

local f = fixture({})
f.tick(0)
assert(f.visible and f.interval == 16 and f.queries == 1)
near(f.markers()[1].props.opacity, 0)
f.tick(90); near(f.markers()[1].props.opacity, 0.875)
f.tick(180); near(f.markers()[1].props.opacity, 1)
assert(f.interval > 16 and f.queries == 1)
f.focus('a', 200); near(f.weight(1), 0); near(f.weight(2), 1)
f.tick(245)
local partial = f.weight(1)
assert(partial > 0 and partial < 1)
-- Reverse while the first transition is still moving, without jumping.
f.focus('b', 245); near(f.weight(1), partial)
f.tick(290); assert(f.weight(1) < partial)
f.tick(425); near(f.weight(1), 0); near(f.weight(2), 1)
assert(f.interval > 16 and f.queries == 3)
-- Scrolling shifts every x coordinate. Existing markers must keep their transition state.
f.data[3][1].at[1] = -100; f.data[3][2].at[1] = 0
f.focus('b', 450)
near(f.markers()[1].props.opacity, 1); near(f.markers()[2].props.opacity, 1)
assert(f.markers()[1].props.key == 'a' and f.markers()[2].props.key == 'b')
-- New columns fade independently, and removed columns are pruned.
f.data[3][3] = { address = 'c', at = {100, 0}, workspace = {name = '10'}, mapped = true }
f.focus('b', 500)
near(f.markers()[1].props.opacity, 1); near(f.markers()[3].props.opacity, 0)
f.tick(680); near(f.markers()[3].props.opacity, 1)
table.remove(f.data[3], 3); f.focus('b', 700); assert(#f.markers() == 2)
-- Animation ticks do not replace the safety poll or increase query frequency.
local before = f.queries
f.tick(2699); assert(f.queries == before)
f.tick(2700); assert(f.queries == before + 1)
-- Floating focus fades every highlight out.
f.focus('floating', 2720); f.tick(2900)
near(f.weight(1), 0); near(f.weight(2), 0)
assert(f.tooltip:find('no tiled app focused', 1, true))
f.data[1].tiledLayout = 'dwindle'; f.focus('b', 3000)
assert(not f.visible and f.interval > 16)
f.data[1].tiledLayout = 'scrolling'; f.focus('b', 3100)
near(f.markers()[1].props.opacity, 0)
f.tick(3280); f.data[3] = {}; f.focus('b', 3300); assert(not f.visible)

-- Either animation switch restores immediate updates and idle polling.
for _, spec in ipairs({ {config = {animations = false}}, {config = {}, global = false} }) do
  f = fixture(spec.config, spec.global)
  f.tick(0); assert(f.interval == 2000); near(f.markers()[1].props.opacity, 1)
  f.focus('a', 10); near(f.weight(1), 1); near(f.weight(2), 0)
  assert(f.interval == 2000)
end
-- Global speed scales the configured duration, for both orientations and styles.
for _, vertical in ipairs({false, true}) do
  for _, style in ipairs({'dots', 'line'}) do
    f = fixture({style = style, animation_duration = 400, alignment = 'bottom', alignment_size = 40,
      edge_inset = 3, line_gap = 2, line_radius = 10, inactive_opacity = 0.4,
      dot_shape = 'square', fill_inactive_dots = true,
      use_theme_colors = false, focused_color = '#123456', inactive_color = '#abcdef'}, true, 2)
    f.vertical = vertical; f.tick(0); f.tick(200)
    assert(f.tree.kind == (vertical and 'row' or 'column') and f.tree.props.justify == 'end')
    assert((vertical and f.tree.props.width or f.tree.props.height) == 40)
    assert((vertical and f.tree.props.paddingH or f.tree.props.paddingV) == 3)
    near(f.markers()[1].props.opacity, 0.4); near(f.markers()[2].props.opacity, 1)
    assert(f.markers()[1].props.fill == '#abcdef')
    assert(f.markers()[2].children[1].props.fill == '#123456')
    assert(f.markers()[1].props.radius == (style == 'dots' and 0 or 1.5))
    f.focus('a', 210); f.tick(310); near(f.weight(1), 0.875)
    f.tick(410); near(f.weight(1), 1); assert(f.interval > 16 and f.queries == 2)
  end
end
-- Curve presets have distinct timing and exact endpoints, with no opacity overshoot.
local curves = {linear = 0.5, ease_in = 0.25, ease_out = 0.875,
  ease_in_out = 0.5, exponential_out = 0.96875}
for curve, midpoint in pairs(curves) do
  for _, mode in ipairs({'crossfade', 'grow', 'wipe'}) do
    f = fixture({animation_style = mode, animation_curve = curve, animation_duration = 200})
    f.tick(0); f.tick(100); near(f.markers()[1].props.opacity, midpoint)
    f.tick(200); near(f.markers()[1].props.opacity, 1)
    f.focus('a', 210); f.tick(310); near(f.weight(1), midpoint)
    local highlight = f.markers()[1].children[1].props
    if mode == 'grow' then
      near(highlight.width, 8 * (0.2 + 0.8 * midpoint))
      near(highlight.height, highlight.width)
      assert(f.markers()[1].props.justify == 'center')
    elseif mode == 'wipe' then near(highlight.width, 8 * midpoint); near(highlight.height, 8) end
    f.tick(410); near(f.weight(1), 1); assert(f.interval > 16 and f.queries == 2)
  end
end
-- A single overlay physically travels along the marker track in either bar orientation.
for _, vertical in ipairs({false, true}) do
  for _, style in ipairs({'dots', 'line'}) do
    for curve, midpoint in pairs(curves) do
      local config = {animation_style = 'slide', animation_curve = curve, animation_duration = 200,
        style = style, line_gap = 3, alignment = 'top'}
      f = fixture(config); f.vertical = vertical; f.tick(0); f.tick(200)
      local stride = style == 'line' and 23 or 14
      local markerSize = style == 'line' and 20 or 8
      local axis = vertical and 'height' or 'width'
      local function offset() return f.overlay().children[1].props[axis] end
      near(offset(), stride)
      -- Native Flex overlap leaves the track size unchanged, rather than adding a second row.
      near(f.content().props.gap, -(stride + markerSize))
      near(f.overlay().props[axis], stride + markerSize)
      near(f.overlay().children[2].props[axis], markerSize)
      f.focus('a', 210); near(offset(), stride)
      f.tick(310); near(offset(), stride * (1 - midpoint))
      local partial = offset()
      f.focus('b', 310); near(offset(), partial)
      f.tick(410); near(offset(), partial + (stride - partial) * midpoint)
      f.tick(510); near(offset(), stride); assert(f.interval > 16 and f.queries == 3)
      f.focus('floating', 520); f.tick(620); near(f.overlay().props.opacity, 1 - midpoint)
      f.tick(720); near(f.overlay().props.opacity, 0)
      f.focus('a', 730); near(offset(), 0)
      f.tick(930); near(f.overlay().props.opacity, 1)
      -- Removing the focused column keeps the rendered highlight and its spacers in bounds.
      f.focus('b', 940); f.tick(1040)
      table.remove(f.data[3], 2); f.focus('a', 1040)
      assert(offset() >= 0 and offset() <= 0)
      for _, child in ipairs(f.overlay().children) do assert(child.props[axis] >= 0) end
      f.tick(1240); near(offset(), 0); assert(f.interval > 16)
      f.data[1].tiledLayout = 'dwindle'; f.focus('a', 1250); assert(not f.visible)
    end
  end
end
-- Disabling animation also makes Slide/Grow/Wipe immediate; stored effect preference stays intact.
for _, mode in ipairs({'slide', 'grow', 'wipe'}) do
  f = fixture({animation_style = mode, animations = false})
  f.tick(0); f.focus('a', 10); assert(f.interval == 2000)
  if mode == 'slide' then
    near(f.overlay().children[1].props.width, 0); near(f.overlay().props.opacity, 1)
  else near(f.weight(1), 1); near(f.markers()[1].children[1].props.width, 8) end
end
-- Fluid Slide retains momentum, stretches in flight, and compresses against the track ends.
for _, vertical in ipairs({false, true}) do
  for _, style in ipairs({'dots', 'line'}) do
    f = fixture({animation_style = 'slide', animation_curve = 'bouncy', animation_duration = 200, style = style})
    f.vertical = vertical; f.data[2] = {address = 'a'}
    f.data[3][3] = {address = 'c', at = {200, 0}, workspace = {name = '10'}, mapped = true}
    local stride = style == 'line' and 20 or 14
    local length = style == 'line' and 20 or 8
    local total = 2 * stride + length
    local axis = vertical and 'height' or 'width'
    local function extent() return f.overlay().children[2].props[axis] end
    local function offset() return f.overlay().children[1].props[axis] end
    local function center() return offset() + extent() / 2 end
    f.tick(0); settle(f); near(offset(), 0); near(extent(), length)
    local start = f.now + 10; f.focus('b', start)
    f.tick(start + 40); local before = center()
    f.tick(start + 41); local at = center()
    local beforeVelocity = at - before
    assert(beforeVelocity > 0 and extent() > length)
    f.focus('a', start + 41); near(center(), at) -- Position does not jump at retarget.
    f.tick(start + 42)
    local afterVelocity = center() - at
    assert(afterVelocity > 0, 'momentum must continue briefly through a reversal')
    assert(math.abs(afterVelocity - beforeVelocity) < 0.02, 'velocity must remain continuous')
    settle(f); near(offset(), 0); near(extent(), length)
    start = f.now + 10; f.focus('c', start)
    local widest, narrowest = length, length
    for ms = start + 8, start + 600, 8 do
      f.tick(ms); widest = math.max(widest, extent()); narrowest = math.min(narrowest, extent())
      assert(offset() >= 0 and offset() + extent() <= total + 0.000001)
      valid(f.tree)
    end
    settle(f); near(offset(), 2 * stride); near(extent(), length)
    assert(widest > length * 1.05 and narrowest < length * 0.99)
    assert(f.queries == 4, 'frames must not query Hyprland')
    f.focus('floating', f.now + 10); settle(f); near(f.overlay().props.opacity, 0)
    f.focus('a', f.now + 10); near(offset(), 0); settle(f)
    near(f.overlay().props.opacity, 1)
    table.remove(f.data[3], 3); f.event('closewindow>>c'); settle(f)
    valid(f.tree)
  end
end
-- A no-stretch setting retains a fixed-sized highlight, with the same spring motion.
f = fixture({animation_style = 'slide', animation_curve = 'bouncy', animation_duration = 200, slide_fluidity = 0})
f.tick(0); settle(f); f.focus('a', f.now + 10)
for _ = 1, 40 do f.tick(f.now + 16); near(f.overlay().children[2].props.width, 8) end
settle(f)
-- The analytic spring follows the same trajectory at different frame cadences.
local dense = fixture({animation_style = 'slide', animation_curve = 'bouncy', animation_duration = 200})
local sparse = fixture({animation_style = 'slide', animation_curve = 'bouncy', animation_duration = 200})
dense.tick(0); sparse.tick(0); dense.tick(1000); sparse.tick(1000)
dense.focus('a', 1010); sparse.focus('a', 1010)
for ms = 1015, 1110, 5 do dense.tick(ms) end
sparse.tick(1110)
near(dense.overlay().children[1].props.width, sparse.overlay().children[1].props.width)
near(dense.overlay().children[2].props.width, sparse.overlay().children[2].props.width)
for _, mode in ipairs({'crossfade', 'grow', 'wipe'}) do
  f = fixture({animation_style = mode, animation_curve = 'bouncy', animation_duration = 200})
  f.tick(0); settle(f); f.focus('a', f.now + 10)
  local overshot = false
  for _ = 1, 50 do
    f.tick(f.now + 8); valid(f.tree)
    if mode == 'grow' and f.foreground(1).props.width > 8 then overshot = true end
    if mode == 'wipe' then assert(f.foreground(1).props.width <= 8) end
  end
  if mode == 'grow' then assert(overshot) end
  settle(f); near(f.weight(1), 1); near(f.weight(2), 0); assert(f.queries == 2)
end
-- Hover fades in and out without snapping or starting subprocesses.
f = fixture({animation_duration = 200})
f.tick(0); settle(f); local beforeQueries = f.queries
f.hover('true', 'a'); near(f.hoverCover(1).props.opacity, 0)
f.tick(f.now + 16); assert(f.hoverCover(1).props.opacity > 0 and f.hoverCover(1).props.opacity < 0.18)
settle(f); near(f.hoverCover(1).props.opacity, 0.18)
f.hover('false', 'a'); near(f.hoverCover(1).props.opacity, 0.18)
settle(f); near(f.hoverCover(1).props.opacity, 0); assert(f.queries == beforeQueries)
-- Native per-segment hover targets stay above every animation layer, with current window titles.
for _, vertical in ipairs({false, true}) do
  for _, style in ipairs({'dots', 'line'}) do
    for _, mode in ipairs({'crossfade', 'slide', 'grow', 'wipe'}) do
      f = fixture({style = style, animation_style = mode, animations = false, inactive_opacity = 0.3})
      f.vertical = vertical
      f.data[3][1].title = '  Editor — main.lua  '
      f.data[3][2].title = ''; f.data[3][2].class = 'Terminal'
      f.tick(0)
      assert(f.hoverLayer().props.key == 'hover-stack')
      local target = f.hoverTargets()[1]
      assert(target.kind == 'button' and target.props.variant == 'ghost')
      assert(target.props.onHover == 'onSegmentHover' and target.props.onRightClick == 'onRightClick')
      assert(target.props.tooltip == 'Editor — main.lua\nColumn 1 of 2')
      assert(f.hoverTargets()[2].props.tooltip == 'Terminal\nColumn 2 of 2')
      local length = style == 'line' and 20 or 8
      local thickness = style == 'line' and 3 or 8
      assert(target.props.width == (vertical and thickness or length))
      assert(target.props.height == (vertical and length or thickness))
      local before = f.queries
      near(f.markers()[1].props.opacity, 0.3)
      f.hover('true', 'a'); near(f.markers()[1].props.opacity, 1)
      f.hover('true', 'b'); f.hover('false', 'a') -- Ignore a stale leave.
      f.data[2] = {address = 'floating'}; f.event('activewindowv2>>floating')
      near(f.markers()[2].props.opacity, 1)
      f.hover('false', 'b'); near(f.markers()[2].props.opacity, 0.3)
      assert(f.queries == before + 1) -- Only the socket event queried; hovering never did.
      f.hover('true', 'a')
      -- Stacked windows share a tooltip in stable address order, regardless of client ordering.
      f.data[3][3] = {address = 'c', at = {0, 50}, workspace = {name = '10'}, mapped = true,
        title = 'Browser\nProject'}
      f.event('openwindow>>c')
      assert(f.hoverTargets()[1].props.tooltip == 'Editor — main.lua\nBrowser Project\nColumn 1 of 2')
      f.data[3][1], f.data[3][3] = f.data[3][3], f.data[3][1]
      f.event('windowtitlev2>>a,renamed')
      assert(f.hoverTargets()[1].props.tooltip == 'Editor — main.lua\nBrowser Project\nColumn 1 of 2')
      f.data[3][3].title = 'Renamed editor'; before = f.queries
      f.event('windowtitlev2>>a,Renamed editor')
      assert(f.queries == before + 1 and f.hoverTargets()[1].props.tooltip:find('Renamed editor', 1, true))
      f.data[3][2].class = ''; f.event('windowtitlev2>>b,')
      assert(f.hoverTargets()[2].props.tooltip == 'Untitled window\nColumn 2 of 2')
      -- Remove the hovered column, then reuse its address: no hover state may leak.
      f.data[3] = {f.data[3][2]}; f.event('closewindow>>a')
      assert(#f.hoverTargets() == 1)
      f.data[3][2] = {address = 'a', at = {0, 0}, workspace = {name = '10'}, mapped = true}
      f.event('openwindow>>a'); near(f.markers()[1].props.opacity, 0.3)
    end
  end
end
-- Cover paint is configurable independently from the native tooltip hit area.
for _, vertical in ipairs({false, true}) do
  for _, style in ipairs({'dots', 'line'}) do
    local config = {animations = false, style = style, hover_use_theme_color = false,
      hover_color = '#ff8800', hover_opacity = 0.65, hover_coverage = 60,
      hover_thickness = 16, hover_radius = 3, alignment = 'bottom', alignment_size = 8, edge_inset = 20}
    f = fixture(config); f.vertical = vertical; f.tick(0)
    local main = style == 'line' and 20 or 8
    local cover = f.hoverCover(1).props
    near(cover.opacity, 0); assert(cover.fill == '#ff8800')
    near(cover.width, vertical and 16 or main * 0.6)
    near(cover.height, vertical and main * 0.6 or 16)
    near(cover.radius, math.min(3, main * 0.3))
    local target = f.hoverTargets()[1].props
    assert(target.opacity == 0 and target.tooltip ~= '')
    near(target.width, vertical and 16 or main); near(target.height, vertical and main or 16)
    assert((vertical and f.tree.props.width or f.tree.props.height) == 16)
    assert((vertical and f.tree.props.paddingH or f.tree.props.paddingV) == 0)
    f.hover('true', 'a'); near(f.hoverCover(1).props.opacity, 0.65)
    f.hover('false', 'a'); near(f.hoverCover(1).props.opacity, 0)
    config.hover_opacity = 0; f.hover('true', 'b')
    near(f.hoverCover(2).props.opacity, 0); assert(f.hoverTargets()[2].props.tooltip ~= '')
    assert(f.queries == 1)
  end
end
-- Fine tuning changes the curve while retaining exact endpoints and bounded progress.
for _, spec in ipairs({
  {curve = 'ease_in', curve_power = 6, midpoint = 0.0625},
  {curve = 'ease_out', curve_power = 6, midpoint = 0.984375},
  {curve = 'ease_in_out', curve_power = 6, midpoint = 0.5},
  {curve = 'exponential_out', curve_exponential = 2, midpoint = 2 / 3},
  {curve = 'custom', curve_x1 = 0, curve_y1 = 0, curve_x2 = 1, curve_y2 = 1, midpoint = 0.5},
}) do
  local config = {animation_duration = 200, animation_curve = spec.curve}
  for key, value in pairs(spec) do if key:find('curve_', 1, true) == 1 then config[key] = value end end
  f = fixture(config); f.tick(0); near(f.markers()[1].props.opacity, 0)
  f.tick(100); near(f.markers()[1].props.opacity, spec.midpoint)
  f.tick(200); near(f.markers()[1].props.opacity, 1)
  f.focus('a', 210); f.tick(310); near(f.weight(1), spec.midpoint)
  f.tick(410); near(f.weight(1), 1); assert(f.interval > 16 and f.queries == 2)
end
local peaks = {}
for _, depth in ipairs({0, 0.5, 1, 2}) do
  f = fixture({animation_style = 'grow', animation_duration = 200,
    animation_curve = 'bouncy', curve_bounce_strength = depth})
  f.tick(0); settle(f); f.focus('a', f.now + 10)
  local peak = 0
  for _ = 1, 60 do
    f.tick(f.now + 8); peak = math.max(peak, f.foreground(1).props.width); valid(f.tree)
  end
  settle(f); near(f.foreground(1).props.width, 8)
  table.insert(peaks, peak)
end
assert(peaks[1] <= 8 and peaks[2] > peaks[1] and peaks[3] > peaks[2] and peaks[4] > peaks[3])
local function bezierMid(x1, x2)
  f = fixture({animation_duration = 200, animation_curve = 'custom',
    curve_x1 = x1, curve_y1 = 0.1, curve_x2 = x2, curve_y2 = 0.8})
  f.tick(0); f.tick(100); return f.markers()[1].props.opacity
end
assert(bezierMid(0.1, 0.2) > bezierMid(0.8, 0.9)) -- Both X controls must affect time mapping.
-- Outer ends have rounded caps; internal ends remain square, including a single-column line.
for _, vertical in ipairs({false, true}) do
  for _, mode in ipairs({'crossfade', 'slide', 'grow', 'wipe'}) do
    f = fixture({animations = false, style = 'line', animation_style = mode,
      segment_length = 20, line_thickness = 10, line_radius = 0, outer_radius = 8})
    f.vertical = vertical
    f.data[3][3] = {address = 'c', at = {200, 0}, workspace = {name = '10'}, mapped = true}
    f.tick(0)
    local function radii(shape)
      local result = {}
      for _, band in ipairs(shape.children) do result[band.props.key] = band.children[2].props.radius end
      return result
    end
    local first = radii(f.markers()[1].children[1])
    local middle = radii(f.markers()[2].children[1])
    local last = radii(f.markers()[3].children[1])
    assert(first['start-cap'] == 5 and not first['end-cap'] and first.middle == 0)
    assert(not middle['start-cap'] and not middle['end-cap'] and middle.middle == 0)
    assert(last['end-cap'] == 5 and not last['start-cap'] and last.middle == 0)
    local mainAxis = vertical and 'height' or 'width'
    near(f.markers()[1].children[1].props[mainAxis], 20)
    f.data[3] = {f.data[3][1]}; f.focus('a', 10)
    local single = radii(f.markers()[1].children[1])
    assert(single['start-cap'] == 5 and single['end-cap'] == 5)
    if mode == 'slide' then
      local highlight = radii(f.overlay().children[2])
      assert(highlight['start-cap'] == 5 and highlight['end-cap'] == 5)
    end
    near(f.foreground(1).props.width, vertical and 10 or 20)
    assert(f.hoverTargets()[1].props.tooltip ~= '')
  end
end
-- Global and local animation switches bypass all spring state immediately.
for _, preferences in ipairs({{animations = false}, {global = false}}) do
  f = fixture({animation_style = 'slide', animation_curve = 'bouncy', animations = preferences.animations}, preferences.global)
  f.tick(0); f.focus('a', 10)
  near(f.overlay().children[1].props.width, 0); near(f.overlay().children[2].props.width, 8)
  near(f.overlay().props.opacity, 1); assert(f.interval == 2000)
  f.hover('true', 'a'); near(f.hoverCover(1).props.opacity, 0.18)
  assert(f.interval == 2000 and f.queries == 2)
end
print('Widget tests passed: animation styles and curves, slide geometry, interruption, stable columns, preferences, timing, query budget, styling and orientations')
