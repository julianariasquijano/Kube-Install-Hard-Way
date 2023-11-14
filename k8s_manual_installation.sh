#Setting Variables
#Compute cluster internal API server service address, which is always .1 in the service CIDR range. This is also required as a SAN in the API server certificate
POD_CIDR=10.244.0.0/16
SERVICE_CIDR=10.96.0.0/16
API_SERVICE=$(echo $SERVICE_CIDR | awk 'BEGIN {FS="."} ; { printf("%s.%s.%s.1", $1, $2, $3) }')
MASTER_1=10.0.2.210
MASTER_2=10.0.2.210
LOADBALANCER=10.0.2.210
WORKER_1=10.0.2.210
INTERNAL_IP=$MASTER_1
ETCD_NAME=$(hostname -s)
CONTAINERD_VERSION=1.5.9
CNI_VERSION=0.8.6
RUNC_VERSION=1.1.1
CLUSTER_DNS=10.96.0.10 # Tipically the SERVICE_CIDR but ending in 10
WORKER_NAME=worker-1

 #https://www.youtube.com/watch?v=uUupRagM7m0&list=PL2We04F3Y_41jYdadX55fdJplDvgNGENo
 #https://github.com/mmumshad/kubernetes-the-hard-way


 #Configure machines access
 #   master contol plane
        ssh-keygen
        cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys # scp to ourselfs will be used
 #   other machines to access them with the created key
        cat >> ~/.ssh/authorized_keys <<EOF
<<content of id_rsa.pub>>
EOF

 #Provisioning a CA and Generating TLS Certificates
 #https://kubernetes.io/docs/tasks/administer-cluster/certificates/#openssl

    cd; 
    mkdir certificates;cd certificates

 #      Create (CertificateAautohrity) Certificate

            # Create private key for CA
            openssl genrsa -out ca.key 2048

            # Comment line starting with RANDFILE in /etc/ssl/openssl.cnf definition to avoid permission issues
            sudo sed -i '0,/RANDFILE/{s/RANDFILE/\#&/}' /etc/ssl/openssl.cnf

            # Create CSR using the private key
            openssl req -new -key ca.key -subj "/CN=KUBERNETES-CA/O=Kubernetes" -out ca.csr

            # Self sign the csr using its own private key
            openssl x509 -req -in ca.csr -signkey ca.key -CAcreateserial  -out ca.crt -days 1000

 #      Create Client and Server Certificates
 #          The Admin Client Certificate
                {
                # Generate private key for admin user
                openssl genrsa -out admin.key 2048

                # Generate CSR for admin user. Note the OU.
                openssl req -new -key admin.key -subj "/CN=admin/O=system:masters" -out admin.csr

                # Sign certificate for admin user using CA servers private key
                openssl x509 -req -in admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial  -out admin.crt -days 1000
                }
 #          The Controller Manager Client Certificate
                {
                openssl genrsa -out kube-controller-manager.key 2048

                openssl req -new -key kube-controller-manager.key \
                    -subj "/CN=system:kube-controller-manager/O=system:kube-controller-manager" -out kube-controller-manager.csr

                openssl x509 -req -in kube-controller-manager.csr \
                    -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-controller-manager.crt -days 1000
                }            
 #          The Kube Proxy Client Certificate
                {
                openssl genrsa -out kube-proxy.key 2048

                openssl req -new -key kube-proxy.key \
                    -subj "/CN=system:kube-proxy/O=system:node-proxier" -out kube-proxy.csr

                openssl x509 -req -in kube-proxy.csr \
                    -CA ca.crt -CAkey ca.key -CAcreateserial  -out kube-proxy.crt -days 1000
                }

 #          The Scheduler Client Certificate
                {
                openssl genrsa -out kube-scheduler.key 2048

                openssl req -new -key kube-scheduler.key \
                    -subj "/CN=system:kube-scheduler/O=system:kube-scheduler" -out kube-scheduler.csr

                openssl x509 -req -in kube-scheduler.csr -CA ca.crt -CAkey ca.key -CAcreateserial  -out kube-scheduler.crt -days 1000
                }
 #          The Kubernetes API Server Certificate                

                cat > kube-apiserver-openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster
