--- Системная библиотека zlib: объявления FFI и поиск.
---
--- Своего сжатия у Tarantool CE нет: модуль `compress` и сжатие полей
--- кортежа — только в Enterprise, а zstd, которым сжимает страницы vinyl,
--- наружу не выведен. zlib под рукой есть всегда, но по-разному. Сборка
--- Homebrew на macOS тянет её за libcurl, и символы видны в процессе.
--- Официальная сборка под Linux (образ `tarantool/tarantool:3.8`)
--- статическая: символов zlib в ней нет, `ffi.load('z')` не находит
--- `libz.so` — это имя ставит только пакет разработчика, — а `libz.so.1`
--- лежит в любой поставке (сверено на 3.8). Отсюда порядок поиска: общее
--- имя, затем soname.
---
--- Имена объявлений свои (`tnt_compress_*`), а на символы библиотеки
--- они ведут через `__asm__`. Структура с чужим именем `z_stream`,
--- объявленная другим модулем раньше нас, уронила бы `ffi.cdef`
--- «attempt to redefine», а функция `deflate` с чужой подписью молча
--- осталась бы чужой.

local ffi = require('ffi')

local system = require('tnt.compress.system')

local Module = {}

--- Коды возврата и режимы сброса zlib (`zlib.h`).
Module.OK = 0
Module.STREAM_END = 1
Module.MEM_ERROR = -4
Module.BUF_ERROR = -5
Module.NO_FLUSH = 0
Module.SYNC_FLUSH = 2
Module.FINISH = 4

--- Имена библиотеки в порядке поиска.
Module.NAMES = { 'z', 'libz.so.1' }

--- Описание потока zlib; повторная загрузка модуля (проверки грузят
--- исходники заново) объявляет его один раз.
if not pcall(ffi.typeof, 'tnt_compress_stream') then
    ffi.cdef([[
        typedef struct tnt_compress_stream {
            const unsigned char *next_in;
            unsigned int avail_in;
            unsigned long total_in;
            unsigned char *next_out;
            unsigned int avail_out;
            unsigned long total_out;
            const char *msg;
            void *state;
            void *zalloc;
            void *zfree;
            void *opaque;
            int data_type;
            unsigned long adler;
            unsigned long reserved;
        } tnt_compress_stream;

        const char *tnt_compress_version(void) __asm__("zlibVersion");

        int tnt_compress_deflate_init(tnt_compress_stream *stream, int level, int method,
            int window, int memory, int strategy, const char *version, int size) __asm__("deflateInit2_");
        int tnt_compress_deflate(tnt_compress_stream *stream, int flush) __asm__("deflate");
        int tnt_compress_deflate_end(tnt_compress_stream *stream) __asm__("deflateEnd");

        int tnt_compress_inflate_init(tnt_compress_stream *stream, int window,
            const char *version, int size) __asm__("inflateInit2_");
        int tnt_compress_inflate(tnt_compress_stream *stream, int flush) __asm__("inflate");
        int tnt_compress_inflate_reset(tnt_compress_stream *stream) __asm__("inflateReset");
        int tnt_compress_inflate_end(tnt_compress_stream *stream) __asm__("inflateEnd");
    ]])
end

--- Найденные библиотеки по загрузчику.
---
--- Ключ — сам загрузчик: проверка, подменившая его внешней зависимостью, получает свою
--- библиотеку, а вернувшая настоящий — прежнюю, без второго поиска.
---@type table<function, any>
local opened = setmetatable({}, { __mode = 'k' })

--- Ищет библиотеку по именам.
---@param load fun(name: string): any
---@return any|nil library
---@return string|nil err
local function discover(load)
    local reasons = {}

    for _, name in ipairs(Module.NAMES) do
        local ok, library = pcall(load, name)

        if ok then
            return library
        end

        table.insert(reasons, tostring(library))
    end

    return nil, 'нет системной библиотеки zlib: ' .. table.concat(reasons, '; ')
end

--- Библиотека zlib либо отказ: почему её не нашли.
---@return any|nil library
---@return string|nil err
local function resolve()
    local load = system.current().load
    local library = opened[load]

    if library ~= nil then
        return library
    end

    local found, err = discover(load)

    opened[load] = found

    return found, err
end

--- Есть ли zlib на узле.
---
--- Для проверки при запуске: слой ответов спрашивает это при сборке,
--- и узел без библиотеки узнаёт о ней при настройке, а не на первом
--- сжатом ответе.
---@return boolean ok
---@return string|nil err Почему нет
function Module.available()
    local library, err = resolve()

    return library ~= nil, err
end

--- Библиотека zlib.
---
--- Нет её — бросок: это поломка поставки, а не данные вызывающего, и чинит
--- её тот, кто ставит узел.
---@param level integer Уровень вины, как у `error`
---@return any
function Module.library(level)
    local library, err = resolve()

    if library == nil then
        error(err, level + 1)
    end

    return library
end

return Module
