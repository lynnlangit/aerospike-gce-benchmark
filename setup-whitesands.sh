#!/bin/bash

NUM_AS_SERVERS=20
NUM_AS_CLIENTS=20
ZONE=us-central1-b
PROJECT=maximal-inkwell-658

GCLOUD_ARGS="--zone $ZONE --project $PROJECT"

SERVER_IPS=""
CLIENT_IPS=""

# enable ssh login
/bin/echo "Setting up password login on servers..."
for i in $(seq 1 $NUM_AS_SERVERS); do
    /bin/echo -n "  as-server-$i"
    gcloud compute ssh $GCLOUD_ARGS as-server-$i --ssh-flag="-o LogLevel=quiet" \
        --command "sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config;
                   sudo sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/g' /etc/ssh/sshd_config;
                   echo 'root:password' | sudo chpasswd;
                   sudo service ssh restart > /dev/null"
done
/bin/echo ""

/bin/echo "Setting up password login on clients..."
for i in $(seq 1 $NUM_AS_CLIENTS); do
    /bin/echo -n "  as-client-$i"
    gcloud compute ssh $GCLOUD_ARGS as-client-$i --ssh-flag="-o LogLevel=quiet" \
        --command "sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config;
                   sudo sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/g' /etc/ssh/sshd_config;
                   echo 'root:password' | sudo chpasswd;
                   sudo service ssh restart > /dev/null"
done
/bin/echo ""
