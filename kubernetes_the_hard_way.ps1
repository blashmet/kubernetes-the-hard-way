#region INSTALL_PREREQUISITES

#Install Chocolatey

$ChocoIsInstalled = powershell.exe choco -v

if($ChocoIsInstalled){

    Write-Host "Chocolatey Version $ChocoIsInstalled is already installed!" -ForegroundColor Yellow
}

else{    

    Write-Host "Chocolatey is not installed, installing now..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
 }

#Install Google Cloud Platform SDK

choco install gcloudsdk --ignore-checksums -y

gcloud init

#Enter credentials in browser window

#Select 1 for default project

#Set a default region and compute zone

gcloud config set compute/region us-west1

gcloud config set compute/zone us-west1-c

#endregion INSTALL_PREREQUISITES

#regoin INSTALLING_THE_CLIENT_TOOLS

#Install cfssl, cfssljson, and kubectl
#https://github.com/cloudflare/cfssl

choco install kubernetes-cli -y

#endregion INSTALLING_THE_CLIENT_TOOLS


#region PROVISION_COMPUTE_RESOURCES


#Create VPC [note, you might be prompted to enable API access. enter 'y' to enable]
gcloud compute networks create kubernetes-the-hard-way --subnet-mode custom

#Create Subnet
gcloud compute networks subnets create kubernetes --network kubernetes-the-hard-way --range 10.240.0.0/24

#Create firewall rule that allows internal communication across all protocols:
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-internal --allow tcp,udp,icmp --network kubernetes-the-hard-way --source-ranges 10.240.0.0/24,10.200.0.0/16

#Create firewall rule that allows external SSH, ICMP, and HTTPS:
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-external --allow tcp:22,tcp:6443,icmp --network kubernetes-the-hard-way --source-ranges 0.0.0.0/0

#Allocate IP address for API server external load balancer

gcloud compute addresses create kubernetes-the-hard-way --region $(gcloud config get-value compute/region)

#Provision 3 controllers

For ($i=1; $i -le 3; $i++) {

      gcloud compute instances create controller-${i} --async --boot-disk-size 200GB --can-ip-forward --image-family ubuntu-2004-lts --image-project ubuntu-os-cloud --machine-type e2-standard-2 --private-network-ip 10.240.0.1${i} --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring --subnet kubernetes --tags kubernetes-the-hard-way,controller

    }

#Provision 3 worker nodes
For ($i=1; $i -le 3; $i++) {

      gcloud compute instances create worker-${i} --async --boot-disk-size 200GB --can-ip-forward --image-family ubuntu-2004-lts --image-project ubuntu-os-cloud --machine-type e2-standard-2 --metadata pod-cidr=10.200.${i}.0/24 --private-network-ip 10.240.0.2${i} --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring --subnet kubernetes --tags kubernetes-the-hard-way,worker

}

#endregion PROVISION_COMPUTE_RESOURCES




#region PROVISION_CA_AND_TLS_CERTS

#Provision CA - Generate the CA configuration file, certificate, and private key:

$CaConfigJson = @'
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
'@

$CaConfigJson | Out-File "ca-config.json" -Force

$CaCsrJson = @'
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
'@

$CaCsrJson | Out-File "ca-csr.json" -Force

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

#Client and Server Certificates

##Admin Client Certificate

$AdminCsrJson = @'
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
'@

$AdminCsrJson | Out-File "admin-csr.json" -Force

cfssl gencert -ca="ca.pem" -ca-key="ca-key.pem" -config="ca-config.json" -profile="kubernetes" admin-csr.json | cfssljson -bare admin

##Kubelet Client Certificates

$Instances = @("worker-1","worker-2","worker-3")

