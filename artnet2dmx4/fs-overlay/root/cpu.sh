#!/bin/sh

while true; do
	CPU_USAGE=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print usage "%"}' | sed 's/\%//g')
	mosquitto_pub -h 192.168.1.4 -p 1883 -u homeassistant -P hnw4main -m "$CPU_USAGE" -t sensors/bbb/cpu -q 2 -V mqttv311
	sleep 1
done
