#!/bin/bash

# Need super user access to certain commands
if [ $(id -u) -ne 0 ]; then
    echo "Run this script as root!"
    exit 1
fi

# Check for the number of parameters to the script
if [[ $# != 2 ]]; then
    echo "usage: $0 <absolute mount path> <server ip>"
    exit 1
fi

# Download the latest troubleshooting script
wget https://raw.githubusercontent.com/Azure/blobnfs-troubleshoot/main/ubuntu-troubleshoot.sh

# Make the script executable
chmod +x ubuntu-troubleshoot.sh

# Log file
logfile="/tmp/troubleshoot$RANDOM.log"

# Clear the file
> $logfile

# Run the script
echo "Logging to $logfile ..."
./ubuntu-troubleshoot.sh "$1" "$2" |& tee -a $logfile

echo "Share the log file $logfile with the support team."

# Populate absmountpoint and serverip
# absmountpoint=""; serverip=""; logfile="/tmp/troubleshoot$$.log"; > $logfile; ./ubuntu-troubleshoot.sh "$absmountpoint" "$serverip" |& tee -a $logfile; echo "Share the log file $logfile with the support team."