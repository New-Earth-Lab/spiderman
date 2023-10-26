#!/bin/bash
# Start with current project activated, two general threads, and one thread in the interactive threadpool
# Default arugment value: /opt/spiders/spiderman/config.toml
cd /opt/spiders/spiderman
julia +1.10 --project=/opt/spiders/spiderman/ --threads 2,2 --gcthreads=1 -i  -e "using SpiderMan; try; fetch(SpiderMan.spiderman()); exit(0); catch; end;" -- ${1:-/opt/spiders/spiderman/spiderman-config.toml}
