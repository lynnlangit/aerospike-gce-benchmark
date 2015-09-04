# ---------------STARTING WITH GOOGLE CLOUD: STEP 0------------
# - Open Terminal & Create a working directory, cd into it
# - Authenticate to GCP 
gcloud auth login

# ------------------- SETUP: STEPS 1-8 -----------------------
# 1. SET VARIABLES
export NUM_AS_SERVERS=20                        
export NUM_AS_CLIENTS=20                        
export ZONE=us-central1-b
export PROJECT=<your-project-name>              # use your project name
export SERVER_INSTANCE_TYPE=n1-standard-8
export CLIENT_INSTANCE_TYPE=n1-highcpu-8
export USE_PERSISTENT_DISK=0                    # 0 for in-mem only, 1 for persistent disk
export GCE_USER=$USER                           # the username to use on Google Compute Engine

# 2. SET DEFAULTS
gcloud config set project $PROJECT
gcloud config set compute/zone $ZONE

# 3. CREATE SERVER GCE VMS AND DISKS          
# - In parallel, create server instances from an image. Create persistent disks if requested.
echo "Creating GCE instances, please wait..."
gcloud compute instances create `for i in $(seq 1 $NUM_AS_SERVERS); 
do echo   creating as-server-$i; 
done` --zone $ZONE --machine-type $SERVER_INSTANCE_TYPE --tags "http-server" --image aerospike-image-1 --image-project $PROJECT
if [ $USE_PERSISTENT_DISK -eq 1 ]
then
  gcloud compute disks create `for i in $(seq 1 $NUM_AS_SERVERS); 
  do echo   creating as-persistent-disk-$i; done` --zone $ZONE --size "500GB"
  for i in $(seq 1 $NUM_AS_SERVERS); do
    echo "  attaching to server-$i"
    gcloud compute instances attach-disk as-server-$i --disk as-persistent-disk-$i
  done
fi

# 4. UPDATE/UPLOAD THE CONFIG FILES
if [ $USE_PERSISTENT_DISK -eq 0 ]
then
  export CONFIG_FILE=inmem_only_aerospike.conf
else
  export CONFIG_FILE=inmem_and_ondisk_aerospike.conf
fi

for i in $(seq 1 $NUM_AS_SERVERS); do
  echo -n "as-server-$i: "
  gcloud compute copy-files $CONFIG_FILE $GCE_USER@as-server-$i:aerospike.conf    
  gcloud compute ssh as-server-$i --zone $ZONE --command "sudo mv ~/aerospike.conf /etc/aerospike/aerospike.conf"
done

# 5. MODIFY CONFIG FILES TO SETUP MESH    
server1_ip=`gcloud compute instances describe as-server-1 --zone $ZONE | grep networkIP | cut -d ' ' -f 4`
echo "Updating remote config files to use server1 IP $server1_ip as mesh-address":
for i in $(seq 1 $NUM_AS_SERVERS); do
  echo -n "  as-server-$i: "
  gcloud compute ssh as-server-$i --zone $ZONE --command "sudo sed -i 's/mesh-address .*/mesh-address $server1_ip/g' /etc/aerospike/aerospike.conf"
done

# 6. CREATE CLIENT VMS
# - In parallel, create client boot-disks and client instances 
echo "Creating client instances, please wait..."
gcloud compute instances create `for i in $(seq 1 $NUM_AS_CLIENTS); do echo   as-client-$i; done` --zone $ZONE --machine-type $CLIENT_INSTANCE_TYPE --tags "http-server" --image aerospike-image-1 --image-project $PROJECT

# 7. BOOT SERVERS TO CREATE CLUSTER  ***We Need to test WITHOUT 'taskset'***
# - We are running server only on 19 cores (0-19) out of 20 cores using the taskset command
# - Network latencies take a hit when all the cores are busy - taskset improves perf by 10-20%, 
# - but must verify w/GCE updates
#echo "Starting aerospike daemons on cores 0-18..."
#for i in $(seq 1 $NUM_AS_SERVERS); do
#  echo -n "server-$i: "
#  gcloud compute ssh as-server-$i --zone $ZONE --command "sudo taskset -c 0-6 /usr/bin/asd --config-file /etc/aerospike/aerospike.conf"
#done

# 8. START AMC (Aerospike Management Console) on server-1
# - Find the public IP of as-server-1 and in your browser open http://<public ip of server-1>:8081
# - Then enter the internal IP in the dialog box in the AMC window http://<internal IP of server-1>:3000
# - You can find the IPs on GCP console, COMPUTE>click on instance named 'server-1'
# - You may need to create firewall rules to open the ports, GCP console, COMPUTE>Firewalls
echo "Starting Aerospike management console on as-server-1"
gcloud compute ssh as-server-1 --zone $ZONE --ssh-flag="-t" --command "sudo service amc start"

