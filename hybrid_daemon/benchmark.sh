#!/bin/bash

# Usage: ./unified_benchmark.sh [engine] [cold_type]
# Example: ./unified_benchmark.sh docker 10

ENGINE="$1" # docker | wasm | hybrid
COLD_TYPE="$2" # 1st | 5 | 10

if [[ -z $ENGINE || -z $COLD_TYPE ]]; then
    echo "Usage: $0 [docker|wasm|hybrid] [1st|5|10]"
    exit 1
fi

case "$COLD_TYPE" in
    1st)
        NUM_REQUESTS=100
        SLEEP_AFTER=( )
        TOTAL_SLEEP=0
        ;;
    5)
        NUM_REQUESTS=100
        SLEEP_AFTER=(20 40 60 80)
        TOTAL_SLEEP=$((4*120))
        ;;
    10)
        NUM_REQUESTS=200
        SLEEP_AFTER=(20 40 60 80 100 120 140 160 180)
        TOTAL_SLEEP=$((9*120))
        ;;
    *)
        echo "Invalid cold_type: $COLD_TYPE"
        exit 1
        ;;
esac

OUTPUT_FILE="request_times.txt"
TOTAL_OUTPUT_FILE="total_time.txt"

> "$OUTPUT_FILE"
> "$TOTAL_OUTPUT_FILE"

echo "Running $NUM_REQUESTS requests for $ENGINE ($COLD_TYPE cold)..."

START_TIME=$(date +%s.%N)

for ((i=1;i<=NUM_REQUESTS;i++))
do
    if [[ "$ENGINE" == "docker" ]]; then
        REQ_START=$(date +%s.%N)
        wsk action invoke mobilenet_docker --param-file ./cat1.json --result --blocking > /dev/null
        REQ_END=$(date +%s.%N)
        TIME_TAKEN=$(echo "$REQ_END - $REQ_START" | bc)
    elif [[ "$ENGINE" == "wasm" ]]; then
        REQ_START=$(date +%s.%N)
        wsk action invoke mobilenet_wasm --param-file ./cat1.json --result --blocking > /dev/null
        REQ_END=$(date +%s.%N)
        TIME_TAKEN=$(echo "$REQ_END - $REQ_START" | bc)
    elif [[ "$ENGINE" == "hybrid" ]]; then
        TIME_TAKEN=$(curl -s -o /dev/null -w "%{time_total}" \
            -X POST -H "Content-Type: application/json" \
            --data @cat1.json \
            http://127.0.0.1:8080/invoke)
    else
        echo "Invalid engine: $ENGINE"
        exit 1
    fi

    echo "Request $i: $TIME_TAKEN seconds" >> "$OUTPUT_FILE"

    if [[ " ${SLEEP_AFTER[*]} " == *" $i "* ]]; then
        echo "Sleeping for 2 minutes after request $i..."
        sleep 120
    fi
done

END_TIME=$(date +%s.%N)

ELAPSED_TIME=$(echo "$END_TIME - $START_TIME" | bc)
ADJUSTED_TIME=$(echo "$ELAPSED_TIME - $TOTAL_SLEEP" | bc)

echo "Actual request processing time (excluding sleep): $ADJUSTED_TIME seconds" | tee "$TOTAL_OUTPUT_FILE"
