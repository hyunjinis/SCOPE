#!/bin/bash
set -euo pipefail

###############################################################################
# Volcano 2-Node / 5-Pod YOLO Benchmark
#
# Workload:
#   yolo-cls, yolo-det, yolo-seg, yolo-obb, yolo-pos
#
# Target nodes:
#   gpu-orin2, gpu-orin3
#
# Method:
#   1. Extract each pod from yolo-5pods-all.yaml
#   2. Add schedulerName: volcano + nodeAffinity for orin2/orin3
#   3. Apply once and read Volcano-selected node
#   4. Delete the temporary pod
#   5. Re-apply locked pod with nodeName
#   6. If selected node is gpu-orin3, replace .engine -> _trt10.engine
#
# Notes:
#   - Original YAML is never modified.
#   - No CPU/memory requests or limits are added.
#   - Failed runs are not written as 0ms.
###############################################################################

START_ITER=1
END_ITER=50

EXP_NAME="volcano_2nodes_5pods"
REMOTE_YAML="/home/gpu-master/yolo-5pods-all.yaml"

RESULT_BASE_DIR="./experiment_results_volcano_2nodes_5pods"
SUMMARY_CSV="${RESULT_BASE_DIR}/volcano_total_summary_2nodes_5pods.csv"
FAILURE_CSV="${RESULT_BASE_DIR}/volcano_failure_summary_2nodes_5pods.csv"

TMP_SPEC_DIR="./volcano_2nodes_5pods_tmp_specs"

# 현재 kubectl 기본 설정 사용
KUBECTL_ARGS=""

SCHEDULER_NAME="volcano"
VOLCANO_NAMESPACE="volcano-system"

SSH_PASS="0"

###############################################################################
# Node information
###############################################################################

ORIN2_USER="gpu-orin2"
ORIN2_IP="192.168.0.206"
ORIN2_NODE="gpu-orin2"

ORIN3_USER="gpu-orin3"
ORIN3_IP="192.168.0.52"
ORIN3_NODE="gpu-orin3"

###############################################################################
# Pod order
###############################################################################

POD_ORDER=(
  "yolo-cls"
  "yolo-det"
  "yolo-seg"
  "yolo-obb"
  "yolo-pos"
)

###############################################################################
# Init
###############################################################################

mkdir -p "${RESULT_BASE_DIR}"
mkdir -p "${TMP_SPEC_DIR}"

if [ ! -f "${SUMMARY_CSV}" ]; then
  echo "Exp_ID,Iteration,Pod,Node,StartTime,EndTime,Pre(ms),Inf(ms),Post(ms),Total(ms)" > "${SUMMARY_CSV}"
fi

if [ ! -f "${FAILURE_CSV}" ]; then
  echo "Exp_ID,Iteration,Reason,Pod,Node,Time" > "${FAILURE_CSV}"
fi

timestamp() {
  date '+%Y-%m-%d %H:%M:%S.%3N'
}

log() {
  echo "[$(timestamp)] $1"
}

remote_pkill() {
  local user="$1"
  local ip="$2"

  sshpass -p "${SSH_PASS}" \
    ssh -o StrictHostKeyChecking=no "${user}@${ip}" \
    "pkill -u \$(whoami) -f 'tegrastats|mpstat|pidstat|vmstat'" \
    >/dev/null 2>&1 || true
}

delete_yolo_pods() {
  for pod_name in "${POD_ORDER[@]}"; do
    kubectl ${KUBECTL_ARGS} delete pod "${pod_name}" \
      --force --grace-period=0 >/dev/null 2>&1 || true
  done

  for pod_name in "${POD_ORDER[@]}"; do
    while kubectl ${KUBECTL_ARGS} get pod "${pod_name}" >/dev/null 2>&1; do
      sleep 0.2
    done
  done
}

extract_pod_yaml() {
  local pod_name="$1"
  local out_file="$2"

  awk -v RS='---' -v name="${pod_name}" '
    $0 ~ "name:[[:space:]]*"name"([[:space:]]|$)" {
      print "---"
      print $0
      exit
    }
  ' "${REMOTE_YAML}" > "${out_file}"

  if [ ! -s "${out_file}" ]; then
    echo "ERROR: Failed to extract YAML block for ${pod_name} from ${REMOTE_YAML}" >&2
    exit 1
  fi
}

