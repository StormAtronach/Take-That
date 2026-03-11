local log = mwse.Logger.new({ moduleName = "sounds" })

local sounds = {}

-- Cache for scanned directories
local fileCache = {}

--- Get a random sound from a subdirectory
--- @param subdir string The subdirectory name under your sound folder
--- @return string|nil The relative sound path, or nil if no sounds found
function sounds.getRandom(subdir)
    -- Cache files if not already done
    if not fileCache[subdir] then
        fileCache[subdir] = {}
        local path = "data files\\sound\\sa_tt\\" .. subdir

        -- lfs.dir returns nil when the directory doesn't exist; guard prevents crash
        local iter = lfs.dir(path)
        if not iter then
            log:warn("Sound directory not found: %s", path)
        else
            for file in iter do
                if file:match("%.wav$") or file:match("%.mp3$") then
                    table.insert(fileCache[subdir], file)
                end
            end
            log:debug("Cached %d sounds from %s", #fileCache[subdir], path)
        end
    end

    -- Return nil if no files found
    if #fileCache[subdir] == 0 then
        return nil
    end

    -- Return random file path
    return string.format("sa_tt\\%s\\%s", subdir, table.choice(fileCache[subdir]))
end

--- Play a random sound from a subdirectory
--- @param subdir string
--- @param reference tes3reference|nil
--- @param volume number|nil
function sounds.playRandom(subdir, reference, volume)
    local soundPath = sounds.getRandom(subdir)
    if soundPath then
        log:trace("Playing %s", soundPath)
        tes3.playSound({
            soundPath = soundPath,
            reference = reference,
            volume = volume or 1,
            pitch = math.random(90, 110) / 100,  -- Slight pitch variation
        })
    end
end

return sounds