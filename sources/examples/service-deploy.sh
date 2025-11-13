
#!/bin/sh
set -eu

docker service update \
  --image my.registry/image:production \
  my_service-prod