insert_volcano_scheduler_and_affinity() {
  local yaml_file="$1"

  awk \
    -v sched="${SCHEDULER_NAME}" \
    -v node1="${ORIN2_NODE}" \
    -v node2="${ORIN3_NODE}" '
    /^[[:space:]]*nodeName:[[:space:]]*/ { next }
    /^[[:space:]]*schedulerName:[[:space:]]*/ { next }

    /^spec:[[:space:]]*$/ && inserted == 0 {
      print
      print "  schedulerName: " sched
      print "  affinity:"
      print "    nodeAffinity:"
      print "      requiredDuringSchedulingIgnoredDuringExecution:"
      print "        nodeSelectorTerms:"
      print "        - matchExpressions:"
      print "          - key: kubernetes.io/hostname"
      print "            operator: In"
      print "            values:"
      print "            - " node1
      print "            - " node2
      inserted = 1
      next
    }

    { print }
  ' "${yaml_file}" > "${yaml_file}.tmp"

  mv "${yaml_file}.tmp" "${yaml_file}"
}

insert_node_name() {
  local yaml_file="$1"
  local node_name="$2"

  awk -v node="${node_name}" '
    /^[[:space:]]*nodeName:[[:space:]]*/ { next }
    /^[[:space:]]*schedulerName:[[:space:]]*/ { next }

    /^spec:[[:space:]]*$/ && inserted == 0 {
      print
      print "  nodeName: " node
      inserted = 1
      next
    }

    { print }
  ' "${yaml_file}" > "${yaml_file}.tmp"

  mv "${yaml_file}.tmp" "${yaml_file}"
}

find_volcano_pod() {
  kubectl ${KUBECTL_ARGS} get pods -n "${VOLCANO_NAMESPACE}" --no-headers 2>/dev/null \
    | awk '$1 ~ /^volcano-scheduler-/ && $3 == "Running" {print $1; exit}'
}

node_ready_status() {
  local node_name="$1"

  kubectl ${KUBECTL_ARGS} get node "${node_name}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown"
}

check_target_nodes_ready() {
  local orin2_ready
  local orin3_ready

  orin2_ready=$(node_ready_status "${ORIN2_NODE}")
  orin3_ready=$(node_ready_status "${ORIN3_NODE}")

  if [ "${orin2_ready}" != "True" ]; then
    echo "${ORIN2_NODE}"
    return 1
  fi

  if [ "${orin3_ready}" != "True" ]; then
    echo "${ORIN3_NODE}"
    return 1
  fi

  echo "OK"
  return 0
}