DNS.5 = kubernetes.default.svc.cluster.local
IP.1 = ${API_SERVICE}
IP.2 = ${MASTER_1}
IP.3 = 127.0.0.1
EOF

                {
                openssl genrsa -out kube-apiserver.key 2048

                openssl req -new -key kube-apiserver.key \
                    -subj "/CN=kube-apiserver/O=Kubernetes" -out kube-apiserver.csr -config kube-apiserver-openssl.cnf

                openssl x509 -req -in kube-apiserver.csr \
                -CA ca.crt -CAkey ca.key -CAcreateserial  -out kube-apiserver.crt -extensions v3_req -extfile kube-apiserver-openssl.cnf -days 1000
                }

 #          The Kubelet Client Certificate
 #              Certificate to authenticate against the kubelet from the API Server
                    cat > apiserver-kubelet-client-openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

                    {
                    openssl genrsa -out apiserver-kubelet-client.key 2048

                    openssl req -new -key apiserver-kubelet-client.key \
                        -subj "/CN=kube-apiserver-kubelet-client/O=system:masters" -out apiserver-kubelet-client.csr -config apiserver-kubelet-client-openssl.cnf

                    openssl x509 -req -in apiserver-kubelet-client.csr \
                    -CA ca.crt -CAkey ca.key -CAcreateserial  -out apiserver-kubelet-client.crt -extensions v3_req -extfile apiserver-kubelet-client-openssl.cnf -days 1000
                    }
 #          The ETCD Server Certificate
                cat > etcd-server-openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
IP.1 = ${API_SERVICE}
IP.2 = ${MASTER_1}
IP.3 = 127.0.0.1
EOF

                {
                openssl genrsa -out etcd-server.key 2048

                openssl req -new -key etcd-server.key \
                    -subj "/CN=etcd-server/O=Kubernetes" -out etcd-server.csr -config etcd-server-openssl.cnf

                openssl x509 -req -in etcd-server.csr \
                    -CA ca.crt -CAkey ca.key -CAcreateserial  -out etcd-server.crt -extensions v3_req -extfile etcd-server-openssl.cnf -days 1000
                }

 #          The Service Account Key Pair
                {
                openssl genrsa -out service-account.key 2048

                openssl req -new -key service-account.key \
                    -subj "/CN=service-accounts/O=Kubernetes" -out service-account.csr

                openssl x509 -req -in service-account.csr \
                    -CA ca.crt -CAkey ca.key -CAcreateserial  -out service-account.crt -days 1000
                }      

 #          Copy the appropriate certificates and private keys to each control planeinstance:
 #               {
 #               for instance in $MASTER_1 $MASTER_2; do
 #                   scp ca.crt ca.key kube-apiserver.key kube-apiserver.crt \
 #                       apiserver-kubelet-client.crt apiserver-kubelet-client.key \
 #                       service-account.key service-account.crt \
 #                       etcd-server.key etcd-server.crt \
 #                       kube-controller-manager.key kube-controller-manager.crt \
 #                       kube-scheduler.key kube-scheduler.crt \
 #                       ${instance}:~/
 #               done
 #
 #               for instance in $WORKER_1 $WORKER_2 ; do
 #                   scp ca.crt kube-proxy.crt kube-proxy.key ${instance}:~/
 #               done
 #               }          

