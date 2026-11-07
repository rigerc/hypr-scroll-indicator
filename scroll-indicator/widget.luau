--!nonstrict
-- Scroll indicator: one marker per column in Hyprland's scrolling layout,
-- rendered as dots or a continuous line. Hidden on every other layout.
-- Idea from jtams/waybar-hyprland-scroll-indicator (Go/Waybar); independent Luau implementation.

-- One shell call returns [activeworkspace, activewindow, clients] as a JSON array.
local QUERY = { "sh", "-c",
  "printf '['; hyprctl -j activeworkspace; printf ','; hyprctl -j activewindow; printf ','; hyprctl -j clients; printf ']'" }

-- Hyprland event socket, so the dots update the moment focus changes.
local EVENTS = "socat -U - UNIX-CONNECT:\"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock\""

local busy = false
local pending = false
local streaming = false

local snapshot = nil
local workspaceName = nil
local markerStates = {}
local previousColumns = {}
local slideState = nil
local slideLayoutId, slideLayoutPosition = nil, nil
local hoveredId = nil
local hoverStates = {}
local animating = false
local lastPollMs = -math.huge
local curveOptions = {}

-- Negative gaps center ink even when it is wider than its layout slot. Native Flex
-- clamps justify="center" at zero overflow, so a plain centered row would shift it.
local function inkCell(key, main, cross, inkMain, vertical, ink)
  local container = vertical and ui.column or ui.row
  local function halfSlot(key)
    return ui.box({ key = key, width = vertical and cross or main / 2,
      height = vertical and main / 2 or cross, fill = "surface/0" })
  end
  return container({ key = key, width = vertical and cross or main,
    height = vertical and main or cross, gap = -inkMain / 2, align = "center" }, {
    halfSlot("before"), ink, halfSlot("after"),
  })
end

local function pollInterval()
  return streaming and 2000 or 400
end

local function schedule(now)
  noctalia.setUpdateInterval(animating and 16 or math.max(16, pollInterval() - (now - lastPollMs)))
end

local function hide()
  snapshot = nil
  workspaceName = nil
  markerStates = {}
  previousColumns = {}
  slideState = nil
  slideLayoutId, slideLayoutPosition = nil, nil
  hoveredId = nil
  hoverStates = {}
  animating = false
  barWidget.setVisible(false)
  schedule(noctalia.nowMs())
end

local function ease(t, curve)
  if t == 0 or t == 1 then return t end
  if curve == "custom" then
    local function bezier(u, a, b)
      return 3 * (1 - u) ^ 2 * u * a + 3 * (1 - u) * u ^ 2 * b + u ^ 3
    end
    -- Solve the time coordinate; using t directly as the parameter would ignore X1/X2.
    local lo, hi = 0, 1
    for _ = 1, 24 do
      local mid = (lo + hi) / 2
      if bezier(mid, curveOptions.x1, curveOptions.x2) < t then lo = mid else hi = mid end
    end
    return bezier((lo + hi) / 2, curveOptions.y1, curveOptions.y2)
  end
  if curve == "linear" then return t end
  if curve == "ease_in" then return t ^ (curveOptions.power * 2 / 3) end
  if curve == "ease_in_out" then
    return t < 0.5 and (2 * t) ^ curveOptions.power / 2
      or 1 - (2 * (1 - t)) ^ curveOptions.power / 2
  end
  if curve == "exponential_out" then
    -- Preserve the existing preset at strength 10; normalize other strengths to reach one smoothly.
    local rate = curveOptions.exponential
    local value = 1 - 2 ^ (-rate * t)
    return rate == 10 and value or value / (1 - 2 ^ (-rate))
  end
  return 1 - (1 - t) ^ curveOptions.power
end

