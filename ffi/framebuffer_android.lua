local ffi = require("ffi")
local android = require("android")
local BB = require("ffi/blitbuffer")
local C = ffi.C

--[[ configuration for devices with an electric paper display controller ]]--

-- does the device has an e-ink screen?
local has_eink_screen, eink_platform = android.isEink()

-- does the device needs to handle all screen refreshes
local has_eink_full_support = android.isEinkFull()

-- for *some* rockchip devices
local rk_full, rk_partial, rk_a2, rk_auto = 1, 2, 3, 4 -- luacheck: ignore

-- for *some* freescale devices
local update_full, update_partial = 32, 0 -- luacheck: ignore
local waveform_du, waveform_gc16, waveform_regal = 1, 2, 7 -- luacheck: ignore
local partial_du, partial_gc16, partial_regal = waveform_du, waveform_gc16, waveform_regal -- luacheck: ignore
local full_gc16, full_regal = update_full + waveform_gc16, update_full + waveform_regal -- luacheck: ignore

local qualcomm_delay_page = 250
local qualcomm_delay_ui = 100
local qualcomm_wait_mode_wait = 64 -- luacheck: ignore
local qualcomm_reagl_mode_reagl = 4096 -- luacheck: ignore
local qualcomm_update_full, qualcomm_update_partial = 32, 0 -- luacheck: ignore
local qualcomm_waveform_du, qualcomm_waveform_gc16, qualcomm_waveform_regal = 1, 2, 6 -- luacheck: ignore
local qualcomm_partial_du, qualcomm_partial_gc16, qualcomm_partial_regal = qualcomm_waveform_du, qualcomm_waveform_gc16, qualcomm_waveform_regal -- luacheck: ignore
local qualcomm_full_gc16, qualcomm_full_regal = qualcomm_update_full + qualcomm_waveform_gc16 + qualcomm_wait_mode_wait, qualcomm_update_full + qualcomm_waveform_regal -- luacheck: ignore

local framebuffer = {}

-- update a region of the screen
function framebuffer:_updatePartial(mode, delay, x, y, w, h)
    local bb = self.full_bb or self.bb
    w, x = BB.checkBounds(w or bb:getWidth(), x or 0, 0, bb:getWidth(), 0xFFFF)
    h, y = BB.checkBounds(h or bb:getHeight(), y or 0, 0, bb:getHeight(), 0xFFFF)
    x, y, w, h = bb:getPhysicalRect(x, y, w, h)

    android.einkUpdate(mode, delay, x, y, (x + w), (y + h))
end

-- update the entire screen
function framebuffer:_updateFull()
    -- freescale ntx platform
    if has_eink_screen and (eink_platform == "freescale") then
        if has_eink_full_support then
            -- we handle the screen entirely. No delay is needed
            self:_updatePartial(full_gc16, 0)
        else
            -- we're racing against system driver. Let the system win and apply
            -- a full update after it.
            self:_updatePartial(full_gc16, 500)
        end
    -- rockchip rk3x platform
    elseif has_eink_screen and (eink_platform == "rockchip") then
        android.einkUpdate(rk_full)
    elseif has_eink_screen and (eink_platform == "qualcomm") then
        self:_updatePartial(qualcomm_full_gc16, qualcomm_delay_page)
    end
end

function framebuffer:init()
    -- we present this buffer to the outside
    self.bb = BB.new(android.screen.width, android.screen.height, BB.TYPE_BBRGB32)
    self.bb:fill(BB.COLOR_WHITE)
    self:_updateWindow()
    framebuffer.parent.init(self)
end

-- resize on rotation or split view.
function framebuffer:resize()
    android.screen.width = android.getScreenWidth()
    android.screen.height = android.getScreenHeight()
    local rotation
    local inverse
    if self.bb then
        rotation = self.bb:getRotation()
        inverse = self.bb:getInverse() == 1
        self.bb:free()
    end
    self.bb = BB.new(android.screen.width, android.screen.height, BB.TYPE_BBRGB32)

    -- Rotation and inverse must be inherited
    if rotation then
        self.bb:setRotation(rotation)
    end
    if inverse then
        self.bb:invert()
    end

    self.bb:fill(inverse and BB.COLOR_BLACK or BB.COLOR_WHITE)
    self:_updateWindow()
