fx_version 'cerulean'
game 'rdr3'

author 'VEX'
description 'Server-authoritative network entity lifecycle, ownership, state bag, and cleanup utility.'
version '1.0.0'

lua54 'yes'

dependencies {
    'vex_core',
    'vex_callback'
}

shared_scripts {
    'config.lua',
    'shared/sh_config.lua'
}

server_scripts {
    'server/main.lua'
}

client_scripts {
    'client/main.lua'
}