-- Exact damped-spring solution: elapsed wall time drives the motion, and retargets preserve
-- both position and velocity. There is no fixed step, start-of-curve kick, or reflected velocity.
local function springTo(state, target, now, duration, damping, tolerance)
  if not state then state = { value = target, velocity = 0, target = target, time = now } end
  if duration == 0 then
    state.value, state.velocity, state.target, state.time = target, 0, target, now
    return state, false
  end
  local dt = math.max(0, (now - state.time) / 1000)
  if state.omega and dt > 0 then
    local omega, zeta = state.omega, state.damping
    local displacement, velocity = state.value - state.target, state.velocity
    local decay = math.exp(-zeta * omega * dt)
    if zeta >= 1 then
      local coefficient = velocity + omega * displacement
      state.value = state.target + (displacement + coefficient * dt) * decay
      state.velocity = (velocity - omega * coefficient * dt) * decay
    else
      local frequency = omega * math.sqrt(1 - zeta * zeta)
      local sine, cosine = math.sin(frequency * dt), math.cos(frequency * dt)
      local coefficient = (velocity + zeta * omega * displacement) / frequency
      local wave = displacement * cosine + coefficient * sine
      state.value = state.target + decay * wave
      state.velocity = decay * (-zeta * omega * wave
        + frequency * (coefficient * cosine - displacement * sine))
    end
  end
  state.target, state.time = target, now
  state.omega, state.damping = 5 / (duration / 1000), damping
  local settled = math.abs(state.value - target) < tolerance
    and math.abs(state.velocity) < tolerance / (duration / 1000)
  if settled then state.value, state.velocity = target, 0 end
  return state, not settled
end

local function newSpring(value, now)
  return { value = value, velocity = 0, target = value, time = now }
end

local function springDamping()
  return 1 / (1 + 0.47 * curveOptions.bounce)
end

-- Evaluate before retargeting so rapid focus changes continue from the visible state.
local function sample(state, now, duration, curve)
  local t = math.max(0, math.min(1, (now - state.startedAt) / duration))
  local eased = ease(t, curve)
  return state.fromFocus + (state.target - state.fromFocus) * eased,
    math.max(0, math.min(1, state.fromPresence + ((state.presenceTarget or 1) - state.fromPresence) * eased)), t < 1
end

local function transition(id, target, now, duration, curve, presenceTarget)
  presenceTarget = presenceTarget == nil and 1 or presenceTarget
  local state = markerStates[id]
  if curve == "bouncy" and duration > 0 then
    if not state or not state.physical then
      state = { physical = true, focus = newSpring(target, now), presence = newSpring(0, now) }
    end
    local focusRunning, presenceRunning
    state.focus, focusRunning = springTo(state.focus, target, now, duration, springDamping(), 0.001)
    state.presence, presenceRunning = springTo(state.presence, presenceTarget, now, duration * 0.7, 1, 0.001)
    markerStates[id] = state
    if focusRunning or presenceRunning then animating = true end
    return state.focus.value, math.max(0, math.min(1, state.presence.value))
  end
  if state and state.physical then state = nil end
  if duration == 0 then
    markerStates[id] = { fromFocus = target, target = target, fromPresence = presenceTarget,
      presenceTarget = presenceTarget, startedAt = now }
    return target, presenceTarget
  end
  if not state then
    state = { fromFocus = target, target = target, fromPresence = 0, presenceTarget = presenceTarget, startedAt = now }
  elseif state.target ~= target or state.presenceTarget ~= presenceTarget then
    local focus, presence = sample(state, now, duration, curve)
    state = { fromFocus = focus, target = target, fromPresence = presence,
      presenceTarget = presenceTarget, startedAt = now }
  end
  markerStates[id] = state
  local focus, presence, running = sample(state, now, duration, curve)
  if running and (state.fromFocus ~= state.target or state.fromPresence ~= presenceTarget) then
    animating = true
  end
  return focus, presence
end

