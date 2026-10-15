#!/usr/bin/env bash
# Coleta evidências do LAB 02 (HPA scale-out + Cluster Autoscaler node scale-out).
source "$(dirname "$0")/../../scripts/lib/common.sh"
out="$STATE_DIR/lab-02-evidence.txt"
{
  echo "# LAB 02 — $(date -u +%FT%TZ)"
  echo "## HPA"; kubectl -n ecommerce describe hpa orders-api | sed -n '/Events:/,$p'
  echo "## Eventos FailedScheduling / TriggeredScaleUp"
  kubectl get events -A --field-selector reason=FailedScheduling -o custom-columns=TIME:.lastTimestamp,OBJ:.involvedObject.name,MSG:.message | tail -5
  kubectl get events -A --field-selector reason=TriggeredScaleUp -o custom-columns=TIME:.lastTimestamp,OBJ:.involvedObject.name,MSG:.message | tail -5
  echo "## Cluster Autoscaler (scale-up)"
  kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler --since=30m 2>/dev/null | grep -E "Final scale-up plan|Scale-up: setting group|Scale-down: removing|removing empty node|ScaleDown" | tail -6
  echo "## Nós"; kubectl get nodes -l workload=apps -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
} | tee "$out"
grep -q "SuccessfulRescale" "$out" && ok "HPA escalou (SuccessfulRescale)" || warn "Sem evento SuccessfulRescale"
grep -qE "TriggeredScaleUp|Final scale-up plan" "$out" && ok "Cluster Autoscaler disparou scale-up" || warn "Sem evidência de scale-up de nós"
info "Evidências em $out"
