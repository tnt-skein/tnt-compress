rockspec_format = '3.0'

package = 'tnt-compress'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-compress.git',
    branch = 'main',
}

description = {
    summary = 'Сжатие gzip, zlib и DEFLATE поверх системной zlib и слой ответа для роутера',
    detailed = [[
        Своего сжатия у Tarantool CE нет: модуль compress есть только
        в Enterprise, а http.client лишь разжимает ответ. Работу делает
        системная zlib через FFI — libz.so.1 есть в любой поставке Linux,
        в том числе рядом со статической сборкой Tarantool, — а пакет
        даёт то, чего у неё нет.

        Сжатие строкой и потоком в форматах gzip, zlib и raw; поток
        сбрасывается по кускам, и та сторона разжимает всё пришедшее,
        не дожидаясь конца. Разжатие отказывает парой nil, err с родом:
        испорчено, оборвано, больше предела, отказала сама zlib. Предел
        разжатого есть всегда, 16 МБ по умолчанию: килобайт злого входа
        разжимается в гигабайт. gzip разжимается членами подряд, так что
        файл, в который дописывали сжатые партии, читается целиком.

        Сжатие — счёт в потоке событий, поэтому между вызовами zlib работа
        уступает, а внутри транзакции box — нет, чтобы её не оборвать.

        Слой ответа для роутера: gzip по Accept-Encoding с весами, Vary,
        слабая метка у сжатого вида, ответ по кускам остаётся потоком.

        Зависит от tnt-must (проверки аргументов) и tnt-external (внешние
        зависимости и их подмена в проверках). Покрытие строк и убитых
        мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-compress',
    issues_url = 'https://github.com/tnt-skein/tnt-compress/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'compression', 'gzip', 'zlib', 'deflate', 'http' },
}

dependencies = {
    'lua >= 5.1',
    'tnt-must',
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.compress'] = 'tnt/compress.lua',
        ['tnt.compress.deflater'] = 'tnt/compress/deflater.lua',
        ['tnt.compress.failure'] = 'tnt/compress/failure.lua',
        ['tnt.compress.inflater'] = 'tnt/compress/inflater.lua',
        ['tnt.compress.layer'] = 'tnt/compress/layer.lua',
        ['tnt.compress.stream'] = 'tnt/compress/stream.lua',
        ['tnt.compress.system'] = 'tnt/compress/system.lua',
        ['tnt.compress.zlib'] = 'tnt/compress/zlib.lua',
    },
}
