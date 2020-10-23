#!/bin/bash

docker_ufw_setup=https://gist.githubusercontent.com/rubot/418ecbcef49425339528233b24654a7d/raw/docker_ufw_setup.sh
DEBUG=1 CRONFIX=1 bash <(curl -SsL $docker_ufw_setup)
