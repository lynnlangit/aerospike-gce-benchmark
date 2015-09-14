#!/bin/bash

# ---------------STARTING WITH GOOGLE CLOUD: STEP 0------------
ACCOUNT=<your GCE user email>
gcloud auth login $ACCOUNT --brief              # authenticate to GCP from your working directory via Terminal.
                                                # will not launch if $ACCOUNT already has credentials.

# ------------------- SETUP: STEPS 1-5 -----------------------
# 1a. SET VARIABLES
NUM_AS_SERVERS=20
NUM_AS_CLIENTS=20
ZONE=us-central1-b
PROJECT=<your GCE project>               # use your project name
SERVER_INSTANCE_TYPE=n1-standard-8
CLIENT_INSTANCE_TYPE=n1-highcpu-8
USE_PERSISTENT_DISK=0                    # 0 for in-mem only, 1 for persistent disk
AEROSPIKE_IMAGE=aerospike-image-1        # the Aerospike image you create and store in GCE Images

SERVER_INSTANCES=`for i in $(seq 1 $NUM_AS_SERVERS); do echo as-server-$i; done`
SERVER_DISKS=`for i in $(seq 1 $NUM_AS_SERVERS); do echo as-persistent-disk-$i; done`
CLIENT_INSTANCES=`for i in $(seq 1 $NUM_AS_CLIENTS); do echo as-client-$i; done`

GCLOUD_ARGS="--zone $ZONE --project $PROJECT"

# 2. CREATE SERVER GCE VMS AND DISKS
echo "Creating GCE server instances, please wait..."
gcloud compute instances create $GCLOUD_ARGS $SERVER_INSTANCES \
    --machine-type $SERVER_INSTANCE_TYPE --tags "http-server" \
    --image $AEROSPIKE_IMAGE --image-project $PROJECT

# Set up persistent disks if necessary
if [ $USE_PERSISTENT_DISK -eq 1 ]
then
    /bin/echo "Creating persistent disks..."
    gcloud compute disks create $GCLOUD_ARGS $SERVER_DISKS --size "500GB"
    for i in $(seq 1 $NUM_AS_SERVERS); do
        /bin/echo -n "  attaching as-persistent-disk-$i to as-server-$i:"
        gcloud compute instances $GCLOUD_ARGS attach-disk as-server-$i --disk as-persistent-disk-$i
    done
fi

# 3a. UPDATE/UPLOAD THE CONFIG FILES
if [ $USE_PERSISTENT_DISK -eq 0 ]
then
    CONFIG_FILE=inmem_only_aerospike.conf
else
    CONFIG_FILE=inmem_and_ondisk_aerospike.conf
fi

/bin/echo "Copying config files..."
for i in $(seq 1 $NUM_AS_SERVERS); do
    /bin/echo -n "  as-server-$i"
    gcloud compute copy-files $GCLOUD_ARGS $CONFIG_FILE as-server-$i:~/aerospike.conf --user-output-enabled=false
    gcloud compute ssh $GCLOUD_ARGS as-server-$i \
        --command "sudo mv ~/aerospike.conf /etc/aerospike/aerospike.conf" \
        --ssh-flag="-o LogLevel=quiet"
done
/bin/echo


# 3b. MODIFY CONFIG FILES TO SETUP MESH
server1_ip=`gcloud compute instances describe $GCLOUD_ARGS as-server-1 | grep networkIP | cut -d ' ' -f 4`
server1_external_ip=`gcloud compute instances describe $GCLOUD_ARGS as-server-1 | grep natIP | cut -d ' ' -f 6`
/bin/echo "Updating remote config files to use server1 IP $server1_ip as mesh-address:"
for i in $(seq 1 $NUM_AS_SERVERS); do
    /bin/echo -n "  as-server-$i"
    gcloud compute ssh $GCLOUD_ARGS as-server-$i --ssh-flag="-o LogLevel=quiet" \
        --command "sudo sed -i 's/mesh-address .*/mesh-address $server1_ip/g' /etc/aerospike/aerospike.conf"
done
/bin/echo

# 4. CREATE CLIENT VMS
/bin/echo "Creating client instances, please wait..."
gcloud compute instances create $GCLOUD_ARGS $CLIENT_INSTANCES \
    --machine-type $CLIENT_INSTANCE_TYPE --tags "benchmark-client" \
    --image $AEROSPIKE_IMAGE --image-project $PROJECT

# 4b?. BOOT SERVERS TO CREATE CLUSTER  ***We Need to test WITHOUT 'taskset'***
# - We are running server only on 19 cores (0-19) out of 20 cores using the taskset command
# - Network latencies take a hit when all the cores are busy - taskset improves perf by 10-20%,
# - but must verify w/GCE updates
/bin/echo "Starting aerospike daemons..."
for i in $(seq 1 $NUM_AS_SERVERS); do
  /bin/echo -n "  server-$i"
  #gcloud compute ssh as-server-$i --zone $ZONE --command "
  #  sudo taskset -c 0-6 /usr/bin/asd --config-file /etc/aerospike/aerospike.conf"
  gcloud compute ssh $GCLOUD_ARGS as-server-$i --ssh-flag="-o LogLevel=quiet" \
      --command "sudo /usr/bin/asd --config-file /etc/aerospike/aerospike.conf"
