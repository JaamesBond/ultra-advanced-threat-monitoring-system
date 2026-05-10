#!/bin/bash
for f in new-infra/k8s/system-netpols/*netpol.yaml; do
  sed -i 's/- cluster/- cluster\n        - remote-node/' "$f"
done
