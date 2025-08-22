#!/bin/bash

usage() {
  echo "Usage: $0 (--docker|--wasm|--hybrid) --param-file <file.json> [--num-requests <n>]"
  echo
  echo "Arguments:"
  echo "  --docker         Run in Docker mode"
  echo "  --wasm           Run in WASM mode"
  echo "  --hybrid         Run in Hybrid mode"
  echo "  --param-file     Path to parameter JSON file (mandatory)"
  echo "  --num-requests   Number of requests to run (default: 500)"
  echo "  -h, --help       Show this help message"
  echo
  exit 1
}

# Default values
NUM_REQUESTS=500
MODE=""
PARAM_FILE=""

# Parse arguments
ARGS=$(getopt -o h --long docker,wasm,hybrid,param-file:,num-requests:,help -n "$0" -- "$@")
if [[ $? -ne 0 ]]; then
  usage
fi
eval set -- "$ARGS"

while true; do
  case "$1" in
    --docker) MODE="--docker"; shift ;;
    --wasm) MODE="--wasm"; shift ;;
    --hybrid) MODE="--hybrid"; shift ;;
    --param-file) PARAM_FILE="$2"; shift 2 ;;
    --num-requests) NUM_REQUESTS="$2"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Validate mandatory args
if [[ -z "$MODE" ]]; then
  echo "Error: You must specify one of --docker, --wasm, or --hybrid."
  usage
fi

if [[ -z "$PARAM_FILE" ]]; then
  echo "Error: --param-file is required."
  usage
fi

if [[ ! -f "$PARAM_FILE" ]]; then
  echo "Error: Parameter file '$PARAM_FILE' not found."
  usage
fi

# --- the rest of your benchmarking script here ---
echo "Running benchmark:"
echo "  Mode         : $MODE"
echo "  Param file   : $PARAM_FILE"
echo "  Num requests : $NUM_REQUESTS"

TIMESTAMP=$(date +"%d_%m_%Y_%H_%M")
OUTPUT_FILE="output_${TIMESTAMP}_${MODE}.json"

echo "Running $NUM_REQUESTS requests in $MODE mode..."
results=()
total_latency=0
min_latency=999999
max_latency=0

if [[ "$MODE" == "--docker" || "$MODE" == "--hybrid" ]]; then
  echo "Removing Docker container to prepare for new cold start..."
  docker rm -f $(docker ps -aq --filter "name=mobilenet_docker") 2>/dev/null
fi

for ((i=1; i<=NUM_REQUESTS; i++)); do
  REQ_START=$(date +%s.%N)
  if [[ "$MODE" == "--docker" ]]; then
    wsk action invoke mobilenet_docker --param-file "$PARAM_FILE" --blocking > /dev/null
  elif [[ "$MODE" == "--wasm" ]]; then
    wsk action invoke mobilenet_wasm --param-file "$PARAM_FILE" --blocking > /dev/null
  elif [[ "$MODE" == "--hybrid" ]]; then
    curl -s -o /dev/null -X POST -H "Content-Type: application/json" --data @"$PARAM_FILE" http://127.0.0.1:8080/invoke
  fi
  REQ_END=$(date +%s.%N)
  TIME_TAKEN=$(echo "$REQ_END - $REQ_START" | bc)

  results+=("{\"id\":$i,\"latency\":$TIME_TAKEN}")
  
  if (( i % 10 == 0 )); then
    echo "Completed $i / $NUM_REQUESTS requests"
  fi

  # Accumulate total latency
  total_latency=$(echo "$total_latency + $TIME_TAKEN" | bc)

  # Update min & max
  cmp_min=$(echo "$TIME_TAKEN < $min_latency" | bc)
  cmp_max=$(echo "$TIME_TAKEN > $max_latency" | bc)
  if [[ $cmp_min -eq 1 ]]; then
    min_latency=$TIME_TAKEN
  fi
  if [[ $cmp_max -eq 1 ]]; then
    max_latency=$TIME_TAKEN
  fi

  # Every 100 requests do cleanup depending on MODE
  if (( i % 50 == 0 && i < NUM_REQUESTS )); then
    if [[ "$MODE" == "--docker" || "$MODE" == "--hybrid" ]]; then
      echo "Removing Docker container to prepare for new cold start..."
      docker rm -f $(docker ps -aq --filter "name=mobilenet_docker") 2>/dev/null
    elif [[ "$MODE" == "--wasm" || "$MODE" == "--hybrid" ]]; then
      echo "Sleeping 20s to put WASM to sleep..."
      sleep 20
    fi
  fi
done

# Compute average latency
average_latency=$(echo "scale=6; $total_latency / $NUM_REQUESTS" | bc)

# Build JSON with jq
jq -n \
  --arg mode "${MODE#--}" \
  --arg timestamp "$TIMESTAMP" \
  --arg param_file "$PARAM_FILE" \
  --arg num_requests "$NUM_REQUESTS" \
  --arg total_latency "$total_latency" \
  --arg avg_latency "$average_latency" \
  --arg min_latency "$min_latency" \
  --arg max_latency "$max_latency" \
  --slurpfile results <(printf '%s\n' "${results[@]}" | jq -s '.') \
  'def round2: (.*100 | floor / 100);
   {
     mode: $mode,
     timestamp: $timestamp,
     param_file: $param_file,
     num_requests: ($num_requests | tonumber),
     total_latency: ($total_latency | tonumber | round2),
     average_latency: ($avg_latency | tonumber | round2),
     min_latency: ($min_latency | tonumber | round2),
     max_latency: ($max_latency | tonumber | round2),
     results: ($results[0] | map(.latency |= (round2)))
   }' > "$OUTPUT_FILE"

echo "Finished... Result written in $OUTPUT_FILE..."
