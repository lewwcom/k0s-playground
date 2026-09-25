#!/usr/bin/env bash
make gen-kubeconfig > kubeconfig.tmp
export KUBECONFIG=$(realpath kubeconfig.tmp)

echo 'Try: kubectl cluster-info'

