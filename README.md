# Docker UFW Fix

Solves the problem with open ports with docker and ufw
As Docker uses the nat table, the filter table FORWARD chain is used and does not touch ufw-input chains as expected.
Even for ufw-forward chains it would not work, as DOCKER chains are inserted in front.
This is a simple fix that worked for me.
https://github.com/moby/moby/issues/4737#issuecomment-420264979

Unfortunately this fix stops forwarding users origin ip to host mode configured service
We hotfix that with cronjob for now: Add CRONFIX=1
Check yourself if you need that. It only allows 1:1 port mappings

# Usage:
Apply the Patch:
```
docker_ufw_setup=https://gist.githubusercontent.com/rubot/418ecbcef49425339528233b24654a7d/raw/docker_ufw_setup.sh
DEBUG=1 CRONFIX=1 bash <(curl -SsL $docker_ufw_setup)
```
Reset the patch:
```
RESET=1 bash <(curl -SsL $docker_ufw_setup)
```