local function fluidSlide(position, now, duration, maxPosition, markerLength, fluidity)
  local state = slideState
  local alphaTarget = position and 1 or 0
  if not state or not state.physical then
    local origin = position or 0
    state = { physical = true, startEdge = newSpring(origin, now),
      endEdge = newSpring(origin + markerLength, now), alpha = newSpring(0, now),
      destination = origin, direction = 1 }
  end
  local destination = position or state.destination
  if destination ~= state.destination then
    state.direction = destination > state.destination and 1 or -1
    if state.alpha.value == 0 and state.alpha.velocity == 0 then
      state.startEdge = newSpring(destination, now)
      state.endEdge = newSpring(destination + markerLength, now)
    end
  end
  local fast, slow = duration * (1 - 0.2 * fluidity), duration * (1 + 0.35 * fluidity)
  local startRunning, endRunning, alphaRunning
  state.startEdge, startRunning = springTo(state.startEdge, destination, now,
    state.direction > 0 and slow or fast, springDamping(), 0.01)
  state.endEdge, endRunning = springTo(state.endEdge, destination + markerLength, now,
    state.direction > 0 and fast or slow, springDamping(), 0.01)
  state.alpha, alphaRunning = springTo(state.alpha, alphaTarget, now, duration * 0.6, 1, 0.001)
  state.destination = destination
  slideState = state
  if startRunning or endRunning or alphaRunning then animating = true end
  local total = maxPosition + markerLength
  local first = math.max(0, math.min(total, state.startEdge.value))
  local last = math.max(0, math.min(total, state.endEdge.value))
  -- An edge compresses against the end of the track. Its spring retains momentum underneath,
  -- so the rebound releases naturally instead of reversing position at the boundary.
  local extent = fluidity == 0 and markerLength
    or math.max(markerLength * 0.45, math.min(total, last - first))
  local offset = math.max(0, math.min(total - extent, (first + last - extent) / 2))
  return offset, math.max(0, math.min(1, state.alpha.value)), extent
end

local function slide(position, now, duration, curve, maxPosition, markerLength, fluidity)
  if curve == "bouncy" and duration > 0 then
    return fluidSlide(position, now, duration, maxPosition, markerLength, fluidity)
  end
  if slideState and slideState.physical then slideState = nil end
  local targetOpacity = position and 1 or 0
  local state = slideState
  if not state or duration == 0 then
    state = { fromPosition = position or 0, targetPosition = position or 0,
      fromOpacity = duration == 0 and targetOpacity or 0,
      targetOpacity = targetOpacity, startedAt = now }
  end
  local function sampleSlide()
    local t = duration == 0 and 1 or math.max(0, math.min(1, (now - state.startedAt) / duration))
    local weight = ease(t, curve)
    local result = state.fromPosition + (state.targetPosition - state.fromPosition) * weight
    -- The non-spring presets stay within their start/end values; constrain after track resizes.
    result = math.max(0, math.min(maxPosition, result))
    return result, math.max(0, math.min(1,
      state.fromOpacity + (state.targetOpacity - state.fromOpacity) * weight)), t < 1
  end
  local currentPosition, opacity = sampleSlide()
  local targetPosition = position or state.targetPosition
  if targetPosition ~= state.targetPosition or targetOpacity ~= state.targetOpacity then
    -- An invisible highlight can reappear at the new column without travelling from an old workspace.
    state = { fromPosition = opacity == 0 and targetPosition or currentPosition,
      targetPosition = targetPosition, fromOpacity = opacity,
      targetOpacity = targetOpacity, startedAt = now }
  end
  slideState = state
  local result, alpha, running = sampleSlide()
  if running and (state.fromPosition ~= state.targetPosition or state.fromOpacity ~= state.targetOpacity) then
    animating = true
  end
  return result, alpha, markerLength
end

-- A union of two rounded caps and a straight middle gives independent end radii.
-- Each layer has the same extent; negative Flex gaps place them at the same origin.
local function lineShape(key, width, height, color, startRadius, endRadius, vertical)
  local main, cross = vertical and height or width, vertical and width or height
  local first = math.min(startRadius, main / 2, cross / 2)
  local last = math.min(endRadius, main / 2, cross / 2)
  local container = vertical and ui.column or ui.row
  local layers = {}
  local function band(name, offset, size, radius)
    local function box(k, extent, fill, rounding)
      return ui.box({ key = k, width = vertical and cross or extent,
        height = vertical and extent or cross, fill = fill, radius = rounding or 0 })
    end
    table.insert(layers, container({ key = name, gap = 0, width = width, height = height }, {
      box("before", offset, "surface/0"), box("paint", size, color, radius),
      box("after", math.max(0, main - offset - size), "surface/0"),
    }))
  end
  if first > 0 then band("start-cap", 0, 2 * first, first) end
  band("middle", first, math.max(0, main - first - last), 0)
  if last > 0 then band("end-cap", main - 2 * last, 2 * last, last) end
  return container({ key = key, width = width, height = height, gap = -main }, layers)
