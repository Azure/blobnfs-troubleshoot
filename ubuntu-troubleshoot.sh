#!/bin/bash

# copy the the following content into troubleshoot.sh file
# and execute chmod +x ubuntu-troubleshoot.sh
#
# run this script with the absolute path of mount point.
# sudo ./troubleshoot.sh <mountpoint> <server-ip> 
# parameter 1 => absolute path of mount point
# parameter 2 => server ip address

# To-do:
# 1. Add colors to the output
# 2. Prompt user to fix the issues
# 3. Add support for aznfs

# Need super user access to certain commands
if [ $(id -u) -ne 0 ]; then
    echo "Run this script as root!"
    exit 1
fi

# Check for the number of parameters to the script
if [[ ($# != 2) || ("$1" == "") || ("$2" == "") ]]; then
    echo "usage: $0 <absolute mount path> <server ip>"
    exit 1
fi

randomnum=$$
mountpoint=$1
accname=""
ipaddr=$2

# Print current date and time
echo "-------------------- Starting troubleshooting at $(date -u). --------------------"

cat /proc/self/mountstats > /tmp/mountstats.baseline

# Detect OS and Version
__m=$(uname -m 2>/dev/null) || __m=unknown
__s=$(uname -s 2>/dev/null) || __s=unknown

case "${__m}:${__s}" in
    "x86_64:Linux")
        # To-do: Add support for other distros
        distro_id=""
        distro_id=$(grep "^ID=" /etc/os-release | awk -F= '{print $2}' | tr -d '"')
        distro_id=$(echo "$distro_id" | tr '[:upper:]' '[:lower:]')
        if [[ $distro_id != "ubuntu" ]]; then
            echo "[FATAL] Unsupported distro: $distro_id."
            exit 1
        fi
        ;;
    *)
        echo "[FATAL] Unsupported platform: ${__m}:${__s}."
        exit 1
        ;;
esac

# Log the OS and version
echo "Platform: ${__m}:${__s}"
echo "Distro: $distro_id"

set -eu

# Setup
dpkg -s httping tcptraceroute ioping tshark net-tools &> /dev/null
if [[ $? -ne 0 ]]; then
    echo "All the necessary tools are already installed."
    confirmation="N"
    echo -n "Installing tools such as tcping, httping, tcptraceroute, ioping, and tshark for troubleshooting. "
    echo -n "Will capture traces on port 2048 and 111 to your account endpoint. "
    echo -n "Enter Y/y if you want to continue: "
    read confirmation
    if [[ $confirmation == "Y" || $confirmation == "y" ]]; then
        wget http://www.vdberg.org/~richard/tcpping -O /usr/bin/tcping &> /dev/null
        chmod 755 /usr/bin/tcping > /dev/null
        echo "Installed tcping. "
        apt-get update > /dev/null
        echo "Updated the package list. "
        apt-get install -y httping > /dev/null
        echo "Installed httping. "
        apt-get install -y tcptraceroute > /dev/null
        echo "Installed tcptraceroute. "
        apt-get install -y ioping > /dev/null
        echo "Installed ioping. "
        apt-get install net-tools > /dev/null
        echo "Installed net-tools. Installing tshark. It might take a while..."
        apt-get install -y tshark > /dev/null
        echo "Installed tshark. "
        echo "Installed necessary tools. "
    else
        echo "Exiting troubleshooting."
        exit 0
    fi
fi

echo "Packet drops: " $(netstat -s | grep "fast retransmits")

# Extract the account name using pattern matching
accname=$(findmnt -t nfs --target $mountpoint | awk 'FNR == 2 { print $2 }' | awk -F '/' '{ print $2 }')
if [[ $accname == "" ]]; then
    echo "No account/container mounted on the given mount point: $mountpoint. Please check the mount point!"
    exit 1
fi

# Extract the IP address using pattern matching
# ipaddr=$(mount | grep $mountpoint | awk '{ print $6}' | awk -F , '{ print $NF }' | awk -F ')' '{print $1}' | awk -F '=' '{ print $NF }')
# if [[ $ipaddr == "" ]]; then
#     echo "IP address of the account endpoint mounted not found!"
#     exit 1
# fi

# Collect diagnostics details
# echo "-------------------- Share the below o/p with your Azure support team. --------------------"

# Change the directory to the mount point
cd $mountpoint

# Create a test dir
testdir="troubleshooting"
while
    testdir="troubleshooting-$RANDOM"
    [ -d "$testdir" ]
do true; done
mkdir $testdir

# Start Tshark capture
tshark -w /tmp/nfscapture.pcap -f "host $ipaddr and (port 2048 or port 111)" &> /dev/null &
tsharkpid=$!

sleep 3

# Print the extracted values
echo "Mount point: $mountpoint"
echo "Account name: $accname"
echo "IP Address of the endpoint: $ipaddr"

# Get the mount options
echo "Mount details:"
echo $(findmnt -t nfs --target $mountpoint | awk 'FNR == 2 { print $4 }')

# Mount options
IFS=',' read -ra mountoptions <<< $(findmnt -t nfs --target $mountpoint | awk 'FNR == 2 { print $4 }')

if [[ $(cat /sys/class/bdi/0\:$(stat -c "%d" .)/read_ahead_kb) -lt 1024 ]]; then
    confirmation="N"
    echo -n "Read ahead KB is less than 1024. Do you want to increase the read ahead KB? Enter Y/y to continue and any other key to abort. (Default: Y): "
    read confirmation
    if [[ $confirmation == "" || $confirmation == "Y" || $confirmation == "y" ]]; then
        echo 16384 > /sys/class/bdi/0\:$(stat -c "%d" .)/read_ahead_kb
        echo "Read ahead KB increased to 1024."
    else
        echo "Please increase the read ahead KB above 1MB and try again."
        exit 1
    fi
fi

echo "Read ahead KB:" $(cat /sys/class/bdi/0\:$(stat -c "%d" .)/read_ahead_kb)

# Read and write size in the mount options should be 1M
if [[ ! " ${mountoptions[@]} " =~ " rsize=1048576 " ]]; then
    echo -n "rsize is not 1M. Please set rsize to 1M while mounting."
    exit 1
fi

if [[ ! " ${mountoptions[@]} " =~ " wsize=1048576" ]]; then
    echo -n "wsize is not 1M. Please set wsize to 1M while mounting."
    exit 1
fi

# Check if nconnect is used but nconnect patch is not enabled.
if [[ (" ${mountoptions[@]} " =~ " nconnect=.* ") && (" ${mountoptions[@]} " =~ " port=2048 ") ]]; then
    echo -n "nconnect " 
    if [[ $(cat /sys/module/sunrpc/parameters/enable_azure_nconnect) -eq "N" ]]; then
        confirmation="N"
        echo -n "Nconnect is used on port 2048 but the patch is not enabled. Do you want to enable nconnect patch? Enter Y/y to continue and any other key to abort. (Default: Y): "
        read confirmation
        if [[ $confirmation == "" || $confirmation == "Y" || $confirmation == "y" ]]; then
            echo "Y" > /sys/module/sunrpc/parameters/enable_azure_nconnect
            echo "Y" > /sys/module/sunrpc/parameters/azure_nconnect_readscaling
            echo "Nconnect patch enabled."
        else
            echo "Please enable nconnect patch and try again."
            exit 1
        fi
    fi
fi

echo "Nconnect patch enabled:" $(cat /sys/module/sunrpc/parameters/enable_azure_nconnect)
echo "Read scaling patch enabled:" $(cat /sys/module/sunrpc/parameters/azure_nconnect_readscaling)

# Get the ram size, dirty ratio, and dirty background ratio
# We need to change the VM dirty config to start flushing when there are fewer dirty pages so that there is not
# excessive queueing of requests at the NFS client causing requests to timeout even w/o being sent to the server.
# expr \( 16 \* 1024 \* 1024 \* 1024 \) > /proc/sys/vm/dirty_bytes
# expr \( 4 \* 1024 \* 1024 \* 1024 \) > /proc/sys/vm/dirty_background_ratio
# These values will be reset on system reboot so you will have to persisting them in /etc/sysctl.conf or however your distro allows.
# cat /proc/vmstat | egrep "nr_free_pages|nr_active_file|nr_inactive_file" | awk '{print $2}' | paste -s -d+ | bc
free -ght
cat /proc/sys/vm/dirty_background_ratio
cat /proc/sys/vm/dirty_ratio

# Latency details
echo "Tcping checks on port 2048:"
date -u; tcping -x 10 $ipaddr 2048; date -u

echo "Tcping checks on port 111:"
date -u; tcping -x 10 $ipaddr 111; date -u

echo "Httping checks:" 
date -u; httping -c 10 $ipaddr; date -u

echo "TestHook Write Ioping checks:"
truncate -s 1G ioping.write.$randomnum
date -u; ioping -c 10 -s 4K -WWW ioping.write.$randomnum; date -u
date -u; ioping -c 10 -s 1M -WWW ioping.write.$randomnum; date -u

echo "TestHook Read Ioping checks:"
truncate -s 1G ioping.read.$randomnum
date -u; ioping -c 10 -s 4K ioping.read.$randomnum; date -u
date -u; ioping -c 10 -s 1M ioping.read.$randomnum; date -u

echo "File Write Ioping checks:"
truncate -s 1G ioping.write.$randomnum
date -u; ioping -c 10 -s 4K -WWW -L ioping.write.$randomnum; date -u
date -u; ioping -c 10 -s 1M -WWW -L ioping.write.$randomnum; date -u
date -u; ioping -c 10 -s 4K -WWW ioping.write.$randomnum; date -u
date -u; ioping -c 10 -s 1M -WWW ioping.write.$randomnum; date -u

echo "File Read Ioping checks:"
truncate -s 1G ioping.read.$randomnum
date -u; ioping -c 10 -s 4K -L ioping.read.$randomnum; date -u
date -u; ioping -c 10 -s 1M -L ioping.read.$randomnum; date -u
date -u; ioping -c 10 -s 4K ioping.read.$randomnum; date -u
date -u; ioping -c 10 -s 1M ioping.read.$randomnum; date -u

# Throughput test
echo "TestHook Write throughput test:"
date -u; time dd if=/dev/zero of=..TestHook bs=1M count=10000 conv=fsync status=progress; date -u

echo "TestHook Read throughput test:"
echo 3 > /proc/sys/vm/drop_caches
date -u; time dd of=/dev/null if=..TestHook bs=1G count=10 status=progress; date -u

echo "File Write throughput test, file: dd.file.$randomnum:"
date -u; time dd if=/dev/zero of=dd.file.$randomnum bs=1M count=10000 conv=fsync status=progress; date -u

echo "File Read throughput test, file: dd.file.$randomnum:"
echo 3 > /proc/sys/vm/drop_caches
date -u; time dd of=/dev/null if=dd.file.$randomnum bs=1G count=10 status=progress; date -u

# Download & Untar Wordpress zip
echo "Downloading wordpress zip:"
date -u; wget https://wordpress.org/latest.tar.gz &> /dev/null; date -u
echo "Untar wordpress zip:"
date -u; time tar -xf latest.tar.gz; date -u

mountstats $mountpoint -S /tmp/mountstats.baseline

# End Tshark capture
kill $tsharkpid
echo "-------------------- Share the tshark capture file (in /tmp/nfscapture.pcap) if it's not large. --------------------"

# Clean up the test dir
cd $mountpoint
rm -rf $testdir

echo "-------------------- Done $(date -u) --------------------"