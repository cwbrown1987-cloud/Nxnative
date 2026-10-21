#!/bin/bash
# focus dmhost then press A every 2.5 s for $1 seconds
end=$((SECONDS+$1))
while [ $SECONDS -lt $end ]; do
  osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "dmhost") to true' -e 'tell application "System Events" to key code 49' 2>/dev/null
  sleep 2.5
done