end

local function show(ws, active, clients)
  if not ws or ws.tiledLayout ~= "scrolling" then
    hide()
    return
  end

  -- Tiled, visible windows on this workspace; windows stacked in one column share an x.
  local xs, seen, columnIds, windows = {}, {}, {}, {}
  local activeX = nil
  for _, c in ipairs(clients or {}) do
    -- Hyprland 0.56 identifies workspaces by address/name (no numeric id in clients JSON)
    if c.workspace and c.workspace.name == ws.name and not c.floating and c.mapped and not c.hidden then
      local x = c.at and c.at[1] or 0
      if not seen[x] then
        seen[x] = true
        table.insert(xs, x)
      end
      if not windows[x] then windows[x] = {} end
      table.insert(windows[x], c)
      -- Addresses survive scrolling offsets; x coordinates do not. Pick a stable representative
      -- for stacked windows independently of the order of Hyprland's clients array.
      local id = c.address or tostring(x)
      if not columnIds[x] or id < columnIds[x] then
        columnIds[x] = id
      end
      if active and c.address == active.address then
        activeX = x
      end
    end
  end
  table.sort(xs)

  if #xs == 0 and (#previousColumns == 0 or workspaceName ~= ws.name) then
    hide()
    return
  end

  snapshot = { ws, active, clients }
  if workspaceName ~= ws.name then
    markerStates = {}
    previousColumns = {}
    slideState = nil
    slideLayoutId, slideLayoutPosition = nil, nil
    hoveredId = nil
    hoverStates = {}
    workspaceName = ws.name
  end
  local now = noctalia.nowMs()
  local duration = 0
  if noctalia.getConfig("animations") ~= false and noctalia.getSetting("shell.animation.enabled") ~= false then
    local speed = math.max(0.1, noctalia.getSetting("shell.animation.speed") or 1)
    duration = (noctalia.getConfig("animation_duration") or 180) / speed
  end
  local animationStyle = noctalia.getConfig("animation_style") or "crossfade"
  local curve = noctalia.getConfig("animation_curve") or "ease_out"
  curveOptions = {
    power = noctalia.getConfig("curve_power") or 3,
    exponential = noctalia.getConfig("curve_exponential") or 10,
    bounce = noctalia.getConfig("curve_bounce_strength") or 1,
    x1 = noctalia.getConfig("curve_x1") or 0.25, y1 = noctalia.getConfig("curve_y1") or 0.1,
    x2 = noctalia.getConfig("curve_x2") or 0.25, y2 = noctalia.getConfig("curve_y2") or 1,
  }
  animating = false
  local liveIds = {}
  local style = noctalia.getConfig("style") or "dots"
  local vertical = barWidget.isVertical()
  local themeColors = noctalia.getConfig("use_theme_colors") ~= false
  local focusedColor = themeColors and "primary" or noctalia.getConfig("focused_color")
  local inactiveColor = themeColors and "on_surface_variant" or noctalia.getConfig("inactive_color")
  local dotSize = noctalia.getConfig("dot_size") or 8
  local spacing = noctalia.getConfig("dot_spacing") or 6
  local length = noctalia.getConfig("segment_length") or 20
  local thickness = noctalia.getConfig("line_thickness") or 3
  local alignment = noctalia.getConfig("alignment") or "center"
  local alignmentSize = noctalia.getConfig("alignment_size") or 34
  local edgeInset = noctalia.getConfig("edge_inset") or 2
  local lineGap = noctalia.getConfig("line_gap") or 0
  local lineRadius = noctalia.getConfig("line_radius") or 0
  local fluidity = noctalia.getConfig("slide_fluidity") or 0.65
  local dotShape = noctalia.getConfig("dot_shape") or "round"
  local fillInactive = noctalia.getConfig("fill_inactive_dots") == true
  local inactiveOpacity = noctalia.getConfig("inactive_opacity") or 1
  local outerRadius = noctalia.getConfig("outer_radius") or 0
  local hoverColor = noctalia.getConfig("hover_use_theme_color") ~= false and "on_surface"
    or noctalia.getConfig("hover_color")
  local hoverOpacity = noctalia.getConfig("hover_opacity") or 0.18
  if noctalia.getConfig("hover_highlight") == false then hoverOpacity = 0 end
  local hoverCoverage = (noctalia.getConfig("hover_coverage") or 100) / 100
  local hoverThickness = noctalia.getConfig("hover_thickness") or 0
  local hoverRadius = noctalia.getConfig("hover_radius") or 4
  local activeScale = math.max(0.5, math.min(4, (noctalia.getConfig("active_scale") or 100) / 100))
  local hoverScale = math.max(0.5, math.min(4, (noctalia.getConfig("hover_scale") or 100) / 100))
  -- Keep normal segment spacing; reserve only cross-axis room for scaled ink.
  local maxScale = math.max(1, activeScale, hoverScale)
  local baseMain = style == "line" and length or dotSize
  local baseCross = style == "line" and thickness or dotSize
  local slotMain, slotCross = baseMain, math.max(baseCross, hoverThickness) * maxScale
  local scaling = activeScale ~= 1 or hoverScale ~= 1
  -- Match by any surviving window so closing the representative of a stack does not
  -- animate a column away while other windows in that column are still open.
  local columns, currentIds = {}, {}
  for i, x in ipairs(xs) do
    local id = columnIds[x]
    for _, old in ipairs(previousColumns) do
      for _, window in ipairs(windows[x]) do
        for _, oldWindow in ipairs(old.windows) do
          if window.address == oldWindow.address then id = old.id end
        end
      end
    end
    currentIds[id] = true
    table.insert(columns, { id = id, windows = windows[x], focused = x == activeX, index = i })
  end
  -- Leave departing columns in their previous order until their presence reaches zero.
  for i, old in ipairs(previousColumns) do
    if not currentIds[old.id] and duration > 0 then
      table.insert(columns, math.min(i, #columns + 1), { id = old.id, windows = old.windows, exiting = true })
    end
  end
  if hoveredId and not currentIds[hoveredId] then hoveredId = nil end
  local markers, hoverTargets, idx = {}, {}, nil
  local retained, positions, presences = {}, {}, {}
  for _, column in ipairs(columns) do
    column.focus, column.presence = transition(column.id,
      animationStyle ~= "slide" and column.focused and 1 or 0,
      now, duration, curve, column.exiting and 0 or 1)
    if not column.exiting or column.presence > 0 then table.insert(retained, column) end
  end
  columns = retained
  local gap = style == "line" and lineGap or spacing
  local total, activePosition, activeId, precedingPresence = 0, nil, nil, 0
  for i, column in ipairs(columns) do
    local focused, id = column.focused, column.id
    liveIds[id] = true
    local focus, presence = column.focus, column.presence
    local cellMain = slotMain * presence
    local cellGap = gap * presence * math.min(1, precedingPresence)
    precedingPresence = precedingPresence + presence
    total = total + cellGap
    if focused then idx = column.index; activePosition = total; activeId = id end
    positions[i], presences[i] = total, presence
    total = total + cellMain
    local hover, hoverRunning
    hoverStates[id], hoverRunning = springTo(hoverStates[id] or newSpring(0, now),
      hoveredId == id and 1 or 0, now, duration > 0 and math.max(60, duration * 0.5) or 0, 1, 0.001)
    hover = math.max(0, math.min(1, hoverStates[id].value))
    if hoverRunning then animating = true end
    local focusAlpha = math.max(0, math.min(1, focus))
    local motionFocus = math.max(0, focus)
    local hoverFactor = 1 + (hoverScale - 1) * hover
    local activeFactor = 1 + (activeScale - 1) * focusAlpha
    -- Focus is painted by the travelling overlay in Slide mode.
    local scale = focusAlpha > 0 and hover > 0 and math.max(activeFactor, hoverFactor)
      or (focusAlpha > 0 and activeFactor or hoverFactor)
    local width = style == "line" and (vertical and thickness or length) or dotSize
    local height = style == "line" and (vertical and length or thickness) or dotSize
    width, height = width * scale * presence, height * scale * presence
    local radius = style == "line" and math.min(lineRadius, thickness / 2, length / 2)
      or (dotShape == "square" and 0 or dotSize / 2)
    radius = radius * scale * presence
    local focusWidth, focusHeight = width, height
    if duration > 0 and animationStyle == "grow" then
      focusWidth, focusHeight = width * (0.2 + 0.8 * motionFocus), height * (0.2 + 0.8 * motionFocus)
    elseif duration > 0 and animationStyle == "wipe" then
      focusWidth = vertical and width or width * focusAlpha
      focusHeight = vertical and height * focusAlpha or height
    end
    -- Two layers blend semantic theme colors directly, without resolving or hardcoding the palette.
    local marker = ui.row({
      key = id, width = width, height = height, radius = radius,
      align = animationStyle == "grow" and "center" or "start",
      justify = animationStyle == "grow" and "center" or "start",
      fill = (style == "line" or fillInactive) and inactiveColor or "surface/0",
      border = style == "dots" and inactiveColor or nil,
      borderWidth = style == "dots" and 1 or 0,
      opacity = presence * (inactiveOpacity + (1 - inactiveOpacity) * math.max(hover, focusAlpha)),
    }, {
      ui.box({
        key = "focus", width = focusWidth, height = focusHeight,
        radius = math.min(radius, focusWidth / 2, focusHeight / 2),
        fill = focusedColor, border = style == "dots" and focusedColor or nil,
        borderWidth = style == "dots" and 1 or 0, opacity = focusAlpha,
      }),
    })
    if style == "line" and outerRadius > 0 then
      local startRadius = (i == 1 and outerRadius or lineRadius) * scale
      local endRadius = (i == #columns and outerRadius or lineRadius) * scale
      local background = lineShape("background", width, height, inactiveColor, startRadius, endRadius, vertical)
      local foreground = ui.row({ key = "focus", width = width, height = height, opacity = focusAlpha,
        align = animationStyle == "grow" and "center" or "start",
        justify = animationStyle == "grow" and "center" or "start" }, {
        lineShape("paint", focusWidth, focusHeight, focusedColor, startRadius, endRadius, vertical),
      })
      marker = ui.row({ key = id, width = width, height = height, gap = -width,
        opacity = presence * (inactiveOpacity + (1 - inactiveOpacity) * math.max(hover, focusAlpha)),
      }, { background, foreground })
    end
    local container = vertical and ui.column or ui.row
    marker = container({ key = id .. ":layout", gap = 0, align = "center" }, {
      ui.box({ key = "gap", width = vertical and slotCross or cellGap,
        height = vertical and cellGap or slotCross, fill = "surface/0" }),
      inkCell(id .. ":cell", cellMain, slotCross, vertical and height or width, vertical, marker),
    })
    table.insert(markers, marker)
    table.sort(column.windows, function(a, b) return (a.address or "") < (b.address or "") end)
    local titles = {}
    for _, window in ipairs(column.windows) do
      local title = (window.title or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
      if title == "" then title = (window.class or ""):match("^%s*(.-)%s*$") end
      table.insert(titles, title ~= "" and title or "Untitled window")
    end
    local cross = hoverThickness > 0 and hoverThickness * scale * presence or (vertical and width or height)
    local main = vertical and height or width
    local cellCross = scaling and slotCross or cross
    local cellWidth, cellHeight = vertical and cellCross or cellMain, vertical and cellMain or cellCross
    local container = vertical and ui.column or ui.row
    -- Transparent native buttons retain tooltips and hit testing; a separate paint layer gives
    -- full control over the cover instead of inheriting the button's opaque hover chrome.
    local hoverCell = container({ key = id .. ":hover-cell", gap = -cellMain,
      width = cellWidth, height = cellHeight }, {
      inkCell("cover-frame", cellMain, cellCross, main * hoverCoverage, vertical,
        ui.box({ key = "cover", fill = hoverColor,
          width = vertical and cross or main * hoverCoverage,
          height = vertical and main * hoverCoverage or cross,
          radius = math.min(hoverRadius * scale, main * hoverCoverage / 2, cross / 2),
          opacity = hover * hoverOpacity })),
      ui.button({ key = id, text = "", variant = "ghost", width = cellWidth, height = cellHeight,
        opacity = 0,
        tooltip = table.concat(titles, "\n") .. string.format("\nColumn %d of %d", column.index or 0, #xs),
        enabled = not column.exiting, onHover = "onSegmentHover", onRightClick = "onRightClick" }),
    })
    table.insert(hoverTargets, container({ key = id .. ":hover-layout", gap = 0, align = "center" }, {
      ui.box({ key = "gap", width = vertical and cellCross or cellGap,
        height = vertical and cellGap or cellCross, fill = "surface/0" }), hoverCell,
    }))
  end

  previousColumns = retained
  if #xs == 0 and #retained == 0 then hide(); return end
  for id in pairs(markerStates) do
    if not liveIds[id] then
      markerStates[id] = nil
      hoverStates[id] = nil
    end
  end
  local container = vertical and ui.column or ui.row
  local content = container({ gap = 0, align = "center" }, markers)
  if animationStyle == "slide" then
    local markerLength = slotMain
    local crossSize = scaling and slotCross or baseCross
    local gap = style == "line" and lineGap or spacing
    -- Emptying tracks can become smaller than one slot during the final exit.
    local trackLength = math.max(markerLength, total)
    -- Reflow moves the track underneath the highlight. Translate its motion state with
    -- the focused column rather than repeatedly restarting a focus transition.
    if slideState and activeId and slideLayoutId == activeId and slideLayoutPosition then
      local delta = activePosition - slideLayoutPosition
      if slideState.physical then
        for _, edge in ipairs({slideState.startEdge, slideState.endEdge}) do
          edge.value, edge.target = edge.value + delta, edge.target + delta
        end
        slideState.destination = slideState.destination + delta
      else
        slideState.fromPosition = slideState.fromPosition + delta
        slideState.targetPosition = slideState.targetPosition + delta
      end
    end
    slideLayoutId, slideLayoutPosition = activeId, activePosition
    local offset, opacity, highlightLength = slide(activePosition,
      now, duration, curve, trackLength - markerLength, markerLength, fluidity)
    highlightLength = math.min(total, highlightLength)
    offset = math.max(0, math.min(total - highlightLength, offset))
    local function spacer(key, size)
      return ui.box({ key = key, width = vertical and crossSize or size,
        height = vertical and size or crossSize, fill = "surface/0" })
    end
    -- Keep the travelling cell on the same track as the markers, and center its scaled ink.
    local hover = 0
    local entryPresence = 1
    for i, column in ipairs(columns) do
      local distance = math.abs(offset - positions[i])
      local weight = math.max(0, 1 - distance / (markerLength + gap))
      local state = hoverStates[column.id]
      hover = math.max(hover, weight * (state and math.max(0, math.min(1, state.value)) or 0))
      if distance < slotMain * presences[i] then entryPresence = presences[i] end
    end
    local scale = hover > 0 and math.max(activeScale, 1 + (hoverScale - 1) * hover) or activeScale
    local inkLength = highlightLength / markerLength * baseMain * scale
    local inkCross = baseCross * scale * entryPresence
    local highlight = ui.box({ key = "highlight", width = vertical and inkCross or inkLength,
      height = vertical and inkLength or inkCross, fill = focusedColor,
      radius = style == "line" and math.min(lineRadius * scale, inkCross / 2, inkLength / 2)
        or (dotShape == "square" and 0 or math.min(inkCross / 2, inkLength / 2)) })
    if style == "line" and outerRadius > 0 then
      highlight = lineShape("highlight", vertical and inkCross or inkLength,
        vertical and inkLength or inkCross, focusedColor,
        math.max(lineRadius, outerRadius - offset) * scale,
        math.max(lineRadius, outerRadius - (total - highlightLength - offset)) * scale, vertical)
    end
    if scaling or inkCross ~= crossSize then
      highlight = inkCell("highlight-cell", highlightLength, crossSize, inkLength, vertical, highlight)
    end
    local overlay = container({ key = "sliding-highlight", gap = 0, opacity = opacity,
      width = vertical and crossSize or total, height = vertical and total or crossSize,
      align = "center" }, {
      spacer("before", offset),
      highlight,
      spacer("after", total - highlightLength - offset),
    })
    -- Native Flex supports negative gaps: overlap two equal-size layers at the same origin.
    -- The track retains its size while the spacer moves the single foreground highlight.
    content = container({ key = "slide-stack", gap = -total, align = "center" }, {content, overlay})
  else
    slideState = nil
    slideLayoutId, slideLayoutPosition = nil, nil
  end
  content = container({ key = "hover-stack", gap = -total, align = "center" }, {
    content,
    container({ key = "hover-targets", gap = 0, align = "center" }, hoverTargets),
  })
  if alignment ~= "center" then
    -- The host centers the whole tree. A bar-sized frame lets us place its ink at either edge.
    -- Keep the content and inset inside the frame even when the configured frame is very small.
    local contentSize = slotCross
    local frameSize = math.max(alignmentSize, contentSize)
    local inset = math.min(edgeInset, (frameSize - contentSize) / 2)
    local frame = vertical and ui.row or ui.column
    content = frame({
      key = "alignment-frame",
      width = vertical and frameSize or nil,
      height = not vertical and frameSize or nil,
      paddingH = vertical and inset or 0,
      paddingV = not vertical and inset or 0,
      align = "center",
      justify = alignment == "top" and "start" or "end",
    }, { content })
  end
  barWidget.render(content)
  local position = idx and string.format("column %d of %d", idx, #xs)
    or string.format("%d columns (no tiled app focused)", #xs)
  barWidget.setTooltip("Scrolling: " .. position .. " · Right-click for settings")
  barWidget.setVisible(true)
  schedule(now)
end

local function refresh()
  if busy then
    pending = true
    return
  end
  busy = true
  lastPollMs = noctalia.nowMs()
  noctalia.runAsync(QUERY, function(result)
    busy = false
    if result.exitCode == 0 then
      local d = noctalia.json.decode(result.stdout)
      if d then
        show(d[1], d[2], d[3])
      end
    end
    if pending then
      pending = false
      refresh()
    end
  end)
end

-- Event names from socket2 that can change which column is focused or how many there are.
local RELEVANT = {
  activewindowv2 = true, workspacev2 = true, openwindow = true, closewindow = true,
  movewindowv2 = true, changefloatingmode = true, focusedmonv2 = true, fullscreen = true,
  windowtitlev2 = true,
}

local function startEvents()
  if not noctalia.commandExists("socat") then
    noctalia.log("scroll-indicator: socat not found, polling only")
    return
  end
  local ok, err = pcall(function()
    noctalia.runStream(EVENTS, function(data)
      -- Callback may receive a line string or a table; handle both, and multi-line chunks.
      local text = type(data) == "string" and data
        or (type(data) == "table" and (data.line or data.stdout or data.data)) or ""
      for ev in text:gmatch("(%w+)>>") do
        if RELEVANT[ev] then
          refresh()
          return
        end
      end
    end)
  end)
  streaming = ok
  if not ok then
    noctalia.log("scroll-indicator: event stream unavailable (" .. tostring(err) .. "), polling only")
  end
end

hide()
startEvents()

function update()
  local now = noctalia.nowMs()
  -- Frames reuse the last snapshot. Only the existing safety poll or socket events query Hyprland.
  if snapshot then
    show(snapshot[1], snapshot[2], snapshot[3])
  end
  if now - lastPollMs >= pollInterval() then
    refresh()
  end
  schedule(now)
end

function onRightClick()
  noctalia.openSettings()
end

function onSegmentHover(state, id)
  if state == "true" then
    hoveredId = id
  elseif hoveredId == id then
    hoveredId = nil
  else
    return -- A delayed leave from another segment must not clear the current hover.
  end
  if snapshot then
    show(snapshot[1], snapshot[2], snapshot[3])
  end
end