end

function framebuffer:getRotationMode()
    if android.hasNativeRotation() then
        return android.orientation.get()
    else
        return self.cur_rotation_mode
    end
end

function framebuffer:setRotationMode(mode)
    if android.hasNativeRotation() then
        local key
        if mode == 0 then key = "PORTRAIT"
        elseif mode == 1 then key = "LANDSCAPE"
        elseif mode == 2 then key = "REVERSE_PORTRAIT"
        elseif mode == 3 then key = "REVERSE_LANDSCAPE" end
        if key then
            android.orientation.set(C["ASCREEN_ORIENTATION_" .. key])
        end
    else
        framebuffer.parent.setRotationMode(self, mode)
    end
end

function framebuffer:_updateWindow()
    if android.app.window == nil then
        android.LOGW("cannot blit: no window")
        return
    end

    local buffer = ffi.new("ANativeWindow_Buffer[1]")
    if android.lib.ANativeWindow_lock(android.app.window, buffer, nil) < 0 then
        android.LOGW("Unable to lock window buffer")
        return
    end

    local bb = nil
    if buffer[0].format == C.WINDOW_FORMAT_RGBA_8888
    or buffer[0].format == C.WINDOW_FORMAT_RGBX_8888
    then
        bb = BB.new(buffer[0].width, buffer[0].height, BB.TYPE_BBRGB32, buffer[0].bits, buffer[0].stride*4, buffer[0].stride)
    elseif buffer[0].format == C.WINDOW_FORMAT_RGB_565 then
        bb = BB.new(buffer[0].width, buffer[0].height, BB.TYPE_BBRGB16, buffer[0].bits, buffer[0].stride*2, buffer[0].stride)
    else
        android.LOGE("unsupported window format!")
    end

    if bb then
        local ext_bb = self.full_bb or self.bb
        -- Rotations and inverse are applied in the base ffi/framebuffer class, so our shadow buffer is already inverted and rotated.
        -- All we need is to do is simply clone the invert and rotation settings, so that the blit below becomes 1:1 copy.
        bb:setInverse(ext_bb:getInverse())
        bb:setRotation(ext_bb:getRotation())
        bb:blitFrom(ext_bb)
    end

    android.lib.ANativeWindow_unlockAndPost(android.app.window);
end

function framebuffer:refreshFullImp(x, y, w, h)
    self:_updateWindow()
    self:_updateFull()
end

function framebuffer:refreshPartialImp(x, y, w, h)
    self:_updateWindow()
    if has_eink_full_support then
        if eink_platform == "qualcomm" then
            self:_updatePartial(qualcomm_partial_gc16, qualcomm_delay_page, x, y, w, h)
        else
            self:_updatePartial(partial_regal, 0, x, y, w, h)
        end
    end
end

function framebuffer:refreshFlashPartialImp(x, y, w, h)
    self:_updateWindow()
    if has_eink_full_support then
        if eink_platform == "qualcomm" then
            self:_updatePartial(qualcomm_partial_regal, qualcomm_delay_page, x, y, w, h)
        else
            self:_updatePartial(full_regal, 0, x, y, w, h)
        end
    end
end

function framebuffer:refreshUIImp(x, y, w, h)
    self:_updateWindow()
    if has_eink_full_support then
        if eink_platform == "qualcomm" then
            self:_updatePartial(qualcomm_partial_gc16, qualcomm_delay_ui, x, y, w, h)
        else
            self:_updatePartial(partial_regal, 0, x, y, w, h)
        end
    end
end

function framebuffer:refreshFlashUIImp(x, y, w, h)
    self:_updateWindow()
    if has_eink_full_support then
        if eink_platform == "qualcomm" then
            self:_updatePartial(qualcomm_full_gc16, qualcomm_delay_ui, x, y, w, h)
        else
            self:_updatePartial(full_regal, 0, x, y, w, h)
        end
    end
end

function framebuffer:refreshFastImp(x, y, w, h)
    self:_updateWindow()
    if has_eink_full_support then
        if eink_platform == "qualcomm" then
            self:_updatePartial(qualcomm_partial_du, 0, x, y, w, h)
        else
            self:_updatePartial(partial_du, 0, x, y, w, h)
        end
    end
end

return require("ffi/framebuffer"):extend(framebuffer)