ForEach($instance in $Instances){

$CsrContent = @"
{
  "CN": "system:node:$($instance)",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
"@

$CsrContent | Out-File "$($instance)-csr.json" -Encoding UTF8 -Force

$ExternalIp = $(gcloud compute instances describe $($instance) --format 'value(networkInterfaces[0].accessConfigs[0].natIP)')

$InternalIp = $(gcloud compute instances describe $($instance) --format 'value(networkInterfaces[0].networkIP)')

cfssl gencert -ca="ca.pem" -ca-key="ca-key.pem" -config="ca-config.json" -profile="kubernetes" -hostname="$($instance),$($ExternalIp),$($InternalIp)" "$($instance)-csr.json" | cfssljson -bare $($instance)

}

#The rest here: https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/04-certificate-authority.md


#endregion PROVISION_CA_TLS_CERTS

#region DISTIRBUTE_CLIENT_AND_SERVER_CERTS

#Copy the appropriate certificates and private keys to each worker instance:

for instance in worker-1 worker-2 worker-3; do
  gcloud compute scp ca.pem ${instance}-key.pem ${instance}.pem ${instance}:/home/blash
done

#Copy the appropriate certificates and private keys to each controller instance:

for instance in controller-1 controller-2 controller-3; do
  gcloud compute scp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
    service-account-key.pem service-account.pem ${instance}:/home/blash
done

#endregion DISTIRBUTE_CLIENT_AND_SERVER_CERTS


#region Generating Kubernetes Configuration Files for Authentication

$KUBERNETES_PUBLIC_ADDRESS = $(gcloud compute addresses describe kubernetes-the-hard-way --region $(gcloud config get-value compute/region)--format 'value(address)')


for instance in worker-1 worker-2 worker-3; do
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=${instance}.pem \
    --client-key=${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${instance} \
    --kubeconfig=${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=${instance}.kubeconfig
done

kubectl config set-cluster kubernetes-the-hard-way \
--certificate-authority=ca.pem \
--embed-certs=true \
--server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
--kubeconfig=kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
--client-certificate=kube-proxy.pem \
--client-key=kube-proxy-key.pem \
--embed-certs=true \
--kubeconfig=kube-proxy.kubeconfig

kubectl config set-context default \
--cluster=kubernetes-the-hard-way \
--user=system:kube-proxy \
--kubeconfig=kube-proxy.kubeconfig

kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

kubectl config set-cluster kubernetes-the-hard-way \
--certificate-authority=ca.pem \
--embed-certs=true \
--server=https://127.0.0.1:6443 \
--kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \
--client-certificate=kube-controller-manager.pem \
--client-key=kube-controller-manager-key.pem \
--embed-certs=true \
--kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-context default \
--cluster=kubernetes-the-hard-way \
--user=system:kube-controller-manager \
--kubeconfig=kube-controller-manager.kubeconfig

kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-cluster kubernetes-the-hard-way \
--certificate-authority=ca.pem \
--embed-certs=true \
--server=https://127.0.0.1:6443 \
--kubeconfig=admin.kubeconfig

kubectl config set-credentials admin \
--client-certificate=admin.pem \
--client-key=admin-key.pem \
--embed-certs=true \
--kubeconfig=admin.kubeconfig

kubectl config set-context default \
--cluster=kubernetes-the-hard-way \
--user=admin \
--kubeconfig=admin.kubeconfig

kubectl config use-context default --kubeconfig=admin.kubeconfig

#Copy the appropriate kubelet and kube-proxy kubeconfig files to each worker instance:

for instance in worker-1 worker-2 worker-3; do
  gcloud compute scp ${instance}.kubeconfig kube-proxy.kubeconfig ${instance}:/home/blash
done

#Copy the appropriate kube-controller-manager and kube-scheduler kubeconfig files to each controller instance:

for instance in controller-1 controller-2 controller-3; do
  gcloud compute scp admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig ${instance}:/home/blash
done

#endregion Generating Kubernetes Configuration Files for Authentication

#region Generating the Data Encryption Config and Key

#Generate an encryption key:
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

#Create the encryption-config.yaml encryption config file:
cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

#Copy the encryption-config.yaml encryption config file to each controller instance:

for instance in controller-1 controller-2 controller-3; do
  gcloud compute scp encryption-config.yaml ${instance}:/home/blash
done

#endregion Generating the Data Encryption Config and Key