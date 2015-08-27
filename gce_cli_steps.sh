# ---------------STARTING WITH GOOGLE CLOUD--------------------
# - Create or use your GCP account at https://cloud.google.com/
# - Access your GCP console at https://console.developers.google.com
# - Create a new GCP project
# - Navigate to your project Compute> VM section
# - Install the gcloud tool download from - https://cloud.google.com/sdk/

# ------------------- SETUP: STEPS 0-9 -----------------------
# 0. PREPARE LOCAL WORKING AREA
# - Open Terminal
# - Create a working directory, cd into it
# - Authenticate to GCP by running `gcloud auth login`
# - Comment this step if you've already set up auth
gcloud auth login

# 1. SET VARIABLES
# - parameterize how many server & clients we need
# - Uncomment step-6 if number of servers >= 32   // in what situation is >=32 servers needed?
# -                                               // what are the default GCP project limits for resources?
export NUM_AS_SERVERS=10                        # // are these minimum numbers?
export NUM_AS_CLIENTS=20                        # // are these minimum numbers?
export ZONE=us-central1-b
export PROJECT=<your-project-name>              # the project where the image files live
export SERVER_INSTANCE_TYPE=n1-standard-8
export CLIENT_INSTANCE_TYPE=n1-highcpu-8
export USE_PERSISTENT_DISK=0                    # 0 for in-mem only, 1 for persistent disk

# 2. SET DEFAULTS
# - set the default project & zone so that we don’t need to pass it each time
gcloud config set project $PROJECT
gcloud config set compute/zone $ZONE

# 3. CREATE SERVER GCE VMS AND DISKS          //how do we provide others with this image? another script to setup?
# - In parallel, create server instances from the image. Create persistent disks if requested
# - (takes time. dont press ctrl-c)
# - You will see the instances become available in the GCP console, COMPUTE>VMs
echo "Creating GCE instances, please wait..."
gcloud compute instances create `for i in $(seq 1 $NUM_AS_SERVERS); do echo   creating as-server-$i; done` --zone $ZONE --machine-type $SERVER_INSTANCE_TYPE --tags "http-server" --image aerospike-image-1 --image-project $PROJECT
if [ $USE_PERSISTENT_DISK -eq 1 ]
then
  gcloud compute disks create `for i in $(seq 1 $NUM_AS_SERVERS); do echo   creating as-persistent-disk-$i; done` --zone $ZONE --size "500GB"
  for i in $(seq 1 $NUM_AS_SERVERS); do
    echo "  attaching to server-$i"
    gcloud compute instances attach-disk as-server-$i --disk as-persistent-disk-$i
  done
fi

# 4. UPDATE/UPLOAD THE CONFIG FILES
# - Replace the config file path and the username with the desired ones   //any non-standard conf file settings?

if [ $USE_PERSISTENT_DISK -eq 0 ]
then
  export CONFIG_FILE=inmem_only_aerospike.conf
else
  export CONFIG_FILE=inmem_and_ondisk_aerospike.conf
fi

for i in $(seq 1 $NUM_AS_SERVERS); do
  echo -n "as-server-$i: "
  # XXX I think we can get rid of the user name and let it use the default
  gcloud compute copy-files $CONFIG_FILE sunil@as-server-$i:aerospike.conf    # //<username>>@as-server-$1:... ?
  gcloud compute ssh as-server-$i --zone $ZONE --command "sudo mv ~/aerospike.conf /etc/aerospike/aerospike.conf"
done

# 5. MODIFY CONFIG FILES TO SETUP MESH    //how do I verify this succeeded?
#                                         // XXX we could cat & grep the config files and look for the IP
server1_ip=`gcloud compute instances describe as-server-1 --zone $ZONE | grep networkIP | cut -d ' ' -f 4`
echo "Updating remote config files to use server1 IP $server1_ip as mesh-address":
for i in $(seq 1 $NUM_AS_SERVERS); do
  echo -n "  as-server-$i: "
  gcloud compute ssh as-server-$i --zone $ZONE --command "sudo sed -i 's/mesh-address .*/mesh-address $server1_ip/g' /etc/aerospike/aerospike.conf"
done

# 6. MODIFY CONFIG FILES AGAIN FOR MORE THAN 32 NODES ONLY                                //what do lines 74-75 actually do?
# -  This step is needed if going beyond the default limit of 32 nodes. Uncomment if needed  //don't understand, why?
# -  This command should be run only once as it will add a new line to the config file every time it runs.   <-- XXX redundant comment, we just overwrote the file above

# Update the max paxos cluster size to 60, if we're using more than 32 nodes.
# XXX does this mean that the true maximum is 60?

if [ $NUM_AS_SERVERS -gt 32 ]
then
  echo "Setting paxos-max-cluster-size to 60:"
  for i in $(seq 1 $NUM_AS_SERVERS); do
    echo -n "  as-server-$i: "
    gcloud compute ssh as-server-$i --zone $ZONE --command "sudo sed -i 's/proto-fd-max 15000/proto-fd-max 15000\n\tpaxos-max-cluster-size 60/g' /etc/aerospike/aerospike.conf"
  done
fi


# 7. CREATE CLIENT VMS
# - In prallel, create client boot-disks and client instances (takes time. dont press ctrl-c)
# - You will see the disks become available in the GCP console, COMPUTE>Disks
echo "Creating client instances, please wait..."
gcloud compute instances create `for i in $(seq 1 $NUM_AS_CLIENTS); do echo   as-client-$i; done` --zone $ZONE --machine-type $CLIENT_INSTANCE_TYPE --tags "http-server" --image aerospike-image-1 --image-project $PROJECT

