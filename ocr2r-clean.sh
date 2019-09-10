source /OCR2R/ocr2r.prop

echo ICP_HOMEDIR is $ICP_HOMEDIR

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

##### Login using bx pr login
echo "ICP_HOMEDIR: $ICP_HOMEDIR"
if [[ "$MASTERNODE" == "" ]] ; then
   MASTERNODE=$(awk '/master/{print $1}' /etc/hosts)
   if [[ "$MASTERNODE" == "" ]] ; then
      echo Master node not found
      exit 1
   fi
fi

echo ===== login to ICP cluster =====
bx pr login -a https://$MASTERNODE:8443 --skip-ssl-validation -u admin -p admin
#####

##### Create storage and storage-claim
echo "Create storage and claim? y/n"; read ans
if [ "$ans" = "y" ]; then
   echo Config the storage yaml files
   kubectl create -f $ocr2rDir/db2-persistent-vol.yaml
#   kubectl create -f $ocr2rDir/db2-persistent-vol-claim.yaml
   kubectl create -f $ocr2rDir/mq-persistent-vol.yaml
#   kubectl create -f $ocr2rDir/mq-persistent-vol-claim.yaml
fi
#####

##### Run bx pr cluster-config mycluster to download Helm Certificates
bx pr cluster-config $CLUSTER
#####

