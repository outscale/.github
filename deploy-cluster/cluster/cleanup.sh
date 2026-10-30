#!/bin/bash
set -ex
OSC_CLUSTER_NAME=$3

# do not wait if stuck, frieza will purge everything
octl kube kubectl --cluster management --profile management -- delete ns $OSC_CLUSTER_NAME --timeout 1m || /bin/true
