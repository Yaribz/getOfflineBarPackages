# getOfflineBarPackages
Retrieve files required to install Beyond All Reason offline

This script retrieves all the files required to install the Beyond All Reason
game offline. Files can be imported both from a local installation of the game
and from official online packages. Versions of game components can be
customized.

Usage:

    getOfflineBarPackages.pl [options]
    
      Options:
        -h,--help                : print usage
        -v,--version             : print version
        -V,--verbose             : use verbose output
        -t,--tasks <tasks>       : comma-separated list of tasks to process
                                   (installer,engine,game,chobby,maps,launcher)
        -d,--disable <tasks>     : comma-separated list of tasks to disable
        -e,--engine <version>    : specify the engine version to retrieve
                                   (default: version from launcher config file)
        -E,--engine-local [dir]  : use local data directory to retrieve engine
        -g,--game <tagOrName>    : specify the game version to retrieve
                                   (default: "byar:test")
        -G,--game-local [dir]    : use local data directory to retrieve game
        -c,--chobby <tagOrName>  : specify the chobby version to retrieve
                                   (default: "byar-chobby:test")
        -C,--chobby-local [dir]  : use local data directory to retrieve chobby
        -m,--maps [dir]          : retrieve all Beyond All Reason maps
        -M,--maps-local [dir]    : retrieve maps from local data directory only
        -L,--local-datadir [dir] : specify local data directory
        -l,--linux               : skip Windows-specific packages
        -w,--windows             : skip Linux-specific packages
        -o,--output <dir>        : use a custom output directory
                                   (default: "BAR-offline_YYYYMMDD-hhmmss")
        -f,--force               : ignore already existing output directory
