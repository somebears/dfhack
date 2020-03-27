local json = require 'json'
local script = require 'gui.script'
local utils = require 'utils'

local args = {...}
local done_command = args[1]

local STATUS_FILE = 'test_status.json'
local TestStatus = {
    PENDING = 'pending',
    PASSED = 'passed',
    FAILED = 'failed',
}

local VALID_MODES = utils.invert{'none', 'fortress'}

expect = {}
function expect.true_(value, comment)
    return not not value, comment, 'expected true'
end
function expect.false_(value, comment)
    return not value, comment, 'expected false'
end
function expect.eq(a, b, comment)
    return a == b, comment, ('%s ~= %s'):format(a, b)
end
function expect.ne(a, b, comment)
    return a ~= b, comment, ('%s == %s'):format(a, b)
end
function expect.error(func, ...)
    local ok, ret = pcall(func, ...)
    if ok then
        return false, 'no error raised by function call'
    else
        return true
    end
end

function delay(frames)
    frames = frames or 1
    script.sleep(frames, 'frames')
end

function build_test_env()
    local env = {
        test = utils.OrderedTable(),
        config = {
            mode = 'none',
        },
        expect = {},
        delay = delay,
    }
    local private = {
        checks = 0,
        checks_ok = 0,
    }
    for name, func in pairs(expect) do
        env.expect[name] = function(...)
            private.checks = private.checks + 1
            local ret = {func(...)}
            local ok = table.remove(ret, 1)
            local msg = ''
            for _, part in pairs(ret) do
                if part then
                    msg = msg .. ': ' .. tostring(part)
                end
            end
            msg = msg:sub(3) -- strip leading ': '
            if ok then
                private.checks_ok = private.checks_ok + 1
            else
                dfhack.printerr('Check failed! ' .. (msg or '(no message)'))
                local info = debug.getinfo(2)
                dfhack.printerr(('  at %s:%d'):format(info.short_src, info.currentline))
                print('')
            end
        end
    end
    setmetatable(env, {__index = _G})
    return env, private
end

function get_test_files()
    local files = {}
    for _, entry in ipairs(dfhack.filesystem.listdir_recursive(dfhack.getHackPath() .. 'test')) do
        if not entry.isdir and not entry.path:match('main.lua') then
            table.insert(files, entry.path)
        end
    end
    table.sort(files)
    return files
end

function load_test_status()
    if dfhack.filesystem.isfile(STATUS_FILE) then
        return json.decode_file(STATUS_FILE)
    end
end

function save_test_status(status)
    json.encode_file(status, STATUS_FILE)
end

function finish_tests()
    if done_command then
        dfhack.run_command(done_command)
    end
end

function load_tests(file, tests)
    local short_filename = file:sub(file:find('test'), -1)
    print('Loading file: ' .. short_filename)
    local env, env_private = build_test_env()
    local code, err = loadfile(file, 't', env)
    if not code then
        dfhack.printerr('Failed to load file: ' .. tostring(err))
        return false
    else
        local ok, err = pcall(code)
        if not ok then
            dfhack.printerr('Error when running file: ' .. tostring(err))
            return false
        else
            if not VALID_MODES[env.config.mode] then
                dfhack.printerr('Invalid config.mode: ' .. env.config.mode)
                return false
            end
            for name, test_func in pairs(env.test) do
                local test_data = {
                    full_name = short_filename .. ':' .. name,
                    func = test_func,
                    private = env_private,
                    config = env.config,
                }
                test_data.name = test_data.full_name:gsub('test/', ''):gsub('.lua', '')
                table.insert(tests, test_data)
            end
        end
    end
    return true
end

function run_test(test, status, counts)
    if status[test.full_name] == TestStatus.PENDING then
        test.private.checks = 0
        test.private.checks_ok = 0
        counts.tests = counts.tests + 1
        local ok, err = pcall(test.func)
        local passed = false
        if not ok then
            dfhack.printerr('test errored: ' .. test.name .. ': ' .. tostring(err))
        elseif test.private.checks ~= test.private.checks_ok then
            dfhack.printerr('test failed: ' .. test.name)
        else
            print('test passed: ' .. test.name)
            passed = true
            counts.tests_ok = counts.tests_ok + 1
        end
        counts.checks = counts.checks + (tonumber(test.private.checks) or 0)
        counts.checks_ok = counts.checks_ok + (tonumber(test.private.checks_ok) or 0)
        status[test.full_name] = passed and TestStatus.PASSED or TestStatus.FAILED
        save_test_status(status)
    else
        print('test skipped: ' .. test.name .. ' (state = ' .. status[test.full_name] .. ')')
    end
end

function main()
    local files = get_test_files()

    local counts = {
        tests = 0,
        tests_ok = 0,
        checks = 0,
        checks_ok = 0,
        file_errors = 0,
    }
    local passed = true

    print('Looking for title screen...')
    for i = 0, 100 do
        local scr = dfhack.gui.getCurViewscreen()
        if df.viewscreen_titlest:is_instance(scr) then
            print('Found title screen')
            break
        else
            scr:feed_key(df.interface_key.LEAVESCREEN)
            delay(10)
        end
    end
    if not df.viewscreen_titlest:is_instance(dfhack.gui.getCurViewscreen()) then
        qerror('Could not find title screen')
    end

    print('Loading tests')
    local tests = {}
    for _, file in ipairs(files) do
        if not load_tests(file, tests) then
            passed = false
            counts.file_errors = counts.file_errors + 1
        end
    end

    local status = load_test_status() or {}
    for _, test in pairs(tests) do
        if not status[test.full_name] then
            status[test.full_name] = TestStatus.PENDING
        end
    end

    print('Running tests')
    for _, test in pairs(tests) do
        run_test(test, status, counts)
    end

    print('\nTest summary:')
    print(('%d/%d tests passed'):format(counts.tests_ok, counts.tests))
    print(('%d/%d checks passed'):format(counts.checks_ok, counts.checks))
    print(('%d test files failed to load'):format(counts.file_errors))
end

script.start(function()
    dfhack.with_finalize(finish_tests, main)
end)