wait_for_node_assignment() {
  local pod_name="$1"
  local assigned_node=""

  for retry in $(seq 1 120); do
    assigned_node=$(kubectl ${KUBECTL_ARGS} get pod "${pod_name}" \
      -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")

    if [ -n "${assigned_node}" ] && [ "${assigned_node}" != "<none>" ]; then
      echo "${assigned_node}"
      return 0
    fi

    sleep 0.5
  done

  echo ""
  return 1
}

wait_until_running() {
  local pod_name="$1"

  for retry in $(seq 1 180); do
    local phase
    local waiting_reason
    local terminated_reason

    phase=$(kubectl ${KUBECTL_ARGS} get pod "${pod_name}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    waiting_reason=$(kubectl ${KUBECTL_ARGS} get pod "${pod_name}" \
      -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")

    terminated_reason=$(kubectl ${KUBECTL_ARGS} get pod "${pod_name}" \
      -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || echo "")

    if [ "${phase}" = "Running" ]; then
      return 0
    fi

    if [ "${phase}" = "Failed" ] || [ "${waiting_reason}" = "CrashLoopBackOff" ] || [ -n "${terminated_reason}" ]; then
      return 1
    fi

    sleep 0.5
  done

  return 1
}

dump_debug_state() {
  local run_id="$1"
  local run_dir="$2"
  local reason="$3"
  local failed_pod="${4:-NA}"
  local failed_node="${5:-NA}"

  log "Dumping debug state: reason=${reason}, pod=${failed_pod}, node=${failed_node}"

  kubectl ${KUBECTL_ARGS} get nodes -o wide \
    > "${run_dir}/${run_id}_failure_nodes.txt" 2>&1 || true

  kubectl ${KUBECTL_ARGS} describe node "${ORIN2_NODE}" \
    > "${run_dir}/${run_id}_${ORIN2_NODE}_describe_failure.txt" 2>&1 || true

  kubectl ${KUBECTL_ARGS} describe node "${ORIN3_NODE}" \
    > "${run_dir}/${run_id}_${ORIN3_NODE}_describe_failure.txt" 2>&1 || true

  kubectl ${KUBECTL_ARGS} get pods -A -o wide \
    > "${run_dir}/${run_id}_failure_pods_all.txt" 2>&1 || true

  kubectl ${KUBECTL_ARGS} get events --sort-by=.lastTimestamp \
    > "${run_dir}/${run_id}_failure_events.txt" 2>&1 || true

  for p in "${POD_ORDER[@]}"; do
    kubectl ${KUBECTL_ARGS} get pod "${p}" -o wide \
      > "${run_dir}/${run_id}_${p}_failure_wide.txt" 2>&1 || true

    kubectl ${KUBECTL_ARGS} describe pod "${p}" \
      > "${run_dir}/${run_id}_${p}_failure_describe.txt" 2>&1 || true

    kubectl ${KUBECTL_ARGS} logs "${p}" \
      > "${run_dir}/${run_id}_${p}_failure_log.txt" 2>&1 || true

    kubectl ${KUBECTL_ARGS} get pod "${p}" -o yaml \
      > "${run_dir}/${run_id}_${p}_failure.yaml" 2>&1 || true
  done

  echo "${EXP_NAME},${run_id#${EXP_NAME}},${reason},${failed_pod},${failed_node},$(timestamp)" >> "${FAILURE_CSV}"
}

finish_remote_logs() {
  local run_id="$1"
  local run_dir="$2"

  log "Stopping remote telemetry and pulling logs"

  remote_pkill "${ORIN2_USER}" "${ORIN2_IP}"
  remote_pkill "${ORIN3_USER}" "${ORIN3_IP}"

  sleep 2

  for NODE_INFO in \
    "${ORIN2_USER}@${ORIN2_IP}:orin2" \
    "${ORIN3_USER}@${ORIN3_IP}:orin3"
  do
    USER_IP="${NODE_INFO%%:*}"
    PREFIX="${NODE_INFO##*:}"

    sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no \
      "${USER_IP}:/tmp/${run_id}_${PREFIX}_tegrastats.raw" \
      "${run_dir}/${run_id}_${PREFIX}_tegrastats.txt" >/dev/null 2>&1 || true

    sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no \
      "${USER_IP}:/tmp/${run_id}_${PREFIX}_mpstat.raw" \
      "${run_dir}/${run_id}_${PREFIX}_mpstat.txt" >/dev/null 2>&1 || true

    sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no \
      "${USER_IP}:/tmp/${run_id}_${PREFIX}_vmstat.raw" \
      "${run_dir}/${run_id}_${PREFIX}_vmstat.txt" >/dev/null 2>&1 || true

    sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no \
      "${USER_IP}:/tmp/${run_id}_${PREFIX}_pidstat.raw" \
      "${run_dir}/${run_id}_${PREFIX}_pidstat.txt" >/dev/null 2>&1 || true

    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" \
      "rm -f /tmp/${run_id}_${PREFIX}_tegrastats.raw /tmp/${run_id}_${PREFIX}_mpstat.raw /tmp/${run_id}_${PREFIX}_vmstat.raw /tmp/${run_id}_${PREFIX}_pidstat.raw" \
      >/dev/null 2>&1 || true
  done
}

cleanup_iteration() {
  local sched_pid="${1:-}"

  if [ -n "${sched_pid}" ]; then
    kill "${sched_pid}" >/dev/null 2>&1 || true
  fi

  remote_pkill "${ORIN2_USER}" "${ORIN2_IP}"
  remote_pkill "${ORIN3_USER}" "${ORIN3_IP}"

  delete_yolo_pods
}

fail_and_exit() {
  local run_id="$1"
  local run_dir="$2"
  local reason="$3"
  local failed_pod="${4:-NA}"
  local failed_node="${5:-NA}"
  local sched_pid="${6:-}"

  log "ERROR: ${reason}, pod=${failed_pod}, node=${failed_node}"

  dump_debug_state "${run_id}" "${run_dir}" "${reason}" "${failed_pod}" "${failed_node}"
  finish_remote_logs "${run_id}" "${run_dir}" || true
  cleanup_iteration "${sched_pid}" || true

  echo "FAILED: ${reason}. Check ${run_dir}" >&2
  exit 1
}

wait_for_yolo_done() {
  local pod_name="$1"
  local run_id="$2"
  local run_dir="$3"
  local sched_pid="$4"

  local wait_sec=0
  local timeout_limit=180

  while true; do
    local pod_node
    local node_ready
    local phase
    local log_output

    pod_node=$(kubectl ${KUBECTL_ARGS} get pod "${pod_name}" \
      -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "Unknown")

    if [ -n "${pod_node}" ] && [ "${pod_node}" != "Unknown" ]; then
      node_ready=$(node_ready_status "${pod_node}")
      if [ "${node_ready}" != "True" ]; then
        fail_and_exit "${run_id}" "${run_dir}" "NodeNotReadyDuringInference" "${pod_name}" "${pod_node}" "${sched_pid}"
      fi
    fi

    phase=$(kubectl ${KUBECTL_ARGS} get pod "${pod_name}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [ "${phase}" = "Failed" ]; then
      fail_and_exit "${run_id}" "${run_dir}" "PodFailedDuringInference" "${pod_name}" "${pod_node}" "${sched_pid}"
    fi

    log_output=$(kubectl ${KUBECTL_ARGS} logs "${pod_name}" 2>/dev/null || echo "NET_ERROR")

    if echo "${log_output}" | grep -q "Results saved to"; then
      log "[${pod_name}] YOLO inference completion detected"
      return 0
    fi

    if [ "${wait_sec}" -ge "${timeout_limit}" ]; then
      fail_and_exit "${run_id}" "${run_dir}" "TimeoutWaitingResultsSavedTo" "${pod_name}" "${pod_node}" "${sched_pid}"
    fi

    sleep 2
    wait_sec=$((wait_sec + 2))
  done
}

save_pod_result() {
  local pod_name="$1"
  local iter="$2"
  local run_id="$3"
  local run_dir="$4"
  local start_time="$5"

  local end_time
  local pod_log
  local speed_line
  local pre
  local inf
  local post
  local total
  local node

  end_time=$(timestamp)
  pod_log="${run_dir}/${run_id}_${pod_name}.log"

  kubectl ${KUBECTL_ARGS} logs "${pod_name}" > "${pod_log}" 2>/dev/null || echo "Log Dump Timeout" > "${pod_log}"

  speed_line=$(grep "Speed:" "${pod_log}" | tail -n 1 || echo "")

  if [ -n "${speed_line}" ]; then
    pre=$(echo "${speed_line}" | awk '{print $2}' | sed 's/ms//; s/,//')
    inf=$(echo "${speed_line}" | awk '{print $4}' | sed 's/ms//; s/,//')
    post=$(echo "${speed_line}" | awk '{print $6}' | sed 's/ms//; s/,//')
    total=$(echo "${pre} + ${inf} + ${post}" | bc -l 2>/dev/null || echo "NA")
  else
    pre="NA"
    inf="NA"
    post="NA"
    total="NA"
  fi

  node=$(kubectl ${KUBECTL_ARGS} get pod "${pod_name}" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "Unknown-Node")

  if [ "${total}" = "NA" ] || [ "${total}" = "0" ] || [ "${total}" = "0ms" ]; then
    echo "ERROR: invalid parsed latency for ${pod_name}" >&2
    return 1
  fi

  echo "${EXP_NAME},${iter},${pod_name},${node},${start_time},${end_time},${pre},${inf},${post},${total}" >> "${SUMMARY_CSV}"

  log "[saved] ${pod_name} -> ${node}, total=${total}ms"
}

###############################################################################
# Pre-flight checks
###############################################################################

log "Pre-flight checks"

if [ ! -f "${REMOTE_YAML}" ]; then
  echo "ERROR: ${REMOTE_YAML} not found" >&2
  exit 1
fi

if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass is not installed" >&2
  exit 1
fi

if ! command -v bc >/dev/null 2>&1; then
  echo "ERROR: bc is not installed. Install with: sudo apt install -y bc" >&2
  exit 1
fi

VOLCANO_POD=$(find_volcano_pod || true)

if [ -z "${VOLCANO_POD}" ]; then
  echo "ERROR: Running Volcano scheduler pod not found in namespace ${VOLCANO_NAMESPACE}" >&2
  echo "Check: kubectl get pods -n ${VOLCANO_NAMESPACE}" >&2
  kubectl ${KUBECTL_ARGS} get pods -n "${VOLCANO_NAMESPACE}" >&2 || true
  exit 1
fi

log "Using Volcano scheduler pod: ${VOLCANO_POD}"

kubectl ${KUBECTL_ARGS} get nodes "${ORIN2_NODE}" "${ORIN3_NODE}" -o wide || {
  echo "ERROR: Target nodes not found. Check node names." >&2
  exit 1
}

READY_CHECK=$(check_target_nodes_ready || true)
if [ "${READY_CHECK}" != "OK" ]; then
  echo "ERROR: target node is not Ready: ${READY_CHECK}" >&2
  exit 1
fi

log "Using workload YAML: ${REMOTE_YAML}"
log "Results directory: ${RESULT_BASE_DIR}"
log "Summary CSV: ${SUMMARY_CSV}"
log "Failure CSV: ${FAILURE_CSV}"

###############################################################################
# Benchmark loop
###############################################################################

for i in $(seq "${START_ITER}" "${END_ITER}"); do
  RUN_ID="${EXP_NAME}${i}"
  RUN_DIR="${RESULT_BASE_DIR}/${RUN_ID}"

  mkdir -p "${RUN_DIR}"
  mkdir -p "${TMP_SPEC_DIR}"

  unset START_TIMES || true
  declare -A START_TIMES

  log "========================================================"
  log "Starting ${RUN_ID}"
  log "========================================================"

  ###########################################################################
  # 0. Cleanup
  ###########################################################################

  log "[0] Pre-cleaning telemetry daemons and old pods"

  remote_pkill "${ORIN2_USER}" "${ORIN2_IP}"
  remote_pkill "${ORIN3_USER}" "${ORIN3_IP}"

  delete_yolo_pods

  sleep 3

  READY_CHECK=$(check_target_nodes_ready || true)
  if [ "${READY_CHECK}" != "OK" ]; then
    fail_and_exit "${RUN_ID}" "${RUN_DIR}" "TargetNodeNotReadyBeforeStart" "NA" "${READY_CHECK}" ""
  fi

  ###########################################################################
  # 1. Record cluster state before deployment
  ###########################################################################

  kubectl ${KUBECTL_ARGS} get nodes -o wide > "${RUN_DIR}/${RUN_ID}_nodes_before.txt" 2>&1 || true
  kubectl ${KUBECTL_ARGS} top nodes > "${RUN_DIR}/${RUN_ID}_top_nodes_before.txt" 2>&1 || true
  kubectl ${KUBECTL_ARGS} get pods -A -o wide > "${RUN_DIR}/${RUN_ID}_pods_before.txt" 2>&1 || true
  kubectl ${KUBECTL_ARGS} get events --sort-by=.lastTimestamp > "${RUN_DIR}/${RUN_ID}_events_before.txt" 2>&1 || true

  ###########################################################################
  # 2. Volcano scheduler log
  ###########################################################################

  log "[1] Starting Volcano scheduler log capture"

  VOLCANO_POD=$(find_volcano_pod || true)

  if [ -n "${VOLCANO_POD}" ]; then
    kubectl ${KUBECTL_ARGS} logs -f "pod/${VOLCANO_POD}" -n "${VOLCANO_NAMESPACE}" \
      > "${RUN_DIR}/${RUN_ID}_volcano_scheduler.log" 2>&1 &
    SCHED_PID=$!
  else
    log "WARNING: Volcano scheduler pod not found during iteration"
    SCHED_PID=""
  fi

  ###########################################################################
  # 3. Start telemetry collection on orin2/orin3
  ###########################################################################

  log "[2] Starting telemetry collection on ${ORIN2_NODE}, ${ORIN3_NODE}"

  for NODE_INFO in \
    "${ORIN2_USER}@${ORIN2_IP}:orin2" \
    "${ORIN3_USER}@${ORIN3_IP}:orin3"
  do
    USER_IP="${NODE_INFO%%:*}"
    PREFIX="${NODE_INFO##*:}"

    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" \
      "rm -f /tmp/${RUN_ID}_${PREFIX}_*.raw; nohup tegrastats --interval 500 > /tmp/${RUN_ID}_${PREFIX}_tegrastats.raw 2>&1 < /dev/null &" || true

    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" \
      "nohup mpstat -P ALL 1 > /tmp/${RUN_ID}_${PREFIX}_mpstat.raw 2>&1 < /dev/null &" || true

    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" \
      "nohup vmstat 1 > /tmp/${RUN_ID}_${PREFIX}_vmstat.raw 2>&1 < /dev/null &" || true

    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" \
      "nohup pidstat -u -r -w 1 > /tmp/${RUN_ID}_${PREFIX}_pidstat.raw 2>&1 < /dev/null &" || true
  done

  sleep 10

  ###########################################################################
  # 4. Deploy 5 pods through Volcano placement decision
  ###########################################################################

  log "[3] Starting Volcano-based 5-pod placement on orin2/orin3 only"

  echo "Pod,SelectedNode" > "${RUN_DIR}/${RUN_ID}_volcano_assignments.csv"

  for pod_name in "${POD_ORDER[@]}"; do
    TMP_SPEC_FIRST="${TMP_SPEC_DIR}/tmp_${RUN_ID}_${pod_name}_first.yaml"
    TMP_SPEC_LOCKED="${TMP_SPEC_DIR}/tmp_${RUN_ID}_${pod_name}_locked.yaml"

    log "Preparing ${pod_name}"

    READY_CHECK=$(check_target_nodes_ready || true)
    if [ "${READY_CHECK}" != "OK" ]; then
      fail_and_exit "${RUN_ID}" "${RUN_DIR}" "TargetNodeNotReadyBeforePodApply" "${pod_name}" "${READY_CHECK}" "${SCHED_PID}"
    fi

    kubectl ${KUBECTL_ARGS} delete pod "${pod_name}" \
      --force --grace-period=0 >/dev/null 2>&1 || true

    while kubectl ${KUBECTL_ARGS} get pod "${pod_name}" >/dev/null 2>&1; do
      sleep 0.2
    done

    #########################################################################
    # First apply: let Volcano select between orin2 and orin3
    #########################################################################

    extract_pod_yaml "${pod_name}" "${TMP_SPEC_FIRST}"
    insert_volcano_scheduler_and_affinity "${TMP_SPEC_FIRST}"

    cp "${TMP_SPEC_FIRST}" "${RUN_DIR}/${RUN_ID}_${pod_name}_volcano_first_apply.yaml"

    log "First apply with schedulerName=${SCHEDULER_NAME}: ${pod_name}"
    kubectl ${KUBECTL_ARGS} apply -f "${TMP_SPEC_FIRST}"

    ASSIGNED_NODE=$(wait_for_node_assignment "${pod_name}" || true)

    if [ -z "${ASSIGNED_NODE}" ]; then
      fail_and_exit "${RUN_ID}" "${RUN_DIR}" "VolcanoDidNotAssignNode" "${pod_name}" "NA" "${SCHED_PID}"
    fi

    if [ "${ASSIGNED_NODE}" != "${ORIN2_NODE}" ] && [ "${ASSIGNED_NODE}" != "${ORIN3_NODE}" ]; then
      fail_and_exit "${RUN_ID}" "${RUN_DIR}" "VolcanoSelectedUnexpectedNode" "${pod_name}" "${ASSIGNED_NODE}" "${SCHED_PID}"
    fi

    echo "${pod_name},${ASSIGNED_NODE}" >> "${RUN_DIR}/${RUN_ID}_volcano_assignments.csv"

    log "Volcano selected: ${pod_name} -> ${ASSIGNED_NODE}"

    #########################################################################
    # Second apply: lock to selected node using nodeName
    #########################################################################

    kubectl ${KUBECTL_ARGS} delete pod "${pod_name}" \
      --force --grace-period=0 >/dev/null 2>&1 || true

    while kubectl ${KUBECTL_ARGS} get pod "${pod_name}" >/dev/null 2>&1; do
      sleep 0.2
    done

    extract_pod_yaml "${pod_name}" "${TMP_SPEC_LOCKED}"
    insert_node_name "${TMP_SPEC_LOCKED}" "${ASSIGNED_NODE}"

    # Orin3 requires TensorRT 10 engine files.
    # Orin2 keeps the original .engine files.
    if [ "${ASSIGNED_NODE}" = "${ORIN3_NODE}" ]; then
      log "[TRT10 node] ${pod_name} -> ${ASSIGNED_NODE}; replacing .engine with _trt10.engine"
      sed -i 's/\.engine/_trt10.engine/g' "${TMP_SPEC_LOCKED}"
    else
      log "[standard node] ${pod_name} -> ${ASSIGNED_NODE}; keeping original .engine files"
    fi

    cp "${TMP_SPEC_LOCKED}" "${RUN_DIR}/${RUN_ID}_${pod_name}_locked_apply.yaml"

    START_TIMES["${pod_name}"]=$(timestamp)

    kubectl ${KUBECTL_ARGS} apply -f "${TMP_SPEC_LOCKED}"

    if wait_until_running "${pod_name}"; then
      log "${pod_name} is Running"
    else
      fail_and_exit "${RUN_ID}" "${RUN_DIR}" "PodDidNotReachRunning" "${pod_name}" "${ASSIGNED_NODE}" "${SCHED_PID}"
    fi

    READY_CHECK=$(check_target_nodes_ready || true)
    if [ "${READY_CHECK}" != "OK" ]; then
      fail_and_exit "${RUN_ID}" "${RUN_DIR}" "TargetNodeNotReadyAfterPodRunning" "${pod_name}" "${READY_CHECK}" "${SCHED_PID}"
    fi

    kubectl ${KUBECTL_ARGS} get pod "${pod_name}" -o wide \
      > "${RUN_DIR}/${RUN_ID}_${pod_name}_placement.txt" 2>&1 || true

    kubectl ${KUBECTL_ARGS} describe pod "${pod_name}" \
      > "${RUN_DIR}/${RUN_ID}_${pod_name}_describe.txt" 2>&1 || true

    rm -f "${TMP_SPEC_FIRST}" "${TMP_SPEC_LOCKED}"

    # 기존 5-pod 실험의 3초 간격 배포 유지
    sleep 3
  done

  kubectl ${KUBECTL_ARGS} get pods -o wide \
    > "${RUN_DIR}/${RUN_ID}_all_pods_placement.txt" 2>&1 || true

  kubectl ${KUBECTL_ARGS} get events --sort-by=.lastTimestamp \
    > "${RUN_DIR}/${RUN_ID}_events_after_deploy.txt" 2>&1 || true

  ###########################################################################
  # 5. Wait for completion and save pod logs/results
  ###########################################################################

  log "[4] Waiting for YOLO completion"

  for pod_name in "${POD_ORDER[@]}"; do
    wait_for_yolo_done "${pod_name}" "${RUN_ID}" "${RUN_DIR}" "${SCHED_PID}"

    if ! save_pod_result "${pod_name}" "${i}" "${RUN_ID}" "${RUN_DIR}" "${START_TIMES[$pod_name]}"; then
      POD_NODE=$(kubectl ${KUBECTL_ARGS} get pod "${pod_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "Unknown")
      fail_and_exit "${RUN_ID}" "${RUN_DIR}" "InvalidLatencyParse" "${pod_name}" "${POD_NODE}" "${SCHED_PID}"
    fi
  done

  ###########################################################################
  # 6. Capture trailing cluster metrics
  ###########################################################################

  log "[4.5] Capturing trailing metrics"
  sleep 2

  kubectl ${KUBECTL_ARGS} top nodes > "${RUN_DIR}/${RUN_ID}_top_nodes_after.txt" 2>&1 || true
  kubectl ${KUBECTL_ARGS} top pods -A > "${RUN_DIR}/${RUN_ID}_top_pods_after.txt" 2>&1 || true
  kubectl ${KUBECTL_ARGS} get pods -A -o wide > "${RUN_DIR}/${RUN_ID}_pods_after.txt" 2>&1 || true
  kubectl ${KUBECTL_ARGS} get events --sort-by=.lastTimestamp > "${RUN_DIR}/${RUN_ID}_events_after.txt" 2>&1 || true

  ###########################################################################
  # 7. Pull telemetry logs
  ###########################################################################

  finish_remote_logs "${RUN_ID}" "${RUN_DIR}"

  ###########################################################################
  # 8. Cleanup
  ###########################################################################

  log "[5] Cleaning resources for iteration ${i}"

  cleanup_iteration "${SCHED_PID}"

  rm -f "${TMP_SPEC_DIR}"/tmp_${RUN_ID}_*.yaml 2>/dev/null || true

  log "Iteration ${i} completed. Waiting 30s before next iteration."
  sleep 30
done

log "======================================================"
log "All Volcano 2-node / 5-pod iterations completed"
log "CSV result: ${SUMMARY_CSV}"
log "Failure CSV: ${FAILURE_CSV}"
log "======================================================"