done
/bin/echo

# 5. START AMC (Aerospike Management Console) on server-1
# - Find the public IP of as-server-1, open http://<public ip of server-1>:8081, then http://<internal IP of server-1>:3000
/bin/echo "Starting Aerospike management console on as-server-1 (external: $server1_external_ip, internal: $server1_ip)"
gcloud compute ssh $GCLOUD_ARGS as-server-1 --ssh-flag="-t" \
    --command "sudo service amc start" --ssh-flag="-o LogLevel=quiet"
/bin/echo "AMC is available at: http://$server1_external_ip:8081"
/bin/echo "    use cluster seed node: $server1_ip"

# ------------------- LOAD: STEPS 6a-c -----------------------
# 6a. SET LOAD PARAMETERS
NUM_KEYS=100000000
CLIENT_THREADS=256

read -p "Press any key to start the benchmarks."

# 6b. RUN INSERT LOAD AND RUN BENCHMARK TOOL (included w/Aerospike Java SDK)
/bin/echo "Starting inserts benchmarks..."
num_keys_perclient=$(expr $NUM_KEYS / $NUM_AS_CLIENTS )
for i in $(seq 1 $NUM_AS_CLIENTS); do
    startkey=$(expr \( $NUM_KEYS / $NUM_AS_CLIENTS \) \* \( $i - 1 \) )
    /bin/echo -n "  as-client-$i: "
    # - For more about benchmark flags, use 'benchmarks -help'
    gcloud compute ssh $GCLOUD_ARGS as-client-$i --command \
        "cd ~sunil/aerospike-client-java/benchmarks ;
        ./run_benchmarks -z $CLIENT_THREADS -n test -w I \
          -o S:50 -b 3 -l 20 -S $startkey -k $num_keys_perclient -latency 10,1 \
          -h $server1_ip > /dev/null &" \
        --ssh-flag="-o LogLevel=quiet"
done
/bin/echo

# 6c. RUN READ-MODIFY-WRITE LOAD and also READ LOAD with desired read percentage
/bin/echo "Starting read/modify/write benchmarks..."
export READPCT=100
for i in $(seq 1 $NUM_AS_CLIENTS); do
    /bin/echo -n "  as-client-$i"
    gcloud compute ssh $GCLOUD_ARGS as-client-$i --command \
        "cd ~sunil/aerospike-client-java/benchmarks ;
        ./run_benchmarks -z $CLIENT_THREADS -n test -w RU,$READPCT -o S:50 -b 3 \
          -l 20 -k $NUM_KEYS -latency 10,1 -h $server1_ip > /dev/null &" \
        --ssh-flag="-o LogLevel=quiet"
done
/bin/echo

# ------------------- STOP & CLEAN UP: STEPS 7-10 -----------------------
# 7. STOP THE LOAD
read -p "Press any key to stop the benchmarks."
/bin/echo "Shutting down benchmark clients..."
for i in $(seq 1 $NUM_AS_CLIENTS); do
    /bin/echo -n "  as-client-$i"
    gcloud compute ssh $GCLOUD_ARGS as-client-$i --command "kill `pgrep java`" --ssh-flag="-o LogLevel=quiet"
done
/bin/echo

# 8. STOP SERVERS
echo "Shutting down aerospike daemons..."
for i in $(seq 1 $NUM_AS_SERVERS); do
    /bin/echo -n "  as-server-$i"
    gcloud compute ssh $GCLOUD_ARGS as-server-$i --command "sudo kill \`pgrep asd\`" --ssh-flag="-o LogLevel=quiet"
done
/bin/echo

read -p "Press any key to clean up instances..."

# 9. DELETE DISKS
if [ $USE_PERSISTENT_DISK -eq 1 ]
then
    /bin/echo "Detaching persistent disks..."
    for i in $(seq 1 $NUM_AS_SERVERS); do
      /bin/echo -n "  as-persistent-disk-$i"
      gcloud compute instances detach-disk $GCLOUD_ARGS as-server-$i --disk as-persistent-disk-$i
    done
    /bin/echo "  deleting disks..."
    gcloud compute disks delete $GCLOUD_ARGS $SERVER_DISKS -q
fi

# 10. SHUTDOWN ALL INSTANCES
echo "Shutting down VM instances..."
gcloud compute instances delete --quiet $GCLOUD_ARGS $SERVER_INSTANCES
gcloud compute instances delete --quiet $GCLOUD_ARGS $CLIENT_INSTANCES