#Install kubectl
    #https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
    cd
    mkdir bin;cd bin
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    ./kubectl version -o yaml    
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

 # Generate Kubernetes configuration files, also known as "kubeconfigs" which enable Kubernetes clients to locate and authenticate to the Kubernetes API Servers. 

    sudo mkdir -p /var/lib/kubernetes/pki/
    cd; cd certificates
    sudo cp ca.crt /var/lib/kubernetes/pki/
    sudo cp ca.key /var/lib/kubernetes/pki/
    sudo cp kube-proxy.crt /var/lib/kubernetes/pki/
    sudo cp kube-proxy.key /var/lib/kubernetes/pki/
    sudo cp kube-apiserver.crt /var/lib/kubernetes/pki/
    sudo cp kube-apiserver.key /var/lib/kubernetes/pki/
    sudo cp service-account.crt /var/lib/kubernetes/pki/
    sudo cp service-account.key /var/lib/kubernetes/pki/
    sudo cp apiserver-kubelet-client.crt /var/lib/kubernetes/pki/
    sudo cp apiserver-kubelet-client.key /var/lib/kubernetes/pki/
    sudo cp etcd-server.crt /var/lib/kubernetes/pki/
    sudo cp etcd-server.key /var/lib/kubernetes/pki/
    sudo cp kube-controller-manager.crt /var/lib/kubernetes/pki/
    sudo cp kube-controller-manager.key /var/lib/kubernetes/pki/
    sudo cp kube-scheduler.crt /var/lib/kubernetes/pki/
    sudo cp kube-scheduler.key /var/lib/kubernetes/pki/
    sudo cp admin.crt /var/lib/kubernetes/pki/
    sudo cp admin.key /var/lib/kubernetes/pki/

    sudo chown root:root /var/lib/kubernetes/pki/*
    sudo chmod 600 /var/lib/kubernetes/pki/*    

    cd;mkdir kubeconfig_files
    cd kubeconfig_files

    # https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
    {
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=/var/lib/kubernetes/pki/ca.crt \
        --server=https://${LOADBALANCER}:6443 \
        --kubeconfig=kube-proxy.kubeconfig

    kubectl config set-credentials system:kube-proxy \
        --client-certificate=/var/lib/kubernetes/pki/kube-proxy.crt \
        --client-key=/var/lib/kubernetes/pki/kube-proxy.key \
        --kubeconfig=kube-proxy.kubeconfig

    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-proxy \
        --kubeconfig=kube-proxy.kubeconfig

    kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
    }


    # https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/

    {
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=/var/lib/kubernetes/pki/ca.crt \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=kube-controller-manager.kubeconfig

    kubectl config set-credentials system:kube-controller-manager \
        --client-certificate=/var/lib/kubernetes/pki/kube-controller-manager.crt \
        --client-key=/var/lib/kubernetes/pki/kube-controller-manager.key \
        --kubeconfig=kube-controller-manager.kubeconfig

    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-controller-manager \
        --kubeconfig=kube-controller-manager.kubeconfig

    kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
    }

    # https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/
    {
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=/var/lib/kubernetes/pki/ca.crt \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=kube-scheduler.kubeconfig

    kubectl config set-credentials system:kube-scheduler \
        --client-certificate=/var/lib/kubernetes/pki/kube-scheduler.crt \
        --client-key=/var/lib/kubernetes/pki/kube-scheduler.key \
        --kubeconfig=kube-scheduler.kubeconfig

    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=system:kube-scheduler \
        --kubeconfig=kube-scheduler.kubeconfig

    kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
    }      

    {
    kubectl config set-cluster kubernetes-the-hard-way \
        --certificate-authority=/var/lib/kubernetes/pki/ca.crt \
        --embed-certs=true \
        --server=https://127.0.0.1:6443 \
        --kubeconfig=admin.kubeconfig

    kubectl config set-credentials admin \
        --client-certificate=/var/lib/kubernetes/pki/admin.crt \
        --client-key=/var/lib/kubernetes/pki/admin.key \
        --embed-certs=true \
        --kubeconfig=admin.kubeconfig

    kubectl config set-context default \
        --cluster=kubernetes-the-hard-way \
        --user=admin \
        --kubeconfig=admin.kubeconfig

    kubectl config set-credentials admin --client-key=$HOME/certificates/admin.key --kubeconfig=admin.kubeconfig
    kubectl config use-context default --kubeconfig=admin.kubeconfig
    
    }    

    # For local
    cd;
    mkdir k8s_worker_files
    mkdir k8s_master_files

    cp kubeconfig_files/kube-proxy.kubeconfig k8s_worker_files
    cp kubeconfig_files/kube-controller-manager.kubeconfig k8s_master_files
    cp kubeconfig_files/kube-scheduler.kubeconfig k8s_master_files
    cp kubeconfig_files/admin.kubeconfig k8s_master_files

    # For remote : Distribute the Kubernetes Configuration Files

    for instance in $WORKER_1 $WORKER_2; do
        scp kube-proxy.kubeconfig ${instance}:~/
    done

    for instance in $MASTER_1 $MASTER_2; do
        scp admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig ${instance}:~/
    done   

 # Generating the Data Encryption Config and Key and copy to the masters ( at rest in etcd )
    cd;mkdir other_k8s_installation_files;cd other_k8s_installation_files
    ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
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

    # For local
    cd
    sudo cp other_k8s_installation_files/encryption-config.yaml k8s_master_files/
    sudo cp other_k8s_installation_files/encryption-config.yaml /var/lib/kubernetes/


    # For remote
    for instance in $MASTER_1 $MASTER_2; do
        scp encryption-config.yaml ${instance}:~/
    done

    for instance in $MASTER_1 $MASTER_2; do
        ssh ${instance} sudo mkdir -p /var/lib/kubernetes/
        ssh ${instance} sudo mv encryption-config.yaml /var/lib/kubernetes/
    done    

 ####################### Install Kubernetes components

    cd;mkdir kube_components;cd kube_components


 # Bootstrapping the etcd Cluster (Install It on all controllers - MASTER_1 and MASTER_2)

    
    wget -q --show-progress --https-only --timestamping "https://github.com/coreos/etcd/releases/download/v3.5.3/etcd-v3.5.3-linux-amd64.tar.gz"

    {
    tar -xvf etcd-v3.5.3-linux-amd64.tar.gz
    sudo cp -p etcd-v3.5.3-linux-amd64/etcd* /usr/local/bin/
    }

    cd

    {
    sudo mkdir -p /etc/etcd /var/lib/etcd
    sudo cp certificates/etcd-server.key certificates/etcd-server.crt /etc/etcd/
    sudo chown root:root /etc/etcd/*
    sudo chmod 600 /etc/etcd/*
    sudo chmod 600 /var/lib/kubernetes/pki/*
    sudo ln -s /var/lib/kubernetes/pki/ca.crt /etc/etcd/ca.crt
    }

    # Assign the ip for local network requests
    #INTERNAL_IP=$(ip addr show enp0s8 | grep "inet " | awk '{print $2}' | cut -d / -f 1)

    # Create the systemd unit file (The ${ETCD_NAME} must be enumerated in the --initial-cluster parameter)

    cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/etcd-server.crt \\
  --key-file=/etc/etcd/etcd-server.key \\
  --peer-cert-file=/etc/etcd/etcd-server.crt \\
  --peer-key-file=/etc/etcd/etcd-server.key \\
  --trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster ${ETCD_NAME}=https://${MASTER_1}:2380 \\
  #--initial-cluster ${ETCD_NAME}=https://${MASTER_1}:2380,master-1=https://${MASTER_1}:2380,master-2=https://${MASTER_2}:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


    # Start the etcd server

    {
    sudo systemctl daemon-reload
    sudo systemctl enable etcd
    sudo systemctl start etcd
    }

    # Verify the etcd cluster members

    sudo ETCDCTL_API=3 etcdctl member list \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/etcd/ca.crt \
    --cert=/etc/etcd/etcd-server.crt \
    --key=/etc/etcd/etcd-server.key    


# Provision the Kubernetes Control Plane

    cd
    cd kube_components

    wget -q --show-progress --https-only --timestamping \
    "https://storage.googleapis.com/kubernetes-release/release/v1.24.3/bin/linux/amd64/kube-apiserver" \
    "https://storage.googleapis.com/kubernetes-release/release/v1.24.3/bin/linux/amd64/kube-controller-manager" \
    "https://storage.googleapis.com/kubernetes-release/release/v1.24.3/bin/linux/amd64/kube-scheduler" \
    #"https://storage.googleapis.com/kubernetes-release/release/v1.24.3/bin/linux/amd64/kubectl"


    {
        #chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
        #sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
        chmod +x kube-apiserver kube-controller-manager kube-scheduler
        sudo mv kube-apiserver kube-controller-manager kube-scheduler /usr/local/bin/
    }

    cd

    #{
    #    # Only copy CA keys as we'll need them again for workers.
    #    for c in kube-apiserver service-account apiserver-kubelet-client etcd-server kube-scheduler kube-controller-manager
    #    do
    #        sudo mv "$c.crt" "$c.key" /var/lib/kubernetes/pki/
    #    done
    #    sudo chown root:root /var/lib/kubernetes/pki/*
    #    sudo chmod 600 /var/lib/kubernetes/pki/*
    #}

    #INTERNAL_IP=$(ip addr show enp0s8 | grep "inet " | awk '{print $2}' | cut -d / -f 1)
    #INTERNAL_IP=$MASTER_1
    #LOADBALANCER=$(dig +short loadbalancer)

    #MASTER_1=$(dig +short master-1)
    #MASTER_2=$(dig +short master-2)  

    #POD_CIDR=10.244.0.0/16
    #SERVICE_CIDR=10.96.0.0/16      


    cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=2 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/pki/ca.crt \\
  --enable-admission-plugins=NodeRestriction,ServiceAccount \\
  --enable-bootstrap-token-auth=true \\
  --etcd-cafile=/var/lib/kubernetes/pki/ca.crt \\
  --etcd-certfile=/var/lib/kubernetes/pki/etcd-server.crt \\
  --etcd-keyfile=/var/lib/kubernetes/pki/etcd-server.key \\
  --etcd-servers=https://${MASTER_1}:2379,https://${MASTER_2}:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/pki/ca.crt \\
  --kubelet-client-certificate=/var/lib/kubernetes/pki/apiserver-kubelet-client.crt \\
  --kubelet-client-key=/var/lib/kubernetes/pki/apiserver-kubelet-client.key \\
  --runtime-config=api/all=true \\
  --service-account-key-file=/var/lib/kubernetes/pki/service-account.crt \\
  --service-account-signing-key-file=/var/lib/kubernetes/pki/service-account.key \\
  --service-account-issuer=https://${LOADBALANCER}:6443 \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/pki/kube-apiserver.crt \\
  --tls-private-key-file=/var/lib/kubernetes/pki/kube-apiserver.key \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


    cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --allocate-node-cidrs=true \\
  --authentication-kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --authorization-kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --bind-address=127.0.0.1 \\
  --client-ca-file=/var/lib/kubernetes/pki/ca.crt \\
  --cluster-cidr=${POD_CIDR} \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/pki/ca.crt \\
  --cluster-signing-key-file=/var/lib/kubernetes/pki/ca.key \\
  --controllers=*,bootstrapsigner,tokencleaner \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --node-cidr-mask-size=24 \\
  --requestheader-client-ca-file=/var/lib/kubernetes/pki/ca.crt \\
  --root-ca-file=/var/lib/kubernetes/pki/ca.crt \\
  --service-account-private-key-file=/var/lib/kubernetes/pki/service-account.key \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF



    cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --kubeconfig=/var/lib/kubernetes/kube-scheduler.kubeconfig \\
  --leader-elect=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


    cd ~/kubeconfig_files
    sudo cp kube-controller-manager.kubeconfig /var/lib/kubernetes/
    sudo cp kube-scheduler.kubeconfig /var/lib/kubernetes/


    {
    sudo systemctl daemon-reload
    sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
    sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
    }

    kubectl get componentstatuses --kubeconfig ~/kubeconfig_files/admin.kubeconfig

    cd
    mkdir containerd
    cd containerd

    {


    wget -q --show-progress --https-only --timestamping \
        https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz \
        https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz \
        https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64

    sudo mkdir -p /opt/cni/bin

    sudo chmod +x runc.amd64
    sudo cp -p runc.amd64 /usr/local/bin/runc

    sudo tar -xzvf containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz -C /usr/local
    sudo tar -xzvf cni-plugins-linux-amd64-v${CNI_VERSION}.tgz -C /opt/cni/bin
    }    


    cat <<EOF | sudo tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
# Comment TasksMax if your systemd version does not supports it.
# Only systemd 226 and above support this version.
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF


    {
    sudo systemctl enable containerd
    sudo systemctl start containerd
    }

cd
mkdir worker_files
cd worker_files


 # Configure workers
    cat > openssl-worker-1.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = worker-1
DNS.2 = kubernetes
IP.1 = ${WORKER_1}
EOF



openssl genrsa -out worker-1.key 2048
openssl req -new -key worker-1.key -subj "/CN=system:node:worker-1/O=system:nodes" -out worker-1.csr -config openssl-worker-1.cnf
openssl x509 -req -in worker-1.csr -CA ~/certificates/ca.crt -CAkey ~/certificates/ca.key -CAcreateserial  -out worker-1.crt -extensions v3_req -extfile openssl-worker-1.cnf -days 1000

sudo chown root:root worker-1.crt
sudo chmod 600 worker-1.key

sudo cp -p worker-1.crt /var/lib/kubernetes/pki/ 
sudo cp -p worker-1.key /var/lib/kubernetes/pki/ 

{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=/var/lib/kubernetes/pki/ca.crt \
    --server=https://${LOADBALANCER}:6443 \
    --kubeconfig=worker-1.kubeconfig

  kubectl config set-credentials system:node:worker-1 \
    --client-certificate=/var/lib/kubernetes/pki/worker-1.crt \
    --client-key=/var/lib/kubernetes/pki/worker-1.key \
    --kubeconfig=worker-1.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:worker-1 \
    --kubeconfig=worker-1.kubeconfig

  kubectl config set-credentials system:node:worker-1 --client-key=$HOME/worker_files/worker-1.key --kubeconfig=worker-1.kubeconfig
  kubectl config use-context default --kubeconfig=worker-1.kubeconfig
}



    scp ca.crt worker-1.crt worker-1.key worker-1.kubeconfig worker-1:~/

    cd
    mkdir worker_bin
    cd worker_bin

    wget -q --show-progress --https-only --timestamping \
        https://storage.googleapis.com/kubernetes-release/release/v1.24.3/bin/linux/amd64/kubectl \
        https://storage.googleapis.com/kubernetes-release/release/v1.24.3/bin/linux/amd64/kube-proxy \
        https://storage.googleapis.com/kubernetes-release/release/v1.24.3/bin/linux/amd64/kubelet


    chmod 777 *


    sudo mkdir -p \
    /var/lib/kubelet \
    /var/lib/kube-proxy \
    /var/lib/kubernetes/pki \
    /var/run/kubernetes         



    {
  #sudo mv ${HOSTNAME}.key ${HOSTNAME}.crt /var/lib/kubernetes/pki/
  #sudo mv ${HOSTNAME}.kubeconfig /var/lib/kubelet/kubelet.kubeconfig

  sudo cp ~/worker_files/worker-1.kubeconfig /var/lib/kubelet/kubelet.kubeconfig

  #sudo mv ca.crt /var/lib/kubernetes/pki/
  #sudo mv kube-proxy.crt kube-proxy.key /var/lib/kubernetes/pki/
  #sudo chown root:root /var/lib/kubernetes/pki/*
  #sudo chmod 600 /var/lib/kubernetes/pki/*

  sudo chown root:root /var/lib/kubelet/*
  sudo chmod 600 /var/lib/kubelet/*
    }


cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
hostname-override: worker-1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /var/lib/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
clusterDomain: cluster.local
clusterDNS:
  - ${CLUSTER_DNS}
resolvConf: /run/systemd/resolve/resolv.conf
runtimeRequestTimeout: "15m"
tlsCertFile: /var/lib/kubernetes/pki/${WORKER_NAME}.crt
tlsPrivateKeyFile: /var/lib/kubernetes/pki/${WORKER_NAME}.key
registerNode: true
EOF

cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --kubeconfig=/var/lib/kubelet/kubelet.kubeconfig \\
  --v=2 \\
  --hostname-override worker-1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo cp -p ~/k8s_worker_files/kube-proxy.kubeconfig /var/lib/kube-proxy/

cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kube-proxy.kubeconfig"
mode: "iptables"
clusterCIDR: ${POD_CIDR}
EOF




cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


sudo cp -p ~/worker_bin/kube-proxy /usr/local/bin/kube-proxy
sudo swapoff -a  

cd
cd worker_files
chmod 600 worker-1.key
sudo chown root:root worker-1.key
sudo cp -p worker-1.key /var/lib/kubelet/

{
  sudo systemctl daemon-reload
  sudo systemctl enable kubelet kube-proxy
  sudo systemctl start kubelet kube-proxy
}

#sudo apt-get remove apparmor apparmor-utils -y
#sudo ./kubelet --config=/var/lib/kubelet/kubelet-config.yaml --kubeconfig ../worker_files/worker-1.kubeconfig --container-runtime-endpoint=unix:///run/containerd/containerd.sock --hostname-override worker-1

cp kubeconfig_files/admin.kubeconfig ./.kube/config

#kubectl get nodes --kubeconfig ~/kubeconfig_files/admin.kubeconfig
kubectl get nodes


# Install wave network solution

cd
mkdir yaml
cd yaml
wget https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s-1.11.yaml
kubectl apply -f weave-daemonset-k8s-1.11.yaml



# RBAC for Kubelet Authorization

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kube-apiserver
EOF

# Core DNS

wget https://raw.githubusercontent.com/mmumshad/kubernetes-the-hard-way/master/deployments/coredns.yaml
kubectl apply -f coredns.yaml

#sudo unlink /etc/resolv.conf
#sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

sudo /bin/sh -c 'echo "127.0.0.1 worker-1" >> /etc/hosts'
kubectl exec -ti busybox -- nslookup kubernetes


# smoke tests

kubectl create secret generic kubernetes-the-hard-way \
  --from-literal="mykey=mydata"

sudo ETCDCTL_API=3 etcdctl get \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key\
  /registry/secrets/default/kubernetes-the-hard-way | hexdump -C

kubectl delete secret kubernetes-the-hard-way

kubectl create deployment nginx --image=nginx:1.23.1
kubectl get pods -l app=nginx
kubectl expose deploy nginx --type=NodePort --port 80
PORT_NUMBER=$(kubectl get svc -l app=nginx -o jsonpath="{.items[0].spec.ports[0].nodePort}")
curl http://worker-1:$PORT_NUMBER

POD_NAME=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].metadata.name}")
kubectl logs $POD_NAME

kubectl exec -ti $POD_NAME -- nginx -v

# k9scli

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
(echo; echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"') >> /home/user/.bashrc
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
sudo apt-get install build-essential
brew install derailed/k9s/k9s
k9s