##### Initialize Helm CLI and copy certificates for TLS
if [[ "$CLUSTERENV" == "yes" ]] ; then 
echo Clustered Environment detect
   for server in $NODES
   do
      if ssh root@$server '[ ! -d $HELM_HOME ]'; then
         echo "mkdir -p $HELM_HOME/charts - $server"
         ssh root@$server "mkdir -p $HELM_HOME/charts"  > /dev/null 2>&1
         echo "export HELM_HOME=$HELM_HOME - $server"
         ssh root@$server "export HELM_HOME=$HELM_HOME" > /dev/null 2>&1
      fi
      if [ ! -d /var/lib/helm ]; then
         echo "mkdir -p $HELM_HOME/charts"
         mkdir -p $HELM_HOME/charts
         echo "export HELM_HOME=$HELM_HOME"
         export HELM_HOME=$HELM_HOME

         echo ===== Copy certificates to /var/lib/helm =====
         echo "Copying /root/.helm to $HELM_HOME"
         cp -r /root/.helm/* $HELM_HOME > /dev/null 2>&1
         echo "Copying charts to $HELM_HOME/charts"
         cp -r /OCR2R/charts/* $HELM_HOME/charts > /dev/null 2>&1
      fi
   done
else   
   if [ ! -d $HELM_HOME ]; then
      echo "mkdir -p $HELM_HOME"
      mkdir -p $HELM_HOME/charts
      echo "export HELM_HOME=$HELM_HOME"
      export HELM_HOME=$HELM_HOME

      echo ===== Copy certificates to $HELM_HOME =====
      echo "Copying /root/.helm to $HELM_HOME"
      cp -r /root/.helm/* $HELM_HOME > /dev/null 2>&1
      echo "Copying charts to $HELM_HOME/charts"
      cp -r /OCR2R/charts/* $HELM_HOMElm/charts > /dev/null 2>&1
   fi
fi

echo ===== Inintialize helm CLI =====
helm init --client-only --skip-refresh

echo ===== Verify helm cli version =====
helm version --tls
#####

##### Create secret
USERNAME=$SECRETUSER
SECRETNAME=$SECRETNAME
APIKEY=$APIKEY
EMAIL=$SECRETEMAIL

#if [ ! -f /root/.secretCreated ]; then
#   touch /root/.secretCreated
#   kubectl create secret docker-registry $SECRETNAME \
#        --docker-username=$USERNAME \
#        --docker-password=$APIKEY \
#        --docker-email=$EMAIL \
#        --namespace=default

   echo Patch service account with docker-registry secret 
#   kubectl patch serviceaccount default -p \
#       '{"imagePullSecrets": [{"name": "admin.registrykey"}]}' \
#        --namespace=default
##       '{"imagePullSecrets": [{"name": "prolifics01"}]}' \
#else
#   echo Secret alredy created
#fi
#####

##### Add repo
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
helm repo add incubator https://kubernetes-charts-incubator.storage.googleapis.com/
#PORT=$(kubectl get svc $REPO-service -o json | jq -r .spec.ports[].nodePort)
#PORT=$(kubectl get svc $REPO-service -o json | jq -r .spec.ports[].nodePort)
#helm repo add $REPO http://$IPADDR:$PORT/repo/stable
#helm repo add $REPO http://10.0.12.60/charts/repo/stable
helm repo add $REPO https://raw.githubusercontent.com/IBM/charts/master/repo/stable/
helm repo update
#helm repo list
#helm search $REPO
read -p "Press enter to continue..."
#####

##### Adding service
echo "Creating $REPO-service"
kubectl apply -f service.yaml
#####

##### Purpose: Install db2 chart
read -p "Press enter to continue to DB2"
echo ===== Install db2 chart =====
read -p "Install DB2? y/n: " instdb2
if [[ $instdb2 == "y" ]]; then
   helm install $REPO/ibm-db2oltp-dev -n $db2dev -f db2-values.yaml --tls
#   helm install local/ibm-db2oltp-dev -n $db2dev -f db2-values.yaml --tls
   echo Sleeping for 5 minutes ..... 
#   sleep 300
   helm status $db2dev --tls
   read -p "Is $db2dev ready? y/n: " cont
   if [[ $cont == "n" ]]; then
      echo Sleeping 5 minutes...
#   sleep 300
   else
      echo continuing...
   fi
else
   echo Not installing DB2...
fi

#####

#### Purpose: Install MQ Advanced
read -p "Press enter to continue to MQ"
echo ===== Install MQ Advanced =====
read -p "Install MQ? y/n: " instmq
if [[ $instmq == "y" ]]; then
   helm install $REPO/ibm-mqadvanced-server-dev -n $mqdev -f mq-values.yaml --tls
   echo Sleeping 5 minutes...
   #sleep 300
else
   echo Not installing MQ...
fi

helm status $mqdev --tls
read -p "Is $mqdev ready? y/n: " cont
if [[ $cont == "n" ]]; then
   echo Sleeping 5 minutes...
   #sleep 300
else
   echo continuing...
fi

read -p "Continue? y/n: " cont
if [[ $cont == "n" ]]; then
   echo exiting...
   exit 0
else
   echo continuing...
fi
#####

##### MQ NotificationQ and grant all auths
echo ===== Create MQ NotificationQ and grant all auths =====
echo ===== Get MQ pod name =====
MQPOD=$(kubectl -n default get pods --selector app=$(mqdev)-ibm-mq -o jsonpath='{.items[].metadata.name}')

echo MQ pod name = $MQPOD

echo ===== Create MQ commands in a script and then copy to the Pod =====

cat << EOF > /tmp/createq
#!/bin/bash
# Copy this script in MQ container and then run it
echo "DEFINE QL('NotificationQ')" > /tmp/crq.txt
runmqsc qmgr < /tmp/crq.txt
dspmqaut -m qmgr -t qmgr -p app
setmqaut -m qmgr -t qmgr -p app +all
echo "ALTER QMGR CHLAUTH(DISABLED)" > /tmp/chauth.txt
runmqsc qmgr < /tmp/chauth.txt
dspmqaut -m qmgr -n NotificationQ -t queue -p app
setmqaut -m qmgr -n NotificationQ -t queue -p app +all
dspmqaut -m qmgr -n NotificationQ -t queue -p app
EOF

chmod +x /tmp/createq
kubectl -n default cp /tmp/createq $MQPOD:/tmp

echo ===== Run script in MQ pod =====
kubectl -n default exec -it $MQPOD -- /bin/bash -c "/tmp/createq"
#####

##### Create secrets for trader container
echo ===== Create tables in Db2 for portfolio =====
echo

echo Get the db2 pod name
DB2POD=$(kubectl -n default get pods --selector app=$(db2dev)-ibm-db2oltp-dev -o jsonpath='{.items[].metadata.name}')
echo Db2 pod name = $DB2POD

echo ===== Copy file to the Pod =====
kubectl -n default cp ./tables.sql $DB2POD:/tmp

echo ===== Create tables in Db2 pod =====
kubectl -n default exec -it $DB2POD -- /bin/bash -c "su - db2psc -c \"db2 -tvf /tmp/tables.sql\""
#####
