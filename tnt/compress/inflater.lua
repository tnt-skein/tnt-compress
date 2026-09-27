--- Разжатие: строкой целиком и потоком по кускам.
---
--- Разжатие берёт чужое и отказывает парой `nil, err`
--- (`tnt.compress.failure`). Предел выхода есть всегда, `LIMIT`
--- по умолчанию: килобайт испорченного либо злого входа разжимается
--- в гигабайт, и без предела это кончилось бы памятью узла.
---
--- gzip разжимается членами подряд, как у `gzip -d`: файл, в который
--- дописывали сжатые куски (`cat a.gz b.gz`), читается целиком. У `zlib`
--- и `raw` байты после конца потока — отказ `corrupt`. Форматы, кусок
--- работы и уступки — `tnt.compress.stream`.

local ffi = require('ffi')

local must = require('tnt.must')

local failure = require('tnt.compress.failure')
local stream_of = require('tnt.compress.stream')
local system = require('tnt.compress.system')
local zlib = require('tnt.compress.zlib')

local Module = {}

--- Предел разжатого по умолчанию, байт. Больше — `limit` явно.
---@type integer
Module.LIMIT = 16 * 1024 * 1024

--- Бросок на кусок после конца потока.
local FINISHED = 'поток разжатия закончен: finish уже позван'

---@class TntDecompressOptions Настройки разжатия
---@field format string|nil `gzip` (по умолчанию), `zlib` либо `raw`
---@field limit number|nil Предел разжатого, байт; по умолчанию 16 МБ

--- Поток разжатия.
---@class TntCompressInflater
---@field library any Библиотека zlib
---@field stream any Поток zlib; nil после `finish`
---@field window integer Окно формата: по нему узнаётся gzip
---@field limit number Предел разжатого, байт
---@field size number Сколько разжато
---@field ended boolean Сжатый поток дошёл до конца
---@field failure TntCompressFailure|nil Отказ; поток после него не пишет
local Inflater = {}
Inflater.__index = Inflater

--- Отказ по коду zlib.
---@param code integer
---@param message any `msg` потока: строка C либо NULL
---@return TntCompressFailure
local function broken(code, message)
    if code == zlib.MEM_ERROR then
        return failure.failed('не хватило памяти')
    end

    if message == nil then
        return failure.corrupt(('код zlib %d'):format(code))
    end

    return failure.corrupt(ffi.string(message))
end

--- Запоминает отказ: следующий кусок получит его же.
---@param self TntCompressInflater
---@param refused TntCompressFailure
---@return nil
---@return TntCompressFailure
local function refuse(self, refused)
    self.failure = refused

    return nil, refused
end

--- Прогоняет вход через поток разжатия.
---
--- Круг кончается, когда вход забран и место в буфере осталось: разжатие
--- останавливается только на пустом входе либо на полном выходе
--- (`zlib.h`). Пройденный конец потока при оставшемся входе у gzip —
--- следующий член, у прочих — лишние байты.
---@param self TntCompressInflater
---@param input string
---@return string|nil
---@return TntCompressFailure|nil
local function unsqueeze(self, input)
    local stream = self.stream
    local buffer = stream_of.buffer
    local chunk = stream_of.CHUNK
    local parts = {}
    local offset = 0
    local started = false

    while offset < #input do
        local size = math.min(#input - offset, chunk)

        stream.next_in = ffi.cast(stream_of.BYTES, input) + offset
        stream.avail_in = size
        offset = offset + size

        repeat
            if self.ended and stream.avail_in > 0 then
                if self.window ~= stream_of.WINDOWS.gzip then
                    return refuse(self, failure.corrupt('лишние байты после конца потока'))
                end

                self.library.tnt_compress_inflate_reset(stream)
                self.ended = false
            end

            if started then
                system.pause()
            end

            started = true
            stream.next_out = buffer
            stream.avail_out = chunk

            local code = self.library.tnt_compress_inflate(stream, zlib.NO_FLUSH)
            local produced = chunk - stream.avail_out

            self.size = self.size + produced

            if self.size > self.limit then
                return refuse(self, failure.too_large(self.limit))
            end

            table.insert(parts, ffi.string(buffer, produced))

            if code == zlib.STREAM_END then
                self.ended = true
            elseif code ~= zlib.OK and code ~= zlib.BUF_ERROR then
                return refuse(self, broken(code, stream.msg))
            end
        until stream.avail_in == 0 and stream.avail_out ~= 0
    end

    return table.concat(parts)
end

--- Дописывает кусок сжатого и отдаёт разжатое из него.
---
--- Отказ — `nil, err`; после отказа поток испорчен, и каждый следующий
--- кусок получает тот же отказ.
---@param chunk string
---@return string|nil
---@return TntCompressFailure|nil
function Inflater:write(chunk)
    must.at(2).string(chunk, 'кусок')

    if self.stream == nil then
        error(FINISHED, 2)
    end

    if self.failure ~= nil then
        return nil, self.failure
    end

    return unsqueeze(self, chunk)
end

--- Заканчивает поток: сверяет, что сжатое дошло до конца.
---@return true|nil
---@return TntCompressFailure|nil
function Inflater:finish()
    if self.stream == nil then
        error(FINISHED, 2)
    end

    stream_of.close(self.stream, self.library.tnt_compress_inflate_end)
    self.stream = nil

    if self.failure ~= nil then
        return nil, self.failure
    end

    if not self.ended then
        return nil, failure.truncated()
    end

    return true
end

--- Заводит поток разжатия по настройкам.
---@param options any
---@param level integer Уровень вины от функции, позвавшей эту
---@return TntCompressInflater
local function inflater_of(options, level)
    local caller = must.at(level + 1)

    caller.optional.options(options, 'настройки', { format = '?string', limit = '?number' })

    local given = options or {}
    local window = stream_of.window_of(given, level + 1)
    local limit = given.limit or Module.LIMIT

    caller.positive(limit, 'настройки.limit')

    local library = zlib.library(level + 1)
    local version = library.tnt_compress_version()
    local stream = stream_of.open(function(raw, size)
        return library.tnt_compress_inflate_init(raw, window, version, size)
    end, library.tnt_compress_inflate_end, level + 1)

    return setmetatable({
        library = library,
        stream = stream,
        window = window,
        limit = limit,
        size = 0,
        ended = false,
    }, Inflater)
end

--- Поток разжатия.
---@param options TntDecompressOptions|nil
---@return TntCompressInflater
function Module.new(options)
    local opened = inflater_of(options, 2)

    return opened
end

--- Разжимает строку целиком.
---@param data string
---@param options TntDecompressOptions|nil
---@return string|nil
---@return TntCompressFailure|nil
function Module.inflate(data, options)
    must.at(2).string(data, 'данные')

    local inflater = inflater_of(options, 2)
    local unpacked = inflater:write(data)

    -- Отказ куска `finish` отдаёт тот же, а целый кусок сверяет на конец.
    local ended, refused = inflater:finish()

    if not ended then
        return nil, refused
    end

    return unpacked
end

return Module