# 8. BOOT SERVERS TO CREATE CLUSTER
# - We are running server only on 7 cores (0-6) out of 8 cores using the taskset command
# -  network latencies take a hit when all the cores are busy
# XXX: what is the performance boost from enabling cpu affinity?
echo "Starting aerospike daemons on cores 0-6..."
for i in $(seq 1 $NUM_AS_SERVERS); do
  echo -n "server-$i: "
  gcloud compute ssh as-server-$i --zone $ZONE --command "sudo taskset -c 0-6 /usr/bin/asd --config-file /etc/aerospike/aerospike.conf"
done

# 9. START AMC (Aerospike Management Console) on server-1
# - Find the public IP of as-server-1 and in your browser open http://<public ip of server-1>:8081
# - Then enter the internal IP in the dialog box in the AMC window http://<internal IP of server-1>:3000
# - You can find the IPs on GCP console, COMPUTE>click on instance named 'server-1'
# - You may need to create firewall rules to open the ports, GCP console, COMPUTE>Firewalls
echo "Starting Aerospike management console on as-server-1"
gcloud compute ssh as-server-1 --zone $ZONE --ssh-flag="-t" --command "sudo service amc start"

# ------------------- LOAD: STEPS 10-13 -----------------------
# 10. SET LOAD PARAMETERS
export NUM_KEYS=100000000
export CLIENT_THREADS=256
server1_ip=`gcloud compute instances describe as-server-1 --zone $ZONE | grep networkIP | cut -d ' ' -f 4`

# 11. DO INSERTS             //what does line 118 do exactly?
echo "Starting inserts benchmarks..."
num_keys_perclient=$(expr $NUM_KEYS / $NUM_AS_CLIENTS )
for i in $(seq 1 $NUM_AS_CLIENTS); do
  # XXX what do all the flags mean?
  # XXX how is the benchmark tool installed? if already installed, where is it put?
  startkey=$(expr \( $NUM_KEYS / $NUM_AS_CLIENTS \) \* \( $i - 1 \) )
  echo -n "  as-client-$i: "
  gcloud compute ssh as-client-$i --zone $ZONE --command "cd ~/aerospike-client-java/benchmarks ; ./run_benchmarks -z $CLIENT_THREADS -n test -w I -o S:50 -b 3 -l 20 -S $startkey -k $num_keys_perclient -latency 10,1 -h $server1_ip > /dev/null &"
done

# 12. RUN READ-MODIFY-WRITE LOAD and also READ LOAD with desired read percentage   //explain lines 129 and 130
# - start two instances of the client on each machine
echo "Starting read/modify/write benchmarks..."
server1_ip=`gcloud compute instances describe as-server-1 --zone $ZONE | grep networkIP | cut -d ' ' -f 4`
export READPCT=100
for i in $(seq 1 $NUM_AS_CLIENTS); do
  # XXX same question, what do these flags mean
  echo -n "  as-client-$i: "
  gcloud compute ssh as-client-$i --zone $ZONE --command "cd ~/aerospike-client-java/benchmarks ; ./run_benchmarks -z $CLIENT_THREADS -n test -w RU,$READPCT -o S:50 -b 3 -l 20 -k $NUM_KEYS -latency 10,1 -h $server1_ip > /dev/null &"
  gcloud compute ssh as-client-$i --zone $ZONE --command "cd ~/aerospike-client-java/benchmarks ; ./run_benchmarks -z $CLIENT_THREADS -n test -w RU,$READPCT -o S:50 -b 3 -l 20 -k $NUM_KEYS -latency 10,1 -h $server1_ip > /dev/null &"
done


# Wait for user input to shut down the benchmarks
read -p "Press any key to stop the benchmarks..."


# 13. STOP THE LOAD
echo "Shutting down benchmark clients..."
for i in $(seq 1 $NUM_AS_CLIENTS); do
  echo -n "  as-client-$i: "
  gcloud compute ssh as-client-$i --zone $ZONE --command "kill \`pgrep java\`"
done

# ------------------- CLEAN: STEPS 14-16 -----------------------
# 14. STOP SERVERS
echo "Shutting down aerospike daemons..."
for i in $(seq 1 $NUM_AS_SERVERS); do
  echo -n "  as-server-$i: "
  gcloud compute ssh as-server-$i --zone $ZONE --command "sudo kill \`pgrep asd\`"
done

# 15. DELETE DISKS
if [ $USE_PERSISTENT_DISK -eq 1 ]
then
  echo "Deleting persistent disks..."
  for i in $(seq 1 $NUM_AS_SERVERS); do
    echo -n "  detaching from as-server-$i: "
    gcloud compute instances detach-disk as-server-$i --disk as-persistent-disk-$i
  done
  gcloud compute disks delete `for i in $(seq 1 $NUM_AS_SERVERS); do echo   deleting as-persistent-disk-$i; done` --zone $ZONE -q
fi

# 16. SHUTDOWN ALL INSTANCES
echo "Shutting down VM instances..."
gcloud compute instances delete --quiet --zone $ZONE `for i in $(seq 1 $NUM_AS_SERVERS); do echo -n   as-server-$i " "; done`
gcloud compute instances delete --quiet --zone $ZONE `for i in $(seq 1 $NUM_AS_CLIENTS); do echo -n   as-client-$i " "; done`