# ------------------- LOAD: STEPS 9-12 -----------------------
# 9. SET LOAD PARAMETERS
export NUM_KEYS=100000000
export CLIENT_THREADS=256
server1_ip=`gcloud compute instances describe as-server-1 --zone $ZONE | grep networkIP | cut -d ' ' -f 4`

# 10. RUN INSERT LOAD AND RUN BENCHMARK TOOL (included w/Aerospike Java SDK)   
echo "Starting inserts benchmarks..."
num_keys_perclient=$(expr $NUM_KEYS / $NUM_AS_CLIENTS )
for i in $(seq 1 $NUM_AS_CLIENTS); do
  startkey=$(expr \( $NUM_KEYS / $NUM_AS_CLIENTS \) \* \( $i - 1 \) )
  echo -n "  as-client-$i: "
# - For more about benchmark flags, use 'benchmarks -help'
# - Benchmark flags as follows - uses 256 threads, -n <namespace>, -w <workload>, I <Insert>, 
# - continues... -o <objects>, S:50 <strings of size 50>, -b <num bins or columns>, -l <key size in bytes>, -S <starting key>,
# - continues... -k <keys per client>, -latency <historgram output>
  gcloud compute ssh as-client-$i --zone $ZONE --command 
    "cd ~/aerospike-client-java/benchmarks ; 
    ./run_benchmarks -z $CLIENT_THREADS -n test -w I 
    -o S:50 -b 3 -l 20 -S $startkey -k $num_keys_perclient -latency 10,1 -h $server1_ip > /dev/null &"
done

# 11. RUN READ-MODIFY-WRITE LOAD and also READ LOAD with desired read percentage   
echo "Starting read/modify/write benchmarks..."
server1_ip=`gcloud compute instances describe as-server-1 --zone $ZONE | grep networkIP | cut -d ' ' -f 4`
export READPCT=100
for i in $(seq 1 $NUM_AS_CLIENTS); do
  echo -n "  as-client-$i: "
  gcloud compute ssh as-client-$i --zone $ZONE --command "cd ~/aerospike-client-java/benchmarks ; ./run_benchmarks -z $CLIENT_THREADS -n test -w RU,$READPCT -o S:50 -b 3 -l 20 -k $NUM_KEYS -latency 10,1 -h $server1_ip > /dev/null &"
  gcloud compute ssh as-client-$i --zone $ZONE --command "cd ~/aerospike-client-java/benchmarks ; ./run_benchmarks -z $CLIENT_THREADS -n test -w RU,$READPCT -o S:50 -b 3 -l 20 -k $NUM_KEYS -latency 10,1 -h $server1_ip > /dev/null &"
done

# 12. STOP THE LOAD
# Wait for user input to shut down the benchmarks
read -p "Press any key to stop the benchmarks..."
 "Shutting down benchmark clients..."
for i in $(seq 1 $NUM_AS_CLIENTS); do
  echo -n "  as-client-$i: "
  gcloud compute ssh as-client-$i --zone $ZONE --command "kill \`pgrep java\`"
done

# ------------------- CLEAN UP: STEPS 13-15 -----------------------
# 13. STOP SERVERS
echo "Shutting down aerospike daemons..."
for i in $(seq 1 $NUM_AS_SERVERS); do
  echo -n "  as-server-$i: "
  gcloud compute ssh as-server-$i --zone $ZONE --command "sudo kill \`pgrep asd\`"
done

# 14. DELETE DISKS
if [ $USE_PERSISTENT_DISK -eq 1 ]
then
  echo "Deleting persistent disks..."
  for i in $(seq 1 $NUM_AS_SERVERS); do
    echo -n "  detaching from as-server-$i: "
    gcloud compute instances detach-disk as-server-$i --disk as-persistent-disk-$i
  done
  gcloud compute disks delete `for i in $(seq 1 $NUM_AS_SERVERS); do echo   deleting as-persistent-disk-$i; done` --zone $ZONE -q
fi

# 15. SHUTDOWN ALL INSTANCES
echo "Shutting down VM instances..."
gcloud compute instances delete --quiet --zone $ZONE `for i in $(seq 1 $NUM_AS_SERVERS); 
do echo -n   as-server-$i " "; done`
gcloud compute instances delete --quiet --zone $ZONE `for i in $(seq 1 $NUM_AS_CLIENTS); 
do echo -n   as-client-$i " "; done`
