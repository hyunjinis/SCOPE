#!/bin/bash
set -euo pipefail

# --- [1] 환경 설정 ---
START_ITER=1
END_ITER=50
EXP_NAME="nonmps_most"           # [수정] 기존 방식 이름 (nonmps1, nonmps2...)
REMOTE_YAML="/home/gpu-master/yolo-5pods-all.yaml"
RESULT_BASE_DIR="./experiment_results_ultra_v4_most"
SUMMARY_CSV="${RESULT_BASE_DIR}/nonmps_total_summary_most.csv"
KUBECONFIG="--kubeconfig=/etc/kubernetes/admin.conf"

# SSH 및 노드 정보
SSH_PASS="0"
ORIN2_USER="gpu-orin2"; ORIN2_IP="192.168.0.254"
ORIN3_USER="gpu-orin3"; ORIN3_IP="192.168.0.216"

# --- [2] 초기화 ---
mkdir -p "$RESULT_BASE_DIR"
echo "Exp_ID,Iteration,Pod,Node,StartTime,EndTime,Pre(ms),Inf(ms),Post(ms),Total(ms)" > "$SUMMARY_CSV"

sshrun() { bash -c "$@"; }

remote_pkill() {
    local user=$1; local ip=$2
    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${user}@${ip}" \
    "pkill -u \$(whoami) -f 'tegrastats|mpstat|pidstat|vmstat'" || true
}

# --- [3] 메인 루프 (1~50) ---
for i in $(seq $START_ITER $END_ITER); do
    RUN_ID="${EXP_NAME}${i}"   # 예: nonmps1, nonmps2...
    RUN_DIR="${RESULT_BASE_DIR}/${RUN_ID}"
    mkdir -p "${RUN_DIR}"

    echo "------------------------------------------------"
    echo ">>> [ULTRA-ANALYSIS] ${RUN_ID} 시작"
    echo "------------------------------------------------"

    # 1. 스케줄러 로그 수집 ($line 수정 및 파일명 규칙 변경)
    echo "[1] Capturing Scheduler Logs..."
    kubectl logs -f kube-scheduler-gpu-master -n kube-system $KUBECONFIG \
    | grep --line-buffered -iE "score|filter|selecting|evaluating" \
    | while read line; do echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') $line"; done > "${RUN_DIR}/${RUN_ID}_scheduler_scoring.log" &
    SCHED_PID=$!

    # 2. 모든 에지 노드 지표 모니터링 ($line 수정)
    for NODE_INFO in "${ORIN2_USER}@${ORIN2_IP}:orin2" "${ORIN3_USER}@${ORIN3_IP}:orin3"; do
        USER_IP=${NODE_INFO%%:*}; PREFIX=${NODE_INFO##*:}
        
        # [A] Tegrastats
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" "tegrastats --interval 500" \
        | while read line; do echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') $line"; done > "${RUN_DIR}/${RUN_ID}_${PREFIX}_tegrastats.txt" 2>&1 &
        
        # [B] mpstat
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" "mpstat -P ALL 1" \
        | while read line; do echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') $line"; done > "${RUN_DIR}/${RUN_ID}_${PREFIX}_mpstat.txt" 2>&1 &
        
        # [C] vmstat
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" "vmstat 1" \
        | while read line; do echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') $line"; done > "${RUN_DIR}/${RUN_ID}_${PREFIX}_vmstat.txt" 2>&1 &
        
        # [D] pidstat
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" "pidstat -u -r -w 1" \
        | while read line; do echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') $line"; done > "${RUN_DIR}/${RUN_ID}_${PREFIX}_pidstat.txt" 2>&1 &
    done

    sleep 10 # Baseline 확보

    # 3. 파드 중첩 배포 (3초 간격)
    echo "[3] Overlapping Deployment starting..."
    POD_ORDER=("yolo-cls" "yolo-det" "yolo-seg" "yolo-obb" "yolo-pos")
    declare -A START_TIMES

    for pod_name in "${POD_ORDER[@]}"; do
        START_TIMES[$pod_name]=$(date '+%Y-%m-%d %H:%M:%S.%3N')
        sshrun "awk -v RS='---' -v name=\"${pod_name}\" '\$0 ~ \"name: \"name {print \"---\"; print \$0}' ${REMOTE_YAML} | kubectl ${KUBECONFIG} apply -f -"
        sleep 3
    done

    # 4. 완료 감지 및 기록
    for pod_name in "${POD_ORDER[@]}"; do
        while ! sshrun "kubectl ${KUBECONFIG} logs ${pod_name}" 2>/dev/null | grep -q "Results saved to"; do
            sleep 2
        done
        ETIME=$(date '+%Y-%m-%d %H:%M:%S.%3N')
        STIME=${START_TIMES[$pod_name]}
        
        POD_LOG="${RUN_DIR}/${RUN_ID}_${pod_name}.log"
        sshrun "kubectl ${KUBECONFIG} logs ${pod_name}" > "${POD_LOG}"
        SPEED_LINE=$(grep "Speed:" "${POD_LOG}" | tail -n 1)
        PRE=$(echo $SPEED_LINE | awk '{print $2}' | sed 's/ms//'); INF=$(echo $SPEED_LINE | awk '{print $4}' | sed 's/ms//'); POST=$(echo $SPEED_LINE | awk '{print $6}' | sed 's/ms//')
        TOTAL=$(echo "$PRE + $INF + $POST" | bc)
        NODE=$(sshrun "kubectl ${KUBECONFIG} get pod ${pod_name} -o custom-columns=NODE:.spec.nodeName --no-headers")

        echo "${EXP_NAME},${i},${pod_name},${NODE},${STIME},${ETIME},${PRE},${INF},${POST},${TOTAL}" >> "$SUMMARY_CSV"
    done

    # 5. 리소스 정리
    kill $SCHED_PID || true
    remote_pkill "${ORIN2_USER}" "${ORIN2_IP}"
    remote_pkill "${ORIN3_USER}" "${ORIN3_IP}"
    sshrun "kubectl ${KUBECONFIG} delete -f ${REMOTE_YAML}"
    sleep 15
done
