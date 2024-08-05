#!/bin/bash

# Define the base JMX file and the output directory
BASE_JMX_FILE="/jmeter/crdp-jmenter-metrics.jmx"
OUTPUT_DIR="/jmeter"

# Define the thread group values
THREAD_GROUP_VALUES=(100 200 300 400 500)

# Iterate over the thread group values and create a new JMX file for each
for i in "${!THREAD_GROUP_VALUES[@]}"; do
    THREAD_GROUP_VALUE=${THREAD_GROUP_VALUES[$i]}
    OUTPUT_JMX_FILE="${OUTPUT_DIR}/crdp-jmenter-metrics-${THREAD_GROUP_VALUE}.jmx"
          
    # Copy the base JMX file and replace the thread group value
    cp "$BASE_JMX_FILE" "$OUTPUT_JMX_FILE"
    sed -i "s|<stringProp name=\"ThreadGroup.num_threads\">[0-9]\+</stringProp>|<stringProp name=\"ThreadGroup.num_threads\">${THREAD_GROUP_VALUE}</stringProp>|" "$OUTPUT_JMX_FILE"
              
    echo "Created $OUTPUT_JMX_FILE with ThreadGroup.num_threads set to ${THREAD_GROUP_VALUE}"
    done
#