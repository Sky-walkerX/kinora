#!/bin/zsh
# Samples CPU% and top's POWER (energy impact) for matching processes every 5s. Usage: sample.sh <pattern> <seconds> <out.csv>
pat=$1; dur=$2; out=$3; end=$(( $(date +%s) + dur ))
echo "time,pid,command,cpu,power,mem" > $out
while (( $(date +%s) < end )); do
  for p in $(pgrep -f "$pat"); do
    top -l 2 -s 2 -stats pid,command,cpu,power,mem -pid $p | tail -1 | awk -v t=$(date +%T) '{print t","$1","$2","$3","$4","$5}' >> $out
  done
  sleep 3
done
